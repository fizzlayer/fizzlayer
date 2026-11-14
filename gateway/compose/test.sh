#!/bin/sh
# Build the local images, check gateway RLS, then run the MCP probe.
# Database passwords are written to compose/.env and are not printed.
set -eu
cd "$(dirname "$0")"

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

docker compose --env-file .env -f compose.yaml build
docker compose --env-file .env -f compose.yaml up -d --wait postgres
docker compose --env-file .env -f compose.yaml exec -T postgres \
  psql -U fizz -d fizz -v ON_ERROR_STOP=1 -f /tests/gateway_rls.sql

set +e
docker compose --env-file .env -f compose.yaml up --abort-on-container-exit --exit-code-from e2e
status=$?
set -e
if [ "$status" -ne 0 ]; then
  docker compose --env-file .env -f compose.yaml logs --no-color --tail 200 \
    agentgateway fizz-guard sample-mcp fizz-config fizz-config-watch e2e \
    | sed -E \
      -e 's/eyJ[A-Za-z0-9_-]+/[redacted]/g' \
      -e 's#postgres://[^[:space:]@]+@#postgres://[redacted]@#g' \
      -e 's/(PASSWORD|password|token|Bearer)[^[:space:]]*/[redacted]/g'
fi
exit "$status"
