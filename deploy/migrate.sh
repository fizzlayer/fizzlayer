#!/bin/sh
# Apply supabase/migrations after GoTrue has created auth.users.
set -eu
export PGPASSWORD="${POSTGRES_PASSWORD}"
echo "waiting for auth.users"
ready=0
for _ in $(seq 1 60); do
  if psql -h db -U postgres -d postgres -tAc "select to_regprocedure('auth.uid()') is not null" | grep -q t; then
    ready=1
    break
  fi
  sleep 2
done
if [ "$ready" != 1 ]; then
  echo "auth.uid() did not appear; GoTrue did not finish" >&2
  exit 1
fi
psql -h db -U postgres -d postgres -v ON_ERROR_STOP=1 -c \
  "create table if not exists public.fizz_schema_migrations (version text primary key, applied_at timestamptz not null default now());"
for file in /migrations/*.sql; do
  version=$(basename "$file")
  applied=$(psql -h db -U postgres -d postgres -tAc \
    "select 1 from public.fizz_schema_migrations where version = '${version}'")
  if [ "$applied" = "1" ]; then
    echo "skip $version"
    continue
  fi
  echo "apply $version"
  psql -h db -U postgres -d postgres -v ON_ERROR_STOP=1 --single-transaction -f "$file"
  psql -h db -U postgres -d postgres -v ON_ERROR_STOP=1 -c \
    "insert into public.fizz_schema_migrations (version) values ('${version}')"
done
echo "migrations applied"
