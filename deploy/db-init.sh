#!/bin/sh
# First-boot roles for PostgREST and pgcrypto. Runs only when the data volume is empty.
set -eu
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<SQL
create schema if not exists extensions;
create schema if not exists auth;
create extension if not exists pgcrypto with schema extensions;
do \$\$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin noinherit bypassrls;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticator') then
    create role authenticator noinherit login password '${AUTHENTICATOR_PASSWORD}';
  end if;
end
\$\$;
grant anon, authenticated, service_role to authenticator;
grant usage on schema public, extensions to anon, authenticated, service_role, authenticator;
SQL
