-- Live socket and MQTT subscriptions. Devices still write through fizz_ingest_event, so
-- alerts, silence detection, Fizz, and MCP see the same rows as POST /api/ingest.
-- The Compute worker is the only caller of the feed and principal functions. It holds
-- the service-role key; browsers and devices never do.

create table public.fizz_stream_tokens (
  token_hash bytea primary key,
  customer_id uuid not null references public.fizz_customers(id) on delete cascade,
  sensor_id uuid references public.fizz_sensors(id) on delete cascade,
  expires_at timestamptz not null,
  created_at timestamptz not null default now(),
  check (expires_at > created_at)
);

create index fizz_stream_tokens_customer_idx on public.fizz_stream_tokens(customer_id);
create index fizz_stream_tokens_expires_idx on public.fizz_stream_tokens(expires_at);

-- The worker polls new rows for every connected subscriber. (received_at, id) is the cursor.
-- Building this index locks reading writes until it finishes. On a large table, create it
-- with CREATE INDEX CONCURRENTLY before db push; this statement then finds it already present.
create index if not exists fizz_readings_received_id_idx
  on public.fizz_sensor_readings (received_at, id);

alter table public.fizz_stream_tokens enable row level security;
revoke all on table public.fizz_stream_tokens from anon, authenticated;
grant all on table public.fizz_stream_tokens to service_role;

create function public.fizz_stream_issue(p_token text, p_sensor_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_customer uuid;
  v_raw text;
begin
  v_customer := public.fizz_session_customer(p_token);
  if v_customer is null then return jsonb_build_object('error', 'unauthorized'); end if;
  if not public.fizz_rate_limit_hit('stream_issue', v_customer::text, 60, interval '1 hour') then
    return jsonb_build_object('error', 'rate_limited');
  end if;
  if p_sensor_id is not null and not exists (
    select 1 from public.fizz_sensors s
    where s.id = p_sensor_id and s.customer_id = v_customer and s.deleted_at is null
  ) then
    return jsonb_build_object('error', 'not_found');
  end if;
  delete from public.fizz_stream_tokens where expires_at <= now();
  v_raw := 'fizz_stream_' || encode(extensions.gen_random_bytes(32), 'hex');
  insert into public.fizz_stream_tokens(token_hash, customer_id, sensor_id, expires_at)
  values (extensions.digest(v_raw, 'sha256'), v_customer, p_sensor_id, now() + interval '15 minutes');
  return jsonb_build_object(
    'token', v_raw,
    'expires_at', now() + interval '15 minutes',
    'expires_in_seconds', 900,
    'sensor_id', p_sensor_id
  );
end;
$$;

create function public.fizz_stream_issue_agent(p_agent_token text, p_sensor_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_conn public.fizz_agent_connections%rowtype;
  v_raw text;
begin
  if p_agent_token is null or p_agent_token !~ '^fizz_agent_[0-9a-f]{64}$' then
    return jsonb_build_object('error', 'unauthorized');
  end if;
  select a.* into v_conn from public.fizz_agent_connections a
  where a.token_hash = extensions.digest(p_agent_token, 'sha256') and a.revoked_at is null;
  if not found then return jsonb_build_object('error', 'unauthorized'); end if;
  if not public.fizz_rate_limit_hit('stream_issue_agent', v_conn.id::text, 30, interval '1 hour') then
    return jsonb_build_object('error', 'rate_limited');
  end if;
  if p_sensor_id is not null and not exists (
    select 1 from public.fizz_sensors s
    where s.id = p_sensor_id and s.customer_id = v_conn.customer_id and s.deleted_at is null
  ) then
    return jsonb_build_object('error', 'not_found');
  end if;
  delete from public.fizz_stream_tokens where expires_at <= now();
  v_raw := 'fizz_stream_' || encode(extensions.gen_random_bytes(32), 'hex');
  insert into public.fizz_stream_tokens(token_hash, customer_id, sensor_id, expires_at)
  values (extensions.digest(v_raw, 'sha256'), v_conn.customer_id, p_sensor_id, now() + interval '15 minutes');
  return jsonb_build_object(
    'token', v_raw,
    'expires_at', now() + interval '15 minutes',
    'expires_in_seconds', 900,
    'sensor_id', p_sensor_id
  );
end;
$$;

-- One lookup for a socket or MQTT connection. A sensor key is a device and can publish.
-- A stream grant or agent token is a viewer and cannot. sensor_id null is the whole workspace.
create function public.fizz_live_principal(p_credential text, p_sensor_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_sensor public.fizz_sensors%rowtype;
  v_grant public.fizz_stream_tokens%rowtype;
  v_conn public.fizz_agent_connections%rowtype;
  v_customer uuid;
  v_scope uuid;
begin
  if p_credential is null or not public.fizz_rate_limit_hit('live_auth_all', 'all', 5000, interval '1 minute')
    or not public.fizz_rate_limit_hit('live_auth', p_credential, 300, interval '1 minute') then
    return jsonb_build_object('error', 'rate_limited');
  end if;

  if p_credential ~ '^fizz_stream_[0-9a-f]{64}$' then
    select * into v_grant from public.fizz_stream_tokens
    where token_hash = extensions.digest(p_credential, 'sha256') and expires_at > now();
    if not found then return jsonb_build_object('error', 'unauthorized'); end if;
    v_customer := v_grant.customer_id;
    v_scope := v_grant.sensor_id;
  elsif p_credential ~ '^fizz_agent_[0-9a-f]{64}$' then
    select * into v_conn from public.fizz_agent_connections
    where token_hash = extensions.digest(p_credential, 'sha256') and revoked_at is null;
    if not found then return jsonb_build_object('error', 'unauthorized'); end if;
    v_customer := v_conn.customer_id;
    v_scope := null;
  elsif p_credential ~ '^fizz_[0-9a-f]{64}$' then
    if p_sensor_id is null then return jsonb_build_object('error', 'unauthorized'); end if;
    select * into v_sensor from public.fizz_sensors
    where id = p_sensor_id and deleted_at is null and mode = 'api'
      and api_key_hash = extensions.digest(p_credential, 'sha256');
    if not found then return jsonb_build_object('error', 'unauthorized'); end if;
    if v_sensor.status <> 'active' then return jsonb_build_object('error', 'paused'); end if;
    return jsonb_build_object(
      'role', 'device',
      'customer_id', v_sensor.customer_id,
      'sensor_id', v_sensor.id,
      'can_publish', true
    );
  else
    return jsonb_build_object('error', 'unauthorized');
  end if;

  if v_scope is not null and p_sensor_id is not null and p_sensor_id is distinct from v_scope then
    return jsonb_build_object('error', 'unauthorized');
  end if;
  if v_scope is not null and p_sensor_id is null then
    p_sensor_id := v_scope;
  end if;
  if p_sensor_id is not null and not exists (
    select 1 from public.fizz_sensors s
    where s.id = p_sensor_id and s.customer_id = v_customer and s.deleted_at is null
  ) then
    return jsonb_build_object('error', 'unauthorized');
  end if;
  return jsonb_build_object(
    'role', 'viewer',
    'customer_id', v_customer,
    'sensor_id', p_sensor_id,
    'can_publish', false
  );
end;
$$;

-- Newest stored rows, across workspaces. The worker drops customer_id before it forwards
-- a row, and only forwards it to a subscriber whose principal is that customer.
create function public.fizz_live_since(
  p_received_after timestamptz default null,
  p_after_id uuid default null,
  p_limit integer default 100
)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 100), 1), 200);
  v_id uuid := coalesce(p_after_id, '00000000-0000-0000-0000-000000000000');
  v_rows jsonb;
begin
  if p_received_after is null then
    return jsonb_build_object('readings', '[]'::jsonb, 'now', now());
  end if;
  select coalesce(jsonb_agg(to_jsonb(q) order by q.received_at, q.id), '[]'::jsonb)
    into v_rows
  from (
    select r.id, r.sensor_id, s.customer_id, r.event_id, r.metric,
      r.numeric_value, r.boolean_value, r.text_value, r.unit,
      r.observed_at, r.received_at, r.source
    from public.fizz_sensor_readings r
    join public.fizz_sensors s on s.id = r.sensor_id and s.deleted_at is null
    where (r.received_at, r.id) > (p_received_after, v_id)
    order by r.received_at, r.id
    limit v_limit
  ) q;
  return jsonb_build_object('readings', v_rows);
end;
$$;

revoke execute on function
  public.fizz_stream_issue(text, uuid),
  public.fizz_stream_issue_agent(text, uuid),
  public.fizz_live_principal(text, uuid),
  public.fizz_live_since(timestamptz, uuid, integer)
from public, anon, authenticated;

grant execute on function
  public.fizz_stream_issue(text, uuid),
  public.fizz_stream_issue_agent(text, uuid),
  public.fizz_live_principal(text, uuid),
  public.fizz_live_since(timestamptz, uuid, integer)
to service_role;
