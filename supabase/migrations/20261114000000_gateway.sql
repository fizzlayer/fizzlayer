-- Gateway control-plane tables. A workspace is the existing customer account:
-- one gateway.workspaces row per fizz_customers row. The MCP data plane is
-- unmodified agentgateway; these tables are what fizz-config and fizz-guard read.
-- Upstream API keys stay in gateway.secrets as ciphertext. This migration does
-- not decrypt them, and the config renderer refuses to copy them into YAML.
--
-- Authenticated table privileges stay revoked, matching the rest of the API.
-- The policies below apply when a grant is added later. gateway_runtime is the
-- server role fizz-guard and fizz-config use when they are not on the service
-- role. It is NOLOGIN until an operator sets a password outside this file.

create schema if not exists gateway;

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'gateway_runtime') then
    create role gateway_runtime nologin nosuperuser nocreatedb nocreaterole;
  end if;
end
$$;

revoke all on schema gateway from public;
grant usage on schema gateway to anon, authenticated, service_role, gateway_runtime;

create table gateway.workspaces (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null unique references public.fizz_customers(id) on delete cascade,
  created_at timestamptz not null default now()
);

create table gateway.gateways (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references gateway.workspaces(id) on delete cascade,
  name text not null check (name ~ '^[a-z][a-z0-9-]{0,40}$'),
  mode text not null check (mode in ('shared', 'dedicated', 'selfhost')),
  region text check (region is null or char_length(region) between 1 and 40),
  public_url text not null check (
    char_length(public_url) between 8 and 300
    and public_url ~ '^https?://[^[:space:]]+$'
    and public_url !~ '[[:cntrl:]]'
  ),
  listen_port integer not null default 3000 check (listen_port between 1 and 65535),
  status text not null default 'active' check (status in ('active', 'disabled')),
  config_revision bigint not null default 1 check (config_revision >= 1),
  ag_version text check (ag_version is null or ag_version ~ '^[0-9]+\.[0-9]+\.[0-9]+$'),
  created_at timestamptz not null default now()
);
create index gateways_workspace_idx on gateway.gateways(workspace_id);

create table gateway.servers (
  id uuid primary key default gen_random_uuid(),
  gateway_id uuid not null references gateway.gateways(id) on delete cascade,
  name text not null check (name ~ '^[a-z][a-z0-9_-]{0,40}$'),
  transport text not null check (transport in ('http', 'sse', 'stdio')),
  url_or_cmd text not null check (
    char_length(url_or_cmd) between 1 and 500 and url_or_cmd !~ '[[:cntrl:]]'
  ),
  command_args text[] not null default '{}',
  catalog_ref text check (catalog_ref is null or char_length(catalog_ref) <= 200),
  auth_kind text not null default 'none' check (auth_kind in ('none', 'key', 'passthrough')),
  enabled boolean not null default true,
  created_at timestamptz not null default now(),
  unique (gateway_id, name),
  check (command_args = '{}'::text[] or array_to_string(command_args, '') !~ '[[:cntrl:]]')
);
create index servers_gateway_idx on gateway.servers(gateway_id);

create table gateway.secrets (
  id uuid primary key default gen_random_uuid(),
  server_id uuid not null references gateway.servers(id) on delete cascade,
  ciphertext bytea not null check (octet_length(ciphertext) between 1 and 65536),
  key_id text not null check (char_length(key_id) between 1 and 80),
  created_at timestamptz not null default now()
);

create table gateway.policies (
  id uuid primary key default gen_random_uuid(),
  gateway_id uuid not null references gateway.gateways(id) on delete cascade,
  server_id uuid references gateway.servers(id) on delete cascade,
  tool_name text not null check (tool_name = '*' or tool_name ~ '^[A-Za-z0-9_.:-]{1,128}$'),
  effect text not null check (effect in ('allow', 'deny', 'approve')),
  created_at timestamptz not null default now()
);
create unique index policies_gateway_server_tool_idx
  on gateway.policies (gateway_id, coalesce(server_id, '00000000-0000-0000-0000-000000000000'::uuid), tool_name);
create index policies_gateway_idx on gateway.policies(gateway_id);

create table gateway.tool_pins (
  server_id uuid not null references gateway.servers(id) on delete cascade,
  tool_name text not null check (tool_name ~ '^[A-Za-z0-9_.:-]{1,128}$'),
  pin_sha256 text not null check (pin_sha256 ~ '^[0-9a-f]{64}$'),
  approved_at timestamptz,
  primary key (server_id, tool_name)
);

create table gateway.client_tokens (
  id uuid primary key default gen_random_uuid(),
  gateway_id uuid not null references gateway.gateways(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 80),
  jti text not null unique check (jti ~ '^[0-9a-f-]{36}$'),
  expires_at timestamptz not null,
  revoked_at timestamptz,
  created_at timestamptz not null default now()
);
create index client_tokens_active_idx on gateway.client_tokens(gateway_id, jti) where revoked_at is null;

create table gateway.approvals (
  id uuid primary key default gen_random_uuid(),
  gateway_id uuid not null references gateway.gateways(id) on delete cascade,
  workspace_id uuid not null references gateway.workspaces(id) on delete cascade,
  server_name text not null check (char_length(server_name) between 1 and 80),
  tool_name text not null check (char_length(tool_name) between 1 and 128),
  args_hash text not null check (args_hash ~ '^[0-9a-f]{64}$'),
  status text not null check (status in ('pending', 'approved', 'denied', 'consumed', 'expired')),
  decided_by uuid,
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);
create index approvals_lookup_idx
  on gateway.approvals(gateway_id, server_name, tool_name, args_hash, status);

create table gateway.audit_log (
  id uuid primary key default gen_random_uuid(),
  gateway_id uuid not null references gateway.gateways(id) on delete cascade,
  workspace_id uuid not null references gateway.workspaces(id) on delete cascade,
  server_name text not null check (char_length(server_name) between 1 and 80),
  tool_name text not null check (char_length(tool_name) between 1 and 128),
  subject text check (subject is null or char_length(subject) <= 80),
  jti text check (jti is null or char_length(jti) <= 80),
  args_hash text not null check (args_hash ~ '^[0-9a-f]{64}$'),
  args_preview text not null default '' check (char_length(args_preview) <= 120),
  decision text not null check (decision in ('allow', 'deny', 'approval_required', 'approval_consumed')),
  reason text check (reason is null or char_length(reason) <= 400),
  created_at timestamptz not null default now()
);
create index audit_gateway_created_idx on gateway.audit_log(gateway_id, created_at desc);

create table gateway.usage_daily (
  gateway_id uuid not null references gateway.gateways(id) on delete cascade,
  usage_date date not null,
  tool_calls integer not null default 0 check (tool_calls >= 0),
  approvals integer not null default 0 check (approvals >= 0),
  primary key (gateway_id, usage_date)
);

comment on table gateway.secrets is
  'Envelope ciphertext for an upstream MCP credential. Plaintext is never stored here.';
comment on column gateway.audit_log.args_preview is
  'Key names only. Argument values are not stored.';

-- Ownership check used by authenticated policies. security definer so the check
-- still works when the browser role cannot select fizz_customers. It returns a
-- boolean and does not reveal other customers.
create function gateway.owns_customer(p_customer uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_customer is not null
    and coalesce((select auth.jwt() ->> 'is_anonymous'), 'false') <> 'true'
    and exists (
      select 1 from public.fizz_customers c
      where c.id = p_customer and c.auth_user_id = (select auth.uid())
    );
$$;

revoke all on function gateway.owns_customer(uuid) from public;
grant execute on function gateway.owns_customer(uuid) to authenticated, service_role;

-- The runtime role cannot read fizz_customers under that table's policies.
-- This returns one subject for a gateway the caller already named.
create function gateway.client_subject(p_gateway uuid)
returns table (workspace_id uuid, user_id uuid, public_url text)
language sql
stable
security definer
set search_path = ''
as $$
  select g.workspace_id, c.auth_user_id, g.public_url
  from gateway.gateways g
  join gateway.workspaces w on w.id = g.workspace_id
  join public.fizz_customers c on c.id = w.customer_id
  where g.id = p_gateway and g.status = 'active';
$$;

revoke all on function gateway.client_subject(uuid) from public;
grant execute on function gateway.client_subject(uuid) to gateway_runtime, service_role;

alter table gateway.workspaces enable row level security;
alter table gateway.gateways enable row level security;
alter table gateway.servers enable row level security;
alter table gateway.secrets enable row level security;
alter table gateway.policies enable row level security;
alter table gateway.tool_pins enable row level security;
alter table gateway.client_tokens enable row level security;
alter table gateway.approvals enable row level security;
alter table gateway.audit_log enable row level security;
alter table gateway.usage_daily enable row level security;

create policy workspaces_owner on gateway.workspaces
  for all to authenticated
  using (gateway.owns_customer(customer_id))
  with check (gateway.owns_customer(customer_id));

create policy gateways_owner on gateway.gateways
  for all to authenticated
  using (
    exists (
      select 1 from gateway.workspaces w
      where w.id = workspace_id and gateway.owns_customer(w.customer_id)
    )
  )
  with check (
    exists (
      select 1 from gateway.workspaces w
      where w.id = workspace_id and gateway.owns_customer(w.customer_id)
    )
  );

create policy servers_owner on gateway.servers
  for all to authenticated
  using (
    exists (
      select 1 from gateway.gateways g
      join gateway.workspaces w on w.id = g.workspace_id
      where g.id = gateway_id and gateway.owns_customer(w.customer_id)
    )
  )
  with check (
    exists (
      select 1 from gateway.gateways g
      join gateway.workspaces w on w.id = g.workspace_id
      where g.id = gateway_id and gateway.owns_customer(w.customer_id)
    )
  );

create policy policies_owner on gateway.policies
  for all to authenticated
  using (
    exists (
      select 1 from gateway.gateways g
      join gateway.workspaces w on w.id = g.workspace_id
      where g.id = gateway_id and gateway.owns_customer(w.customer_id)
    )
  )
  with check (
    exists (
      select 1 from gateway.gateways g
      join gateway.workspaces w on w.id = g.workspace_id
      where g.id = gateway_id and gateway.owns_customer(w.customer_id)
    )
    and (
      server_id is null or exists (
        select 1 from gateway.servers s
        where s.id = server_id and s.gateway_id = gateway.policies.gateway_id
      )
    )
  );

create policy tool_pins_owner on gateway.tool_pins
  for all to authenticated
  using (
    exists (
      select 1 from gateway.servers s
      join gateway.gateways g on g.id = s.gateway_id
      join gateway.workspaces w on w.id = g.workspace_id
      where s.id = server_id and gateway.owns_customer(w.customer_id)
    )
  )
  with check (
    exists (
      select 1 from gateway.servers s
      join gateway.gateways g on g.id = s.gateway_id
      join gateway.workspaces w on w.id = g.workspace_id
      where s.id = server_id and gateway.owns_customer(w.customer_id)
    )
  );

create policy client_tokens_owner_select on gateway.client_tokens
  for select to authenticated
  using (
    exists (
      select 1 from gateway.gateways g
      join gateway.workspaces w on w.id = g.workspace_id
      where g.id = gateway_id and gateway.owns_customer(w.customer_id)
    )
  );

create policy client_tokens_owner_update on gateway.client_tokens
  for update to authenticated
  using (
    exists (
      select 1 from gateway.gateways g
      join gateway.workspaces w on w.id = g.workspace_id
      where g.id = gateway_id and gateway.owns_customer(w.customer_id)
    )
  )
  with check (
    exists (
      select 1 from gateway.gateways g
      join gateway.workspaces w on w.id = g.workspace_id
      where g.id = gateway_id and gateway.owns_customer(w.customer_id)
    )
  );

create policy approvals_owner_select on gateway.approvals
  for select to authenticated
  using (
    exists (
      select 1 from gateway.workspaces w
      where w.id = workspace_id and gateway.owns_customer(w.customer_id)
    )
  );

create policy approvals_owner_update on gateway.approvals
  for update to authenticated
  using (
    exists (
      select 1 from gateway.workspaces w
      where w.id = workspace_id and gateway.owns_customer(w.customer_id)
    )
  )
  with check (
    exists (
      select 1 from gateway.workspaces w
      where w.id = workspace_id and gateway.owns_customer(w.customer_id)
    )
    and exists (
      select 1 from gateway.gateways g
      where g.id = gateway_id and g.workspace_id = gateway.approvals.workspace_id
    )
  );

create policy audit_owner_select on gateway.audit_log
  for select to authenticated
  using (
    exists (
      select 1 from gateway.workspaces w
      where w.id = workspace_id and gateway.owns_customer(w.customer_id)
    )
  );

create policy usage_owner_select on gateway.usage_daily
  for select to authenticated
  using (
    exists (
      select 1 from gateway.gateways g
      join gateway.workspaces w on w.id = g.workspace_id
      where g.id = gateway_id and gateway.owns_customer(w.customer_id)
    )
  );

-- The runtime role is the server, not a tenant. Grants below are the operation
-- boundary. There is no authenticated policy on gateway.secrets.
create policy runtime_workspaces on gateway.workspaces for all to gateway_runtime using (true) with check (true);
create policy runtime_gateways on gateway.gateways for all to gateway_runtime using (true) with check (true);
create policy runtime_servers on gateway.servers for all to gateway_runtime using (true) with check (true);
create policy runtime_policies on gateway.policies for all to gateway_runtime using (true) with check (true);
create policy runtime_tokens on gateway.client_tokens for all to gateway_runtime using (true) with check (true);
create policy runtime_approvals on gateway.approvals for all to gateway_runtime using (true) with check (true);
create policy runtime_audit on gateway.audit_log for all to gateway_runtime using (true) with check (true);
create policy runtime_usage on gateway.usage_daily for all to gateway_runtime using (true) with check (true);

revoke all on all tables in schema gateway from public, anon, authenticated;
grant all on all tables in schema gateway to service_role;
grant select on gateway.workspaces, gateway.gateways, gateway.servers, gateway.policies to gateway_runtime;
grant select, insert on gateway.client_tokens, gateway.audit_log to gateway_runtime;
grant select, insert, update on gateway.approvals, gateway.usage_daily to gateway_runtime;
