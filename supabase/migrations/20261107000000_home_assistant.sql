-- Home Assistant sits on top of an existing install and pushes readings out, because most
-- installs are not reachable from the internet. Pairing reuses fizz_device_pairings (a
-- short-lived claimed row, approved only after the signed-in owner allows it). Each shared
-- entity becomes an ordinary API-mode sensor, so device limits, silence alerts, and
-- /api/ingest stay on the path devices already use. The connection holds one fizz_ device
-- key; revoking it stops every entity. Readings are labeled source homeassistant.

alter table public.fizz_device_pairings
  add column ha_state_hash bytea;
create unique index fizz_device_pairings_ha_state_idx
  on public.fizz_device_pairings(ha_state_hash) where ha_state_hash is not null;

create table public.fizz_ha_connections (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.fizz_customers(id) on delete cascade,
  pairing_id uuid references public.fizz_device_pairings(id) on delete set null,
  name text not null check (char_length(name) between 1 and 80),
  key_hash bytea unique,
  ha_version text check (ha_version is null or char_length(ha_version) <= 40),
  created_at timestamptz not null default now(),
  last_seen_at timestamptz,
  revoked_at timestamptz
);
create index fizz_ha_connections_customer_idx
  on public.fizz_ha_connections(customer_id) where revoked_at is null;

alter table public.fizz_sensors
  add column ha_connection_id uuid references public.fizz_ha_connections(id) on delete cascade,
  add column ha_entity_id text,
  add column device_class text,
  add column unit text,
  add constraint fizz_sensors_ha_entity_check check (
    (ha_connection_id is null and ha_entity_id is null)
    or (ha_connection_id is not null and ha_entity_id ~ '^(sensor|binary_sensor)\.[a-z0-9_]{1,120}$')),
  add constraint fizz_sensors_device_class_check check (
    device_class is null or device_class ~ '^[a-z][a-z0-9_]{0,39}$'),
  add constraint fizz_sensors_unit_check check (
    unit is null or (char_length(unit) between 1 and 24 and unit !~ '[[:cntrl:]]'));
create unique index fizz_sensors_ha_entity_idx
  on public.fizz_sensors(ha_connection_id, ha_entity_id)
  where deleted_at is null and ha_entity_id is not null;
create index fizz_sensors_ha_connection_idx
  on public.fizz_sensors(ha_connection_id)
  where deleted_at is null and ha_connection_id is not null;

do $$
declare v_name text;
begin
  select conname into v_name from pg_constraint
  where conrelid = 'public.fizz_sensor_readings'::regclass and contype = 'c'
    and (pg_get_constraintdef(oid) ilike '%source in%' or pg_get_constraintdef(oid) ilike '%(source = any%');
  if v_name is not null then
    execute format('alter table public.fizz_sensor_readings drop constraint %I', v_name);
  end if;
end $$;
alter table public.fizz_sensor_readings
  add constraint fizz_sensor_readings_source_check
  check (source in ('simulated', 'api', 'phone', 'homeassistant'));

alter table public.fizz_ha_connections enable row level security;
revoke all on public.fizz_ha_connections from anon, authenticated;
grant all on public.fizz_ha_connections to service_role;

-- Owner policies. A Home Assistant connection, and a sensor that points at one, cannot be
-- moved onto another customer. Service-role RPCs do the writes; these policies are the
-- same authenticated backstop as the rest of the account.
do $policies$
declare
  v_authenticated constant text := $predicate$
    coalesce((select auth.jwt() ->> 'is_anonymous'), 'false') <> 'true'
  $predicate$;
  v_owner text;
  v_policy text;
begin
  for v_policy in
    select policyname from pg_policies where schemaname = 'public' and tablename = 'fizz_sensors'
  loop
    execute format('drop policy %I on public.fizz_sensors', v_policy);
  end loop;
  v_owner := format('(%s) and (%s)', v_authenticated, $predicate$
    exists (select 1 from public.fizz_customers c
      where c.id = fizz_sensors.customer_id and c.auth_user_id = (select auth.uid()))
    and (ha_connection_id is null or exists (select 1 from public.fizz_ha_connections h
      where h.id = fizz_sensors.ha_connection_id and h.customer_id = fizz_sensors.customer_id))
  $predicate$);
  execute format('create policy fizz_sensors_owner_select on public.fizz_sensors for select to authenticated using (%s)', v_owner);
  execute format('create policy fizz_sensors_owner_insert on public.fizz_sensors for insert to authenticated with check (%s)', v_owner);
  execute format('create policy fizz_sensors_owner_update on public.fizz_sensors for update to authenticated using (%s) with check (%s)', v_owner, v_owner);
  execute format('create policy fizz_sensors_owner_delete on public.fizz_sensors for delete to authenticated using (%s)', v_owner);

  v_owner := format('(%s) and (%s)', v_authenticated, $predicate$
    exists (select 1 from public.fizz_customers c
      where c.id = fizz_ha_connections.customer_id and c.auth_user_id = (select auth.uid()))
    and (pairing_id is null or exists (select 1 from public.fizz_device_pairings p
      where p.id = fizz_ha_connections.pairing_id and p.customer_id = fizz_ha_connections.customer_id))
  $predicate$);
  execute format('create policy fizz_ha_connections_owner_select on public.fizz_ha_connections for select to authenticated using (%s)', v_owner);
  execute format('create policy fizz_ha_connections_owner_insert on public.fizz_ha_connections for insert to authenticated with check (%s)', v_owner);
  execute format('create policy fizz_ha_connections_owner_update on public.fizz_ha_connections for update to authenticated using (%s) with check (%s)', v_owner, v_owner);
  execute format('create policy fizz_ha_connections_owner_delete on public.fizz_ha_connections for delete to authenticated using (%s)', v_owner);
end;
$policies$;

-- A display unit copied onto a custom reading. Known metrics keep the unit ingest already assigns.
create function public.fizz_ha_clean_unit(p_unit text)
returns text language sql immutable set search_path = '' as $$
  select case
    when p_unit is null then null
    when char_length(trim(p_unit)) between 1 and 24 and trim(p_unit) !~ '[[:cntrl:]]' then trim(p_unit)
    else null end;
$$;

-- Map a Home Assistant entity onto a Fizzlayer sensor type. The integration converts values
-- into these units before it posts; an unrecognized device class stays a custom sensor.
create function public.fizz_ha_entity_spec(p_entity_id text, p_device_class text, p_unit text)
returns jsonb language plpgsql immutable set search_path = '' as $$
declare
  v_domain text := split_part(p_entity_id, '.', 1);
  v_class text := case when p_device_class ~ '^[a-z][a-z0-9_]{0,39}$' then p_device_class else null end;
  v_kind text := 'custom';
  v_metric text := 'value';
  v_unit text := public.fizz_ha_clean_unit(p_unit);
  v_boolean boolean := false;
begin
  if p_entity_id !~ '^(sensor|binary_sensor)\.[a-z0-9_]{1,120}$' then
    return null;
  end if;
  if v_domain = 'binary_sensor' then
    v_boolean := true;
    v_unit := null;
    if v_class = 'moisture' then v_kind := 'water'; v_metric := 'leak';
    elsif v_class in ('gas', 'carbon_monoxide', 'safety') then v_kind := 'gas'; v_metric := 'alarm';
    elsif v_class in ('door', 'window', 'opening', 'garage_door', 'lock') then v_metric := 'open';
    elsif v_class in ('motion', 'occupancy', 'presence', 'moving') then v_metric := 'occupied';
    else v_metric := 'on';
    end if;
  elsif v_class = 'temperature' then v_kind := 'temperature'; v_metric := 'temperature_c'; v_unit := '°C';
  elsif v_class = 'humidity' then v_kind := 'humidity'; v_metric := 'humidity_pct'; v_unit := '%';
  elsif v_class in ('pressure', 'atmospheric_pressure') then v_kind := 'pressure'; v_metric := 'pressure_kpa'; v_unit := 'kPa';
  elsif v_class in ('gas', 'carbon_monoxide') then v_kind := 'gas'; v_metric := 'concentration_ppm'; v_unit := 'ppm';
  elsif v_class = 'sound_pressure' then v_kind := 'sound'; v_metric := 'sound_db'; v_unit := 'dB';
  elsif v_class = 'power' then v_metric := 'power_w'; v_unit := 'W';
  elsif v_class = 'energy' then v_metric := 'energy_kwh'; v_unit := 'kWh';
  elsif v_class = 'battery' then v_metric := 'battery_pct'; v_unit := '%';
  elsif v_class = 'current' then v_metric := 'current_a'; v_unit := 'A';
  elsif v_class = 'voltage' then v_metric := 'voltage_v'; v_unit := 'V';
  elsif v_class = 'signal_strength' then v_metric := 'signal_dbm'; v_unit := 'dBm';
  end if;
  return jsonb_build_object(
    'kind', v_kind, 'metric', v_metric, 'unit', v_unit,
    'boolean', v_boolean, 'device_class', v_class);
end;
$$;

-- Opens a claimed Home Assistant pairing. The plaintext code is returned once for the
-- fallback path; the state hash is what the integration polls with. Nothing is approved yet.
create function public.fizz_ha_open_pairing(p_customer uuid, p_name text, p_state text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_alphabet constant text := '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  v_name text := left(regexp_replace(trim(coalesce(p_name, '')), '[[:cntrl:]]', '', 'g'), 80);
  v_bytes bytea; v_code text; v_secret text; v_id uuid;
  v_expires timestamptz := now() + interval '15 minutes';
  v_state_hash bytea;
begin
  if v_name = '' then v_name := 'Home Assistant'; end if;
  if p_state is not null then
    if p_state !~ '^[0-9a-f]{64}$' then return jsonb_build_object('error', 'invalid_request'); end if;
    v_state_hash := extensions.digest(p_state, 'sha256');
  end if;
  v_secret := encode(extensions.gen_random_bytes(32), 'hex');
  for attempt in 1..5 loop
    v_bytes := extensions.gen_random_bytes(8);
    v_code := '';
    for j in 0..7 loop
      v_code := v_code || substr(v_alphabet, get_byte(v_bytes, j) % 32 + 1, 1);
    end loop;
    begin
      insert into public.fizz_device_pairings(
        code_hash, poll_hash, device_name, platform, status, customer_id,
        claimed_via, claimed_at, expires_at, ha_state_hash)
      values (
        extensions.digest(v_code, 'sha256'), extensions.digest(v_secret, 'sha256'),
        v_name, 'homeassistant', 'claimed', p_customer, 'dashboard', now(), v_expires, v_state_hash)
      returning id into v_id;
      return jsonb_build_object(
        'pairing_id', v_id,
        'code', substr(v_code, 1, 4) || '-' || substr(v_code, 5, 4),
        'expires_at', v_expires);
    exception when unique_violation then
      if v_state_hash is not null and exists (
        select 1 from public.fizz_device_pairings where ha_state_hash = v_state_hash
      ) then
        return jsonb_build_object('error', 'already_linked');
      end if;
    end;
  end loop;
  return jsonb_build_object('error', 'unavailable');
end;
$$;

-- Approves a claimed Home Assistant pairing and returns its device key once.
create function public.fizz_ha_finish(p_pairing uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_pair public.fizz_device_pairings%rowtype;
  v_conn public.fizz_ha_connections%rowtype;
  v_key text; v_username text; v_plan jsonb;
begin
  select * into v_pair from public.fizz_device_pairings where id = p_pairing for update;
  if not found or v_pair.platform is distinct from 'homeassistant' then
    return jsonb_build_object('error', 'not_found');
  end if;
  if v_pair.status = 'approved' then return jsonb_build_object('error', 'already_linked'); end if;
  if v_pair.status <> 'claimed' or v_pair.customer_id is null or v_pair.expires_at <= now() then
    return jsonb_build_object('error', 'expired');
  end if;
  v_key := 'fizz_' || encode(extensions.gen_random_bytes(32), 'hex');
  insert into public.fizz_ha_connections(customer_id, pairing_id, name, key_hash)
  values (v_pair.customer_id, v_pair.id, v_pair.device_name, extensions.digest(v_key, 'sha256'))
  returning * into v_conn;
  update public.fizz_device_pairings set status = 'approved', finished_at = now() where id = v_pair.id;
  select username into v_username from public.fizz_customers where id = v_pair.customer_id;
  v_plan := public.fizz_plan_usage(v_pair.customer_id);
  return jsonb_build_object(
    'api_key', v_key, 'connection_id', v_conn.id, 'account', v_username,
    'device_name', v_conn.name, 'devices_used', v_plan->'devices_used',
    'device_limit', v_plan->'device_limit');
end;
$$;

create function public.fizz_ha_prepare(p_token text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_customer uuid; v_opened jsonb;
begin
  v_customer := public.fizz_session_customer(p_token);
  if v_customer is null then return jsonb_build_object('error', 'unauthorized'); end if;
  if not public.fizz_rate_limit_hit('ha_prepare', v_customer::text, 10, interval '1 hour') then
    return jsonb_build_object('error', 'rate_limited');
  end if;
  v_opened := public.fizz_ha_open_pairing(v_customer, 'Home Assistant', null);
  if v_opened ? 'error' then return v_opened; end if;
  return jsonb_build_object('code', v_opened->'code', 'expires_at', v_opened->'expires_at');
end;
$$;

-- The signed-in owner allows the state Home Assistant is polling. No device key is returned here.
create function public.fizz_ha_authorize(p_token text, p_state text, p_name text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_customer uuid; v_pair public.fizz_device_pairings%rowtype; v_opened jsonb;
begin
  v_customer := public.fizz_session_customer(p_token);
  if v_customer is null then return jsonb_build_object('error', 'unauthorized'); end if;
  if p_state is null or p_state !~ '^[0-9a-f]{64}$' then
    return jsonb_build_object('error', 'invalid_request');
  end if;
  if not public.fizz_rate_limit_hit('ha_authorize', v_customer::text, 20, interval '1 hour') then
    return jsonb_build_object('error', 'rate_limited');
  end if;
  select * into v_pair from public.fizz_device_pairings
  where ha_state_hash = extensions.digest(p_state, 'sha256') for update;
  if found then
    if v_pair.customer_id is distinct from v_customer or v_pair.platform is distinct from 'homeassistant' then
      return jsonb_build_object('error', 'invalid_request');
    end if;
    if v_pair.status = 'approved' then return jsonb_build_object('error', 'already_linked'); end if;
    if v_pair.status = 'claimed' and v_pair.expires_at > now() then
      return jsonb_build_object('ok', true, 'expires_at', v_pair.expires_at);
    end if;
    return jsonb_build_object('error', 'expired');
  end if;
  v_opened := public.fizz_ha_open_pairing(v_customer, p_name, p_state);
  if v_opened->>'error' = 'already_linked' then
    select * into v_pair from public.fizz_device_pairings
    where ha_state_hash = extensions.digest(p_state, 'sha256');
    if v_pair.customer_id = v_customer and v_pair.status = 'claimed' and v_pair.expires_at > now() then
      return jsonb_build_object('ok', true, 'expires_at', v_pair.expires_at);
    end if;
  end if;
  if v_opened ? 'error' then return v_opened; end if;
  return jsonb_build_object('ok', true, 'expires_at', v_opened->'expires_at');
end;
$$;

create function public.fizz_ha_exchange(p_state text, p_ip text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_pair public.fizz_device_pairings%rowtype; v_ip text := left(coalesce(p_ip, ''), 80);
begin
  if p_state is null or p_state !~ '^[0-9a-f]{64}$' then
    return jsonb_build_object('error', 'invalid_request');
  end if;
  if not public.fizz_rate_limit_hit('ha_exchange_ip', v_ip, 40, interval '1 minute') then
    return jsonb_build_object('error', 'rate_limited');
  end if;
  select * into v_pair from public.fizz_device_pairings
  where ha_state_hash = extensions.digest(p_state, 'sha256') for update;
  if not found then return jsonb_build_object('status', 'pending'); end if;
  if v_pair.platform is distinct from 'homeassistant' then
    return jsonb_build_object('status', 'pending');
  end if;
  if v_pair.status = 'approved' then return jsonb_build_object('error', 'already_linked'); end if;
  if v_pair.status <> 'claimed' or v_pair.expires_at <= now() then
    return jsonb_build_object('error', 'expired');
  end if;
  return public.fizz_ha_finish(v_pair.id);
end;
$$;

create function public.fizz_ha_exchange_code(p_code text, p_ip text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_code text := public.fizz_normalize_pairing_code(p_code);
  v_pair public.fizz_device_pairings%rowtype;
  v_ip text := left(coalesce(p_ip, ''), 80);
begin
  if not public.fizz_rate_limit_hit('ha_exchange_code_ip', v_ip, 30, interval '1 hour') then
    return jsonb_build_object('error', 'rate_limited');
  end if;
  if v_code is null then return jsonb_build_object('error', 'invalid_code'); end if;
  select * into v_pair from public.fizz_device_pairings
  where code_hash = extensions.digest(v_code, 'sha256') and platform = 'homeassistant'
  for update;
  if not found then return jsonb_build_object('error', 'invalid_code'); end if;
  if v_pair.status = 'approved' then return jsonb_build_object('error', 'already_linked'); end if;
  if v_pair.status <> 'claimed' or v_pair.expires_at <= now() then
    return jsonb_build_object('error', 'expired');
  end if;
  return public.fizz_ha_finish(v_pair.id);
end;
$$;

create function public.fizz_ha_connection_for_key(p_key text)
returns public.fizz_ha_connections language plpgsql stable security definer set search_path = '' as $$
declare v_conn public.fizz_ha_connections%rowtype;
begin
  if p_key is null or p_key !~ '^fizz_[0-9a-f]{64}$' then return null; end if;
  select * into v_conn from public.fizz_ha_connections
  where revoked_at is null and key_hash is not null and key_hash = extensions.digest(p_key, 'sha256');
  return v_conn;
end;
$$;

-- The entity list is the set Home Assistant should share. replace drops entities that were
-- removed from that set (soft-delete, so the device slot frees and history stays). New
-- entities stop at the plan's device limit; ones that already exist stay editable.
create function public.fizz_ha_sync(p_key text, p_entities jsonb, p_name text, p_ha_version text, p_replace boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_conn public.fizz_ha_connections%rowtype;
  v_item jsonb; v_spec jsonb; v_entity text; v_name text; v_seen text[] := '{}';
  v_sensor public.fizz_sensors%rowtype;
  v_sensors jsonb := '[]'::jsonb; v_skipped jsonb := '[]'::jsonb;
  v_version text; v_count integer; v_plan jsonb;
begin
  v_conn := public.fizz_ha_connection_for_key(p_key);
  if v_conn.id is null then return jsonb_build_object('error', 'unauthorized'); end if;
  if not public.fizz_rate_limit_hit('ha_sync', v_conn.id::text, 120, interval '1 hour') then
    return jsonb_build_object('error', 'rate_limited');
  end if;
  -- Same lock as device-limit checks, taken before any insert or soft-delete.
  perform pg_advisory_xact_lock(hashtextextended('fizz_devices:' || v_conn.customer_id::text, 0));
  if p_entities is null or jsonb_typeof(p_entities) <> 'array' then
    return jsonb_build_object('error', 'invalid_request');
  end if;
  if jsonb_array_length(p_entities) > 50 then
    return jsonb_build_object('error', 'invalid_request');
  end if;
  v_version := left(regexp_replace(trim(coalesce(p_ha_version, '')), '[[:cntrl:]]', '', 'g'), 40);
  update public.fizz_ha_connections set
    name = case
      when nullif(left(regexp_replace(trim(coalesce(p_name, '')), '[[:cntrl:]]', '', 'g'), 80), '') is null then name
      else left(regexp_replace(trim(p_name), '[[:cntrl:]]', '', 'g'), 80) end,
    ha_version = case when v_version = '' then ha_version else v_version end,
    last_seen_at = now()
  where id = v_conn.id returning * into v_conn;

  if coalesce(p_replace, true) then
    update public.fizz_sensors set deleted_at = now(), status = 'paused'
    where ha_connection_id = v_conn.id and deleted_at is null
      and not (ha_entity_id in (
        select e->>'entity_id' from jsonb_array_elements(p_entities) e
        where e->>'entity_id' ~ '^(sensor|binary_sensor)\.[a-z0-9_]{1,120}$'));
  end if;

  for v_item in select value from jsonb_array_elements(p_entities) loop
    v_entity := v_item->>'entity_id';
    v_spec := public.fizz_ha_entity_spec(v_entity, v_item->>'device_class', v_item->>'unit');
    if v_spec is null or v_entity = any(v_seen) then
      v_skipped := v_skipped || jsonb_build_array(jsonb_build_object('entity_id', v_entity, 'error', 'invalid_entity'));
      continue;
    end if;
    v_seen := v_seen || v_entity;
    v_name := left(regexp_replace(trim(coalesce(v_item->>'name', '')), '[[:cntrl:]]', '', 'g'), 80);
    if v_name = '' then v_name := left(replace(v_entity, '_', ' '), 80); end if;
    select * into v_sensor from public.fizz_sensors
    where ha_connection_id = v_conn.id and ha_entity_id = v_entity
    order by (deleted_at is null) desc, created_at desc
    limit 1 for update;
    if found and v_sensor.deleted_at is null then
      update public.fizz_sensors set
        name = v_name, kind = v_spec->>'kind', device_class = v_spec->>'device_class',
        unit = v_spec->>'unit', mode = 'api'
      where id = v_sensor.id returning * into v_sensor;
    elsif public.fizz_device_limit_reached(v_conn.customer_id) then
      v_skipped := v_skipped || jsonb_build_array(jsonb_build_object('entity_id', v_entity, 'error', 'device_limit'));
      continue;
    elsif found then
      update public.fizz_sensors set
        deleted_at = null, status = 'active', name = v_name, kind = v_spec->>'kind',
        device_class = v_spec->>'device_class', unit = v_spec->>'unit', mode = 'api', api_key_hash = null
      where id = v_sensor.id returning * into v_sensor;
    else
      insert into public.fizz_sensors(
        customer_id, kind, name, mode, status, ha_connection_id, ha_entity_id, device_class, unit)
      values (
        v_conn.customer_id, v_spec->>'kind', v_name, 'api', 'active', v_conn.id, v_entity,
        v_spec->>'device_class', v_spec->>'unit')
      returning * into v_sensor;
    end if;
    v_sensors := v_sensors || jsonb_build_array(jsonb_build_object(
      'entity_id', v_entity, 'sensor_id', v_sensor.id, 'name', v_sensor.name,
      'kind', v_sensor.kind, 'metric', v_spec->>'metric', 'unit', v_sensor.unit,
      'boolean', v_spec->'boolean', 'device_class', v_sensor.device_class));
  end loop;
  select count(*) into v_count from public.fizz_sensors
  where ha_connection_id = v_conn.id and deleted_at is null;
  v_plan := public.fizz_plan_usage(v_conn.customer_id);
  return jsonb_build_object(
    'connection_id', v_conn.id, 'sensors', v_sensors, 'skipped', v_skipped,
    'shared', v_count, 'devices_used', v_plan->'devices_used', 'device_limit', v_plan->'device_limit');
end;
$$;

create function public.fizz_ha_list(p_token text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_customer uuid;
begin
  v_customer := public.fizz_session_customer(p_token);
  if v_customer is null then return jsonb_build_object('error', 'unauthorized'); end if;
  return jsonb_build_object('connections', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', c.id, 'name', c.name, 'ha_version', c.ha_version,
      'created_at', c.created_at, 'last_seen_at', c.last_seen_at,
      'revoked', c.revoked_at is not null,
      'sensors', (select count(*) from public.fizz_sensors s
        where s.ha_connection_id = c.id and s.deleted_at is null))
      order by c.created_at, c.id)
    from public.fizz_ha_connections c where c.customer_id = v_customer
  ), '[]'::jsonb));
end;
$$;

create function public.fizz_ha_revoke_connection(p_id uuid, p_customer uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_conn public.fizz_ha_connections%rowtype;
begin
  select * into v_conn from public.fizz_ha_connections
  where id = p_id and customer_id = p_customer for update;
  if not found then return jsonb_build_object('error', 'not_found'); end if;
  if v_conn.revoked_at is not null then return jsonb_build_object('ok', true, 'revoked', true); end if;
  update public.fizz_ha_connections set revoked_at = now(), key_hash = null where id = p_id;
  -- Soft-delete frees the device slots. The delete trigger disables alerts. Readings stay.
  update public.fizz_sensors set deleted_at = now(), status = 'paused', api_key_hash = null
  where ha_connection_id = p_id and deleted_at is null;
  return jsonb_build_object('ok', true, 'revoked', true);
end;
$$;

create function public.fizz_ha_revoke(p_token text, p_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_customer uuid;
begin
  v_customer := public.fizz_session_customer(p_token);
  if v_customer is null then return jsonb_build_object('error', 'unauthorized'); end if;
  if not public.fizz_rate_limit_hit('ha_revoke', v_customer::text, 30, interval '1 hour') then
    return jsonb_build_object('error', 'rate_limited');
  end if;
  return public.fizz_ha_revoke_connection(p_id, v_customer);
end;
$$;

create function public.fizz_ha_revoke_key(p_key text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_conn public.fizz_ha_connections%rowtype;
begin
  v_conn := public.fizz_ha_connection_for_key(p_key);
  if v_conn.id is null then return jsonb_build_object('error', 'unauthorized'); end if;
  return public.fizz_ha_revoke_connection(v_conn.id, v_conn.customer_id);
end;
$$;

-- Same reading checks as before. A Home Assistant connection key is accepted for sensors
-- that belong to it; per-sensor keys are unchanged. source homeassistant is what the
-- dashboard labels. A paused sensor is rejected without looking like a revoked key.
create or replace function public.fizz_ingest_reading(p_sensor_id uuid, p_key text, p_event_id text, p_observed_at timestamptz,
  p_metric text, p_numeric_value double precision, p_boolean_value boolean, p_text_value text, p_unit text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_sensor public.fizz_sensors%rowtype;
  v_conn public.fizz_ha_connections%rowtype;
  v_source text := 'api';
begin
  if p_key is null or p_key !~ '^fizz_[0-9a-f]{64}$' then
    return jsonb_build_object('error', 'unauthorized');
  end if;
  select * into v_sensor from public.fizz_sensors
  where id = p_sensor_id and deleted_at is null and mode = 'api';
  if not found then return jsonb_build_object('error', 'unauthorized'); end if;
  if v_sensor.status <> 'active' then return jsonb_build_object('error', 'paused'); end if;
  if v_sensor.api_key_hash is not null and v_sensor.api_key_hash = extensions.digest(p_key, 'sha256') then
    v_source := 'api';
  else
    select * into v_conn from public.fizz_ha_connections
    where id = v_sensor.ha_connection_id and revoked_at is null and key_hash is not null
      and key_hash = extensions.digest(p_key, 'sha256');
    if not found then return jsonb_build_object('error', 'unauthorized'); end if;
    v_source := 'homeassistant';
    update public.fizz_ha_connections set last_seen_at = now() where id = v_conn.id;
  end if;
  if not coalesce((case v_sensor.kind
    when 'water' then (p_metric = 'flow_l_min' and p_numeric_value between 0 and 200) or (p_metric = 'leak' and p_boolean_value is not null)
    when 'gas' then (p_metric = 'concentration_ppm' and p_numeric_value between 0 and 10000) or (p_metric = 'alarm' and p_boolean_value is not null)
    when 'radio' then p_metric = 'rssi_dbm' and p_numeric_value between -150 and 0
    when 'temperature' then p_metric = 'temperature_c' and p_numeric_value between -100 and 200
    when 'pressure' then p_metric = 'pressure_kpa' and p_numeric_value between 0 and 1000
    when 'humidity' then p_metric = 'humidity_pct' and p_numeric_value between 0 and 100
    when 'sound' then p_metric = 'sound_db' and p_numeric_value between 0 and 160
    when 'phone' then (p_metric = 'acceleration_ms2' and p_numeric_value between 0 and 300)
      or (p_metric = 'orientation_deg' and p_numeric_value between -360 and 360)
    when 'custom' then true else false end), false) then
    return jsonb_build_object('error', 'invalid_reading');
  end if;
  if not public.fizz_rate_limit_hit('ingest_sensor', v_sensor.id::text, 1200, interval '1 minute')
    or not public.fizz_rate_limit_hit('ingest_customer', v_sensor.customer_id::text, 5000, interval '1 minute') then
    return jsonb_build_object('error', 'rate_limited');
  end if;
  return public.fizz_write_reading(p_sensor_id, p_event_id, coalesce(p_observed_at, now()), p_metric, p_numeric_value, p_boolean_value, p_text_value, p_unit, v_source);
end;
$$;

create or replace function public.fizz_write_reading(p_sensor_id uuid, p_event_id text, p_observed_at timestamptz,
  p_metric text, p_numeric_value double precision, p_boolean_value boolean, p_text_value text, p_unit text, p_source text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_reading public.fizz_sensor_readings%rowtype;
begin
  if p_event_id is null or char_length(p_event_id) not between 1 and 128
    or p_metric !~ '^[a-z][a-z0-9_]{0,39}$'
    or p_source not in ('simulated', 'api', 'phone', 'homeassistant')
    or p_observed_at < now() - interval '30 days' or p_observed_at > now() + interval '5 minutes'
    or (p_numeric_value is not null)::integer + (p_boolean_value is not null)::integer + (p_text_value is not null)::integer <> 1
    or (p_numeric_value is not null and (p_numeric_value <= '-Infinity'::float8 or p_numeric_value >= 'Infinity'::float8))
    or (p_text_value is not null and char_length(p_text_value) > 512)
    or (p_unit is not null and char_length(p_unit) > 24) then
    return jsonb_build_object('error', 'invalid_reading');
  end if;
  insert into public.fizz_sensor_readings(sensor_id, event_id, observed_at, metric, numeric_value, boolean_value, text_value, unit, source)
  values (p_sensor_id, p_event_id, p_observed_at, p_metric, p_numeric_value, p_boolean_value, p_text_value, p_unit, p_source)
  on conflict (sensor_id, event_id, metric) do update set id = public.fizz_sensor_readings.id
  returning * into v_reading;
  return to_jsonb(v_reading);
end;
$$;

-- Custom and Home Assistant metrics keep the unit stored on the sensor when the metric
-- name is not one of the built-in ones (power_w, a door contact, and anything else).
create or replace function public.fizz_ingest_event(p_sensor_id uuid, p_key text, p_event_id text,
  p_observed_at timestamptz, p_metrics jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_metric text; v_value jsonb; v_type text; v_result jsonb; v_results jsonb := '[]'::jsonb;
  v_count integer;
  v_numeric double precision; v_boolean boolean; v_text text; v_unit text; v_sensor_unit text;
begin
  if p_metrics is null or jsonb_typeof(p_metrics) <> 'object' then
    return jsonb_build_object('error', 'invalid_reading');
  end if;
  select count(*) into v_count from jsonb_object_keys(p_metrics);
  if v_count not between 1 and 16 then return jsonb_build_object('error', 'invalid_reading'); end if;
  select unit into v_sensor_unit from public.fizz_sensors where id = p_sensor_id;
  begin
    for v_metric, v_value in select key, value from jsonb_each(p_metrics) loop
      v_type := jsonb_typeof(v_value);
      if v_metric !~ '^[a-z][a-z0-9_]{0,39}$'
        or v_type not in ('number', 'boolean', 'string') then
        raise exception 'invalid_reading' using errcode = '22023';
      end if;
      v_numeric := null; v_boolean := null; v_text := null;
      if v_type = 'number' then v_numeric := (v_value #>> '{}')::double precision;
      elsif v_type = 'boolean' then v_boolean := (v_value #>> '{}')::boolean;
      else v_text := v_value #>> '{}'; end if;
      v_unit := case v_metric
        when 'flow_l_min' then 'L/min' when 'concentration_ppm' then 'ppm'
        when 'rssi_dbm' then 'dBm' when 'temperature_c' then '°C'
        when 'pressure_kpa' then 'kPa' when 'humidity_pct' then '%'
        when 'sound_db' then 'dB' when 'acceleration_ms2' then 'm/s²'
        when 'orientation_deg' then '°'
        when 'cpu_temperature_c' then '°C'
        when 'memory_used_pct' then '%' when 'disk_used_pct' then '%'
        else null end;
      if v_unit is null then v_unit := v_sensor_unit; end if;
      v_result := public.fizz_ingest_reading(p_sensor_id, p_key, p_event_id, p_observed_at,
        v_metric, v_numeric, v_boolean, v_text, v_unit);
      if v_result ? 'error' then
        raise exception '%', v_result->>'error' using errcode = '22023';
      end if;
      v_results := v_results || jsonb_build_array(v_result);
    end loop;
  exception when sqlstate '22023' then
    return jsonb_build_object('error', SQLERRM);
  end;
  return jsonb_build_object('accepted', v_results);
end;
$$;

-- One round trip for a Home Assistant flush. Each item still goes through fizz_ingest_event,
-- so idempotency, metric checks, and the per-sensor rate limit are unchanged. A bad item
-- does not roll back the others. An unknown key fails the whole batch.
create function public.fizz_ingest_batch(p_key text, p_readings jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_item jsonb; v_at timestamptz; v_metrics jsonb; v_id uuid; v_event text;
  v_result jsonb; v_results jsonb := '[]'::jsonb; v_known boolean;
begin
  if p_key is null or p_key !~ '^fizz_[0-9a-f]{64}$' then
    return jsonb_build_object('error', 'unauthorized');
  end if;
  if p_readings is null or jsonb_typeof(p_readings) <> 'array'
    or jsonb_array_length(p_readings) not between 1 and 40 then
    return jsonb_build_object('error', 'invalid_request');
  end if;
  v_known := (public.fizz_ha_connection_for_key(p_key)).id is not null
    or exists (select 1 from public.fizz_sensors s
      where s.deleted_at is null and s.mode = 'api' and s.api_key_hash = extensions.digest(p_key, 'sha256'));
  if not v_known then return jsonb_build_object('error', 'unauthorized'); end if;
  for v_item in select value from jsonb_array_elements(p_readings) loop
    begin
      v_id := (v_item->>'sensor_id')::uuid;
      v_event := v_item->>'event_id';
      v_metrics := v_item->'metrics';
      v_at := null;
      if nullif(v_item->>'observed_at', '') is not null then
        v_at := (v_item->>'observed_at')::timestamptz;
      end if;
      v_result := public.fizz_ingest_event(v_id, p_key, v_event, v_at, v_metrics);
    exception when others then
      v_result := jsonb_build_object('error', 'invalid_reading');
    end;
    v_results := v_results || jsonb_build_array(
      case when v_result ? 'sensor_id' then v_result
        else v_result || jsonb_build_object('sensor_id', v_item->>'sensor_id') end);
  end loop;
  return jsonb_build_object('connection', 'ok', 'results', v_results);
end;
$$;

-- Home Assistant sensors are managed by the connection. Mode changes and key rotation
-- would detach them from the key the integration is holding.
create or replace function public.fizz_update_sensor(p_token text, p_id uuid, p_name text default null, p_mode text default null, p_status text default null, p_rotate_key boolean default false)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_customer uuid; v_sensor public.fizz_sensors%rowtype; v_key text;
begin
  v_customer := public.fizz_session_customer(p_token);
  if v_customer is null then return jsonb_build_object('error', 'unauthorized'); end if;
  select * into v_sensor from public.fizz_sensors where id = p_id and customer_id = v_customer and deleted_at is null for update;
  if not found then return jsonb_build_object('error', 'not_found'); end if;
  if v_sensor.ha_connection_id is not null and (p_mode is not null or coalesce(p_rotate_key, false)) then
    return jsonb_build_object('error', 'invalid_request');
  end if;
  if (p_name is not null and char_length(trim(p_name)) not between 1 and 80)
    or (p_mode is not null and (p_mode not in ('simulated', 'api', 'phone') or (p_mode = 'phone' and v_sensor.kind <> 'phone')))
    or (p_status is not null and p_status not in ('active', 'paused')) then
    return jsonb_build_object('error', 'invalid_request');
  end if;
  if v_sensor.mode = 'simulated' and coalesce(p_mode, 'simulated') <> 'simulated'
    and public.fizz_device_limit_reached(v_customer) then
    return jsonb_build_object('error', 'device_limit');
  end if;
  -- A Home Assistant sensor has no key of its own. Minting one here would detach it
  -- from the connection key on a rename.
  if v_sensor.ha_connection_id is null
    and coalesce(p_mode, v_sensor.mode) = 'api'
    and (v_sensor.api_key_hash is null or coalesce(p_rotate_key, false) or v_sensor.mode <> 'api') then
    v_key := 'fizz_' || encode(extensions.gen_random_bytes(32), 'hex');
  end if;
  update public.fizz_sensors set
    name = coalesce(trim(p_name), name), mode = coalesce(p_mode, mode), status = coalesce(p_status, status),
    api_key_hash = case when coalesce(p_mode, mode) <> 'api' then null
      when v_key is not null then extensions.digest(v_key, 'sha256') else api_key_hash end,
    last_sample_at = case when p_mode = 'simulated' and v_sensor.mode <> 'simulated' then null else last_sample_at end
  where id = p_id returning * into v_sensor;
  return jsonb_build_object('sensor', public.fizz_sensor_json(v_sensor), 'api_key', v_key);
end;
$$;

create or replace function public.fizz_sensor_json(p_sensor public.fizz_sensors)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', p_sensor.id, 'kind', p_sensor.kind, 'name', p_sensor.name,
    'mode', p_sensor.mode, 'status', p_sensor.status,
    'source', case
      when p_sensor.ha_connection_id is not null then 'homeassistant'
      when p_sensor.mode = 'phone' then 'phone'
      when p_sensor.mode = 'simulated' then 'simulated'
      else 'api' end,
    'device_class', p_sensor.device_class,
    'unit', p_sensor.unit,
    'ha_entity_id', p_sensor.ha_entity_id,
    'ha_connection_id', p_sensor.ha_connection_id,
    'created_at', p_sensor.created_at,
    'last_received_at', (select r.received_at from public.fizz_sensor_readings r
      where r.sensor_id = p_sensor.id order by r.received_at desc limit 1),
    'latest_reading', (select to_jsonb(r) from public.fizz_sensor_readings r
      where r.sensor_id = p_sensor.id
      order by r.observed_at desc,
        case when r.metric = case p_sensor.kind
          when 'water' then 'flow_l_min' when 'gas' then 'concentration_ppm'
          when 'radio' then 'rssi_dbm' when 'temperature' then 'temperature_c'
          when 'pressure' then 'pressure_kpa' when 'humidity' then 'humidity_pct'
          when 'sound' then 'sound_db' when 'phone' then 'acceleration_ms2'
          else 'value' end then 0 else 1 end,
        r.received_at desc limit 1),
    'latest_metrics', coalesce((
      select jsonb_agg(jsonb_build_object(
          'metric', m.metric, 'numeric_value', m.numeric_value, 'boolean_value', m.boolean_value,
          'text_value', m.text_value, 'unit', m.unit, 'observed_at', m.observed_at
        ) order by m.metric)
      from (
        select distinct on (r.metric) r.metric, r.numeric_value, r.boolean_value, r.text_value, r.unit, r.observed_at
        from (
          select * from public.fizz_sensor_readings r0
          where r0.sensor_id = p_sensor.id
          order by r0.observed_at desc, r0.received_at desc
          limit 200
        ) r
        order by r.metric, r.observed_at desc, r.received_at desc
        limit 24
      ) m
    ), '[]'::jsonb)
  );
$$;

revoke execute on function
  public.fizz_ha_clean_unit(text),
  public.fizz_ha_entity_spec(text, text, text),
  public.fizz_ha_open_pairing(uuid, text, text),
  public.fizz_ha_finish(uuid),
  public.fizz_ha_prepare(text),
  public.fizz_ha_authorize(text, text, text),
  public.fizz_ha_exchange(text, text),
  public.fizz_ha_exchange_code(text, text),
  public.fizz_ha_connection_for_key(text),
  public.fizz_ha_sync(text, jsonb, text, text, boolean),
  public.fizz_ha_list(text),
  public.fizz_ha_revoke_connection(uuid, uuid),
  public.fizz_ha_revoke(text, uuid),
  public.fizz_ha_revoke_key(text),
  public.fizz_ingest_batch(text, jsonb)
from public, anon, authenticated;
grant execute on function
  public.fizz_ha_entity_spec(text, text, text),
  public.fizz_ha_prepare(text),
  public.fizz_ha_authorize(text, text, text),
  public.fizz_ha_exchange(text, text),
  public.fizz_ha_exchange_code(text, text),
  public.fizz_ha_sync(text, jsonb, text, text, boolean),
  public.fizz_ha_list(text),
  public.fizz_ha_revoke(text, uuid),
  public.fizz_ha_revoke_key(text),
  public.fizz_ingest_batch(text, jsonb)
to service_role;
