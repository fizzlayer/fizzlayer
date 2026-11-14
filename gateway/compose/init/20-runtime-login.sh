#!/bin/sh
# Gives the local server role a password. The value comes from the compose
# environment and is not printed. Production sets this outside the migration.
set -eu
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<SQL
alter role gateway_runtime with login password '${POSTGRES_PASSWORD}';
SQL
