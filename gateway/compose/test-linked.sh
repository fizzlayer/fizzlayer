#!/bin/sh
# Linked-mode compose test. A mock control plane serves the config pull.
# fizz-agent writes the file, agentgateway hot-reloads it, and a bad document
# is rejected. The registration token is written to .env and is not printed.
set -eu
cd "$(dirname "$0")"

compose() {
  docker compose --env-file .env -f compose.linked.yaml "$@"
}

limited() {
  secs=$1
  shift
  timeout "$secs" docker compose --env-file .env -f compose.linked.yaml "$@"
}

cleanup() {
  status=$?
  if [ "$status" -ne 0 ]; then
    compose logs --no-color --tail 200 \
      agentgateway fizz-agent fizz-guard control-plane sample-mcp sample-extra linked-e2e \
      | sed -E \
        -e 's/eyJ[A-Za-z0-9_-]+/[redacted]/g' \
        -e 's/fizz_reg_[0-9a-fA-F]+/[redacted]/g' \
        -e 's#postgres://[^[:space:]@]+@#postgres://[redacted]@#g' \
        -e 's/(PASSWORD|password|token|Bearer)[^[:space:]]*/[redacted]/g' \
      || true
  fi
  compose down --remove-orphans >/dev/null 2>&1 || true
  exit "$status"
}
trap cleanup EXIT

if [ ! -f .env ]; then
  umask 077
  python3 - <<'PY'
import os
import secrets
from pathlib import Path
password = secrets.token_hex(24)
Path(".env").write_text(
    "POSTGRES_PASSWORD=%s\nDATABASE_URL=postgres://gateway_runtime:%s@postgres:5432/fizz\n"
    % (password, password)
)
os.chmod(".env", 0o600)
PY
fi
if ! grep -q '^DATABASE_URL=.\+' .env; then
  echo "compose .env is missing DATABASE_URL" >&2
  exit 1
fi
if ! grep -q '^FIZZ_REGISTRATION_TOKEN=fizz_reg_[0-9a-f]\{64\}$' .env; then
  umask 077
  python3 - <<'PY'
import os
import secrets
from pathlib import Path
path = Path(".env")
text = path.read_text()
lines = [line for line in text.splitlines() if not line.startswith("FIZZ_REGISTRATION_TOKEN=")]
token = "fizz_reg_" + secrets.token_hex(32)
lines.append("FIZZ_REGISTRATION_TOKEN=%s" % token)
path.write_text("\n".join(lines) + "\n")
os.chmod(path, 0o600)
PY
fi

compose build
limited 180 up -d --wait postgres control-plane fizz-guard sample-mcp sample-extra
limited 180 up -d --wait fizz-agent
limited 180 up -d --no-deps agentgateway
limited 180 run --rm --no-deps linked-e2e
