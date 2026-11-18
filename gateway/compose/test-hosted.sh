#!/bin/sh
# Shared-fleet compose test. Tokens and the upstream key are written to .env
# and are not printed.
set -eu
cd "$(dirname "$0")"

compose() {
  docker compose --env-file .env -f compose.hosted.yaml "$@"
}

limited() {
  secs=$1
  shift
  timeout "$secs" docker compose --env-file .env -f compose.hosted.yaml "$@"
}

cleanup() {
  status=$?
  if [ "$status" -ne 0 ]; then
    compose logs --no-color --tail 200 \
      agentgateway fizz-agent fizz-guard control-plane sample-mcp sample-b sample-extra hosted-e2e \
      | sed -E \
        -e 's/eyJ[A-Za-z0-9_-]+/[redacted]/g' \
        -e 's/fizz_reg_[0-9a-fA-F]+/[redacted]/g' \
        -e 's/fizz_fleet_[0-9a-fA-F]+/[redacted]/g' \
        -e 's/upstream-token-sample/[redacted]/g' \
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
python3 - <<'PY'
import os
import secrets
from pathlib import Path
path = Path(".env")
text = path.read_text() if path.exists() else ""
lines = [
    line for line in text.splitlines()
    if not line.startswith("FIZZ_FLEET_TOKEN=")
    and not line.startswith("FIZZ_UPSTREAM_KEY=")
]
if not any(line.startswith("FIZZ_FLEET_TOKEN=") for line in text.splitlines()):
    lines.append("FIZZ_FLEET_TOKEN=fizz_fleet_" + secrets.token_hex(32))
else:
    lines.append(next(line for line in text.splitlines() if line.startswith("FIZZ_FLEET_TOKEN=")))
if not any(line.startswith("FIZZ_UPSTREAM_KEY=") for line in text.splitlines()):
    lines.append("FIZZ_UPSTREAM_KEY=upstream-token-sample")
else:
    lines.append(next(line for line in text.splitlines() if line.startswith("FIZZ_UPSTREAM_KEY=")))
path.write_text("\n".join(lines) + "\n")
os.chmod(path, 0o600)
PY

compose build
limited 180 up -d --wait postgres control-plane fizz-guard sample-mcp sample-b sample-extra
limited 180 up -d --wait fizz-agent
limited 240 up -d --no-deps agentgateway
limited 240 run --rm --no-deps hosted-e2e
