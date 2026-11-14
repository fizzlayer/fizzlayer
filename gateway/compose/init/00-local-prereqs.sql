-- Local Postgres stand-in for the pieces of Supabase this migration touches.
-- Supabase Cloud already has auth.uid(), auth.jwt(), and these roles.

create schema if not exists auth;

create or replace function auth.uid()
returns uuid
language sql
stable
as $$
  select nullif(
    coalesce(
      nullif(current_setting('request.jwt.claim.sub', true), ''),
      (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
    ),
    ''
  )::uuid;
$$;

create or replace function auth.jwt()
returns jsonb
language sql
stable
as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb);
$$;

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin bypassrls;
  end if;
end
$$;

create table if not exists auth.users (
  id uuid primary key,
  email text,
  encrypted_password text,
  is_anonymous boolean not null default false,
  deleted_at timestamptz,
  banned_until timestamptz
);

create table if not exists public.fizz_customers (
  id uuid primary key default gen_random_uuid(),
  username text not null unique check (username ~ '^[a-z][a-z0-9_]{2,23}$'),
  auth_user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
