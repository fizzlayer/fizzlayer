#!/bin/sh
# Build the local images, check gateway RLS, then run the MCP probe.
# Database passwords are written to compose/.env and are not printed.
#
# fizz-config is a oneshot that exits 0 after writing the YAML. Compose's
# --abort-on-container-exit treats that exit as the end of the project, tears
# the network down, and then does not return when the probe itself exits.
# Run the renderer and the probe as one-shots instead.
set -eu
cd "$(dirname "$0")"

compose() {
  docker compose --env-file .env -f compose.yaml "$@"
}

limited() {
  secs=$1
  shift
  timeout "$secs" docker compose --env-file .env -f compose.yaml "$@"
}

cleanup() {
  status=$?
  if [ "$status" -ne 0 ]; then
    compose logs --no-color --tail 200 \
      agentgateway fizz-guard sample-mcp fizz-config fizz-config-watch e2e \
      | sed -E \
        -e 's/eyJ[A-Za-z0-9_-]+/[redacted]/g' \
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
admin = secrets.token_hex(24)
Path(".env").write_text(
    "POSTGRES_PASSWORD=%s\nDATABASE_URL=postgres://gateway_runtime:%s@postgres:5432/fizz\nFIZZ_GUARD_ADMIN_TOKEN=%s\n"
    % (password, password, admin)
)
os.chmod(".env", 0o600)
PY
fi
if ! grep -q '^FIZZ_GUARD_ADMIN_TOKEN=.\+' .env; then
  umask 077
  python3 - <<'PY'
import os
import secrets
from pathlib import Path
path = Path(".env")
admin = secrets.token_hex(24)
text = path.read_text()
if not text.endswith("\n"):
    text += "\n"
path.write_text(text + "FIZZ_GUARD_ADMIN_TOKEN=%s\n" % admin)
os.chmod(path, 0o600)
PY
fi

compose build
compose up -d --wait postgres
compose exec -T postgres \
  psql -U fizz -d fizz -v ON_ERROR_STOP=1 -f /tests/gateway_rls.sql

limited 180 up -d --wait fizz-guard sample-mcp
limited 180 run --rm --no-deps fizz-config
limited 180 up -d --no-deps --wait agentgateway
limited 180 run --rm --no-deps e2e
