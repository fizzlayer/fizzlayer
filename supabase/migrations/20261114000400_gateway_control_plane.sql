-- Gateway control plane: plan limits, workspace members, and registration tokens.
-- The Rust API calls public.fizz_gateway as the service role. Authenticated
-- clients still have no table grants. RLS is in place for a later grant.
--
-- Policy rows this API writes, matching 20261114000300_gateway_policies.sql:
--   gateway.policies (gateway_id, server_id, tool_name, effect, notify_channel)
--   server_id null means every server on the gateway.
--   tool_name is '*' or a single tool name.
--   effect is allow, deny, or approve.
--   notify_channel is log, webhook, or phone (default log).
-- fizz-guard reads server name, tool_name, effect, and notify_channel.
-- Pin and approval endpoints update the tables that migration already created:
--   gateway.tool_pins, gateway.pin_alerts, gateway.approvals,
--   and gateway.gateways.unreviewed_tools.
-- This file does not create those tables.

alter table public.fizz_plans
  add column gateway_limit integer check (gateway_limit is null or gateway_limit >= 0),
  add column mcp_server_limit integer check (mcp_server_limit is null or mcp_server_limit >= 0),
  add column gateway_stdio boolean not null default false,
  add column gateway_dedicated boolean not null default false,
  add column seat_limit integer check (seat_limit is null or seat_limit >= 0),
  add column tool_calls_per_month integer check (tool_calls_per_month is null or tool_calls_per_month >= 0),
  add column phone_calls_per_month integer check (phone_calls_per_month is null or phone_calls_per_month >= 0),
  add column audit_retention_days integer check (audit_retention_days is null or audit_retention_days >= 0);

-- Approved ladder from the platform plan, section B4. Null means custom / no cap.
-- Keep these numbers aligned with src/gateway/limits.rs.
update public.fizz_plans set
  gateway_limit = 1, mcp_server_limit = 3, gateway_stdio = false, gateway_dedicated = false,
  seat_limit = 1, tool_calls_per_month = 10000, phone_calls_per_month = 0, audit_retention_days = 7
where id = 'hobbyist';
update public.fizz_plans set
  gateway_limit = 1, mcp_server_limit = 10, gateway_stdio = false, gateway_dedicated = false,
  seat_limit = 1, tool_calls_per_month = 50000, phone_calls_per_month = 20, audit_retention_days = 30
where id = 'tinkerer';
update public.fizz_plans set
  gateway_limit = 1, mcp_server_limit = 25, gateway_stdio = true, gateway_dedicated = true,
  seat_limit = 3, tool_calls_per_month = 200000, phone_calls_per_month = 100, audit_retention_days = 90
where id = 'pro';
update public.fizz_plans set
  gateway_limit = null, mcp_server_limit = null, gateway_stdio = true, gateway_dedicated = true,
  seat_limit = null, tool_calls_per_month = null, phone_calls_per_month = null, audit_retention_days = null
where id = 'enterprise';

-- Recreate so SELECT * includes the columns added above.
create or replace function public.fizz_customer_plan(p_customer uuid)
returns public.fizz_plans language sql stable security definer set search_path = '' as $$
  select p.* from public.fizz_plans p
  where p.id = coalesce((select s.plan from public.fizz_subscriptions s where s.customer_id = p_customer), 'hobbyist');
$$;

comment on column gateway.gateways.mode is
  'shared, dedicated, or selfhost. Pro marks a hosted gateway dedicated. The control plane does not provision a machine.';

comment on table gateway.policies is
  'Control-plane upsert key: gateway_id, server_id (null = all servers), tool_name (* or one tool), effect (allow|deny|approve). fizz-guard reads those fields. Extra columns need a default.';

create table gateway.members (
  workspace_id uuid not null references gateway.workspaces(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null check (role in ('owner', 'admin', 'member')),
  created_at timestamptz not null default now(),
  primary key (workspace_id, user_id)
);
create index members_user_idx on gateway.members(user_id);

create table gateway.registration_tokens (
  id uuid primary key default gen_random_uuid(),
  gateway_id uuid not null references gateway.gateways(id) on delete cascade,
  token_hash bytea not null unique check (octet_length(token_hash) = 32),
  created_at timestamptz not null default now(),
  revoked_at timestamptz
);
create unique index registration_tokens_one_active
  on gateway.registration_tokens (gateway_id) where revoked_at is null;

create unique index gateways_workspace_name_idx on gateway.gateways (workspace_id, name);

comment on table gateway.registration_tokens is
  'SHA-256 of a gateway agent registration token. The plaintext is shown once and is never stored.';

-- One workspace per customer, and the account owner. Safe to call on every request.
create function gateway.ensure_owner(p_user uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_customer uuid;
  v_workspace uuid;
begin
  if p_user is null then
    return null;
  end if;
  select c.id into v_customer from public.fizz_customers c where c.auth_user_id = p_user;
  if v_customer is null then
    return null;
  end if;
  select w.id into v_workspace from gateway.workspaces w where w.customer_id = v_customer;
  if v_workspace is null then
    begin
      insert into gateway.workspaces (customer_id) values (v_customer) returning id into v_workspace;
    exception when unique_violation then
      select w.id into v_workspace from gateway.workspaces w where w.customer_id = v_customer;
    end;
  end if;
  insert into gateway.members (workspace_id, user_id, role)
  values (v_workspace, p_user, 'owner')
  on conflict (workspace_id, user_id) do nothing;
  return v_workspace;
end;
$$;

create function gateway.limits(p_workspace uuid)
returns public.fizz_plans
language sql
stable
security definer
set search_path = ''
as $$
  select p.*
  from gateway.workspaces w
  join lateral public.fizz_customer_plan(w.customer_id) p on true
  where w.id = p_workspace;
$$;

create function gateway.plan_json(p_workspace uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id', p.id,
    'name', p.name,
    'gateway_limit', p.gateway_limit,
    'mcp_server_limit', p.mcp_server_limit,
    'stdio', p.gateway_stdio,
    'dedicated', p.gateway_dedicated,
    'seat_limit', p.seat_limit,
    'tool_calls_per_month', p.tool_calls_per_month,
    'phone_calls_per_month', p.phone_calls_per_month,
    'audit_retention_days', p.audit_retention_days
  )
  from gateway.limits(p_workspace) p;
$$;

-- Downgrade keeps rows and turns the extras off. Upgrade turns them back on.
-- The oldest rows stay active. Counts for new rows still include disabled ones,
-- so a workspace over the cap must delete before it can add.
create function gateway.apply_caps(p_workspace uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_gw integer;
  v_srv integer;
begin
  select pl.gateway_limit, pl.mcp_server_limit into v_gw, v_srv
  from gateway.limits(p_workspace) pl;
  if v_gw is null then
    update gateway.gateways g
    set status = 'active', config_revision = g.config_revision + 1
    where g.workspace_id = p_workspace and g.status <> 'active';
  else
    with ranked as (
      select id, row_number() over (order by created_at, id) as n
      from gateway.gateways
      where workspace_id = p_workspace
    )
    update gateway.gateways g
    set status = case when r.n <= v_gw then 'active' else 'disabled' end,
        config_revision = g.config_revision + 1
    from ranked r
    where g.id = r.id
      and g.status is distinct from (case when r.n <= v_gw then 'active' else 'disabled' end);
  end if;
  if v_srv is null then
    with touched as (
      update gateway.servers s
      set enabled = true
      from gateway.gateways g
      where s.gateway_id = g.id and g.workspace_id = p_workspace and s.enabled = false
      returning s.gateway_id
    )
    update gateway.gateways g
    set config_revision = g.config_revision + 1
    where g.id in (select distinct touched.gateway_id from touched);
  else
    with ranked as (
      select s.id, row_number() over (partition by s.gateway_id order by s.created_at, s.id) as n
      from gateway.servers s
      join gateway.gateways g on g.id = s.gateway_id
      where g.workspace_id = p_workspace
    ),
    touched as (
      update gateway.servers s
      set enabled = (r.n <= v_srv)
      from ranked r
      where s.id = r.id and s.enabled is distinct from (r.n <= v_srv)
      returning s.gateway_id
    )
    update gateway.gateways g
    set config_revision = g.config_revision + 1
    where g.id in (select distinct touched.gateway_id from touched);
  end if;
end;
$$;

create function gateway.gateway_json(p_gateway uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id', g.id,
    'workspace_id', g.workspace_id,
    'name', g.name,
    'mode', g.mode,
    'region', g.region,
    'public_url', g.public_url,
    'listen_port', g.listen_port,
    'status', g.status,
    'config_revision', g.config_revision,
    'ag_version', g.ag_version,
    'unreviewed_tools', g.unreviewed_tools,
    'created_at', g.created_at
  )
  from gateway.gateways g
  where g.id = p_gateway;
$$;

create function gateway.touch(p_gateway uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  update gateway.gateways
  set config_revision = config_revision + 1
  where id = p_gateway;
$$;

create function gateway.rate(p_bucket text, p_subject text, p_limit integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if public.fizz_rate_limit_hit(p_bucket, coalesce(p_subject, ''), p_limit, interval '1 minute') then
    return null;
  end if;
  return jsonb_build_object('error', 'rate_limited');
end;
$$;

-- Missing gateway and a gateway in another workspace look the same.
create function gateway.access(p_user uuid, p_gateway uuid, p_write boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_workspace uuid;
  v_role text;
begin
  if p_user is null or p_gateway is null then
    return jsonb_build_object('error', 'not_found');
  end if;
  perform gateway.ensure_owner(p_user);
  select g.workspace_id into v_workspace from gateway.gateways g where g.id = p_gateway;
  if v_workspace is null then
    return jsonb_build_object('error', 'not_found');
  end if;
  select m.role into v_role
  from gateway.members m
  where m.workspace_id = v_workspace and m.user_id = p_user;
  if v_role is null then
    return jsonb_build_object('error', 'not_found');
  end if;
  if p_write and v_role not in ('owner', 'admin') then
    return jsonb_build_object('error', 'forbidden');
  end if;
  perform pg_advisory_xact_lock(hashtextextended('fizz_gateway:' || v_workspace::text, 0));
  if p_write then
    perform gateway.apply_caps(v_workspace);
  end if;
  return jsonb_build_object('ok', true, 'role', v_role, 'workspace_id', v_workspace);
end;
$$;

create function gateway.server_json(p_server uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id', s.id,
    'gateway_id', s.gateway_id,
    'name', s.name,
    'transport', s.transport,
    'url', s.url_or_cmd,
    'args', to_jsonb(s.command_args),
    'auth_kind', s.auth_kind,
    'has_secret', exists (select 1 from gateway.secrets c where c.server_id = s.id),
    'enabled', s.enabled,
    'created_at', s.created_at
  )
  from gateway.servers s
  where s.id = p_server;
$$;

create function gateway.ctl_context(p_user uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_workspace uuid;
  v_limited jsonb;
  v_gateways jsonb;
begin
  v_limited := gateway.rate('gateway_read', p_user::text, 120);
  if v_limited is not null then
    return v_limited;
  end if;
  v_workspace := gateway.ensure_owner(p_user);
  if v_workspace is null then
    return jsonb_build_object('error', 'not_found');
  end if;
  perform pg_advisory_xact_lock(hashtextextended('fizz_gateway:' || v_workspace::text, 0));
  perform gateway.apply_caps(v_workspace);
  select coalesce(jsonb_agg(
    gateway.gateway_json(g.id) || jsonb_build_object('role', m.role)
    order by g.created_at
  ), '[]'::jsonb)
  into v_gateways
  from gateway.members m
  join gateway.gateways g on g.workspace_id = m.workspace_id
  where m.user_id = p_user;
  return jsonb_build_object(
    'workspace_id', v_workspace,
    'role', (select m.role from gateway.members m where m.workspace_id = v_workspace and m.user_id = p_user),
    'plan', gateway.plan_json(v_workspace),
    'gateways', v_gateways
  );
end;
$$;

create function gateway.ctl_create(p_user uuid, p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_workspace uuid;
  v_role text;
  v_limited jsonb;
  v_name text;
  v_mode text;
  v_region text;
  v_url text;
  v_port integer;
  v_hash text;
  v_id uuid;
  v_gw_limit integer;
  v_dedicated boolean;
  v_count integer;
begin
  v_limited := gateway.rate('gateway_write', p_user::text, 60);
  if v_limited is not null then return v_limited; end if;
  v_workspace := gateway.ensure_owner(p_user);
  if v_workspace is null then return jsonb_build_object('error', 'not_found'); end if;
  select m.role into v_role from gateway.members m
  where m.workspace_id = v_workspace and m.user_id = p_user;
  if v_role is null or v_role not in ('owner', 'admin') then
    return jsonb_build_object('error', 'forbidden');
  end if;
  perform pg_advisory_xact_lock(hashtextextended('fizz_gateway:' || v_workspace::text, 0));
  perform gateway.apply_caps(v_workspace);
  v_name := p_payload->>'name';
  v_mode := nullif(p_payload->>'mode', '');
  v_region := nullif(p_payload->>'region', '');
  v_url := nullif(p_payload->>'public_url', '');
  v_port := coalesce((p_payload->>'listen_port')::integer, 3000);
  v_hash := p_payload->>'registration_hash';
  select pl.gateway_limit, pl.gateway_dedicated into v_gw_limit, v_dedicated
  from gateway.limits(v_workspace) pl;
  if v_mode is null then
    v_mode := case when coalesce(v_dedicated, false) then 'dedicated' else 'shared' end;
  end if;
  if v_name is null or v_name !~ '^[a-z][a-z0-9-]{0,40}$' or right(v_name, 1) = '-'
    or v_mode not in ('shared', 'dedicated', 'selfhost')
    or v_port is null or v_port < 1 or v_port > 65535
    or v_hash is null or v_hash !~ '^[0-9a-f]{64}$'
    or (v_region is not null and (char_length(v_region) > 40 or v_region !~ '^[A-Za-z0-9_-]+$'))
    or (v_url is not null and (
      char_length(v_url) < 8 or char_length(v_url) > 300
      or v_url !~ '^https?://[^[:space:]@]+$' or v_url ~ '[[:cntrl:]]'
    )) then
    return jsonb_build_object('error', 'invalid_request');
  end if;
  if v_mode = 'dedicated' and not coalesce(v_dedicated, false) then
    return jsonb_build_object('error', 'dedicated_not_included');
  end if;
  if nullif(p_payload->>'id', '') is null then
    v_id := gen_random_uuid();
  else
    v_id := (p_payload->>'id')::uuid;
  end if;
  if v_url is null then
    if v_mode = 'selfhost' then
      return jsonb_build_object('error', 'invalid_request');
    elsif v_mode = 'dedicated' then
      v_url := 'https://' || v_name || '.gw.fizzlayer.com/mcp';
    else
      v_url := 'https://gw.fizzlayer.com/w/' || v_id::text || '/mcp';
    end if;
  end if;
  select count(*) into v_count from gateway.gateways where workspace_id = v_workspace;
  if v_gw_limit is not null and v_count >= v_gw_limit then
    return jsonb_build_object('error', 'gateway_limit');
  end if;
  insert into gateway.gateways (id, workspace_id, name, mode, region, public_url, listen_port)
  values (v_id, v_workspace, v_name, v_mode, v_region, v_url, v_port);
  insert into gateway.registration_tokens (gateway_id, token_hash)
  values (v_id, decode(v_hash, 'hex'));
  return jsonb_build_object('gateway', gateway.gateway_json(v_id) || jsonb_build_object('role', v_role));
end;
$$;

create function gateway.ctl_delete(p_user uuid, p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_access jsonb;
  v_id uuid;
begin
  v_access := gateway.rate('gateway_write', p_user::text, 60);
  if v_access is not null then return v_access; end if;
  v_id := (p_payload->>'gateway_id')::uuid;
  v_access := gateway.access(p_user, v_id, true);
  if v_access ? 'error' then return v_access; end if;
  delete from gateway.gateways where id = v_id;
  return jsonb_build_object('deleted', true, 'id', v_id);
end;
$$;

create function gateway.ctl_servers(p_user uuid, p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_access jsonb;
  v_id uuid;
  v_rows jsonb;
begin
  v_access := gateway.rate('gateway_read', p_user::text, 120);
  if v_access is not null then return v_access; end if;
  v_id := (p_payload->>'gateway_id')::uuid;
  v_access := gateway.access(p_user, v_id, false);
  if v_access ? 'error' then return v_access; end if;
  select coalesce(jsonb_agg(gateway.server_json(s.id) order by s.created_at), '[]'::jsonb)
  into v_rows
  from gateway.servers s
  where s.gateway_id = v_id;
  return jsonb_build_object('servers', v_rows);
end;
$$;

create function gateway.ctl_add_server(p_user uuid, p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_access jsonb;
  v_id uuid;
  v_workspace uuid;
  v_mode text;
  v_name text;
  v_transport text;
  v_url text;
  v_args text[];
  v_auth text;
  v_cipher text;
  v_key text;
  v_stdio boolean;
  v_limit integer;
  v_count integer;
  v_server uuid;
begin
  v_access := gateway.rate('gateway_write', p_user::text, 60);
  if v_access is not null then return v_access; end if;
  v_id := (p_payload->>'gateway_id')::uuid;
  v_access := gateway.access(p_user, v_id, true);
  if v_access ? 'error' then return v_access; end if;
  v_workspace := (v_access->>'workspace_id')::uuid;
  select g.mode into v_mode from gateway.gateways g where g.id = v_id;
  v_name := p_payload->>'name';
  v_transport := coalesce(p_payload->>'transport', 'http');
  v_url := p_payload->>'url';
  v_auth := coalesce(p_payload->>'auth_kind', 'none');
  v_cipher := nullif(p_payload->>'ciphertext', '');
  v_key := nullif(p_payload->>'key_id', '');
  select coalesce(array_agg(elem), '{}') into v_args
  from jsonb_array_elements_text(coalesce(p_payload->'args', '[]'::jsonb)) elem;
  if v_name is null or v_name !~ '^[a-z][a-z0-9_-]{0,40}$'
    or v_transport not in ('http', 'sse', 'stdio')
    or v_auth not in ('none', 'key', 'passthrough')
    or v_url is null or char_length(v_url) < 1 or char_length(v_url) > 500 or v_url ~ '[[:cntrl:]]'
    or cardinality(v_args) > 32
    or exists (
      select 1 from unnest(v_args) arg
      where char_length(arg) > 200 or arg ~ '[[:cntrl:]]'
    ) then
    return jsonb_build_object('error', 'invalid_request');
  end if;
  if v_transport in ('http', 'sse')
    and (v_url !~ '^https?://[^[:space:]@]+$' or char_length(v_url) < 8) then
    return jsonb_build_object('error', 'invalid_request');
  end if;
  if v_transport = 'stdio' and v_url ~ '[[:space:]]' then
    return jsonb_build_object('error', 'invalid_request');
  end if;
  if v_auth = 'key' and (v_cipher is null or v_key is null or v_key <> 'v1') then
    return jsonb_build_object('error', 'invalid_request');
  end if;
  if v_auth <> 'key' and v_cipher is not null then
    return jsonb_build_object('error', 'invalid_request');
  end if;
  select pl.gateway_stdio, pl.mcp_server_limit into v_stdio, v_limit
  from gateway.limits(v_workspace) pl;
  if v_transport = 'stdio' and not coalesce(v_stdio, false) then
    return jsonb_build_object('error', 'stdio_not_included');
  end if;
  if v_transport = 'stdio' and v_mode = 'shared' then
    return jsonb_build_object('error', 'stdio_shared');
  end if;
  select count(*) into v_count from gateway.servers where gateway_id = v_id;
  if v_limit is not null and v_count >= v_limit then
    return jsonb_build_object('error', 'server_limit');
  end if;
  v_server := gen_random_uuid();
  insert into gateway.servers (id, gateway_id, name, transport, url_or_cmd, command_args, auth_kind)
  values (v_server, v_id, v_name, v_transport, v_url, v_args, v_auth);
  if v_auth = 'key' then
    insert into gateway.secrets (server_id, ciphertext, key_id)
    values (v_server, decode(v_cipher, 'base64'), v_key);
  end if;
  perform gateway.touch(v_id);
  return jsonb_build_object('server', gateway.server_json(v_server));
end;
$$;

create function gateway.ctl_remove_server(p_user uuid, p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_access jsonb;
  v_gateway uuid;
  v_server uuid;
begin
  v_access := gateway.rate('gateway_write', p_user::text, 60);
  if v_access is not null then return v_access; end if;
  v_gateway := (p_payload->>'gateway_id')::uuid;
  v_server := (p_payload->>'server_id')::uuid;
  v_access := gateway.access(p_user, v_gateway, true);
  if v_access ? 'error' then return v_access; end if;
  delete from gateway.servers where id = v_server and gateway_id = v_gateway;
  if not found then
    return jsonb_build_object('error', 'not_found');
  end if;
  perform gateway.touch(v_gateway);
  return jsonb_build_object('deleted', true, 'id', v_server);
end;
$$;

create function gateway.ctl_policies(p_user uuid, p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_access jsonb;
  v_id uuid;
  v_rows jsonb;
begin
  v_access := gateway.rate('gateway_read', p_user::text, 120);
  if v_access is not null then return v_access; end if;
  v_id := (p_payload->>'gateway_id')::uuid;
  v_access := gateway.access(p_user, v_id, false);
  if v_access ? 'error' then return v_access; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', p.id,
    'gateway_id', p.gateway_id,
    'server_id', p.server_id,
    'tool_name', p.tool_name,
    'effect', p.effect,
    'notify_channel', p.notify_channel,
    'created_at', p.created_at
  ) order by p.created_at), '[]'::jsonb)
  into v_rows
  from gateway.policies p
  where p.gateway_id = v_id;
  return jsonb_build_object('policies', v_rows);
end;
$$;

create function gateway.ctl_set_policy(p_user uuid, p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_access jsonb;
  v_gateway uuid;
  v_server uuid;
  v_tool text;
  v_effect text;
  v_channel text;
  v_id uuid;
begin
  v_access := gateway.rate('gateway_write', p_user::text, 60);
  if v_access is not null then return v_access; end if;
  v_gateway := (p_payload->>'gateway_id')::uuid;
  v_access := gateway.access(p_user, v_gateway, true);
  if v_access ? 'error' then return v_access; end if;
  if nullif(p_payload->>'server_id', '') is null then
    v_server := null;
  else
    v_server := (p_payload->>'server_id')::uuid;
    if not exists (
      select 1 from gateway.servers s where s.id = v_server and s.gateway_id = v_gateway
    ) then
      return jsonb_build_object('error', 'not_found');
    end if;
  end if;
  v_tool := p_payload->>'tool_name';
  v_effect := p_payload->>'effect';
  v_channel := nullif(p_payload->>'notify_channel', '');
  if v_tool is null or (v_tool <> '*' and v_tool !~ '^[A-Za-z0-9_.:-]{1,128}$')
    or v_effect not in ('allow', 'deny', 'approve')
    or (v_channel is not null and v_channel not in ('log', 'webhook', 'phone')) then
    return jsonb_build_object('error', 'invalid_request');
  end if;
  update gateway.policies p
  set effect = v_effect, notify_channel = coalesce(v_channel, p.notify_channel)
  where p.gateway_id = v_gateway
    and p.tool_name = v_tool
    and p.server_id is not distinct from v_server
  returning p.id, p.notify_channel into v_id, v_channel;
  if v_id is null then
    insert into gateway.policies (gateway_id, server_id, tool_name, effect, notify_channel)
    values (v_gateway, v_server, v_tool, v_effect, coalesce(v_channel, 'log'))
    returning id, notify_channel into v_id, v_channel;
  end if;
  perform gateway.touch(v_gateway);
  return jsonb_build_object(
    'policy', jsonb_build_object(
      'id', v_id,
      'gateway_id', v_gateway,
      'server_id', v_server,
      'tool_name', v_tool,
      'effect', v_effect,
      'notify_channel', v_channel
    )
  );
end;
$$;

create function gateway.ctl_delete_policy(p_user uuid, p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_access jsonb;
  v_gateway uuid;
  v_policy uuid;
begin
  v_access := gateway.rate('gateway_write', p_user::text, 60);
  if v_access is not null then return v_access; end if;
  v_gateway := (p_payload->>'gateway_id')::uuid;
  v_policy := (p_payload->>'policy_id')::uuid;
  v_access := gateway.access(p_user, v_gateway, true);
  if v_access ? 'error' then return v_access; end if;
  delete from gateway.policies where id = v_policy and gateway_id = v_gateway;
  if not found then
    return jsonb_build_object('error', 'not_found');
  end if;
  perform gateway.touch(v_gateway);
  return jsonb_build_object('deleted', true, 'id', v_policy);
end;
$$;

create function gateway.enabled_servers(p_gateway uuid, p_with_secret boolean)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'name', s.name,
    'transport', s.transport,
    'url', s.url_or_cmd,
    'args', to_jsonb(s.command_args),
    'auth_kind', s.auth_kind,
    'ciphertext', case when p_with_secret then encode(sec.ciphertext, 'base64') else null end,
    'key_id', case when p_with_secret then sec.key_id else null end
  ) order by s.name), '[]'::jsonb)
  from gateway.servers s
  left join lateral (
    select c.ciphertext, c.key_id
    from gateway.secrets c
    where c.server_id = s.id
    order by c.created_at desc
    limit 1
  ) sec on true
  where s.gateway_id = p_gateway and s.enabled;
$$;

create function gateway.ctl_render(p_user uuid, p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_access jsonb;
  v_id uuid;
  v_gateway gateway.gateways%rowtype;
begin
  v_access := gateway.rate('gateway_read', p_user::text, 120);
  if v_access is not null then return v_access; end if;
  v_id := (p_payload->>'gateway_id')::uuid;
  v_access := gateway.access(p_user, v_id, false);
  if v_access ? 'error' then return v_access; end if;
  select * into v_gateway from gateway.gateways g where g.id = v_id;
  return jsonb_build_object(
    'gateway_id', v_gateway.id,
    'workspace_id', v_gateway.workspace_id,
    'mode', v_gateway.mode,
    'public_url', v_gateway.public_url,
    'listen_port', v_gateway.listen_port,
    'config_revision', v_gateway.config_revision,
    'ag_version', v_gateway.ag_version,
    'status', v_gateway.status,
    'servers', gateway.enabled_servers(v_id, false)
  );
end;
$$;

create function gateway.ctl_agent(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hash text;
  v_limited jsonb;
  v_gateway uuid;
  v_row gateway.gateways%rowtype;
begin
  v_hash := p_payload->>'token_hash';
  if v_hash is null or v_hash !~ '^[0-9a-f]{64}$' then
    return jsonb_build_object('error', 'not_found');
  end if;
  v_limited := gateway.rate('gateway_pull', v_hash, 120);
  if v_limited is not null then return v_limited; end if;
  select t.gateway_id into v_gateway
  from gateway.registration_tokens t
  where t.token_hash = decode(v_hash, 'hex') and t.revoked_at is null;
  if v_gateway is null then
    return jsonb_build_object('error', 'not_found');
  end if;
  select * into v_row from gateway.gateways g where g.id = v_gateway;
  if v_row.status <> 'active' then
    return jsonb_build_object('error', 'disabled', 'config_revision', v_row.config_revision);
  end if;
  if exists (
    select 1
    from gateway.servers s
    where s.gateway_id = v_gateway and s.enabled and s.auth_kind = 'key'
      and not exists (select 1 from gateway.secrets c where c.server_id = s.id)
  ) then
    return jsonb_build_object('error', 'missing_secret');
  end if;
  return jsonb_build_object(
    'gateway_id', v_row.id,
    'workspace_id', v_row.workspace_id,
    'mode', v_row.mode,
    'public_url', v_row.public_url,
    'listen_port', v_row.listen_port,
    'config_revision', v_row.config_revision,
    'ag_version', v_row.ag_version,
    'status', v_row.status,
    'servers', gateway.enabled_servers(v_gateway, true)
  );
end;
$$;

create function gateway.ctl_insert_token(p_user uuid, p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_access jsonb;
  v_gateway uuid;
  v_name text;
  v_jti text;
  v_exp timestamptz;
  v_id uuid;
  v_url text;
  v_workspace uuid;
begin
  v_access := gateway.rate('gateway_write', p_user::text, 60);
  if v_access is not null then return v_access; end if;
  v_gateway := (p_payload->>'gateway_id')::uuid;
  v_access := gateway.access(p_user, v_gateway, true);
  if v_access ? 'error' then return v_access; end if;
  v_name := p_payload->>'name';
  v_jti := p_payload->>'jti';
  v_exp := to_timestamp((p_payload->>'expires_at')::double precision);
  if v_name is null or char_length(v_name) < 1 or char_length(v_name) > 80 or v_name ~ '[[:cntrl:]]'
    or v_jti is null or v_jti !~ '^[0-9a-f-]{36}$'
    or v_exp <= now() or v_exp > now() + interval '30 days' then
    return jsonb_build_object('error', 'invalid_request');
  end if;
  select g.public_url, g.workspace_id into v_url, v_workspace
  from gateway.gateways g where g.id = v_gateway and g.status = 'active';
  if v_url is null then
    return jsonb_build_object('error', 'disabled');
  end if;
  insert into gateway.client_tokens (gateway_id, user_id, name, jti, expires_at)
  values (v_gateway, p_user, v_name, v_jti, v_exp)
  returning id into v_id;
  return jsonb_build_object(
    'token', jsonb_build_object(
      'id', v_id,
      'gateway_id', v_gateway,
      'workspace_id', v_workspace,
      'name', v_name,
      'jti', v_jti,
      'expires_at', v_exp,
      'audience', v_url,
      'revoked_at', null
    )
  );
end;
$$;

create function gateway.ctl_tokens(p_user uuid, p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_access jsonb;
  v_id uuid;
  v_rows jsonb;
begin
  v_access := gateway.rate('gateway_read', p_user::text, 120);
  if v_access is not null then return v_access; end if;
  v_id := (p_payload->>'gateway_id')::uuid;
  v_access := gateway.access(p_user, v_id, false);
  if v_access ? 'error' then return v_access; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', t.id,
    'gateway_id', t.gateway_id,
    'name', t.name,
    'jti', t.jti,
    'expires_at', t.expires_at,
    'revoked_at', t.revoked_at,
    'created_at', t.created_at
  ) order by t.created_at desc), '[]'::jsonb)
  into v_rows
  from gateway.client_tokens t
  where t.gateway_id = v_id;
  return jsonb_build_object('tokens', v_rows);
end;
$$;

create function gateway.ctl_revoke_token(p_user uuid, p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_access jsonb;
  v_gateway uuid;
  v_token uuid;
begin
  v_access := gateway.rate('gateway_write', p_user::text, 60);
  if v_access is not null then return v_access; end if;
  v_gateway := (p_payload->>'gateway_id')::uuid;
  v_token := (p_payload->>'token_id')::uuid;
  v_access := gateway.access(p_user, v_gateway, true);
  if v_access ? 'error' then return v_access; end if;
  update gateway.client_tokens
  set revoked_at = coalesce(revoked_at, now())
  where id = v_token and gateway_id = v_gateway;
  if not found then
    return jsonb_build_object('error', 'not_found');
  end if;
  return jsonb_build_object('revoked', true, 'id', v_token);
end;
$$;

create function gateway.ctl_rotate(p_user uuid, p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_access jsonb;
  v_gateway uuid;
  v_hash text;
begin
  v_access := gateway.rate('gateway_write', p_user::text, 60);
  if v_access is not null then return v_access; end if;
  v_gateway := (p_payload->>'gateway_id')::uuid;
  v_hash := p_payload->>'registration_hash';
  v_access := gateway.access(p_user, v_gateway, true);
  if v_access ? 'error' then return v_access; end if;
  if v_hash is null or v_hash !~ '^[0-9a-f]{64}$' then
    return jsonb_build_object('error', 'invalid_request');
  end if;
  update gateway.registration_tokens
  set revoked_at = now()
  where gateway_id = v_gateway and revoked_at is null;
  insert into gateway.registration_tokens (gateway_id, token_hash)
  values (v_gateway, decode(v_hash, 'hex'));
  return jsonb_build_object('rotated', true, 'gateway_id', v_gateway);
end;
$$;

create function gateway.ctl_unreviewed(p_user uuid, p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_access jsonb;
  v_gateway uuid;
  v_mode text;
begin
  v_access := gateway.rate('gateway_write', p_user::text, 60);
  if v_access is not null then return v_access; end if;
  v_gateway := (p_payload->>'gateway_id')::uuid;
  v_mode := p_payload->>'unreviewed_tools';
  if v_mode is null or v_mode not in ('hide', 'show') then
    return jsonb_build_object('error', 'invalid_request');
  end if;
  v_access := gateway.access(p_user, v_gateway, true);
  if v_access ? 'error' then return v_access; end if;
  update gateway.gateways set unreviewed_tools = v_mode where id = v_gateway;
  return jsonb_build_object('gateway', gateway.gateway_json(v_gateway) || jsonb_build_object('role', v_access->>'role'));
end;
$$;

create function gateway.ctl_pins(p_user uuid, p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_access jsonb;
  v_id uuid;
  v_rows jsonb;
begin
  v_access := gateway.rate('gateway_read', p_user::text, 120);
  if v_access is not null then return v_access; end if;
  v_id := (p_payload->>'gateway_id')::uuid;
  v_access := gateway.access(p_user, v_id, false);
  if v_access ? 'error' then return v_access; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'server_id', p.server_id,
    'server_name', s.name,
    'tool_name', p.tool_name,
    'pin_sha256', p.pin_sha256,
    'observed_sha256', p.observed_sha256,
    'status', p.status,
    'approved_at', p.approved_at
  ) order by s.name, p.tool_name), '[]'::jsonb)
  into v_rows
  from gateway.tool_pins p
  join gateway.servers s on s.id = p.server_id
  where s.gateway_id = v_id;
  return jsonb_build_object('pins', v_rows);
end;
$$;

-- Same transition fizz-guard uses: the observed hash becomes the approved pin.
create function gateway.ctl_approve_pin(p_user uuid, p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_access jsonb;
  v_gateway uuid;
  v_server text;
  v_tool text;
  v_updated integer;
begin
  v_access := gateway.rate('gateway_write', p_user::text, 60);
  if v_access is not null then return v_access; end if;
  v_gateway := (p_payload->>'gateway_id')::uuid;
  v_server := p_payload->>'server';
  v_tool := p_payload->>'tool';
  if v_server is null or v_server !~ '^[a-z][a-z0-9_-]{0,40}$'
    or v_tool is null or v_tool !~ '^[A-Za-z0-9_.:-]{1,128}$' then
    return jsonb_build_object('error', 'invalid_request');
  end if;
  v_access := gateway.access(p_user, v_gateway, true);
  if v_access ? 'error' then return v_access; end if;
  update gateway.tool_pins p
  set pin_sha256 = p.observed_sha256,
      status = 'approved',
      approved_at = now()
  from gateway.servers s
  where p.server_id = s.id and s.gateway_id = v_gateway and s.name = v_server
    and p.tool_name = v_tool and p.status in ('changed', 'unreviewed');
  get diagnostics v_updated = row_count;
  if v_updated <> 1 then
    return jsonb_build_object('error', 'not_found');
  end if;
  update gateway.pin_alerts a
  set acknowledged_at = now()
  from gateway.servers s
  where a.server_id = s.id and s.gateway_id = v_gateway and s.name = v_server
    and a.tool_name = v_tool and a.acknowledged_at is null;
  return jsonb_build_object('approved', true, 'server', v_server, 'tool', v_tool);
end;
$$;

create function gateway.ctl_pin_alerts(p_user uuid, p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_access jsonb;
  v_id uuid;
  v_rows jsonb;
begin
  v_access := gateway.rate('gateway_read', p_user::text, 120);
  if v_access is not null then return v_access; end if;
  v_id := (p_payload->>'gateway_id')::uuid;
  v_access := gateway.access(p_user, v_id, false);
  if v_access ? 'error' then return v_access; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', a.id,
    'server_id', a.server_id,
    'server_name', s.name,
    'tool_name', a.tool_name,
    'approved_sha256', a.approved_sha256,
    'observed_sha256', a.observed_sha256,
    'description_preview', a.description_preview,
    'kind', a.kind,
    'created_at', a.created_at,
    'acknowledged_at', a.acknowledged_at
  ) order by a.created_at desc), '[]'::jsonb)
  into v_rows
  from gateway.pin_alerts a
  join gateway.servers s on s.id = a.server_id
  where a.gateway_id = v_id;
  return jsonb_build_object('alerts', v_rows);
end;
$$;

create function gateway.ctl_ack_alert(p_user uuid, p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_access jsonb;
  v_gateway uuid;
  v_alert uuid;
begin
  v_access := gateway.rate('gateway_write', p_user::text, 60);
  if v_access is not null then return v_access; end if;
  v_gateway := (p_payload->>'gateway_id')::uuid;
  v_alert := (p_payload->>'alert_id')::uuid;
  v_access := gateway.access(p_user, v_gateway, true);
  if v_access ? 'error' then return v_access; end if;
  update gateway.pin_alerts
  set acknowledged_at = coalesce(acknowledged_at, now())
  where id = v_alert and gateway_id = v_gateway;
  if not found then
    return jsonb_build_object('error', 'not_found');
  end if;
  return jsonb_build_object('acknowledged', true, 'id', v_alert);
end;
$$;

create function gateway.ctl_approvals(p_user uuid, p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_access jsonb;
  v_id uuid;
  v_rows jsonb;
begin
  v_access := gateway.rate('gateway_read', p_user::text, 120);
  if v_access is not null then return v_access; end if;
  v_id := (p_payload->>'gateway_id')::uuid;
  v_access := gateway.access(p_user, v_id, false);
  if v_access ? 'error' then return v_access; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', a.id,
    'server_name', a.server_name,
    'tool_name', a.tool_name,
    'args_preview', a.args_preview,
    'status', a.status,
    'notify_channel', a.notify_channel,
    'expires_at', a.expires_at,
    'decided_by', a.decided_by,
    'created_at', a.created_at
  ) order by a.created_at desc), '[]'::jsonb)
  into v_rows
  from gateway.approvals a
  where a.gateway_id = v_id;
  return jsonb_build_object('approvals', v_rows);
end;
$$;

create function gateway.ctl_decide_approval(p_user uuid, p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_access jsonb;
  v_gateway uuid;
  v_id uuid;
  v_status text;
begin
  v_access := gateway.rate('gateway_write', p_user::text, 60);
  if v_access is not null then return v_access; end if;
  v_gateway := (p_payload->>'gateway_id')::uuid;
  v_id := (p_payload->>'approval_id')::uuid;
  v_status := p_payload->>'status';
  if v_status is null or v_status not in ('approved', 'denied') then
    return jsonb_build_object('error', 'invalid_request');
  end if;
  v_access := gateway.access(p_user, v_gateway, true);
  if v_access ? 'error' then return v_access; end if;
  update gateway.approvals
  set status = v_status, decided_by = p_user
  where id = v_id and gateway_id = v_gateway and status = 'pending' and expires_at > now();
  if not found then
    return jsonb_build_object('error', 'not_found');
  end if;
  return jsonb_build_object('decided', true, 'id', v_id, 'status', v_status);
end;
$$;

create function public.fizz_gateway(p_user uuid, p_action text, p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_payload jsonb := coalesce(p_payload, '{}'::jsonb);
begin
  if jsonb_typeof(v_payload) <> 'object' or p_action is null then
    return jsonb_build_object('error', 'invalid_request');
  end if;
  case p_action
    when 'context' then return gateway.ctl_context(p_user);
    when 'create_gateway' then return gateway.ctl_create(p_user, v_payload);
    when 'delete_gateway' then return gateway.ctl_delete(p_user, v_payload);
    when 'list_servers' then return gateway.ctl_servers(p_user, v_payload);
    when 'add_server' then return gateway.ctl_add_server(p_user, v_payload);
    when 'remove_server' then return gateway.ctl_remove_server(p_user, v_payload);
    when 'list_policies' then return gateway.ctl_policies(p_user, v_payload);
    when 'set_policy' then return gateway.ctl_set_policy(p_user, v_payload);
    when 'delete_policy' then return gateway.ctl_delete_policy(p_user, v_payload);
    when 'set_unreviewed' then return gateway.ctl_unreviewed(p_user, v_payload);
    when 'list_pins' then return gateway.ctl_pins(p_user, v_payload);
    when 'approve_pin' then return gateway.ctl_approve_pin(p_user, v_payload);
    when 'list_pin_alerts' then return gateway.ctl_pin_alerts(p_user, v_payload);
    when 'ack_pin_alert' then return gateway.ctl_ack_alert(p_user, v_payload);
    when 'list_approvals' then return gateway.ctl_approvals(p_user, v_payload);
    when 'decide_approval' then return gateway.ctl_decide_approval(p_user, v_payload);
    when 'render_source' then return gateway.ctl_render(p_user, v_payload);
    when 'agent_config' then return gateway.ctl_agent(v_payload);
    when 'insert_token' then return gateway.ctl_insert_token(p_user, v_payload);
    when 'list_tokens' then return gateway.ctl_tokens(p_user, v_payload);
    when 'revoke_token' then return gateway.ctl_revoke_token(p_user, v_payload);
    when 'rotate_registration' then return gateway.ctl_rotate(p_user, v_payload);
    else return jsonb_build_object('error', 'invalid_request');
  end case;
exception
  when unique_violation then
    return jsonb_build_object('error', 'conflict');
  when check_violation or not_null_violation or invalid_text_representation or invalid_parameter_value then
    return jsonb_build_object('error', 'invalid_request');
end;
$$;

revoke all on function public.fizz_gateway(uuid, text, jsonb) from public, anon, authenticated;
grant execute on function public.fizz_gateway(uuid, text, jsonb) to service_role;

revoke all on function
  gateway.ensure_owner(uuid),
  gateway.limits(uuid),
  gateway.plan_json(uuid),
  gateway.apply_caps(uuid),
  gateway.gateway_json(uuid),
  gateway.touch(uuid),
  gateway.rate(text, text, integer),
  gateway.access(uuid, uuid, boolean),
  gateway.server_json(uuid),
  gateway.ctl_context(uuid),
  gateway.ctl_create(uuid, jsonb),
  gateway.ctl_delete(uuid, jsonb),
  gateway.ctl_servers(uuid, jsonb),
  gateway.ctl_add_server(uuid, jsonb),
  gateway.ctl_remove_server(uuid, jsonb),
  gateway.ctl_policies(uuid, jsonb),
  gateway.ctl_set_policy(uuid, jsonb),
  gateway.ctl_delete_policy(uuid, jsonb),
  gateway.ctl_unreviewed(uuid, jsonb),
  gateway.ctl_pins(uuid, jsonb),
  gateway.ctl_approve_pin(uuid, jsonb),
  gateway.ctl_pin_alerts(uuid, jsonb),
  gateway.ctl_ack_alert(uuid, jsonb),
  gateway.ctl_approvals(uuid, jsonb),
  gateway.ctl_decide_approval(uuid, jsonb),
  gateway.enabled_servers(uuid, boolean),
  gateway.ctl_render(uuid, jsonb),
  gateway.ctl_agent(jsonb),
  gateway.ctl_insert_token(uuid, jsonb),
  gateway.ctl_tokens(uuid, jsonb),
  gateway.ctl_revoke_token(uuid, jsonb),
  gateway.ctl_rotate(uuid, jsonb)
from public, anon, authenticated;
grant execute on function
  gateway.ensure_owner(uuid),
  gateway.limits(uuid),
  gateway.plan_json(uuid),
  gateway.apply_caps(uuid),
  gateway.gateway_json(uuid),
  gateway.touch(uuid),
  gateway.rate(text, text, integer),
  gateway.access(uuid, uuid, boolean),
  gateway.server_json(uuid),
  gateway.ctl_context(uuid),
  gateway.ctl_create(uuid, jsonb),
  gateway.ctl_delete(uuid, jsonb),
  gateway.ctl_servers(uuid, jsonb),
  gateway.ctl_add_server(uuid, jsonb),
  gateway.ctl_remove_server(uuid, jsonb),
  gateway.ctl_policies(uuid, jsonb),
  gateway.ctl_set_policy(uuid, jsonb),
  gateway.ctl_delete_policy(uuid, jsonb),
  gateway.ctl_unreviewed(uuid, jsonb),
  gateway.ctl_pins(uuid, jsonb),
  gateway.ctl_approve_pin(uuid, jsonb),
  gateway.ctl_pin_alerts(uuid, jsonb),
  gateway.ctl_ack_alert(uuid, jsonb),
  gateway.ctl_approvals(uuid, jsonb),
  gateway.ctl_decide_approval(uuid, jsonb),
  gateway.enabled_servers(uuid, boolean),
  gateway.ctl_render(uuid, jsonb),
  gateway.ctl_agent(jsonb),
  gateway.ctl_insert_token(uuid, jsonb),
  gateway.ctl_tokens(uuid, jsonb),
  gateway.ctl_revoke_token(uuid, jsonb),
  gateway.ctl_rotate(uuid, jsonb)
to service_role;

alter table gateway.members enable row level security;
alter table gateway.registration_tokens enable row level security;

create policy members_owner on gateway.members
  for all to authenticated
  using (
    exists (
      select 1 from gateway.workspaces w
      where w.id = workspace_id and gateway.owns_customer(w.customer_id)
    )
    or user_id = (select auth.uid())
  )
  with check (
    exists (
      select 1 from gateway.workspaces w
      where w.id = workspace_id and gateway.owns_customer(w.customer_id)
    )
  );

-- No authenticated policy on registration token hashes. Same idea as gateway.secrets.
revoke all on gateway.members, gateway.registration_tokens from public, anon, authenticated;
grant all on gateway.members, gateway.registration_tokens to service_role;
