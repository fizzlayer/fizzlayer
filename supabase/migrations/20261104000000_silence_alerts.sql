-- Silence alerts fire when a sensor stops reporting. A reading trigger cannot see
-- that absence, so fizz_scan_silence_alerts runs about once a minute from the
-- protected /api/cron function. A rule fires once per quiet period and arms
-- again when a reading arrives. Calls use the same per-rule and per-account
-- limits as threshold alerts.

alter table public.fizz_alert_rules
  add column kind text not null default 'threshold',
  add column silence_minutes integer,
  add column notify_recovery boolean not null default false,
  -- Newest received_at plus silence_minutes. Null until the sensor has reported.
  -- The minute scan reads this column, so it does not look up every armed rule.
  add column silence_due_at timestamptz;

alter table public.fizz_alert_rules
  add constraint fizz_alert_rules_kind_check check (kind in ('threshold', 'silence')),
  add constraint fizz_alert_rules_kind_shape check (
    (kind = 'threshold' and silence_minutes is null and not notify_recovery)
    or (kind = 'silence' and silence_minutes between 1 and 10080));

alter table public.fizz_alert_events
  add column event_kind text not null default 'threshold'
    check (event_kind in ('threshold', 'silence', 'recovery'));

-- A recovery notice and the next silence both refer to the reading that resumed
-- the sensor. The kind has to be part of the key or that next quiet period is dropped.
alter table public.fizz_alert_events
  drop constraint fizz_alert_events_rule_id_reading_id_key;
alter table public.fizz_alert_events
  add constraint fizz_alert_events_rule_reading_kind_key
  unique (rule_id, reading_id, event_kind);

-- One row, written by each silence scan. The dashboard reads it to warn when no
-- scheduler is calling /api/cron, since silence alerts cannot fire without one.
create table public.fizz_scheduler_status (
  id boolean primary key default true check (id),
  last_scan_at timestamptz not null
);
alter table public.fizz_scheduler_status enable row level security;
revoke all on public.fizz_scheduler_status from anon, authenticated;
grant all on public.fizz_scheduler_status to service_role;

create index fizz_alert_rules_silence_due_idx
  on public.fizz_alert_rules (silence_due_at, id)
  where kind = 'silence' and enabled and armed and silence_due_at is not null;
-- Supabase runs migrations inside a transaction, so this cannot be CREATE INDEX
-- CONCURRENTLY. On a large readings table the build locks writes until it finishes.
-- Before deploying to a large database, create the same index concurrently and this
-- statement will find it already present:
--   create index concurrently if not exists fizz_readings_sensor_received_idx
--     on public.fizz_sensor_readings (sensor_id, received_at desc);
create index if not exists fizz_readings_sensor_received_idx
  on public.fizz_sensor_readings (sensor_id, received_at desc);

-- Same North American check as the API. Agents may pass a formatted number.
create function public.fizz_us_phone(p_phone text)
returns text language plpgsql immutable set search_path = '' as $$
declare v_digits text; v_national text;
begin
  if p_phone is null or btrim(p_phone) = '' then return null; end if;
  if btrim(p_phone) ~ '[^0-9 +().-]' then return null; end if;
  v_digits := regexp_replace(btrim(p_phone), '[^0-9]', '', 'g');
  if length(v_digits) = 11 and left(v_digits, 1) = '1' then v_national := substr(v_digits, 2);
  elsif length(v_digits) = 10 then v_national := v_digits;
  else return null; end if;
  if substr(v_national, 1, 1) < '2' or substr(v_national, 4, 1) < '2' then return null; end if;
  return '+1' || v_national;
end;
$$;

-- 'none' when the rule does not call, 'skipped' inside the 5-minute rule
-- cooldown or the 20-call account hour, otherwise 'pending'.
create function public.fizz_alert_notify_status(p_customer uuid, p_rule uuid, p_channel text)
returns text language plpgsql security definer set search_path = '' as $$
begin
  if p_channel is distinct from 'call' then return 'none'; end if;
  if exists(select 1 from public.fizz_alert_events
      where rule_id = p_rule and notify_status in ('pending', 'sending', 'sent')
        and created_at > now() - interval '5 minutes')
    or (select count(*) from public.fizz_alert_events
      where customer_id = p_customer and notify_status in ('pending', 'sending', 'sent')
        and created_at > now() - interval '1 hour') >= 20 then
    return 'skipped';
  end if;
  return 'pending';
end;
$$;

create or replace function public.fizz_evaluate_alerts() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_rule public.fizz_alert_rules%rowtype;
  v_hit boolean;
  v_notify text;
  v_cancelled bigint;
begin
  update public.fizz_alert_rules
  set silence_due_at = new.received_at + make_interval(mins => silence_minutes)
  -- Enabled only, so this uses the partial sensor index. Resuming a rule recomputes it.
  where sensor_id = new.sensor_id and kind = 'silence' and enabled
    and (silence_due_at is null or silence_due_at < new.received_at + make_interval(mins => silence_minutes));

  -- A reading just stored by the server means the sensor is reporting again.
  -- Backdated rows do not, because received_at is the server clock.
  if new.received_at >= now() - interval '1 minute' then
    for v_rule in
      select * from public.fizz_alert_rules
      where sensor_id = new.sensor_id and kind = 'silence' and enabled and not armed
      order by id
      for update
    loop
      update public.fizz_alert_rules set armed = true, updated_at = now() where id = v_rule.id;
      update public.fizz_alert_events
      set notify_status = 'skipped',
          notify_error = 'Sensor reported again before the call was placed.'
      where rule_id = v_rule.id and event_kind = 'silence' and notify_status = 'pending';
      get diagnostics v_cancelled = row_count;
      if v_cancelled = 0 and v_rule.notify_recovery then
        v_notify := public.fizz_alert_notify_status(v_rule.customer_id, v_rule.id, v_rule.notify_channel);
        insert into public.fizz_alert_events
          (rule_id, reading_id, customer_id, sensor_id, metric, numeric_value, threshold, comparator, unit, observed_at,
           notify_channel, notify_phone, notify_status, event_kind)
        values
          (v_rule.id, new.id, v_rule.customer_id, new.sensor_id, 'silence',
           0, v_rule.silence_minutes, 'gte', 'min', new.observed_at,
           v_rule.notify_channel, v_rule.notify_phone, v_notify, 'recovery')
        on conflict (rule_id, reading_id, event_kind) do nothing;
      end if;
    end loop;
  end if;

  if new.numeric_value is null then return new; end if;
  for v_rule in
    select * from public.fizz_alert_rules
    where sensor_id = new.sensor_id and metric = new.metric and enabled and kind = 'threshold'
    for update
  loop
    if v_rule.unit <> coalesce(new.unit, '') then continue; end if;
    v_hit := case v_rule.comparator
      when 'gt' then new.numeric_value > v_rule.threshold
      when 'gte' then new.numeric_value >= v_rule.threshold
      when 'lt' then new.numeric_value < v_rule.threshold
      else new.numeric_value <= v_rule.threshold end;
    if v_hit and v_rule.armed then
      v_notify := public.fizz_alert_notify_status(v_rule.customer_id, v_rule.id, v_rule.notify_channel);
      insert into public.fizz_alert_events
        (rule_id, reading_id, customer_id, sensor_id, metric, numeric_value, threshold, comparator, unit, observed_at,
         notify_channel, notify_phone, notify_status)
      values
        (v_rule.id, new.id, v_rule.customer_id, new.sensor_id, new.metric,
         new.numeric_value, v_rule.threshold, v_rule.comparator, v_rule.unit, new.observed_at,
         v_rule.notify_channel, v_rule.notify_phone, v_notify)
      on conflict (rule_id, reading_id, event_kind) do nothing;
      update public.fizz_alert_rules set armed = false, updated_at = now() where id = v_rule.id;
    elsif not v_hit and not v_rule.armed then
      update public.fizz_alert_rules set armed = true, updated_at = now() where id = v_rule.id;
    end if;
  end loop;
  return new;
end;
$$;

-- One pass over silence rules whose stored due time has passed. The due time is
-- maintained when a reading is stored, so the scan does not look up every armed
-- rule. Locks are skipped when another worker holds them. The same kind of
-- event for one reading is recorded only once.
create function public.fizz_scan_silence_alerts(p_limit integer default 50)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_rule public.fizz_alert_rules%rowtype;
  v_reading_id uuid;
  v_received timestamptz;
  v_minutes double precision;
  v_notify text;
  v_inserted bigint;
  v_fired integer := 0;
  v_queued integer := 0;
  v_skipped integer := 0;
begin
  insert into public.fizz_scheduler_status(id, last_scan_at) values (true, now())
  on conflict (id) do update set last_scan_at = excluded.last_scan_at;
  for v_rule in
    select r.*
    from public.fizz_alert_rules r
    join public.fizz_sensors s
      on s.id = r.sensor_id and s.deleted_at is null and s.status = 'active'
      -- Sample sensors only produce readings while someone is viewing them.
      and s.mode <> 'simulated'
    where r.kind = 'silence' and r.enabled and r.armed
      and r.silence_due_at <= now()
    order by r.silence_due_at, r.id
    limit least(greatest(coalesce(p_limit, 50), 1), 200)
    for update of r skip locked
  loop
    select rd.id, rd.received_at into v_reading_id, v_received
    from public.fizz_sensor_readings rd
    where rd.sensor_id = v_rule.sensor_id
    order by rd.received_at desc
    limit 1;
    if not found or v_received > now() - make_interval(mins => v_rule.silence_minutes) then
      update public.fizz_alert_rules
      set silence_due_at = case when v_received is null then null
            else v_received + make_interval(mins => silence_minutes) end,
          updated_at = now()
      where id = v_rule.id;
      continue;
    end if;
    v_minutes := extract(epoch from (now() - v_received)) / 60.0;
    v_notify := public.fizz_alert_notify_status(v_rule.customer_id, v_rule.id, v_rule.notify_channel);
    insert into public.fizz_alert_events
      (rule_id, reading_id, customer_id, sensor_id, metric, numeric_value, threshold, comparator, unit, observed_at,
       notify_channel, notify_phone, notify_status, event_kind)
    values
      (v_rule.id, v_reading_id, v_rule.customer_id, v_rule.sensor_id, 'silence',
       v_minutes, v_rule.silence_minutes, 'gte', 'min', now(),
       v_rule.notify_channel, v_rule.notify_phone, v_notify, 'silence')
    on conflict (rule_id, reading_id, event_kind) do nothing;
    get diagnostics v_inserted = row_count;
    if v_inserted = 1 then
      v_fired := v_fired + 1;
      if v_notify = 'pending' then v_queued := v_queued + 1;
      elsif v_notify = 'skipped' then v_skipped := v_skipped + 1; end if;
    end if;
    update public.fizz_alert_rules set armed = false, updated_at = now() where id = v_rule.id;
  end loop;
  return jsonb_build_object('fired', v_fired, 'queued', v_queued, 'skipped', v_skipped);
end;
$$;

create or replace function public.fizz_claim_alert_notifications(p_limit integer default 3)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_batch jsonb;
begin
  -- AgentPhone has no idempotency keys: do not repeat an abandoned call
  -- whose provider result or database acknowledgment could have been lost.
  update public.fizz_alert_events
  set notify_status = 'failed', notify_error = 'Send outcome unknown; check AgentPhone history before retrying.'
  where notify_status = 'sending' and notify_claimed_at < now() - interval '2 minutes';
  update public.fizz_alert_events
  set notify_status = 'failed', notify_error = 'Expired before it could be sent.'
  where notify_status = 'pending' and created_at < now() - interval '1 hour';
  with claimed as (
    update public.fizz_alert_events e
    set notify_status = 'sending', notify_claimed_at = now(), notify_attempts = e.notify_attempts + 1
    where e.id in (
      select ev.id from public.fizz_alert_events ev
      join public.fizz_alert_rules r on r.id = ev.rule_id and r.enabled
      join public.fizz_sensors s on s.id = ev.sensor_id
        and s.deleted_at is null and s.status = 'active'
      where ev.notify_status = 'pending' and ev.notify_channel = 'call'
        and ev.notify_attempts < 3
        and (ev.event_kind <> 'silence' or not exists (
          select 1 from public.fizz_sensor_readings newer
          join public.fizz_sensor_readings basis on basis.id = ev.reading_id
          where newer.sensor_id = ev.sensor_id and newer.received_at > basis.received_at))
      order by ev.created_at
      limit least(greatest(coalesce(p_limit, 3), 1), 10)
      for update of ev skip locked)
    returning e.*)
  select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'channel', c.notify_channel, 'phone', c.notify_phone,
      'sensor_name', s.name, 'metric', c.metric, 'numeric_value', c.numeric_value, 'threshold', c.threshold,
      'comparator', c.comparator, 'unit', c.unit, 'observed_at', c.observed_at, 'event_kind', c.event_kind)), '[]'::jsonb)
  into v_batch
  from claimed c join public.fizz_sensors s on s.id = c.sensor_id;
  return v_batch;
end;
$$;

-- Drop a queued call that should not be dialed. Sending rows are left for the
-- pre-dial check, which can still see a pause or a fresh reading.
create function public.fizz_cancel_pending_alerts(p_rule uuid, p_sensor uuid, p_reason text)
returns void language sql security definer set search_path = '' as $$
  update public.fizz_alert_events
  set notify_status = 'skipped', notify_error = left(p_reason, 200)
  where notify_status = 'pending'
    and (p_rule is null or rule_id = p_rule)
    and (p_sensor is null or sensor_id = p_sensor);
$$;

-- Called after a row is claimed and before the provider is contacted.
create function public.fizz_alert_call_still_due(p_event_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_event public.fizz_alert_events%rowtype;
  v_reason text;
begin
  select * into v_event from public.fizz_alert_events where id = p_event_id for update;
  if not found or v_event.notify_status <> 'sending' then
    return jsonb_build_object('send', false);
  end if;
  if not exists (
    select 1 from public.fizz_alert_rules r
    join public.fizz_sensors s on s.id = r.sensor_id
    where r.id = v_event.rule_id and r.enabled
      and s.deleted_at is null and s.status = 'active'
  ) then
    v_reason := 'Alert or sensor is no longer active.';
  elsif v_event.event_kind = 'silence' and exists (
    select 1 from public.fizz_sensor_readings newer
    join public.fizz_sensor_readings basis on basis.id = v_event.reading_id
    where newer.sensor_id = v_event.sensor_id and newer.received_at > basis.received_at
  ) then
    v_reason := 'Sensor reported again before the call was placed.';
  end if;
  if v_reason is not null then
    update public.fizz_alert_events
    set notify_status = 'skipped', notify_error = v_reason
    where id = p_event_id;
    return jsonb_build_object('send', false);
  end if;
  return jsonb_build_object('send', true);
end;
$$;

drop function public.fizz_create_chat_alert(text, uuid, text, text, double precision, text, text, text);
drop function public.fizz_create_alert(text, uuid, text, text, double precision, text, text, text);

-- Shared by the dashboard, chat, and MCP paths, so matching and the due time
-- live in one place. Callers check ownership and validate the arguments first.
-- Returns {rule, created} or {error}. p_max_active caps enabled rules (null = no cap).
create function public.fizz_save_alert_rule(p_customer uuid, p_sensor_id uuid, p_kind text,
  p_metric text, p_comparator text, p_threshold double precision, p_unit text,
  p_channel text, p_phone text, p_minutes integer, p_recovery boolean, p_max_active integer)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_rule public.fizz_alert_rules%rowtype;
begin
  -- Serialize per customer so concurrent repeats cannot create duplicate rules.
  perform pg_advisory_xact_lock(hashtextextended(p_customer::text, 0));
  if p_kind = 'silence' and exists(select 1 from public.fizz_sensors
      where id = p_sensor_id and mode = 'simulated') then
    return jsonb_build_object('error','simulated_sensor');
  end if;
  select r.* into v_rule from public.fizz_alert_rules r
  join public.fizz_sensors s on s.id = r.sensor_id
  where r.customer_id = p_customer and s.deleted_at is null and r.enabled
    and r.kind = p_kind and r.sensor_id = p_sensor_id
    and r.notify_channel = p_channel and r.notify_phone is not distinct from p_phone
    and case when p_kind = 'silence'
      then r.silence_minutes = p_minutes and r.notify_recovery = p_recovery
      else r.metric = p_metric and r.comparator = p_comparator
        and r.threshold = p_threshold and r.unit = p_unit end
  limit 1;
  if found then
    return jsonb_build_object('rule', to_jsonb(v_rule) - 'customer_id', 'created', false);
  end if;
  if p_max_active is not null and (select count(*) from public.fizz_alert_rules
      where customer_id = p_customer and enabled) >= p_max_active then
    return jsonb_build_object('error','alert_limit');
  end if;
  if p_kind = 'silence' then
    insert into public.fizz_alert_rules(
      customer_id, sensor_id, metric, comparator, threshold, unit,
      notify_channel, notify_phone, kind, silence_minutes, notify_recovery, silence_due_at)
    values (
      p_customer, p_sensor_id, 'silence', 'gte', p_minutes, 'min',
      p_channel, p_phone, 'silence', p_minutes, p_recovery,
      (select rd.received_at + make_interval(mins => p_minutes)
       from public.fizz_sensor_readings rd
       where rd.sensor_id = p_sensor_id order by rd.received_at desc limit 1))
    returning * into v_rule;
  else
    insert into public.fizz_alert_rules(customer_id, sensor_id, metric, comparator, threshold, unit, notify_channel, notify_phone)
    values (p_customer, p_sensor_id, p_metric, p_comparator, p_threshold, p_unit, p_channel, p_phone)
    returning * into v_rule;
  end if;
  return jsonb_build_object('rule', to_jsonb(v_rule) - 'customer_id', 'created', true);
end;
$$;

-- Chat and the dashboard both call this. It returns the existing rule when an
-- identical one is already active.
create function public.fizz_create_alert(p_token text, p_sensor_id uuid, p_metric text default null,
  p_comparator text default null, p_threshold double precision default null, p_unit text default null,
  p_notify_channel text default 'none', p_notify_phone text default null,
  p_kind text default 'threshold', p_silence_minutes integer default null,
  p_notify_recovery boolean default false)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_customer uuid;
  v_unit text;
  v_minutes integer;
begin
  v_customer := public.fizz_session_customer(p_token);
  if v_customer is null then return jsonb_build_object('error','unauthorized'); end if;
  if not exists(select 1 from public.fizz_sensors where id = p_sensor_id
      and customer_id = v_customer and deleted_at is null) then
    return jsonb_build_object('error','sensor_not_found');
  end if;
  if coalesce(p_notify_channel, 'none') not in ('none','call')
    or (coalesce(p_notify_channel, 'none') = 'none') <> (p_notify_phone is null)
    or p_notify_phone !~ '^\+1[2-9][0-9]{2}[2-9][0-9]{6}$' then
    return jsonb_build_object('error','invalid_notify');
  end if;

  if coalesce(p_kind, 'threshold') = 'silence' then
    -- One minute is above the 15-second ingest floor and matches the scheduler.
    v_minutes := coalesce(p_silence_minutes, 10);
    if v_minutes < 1 or v_minutes > 10080 then
      return jsonb_build_object('error','invalid_rule');
    end if;
    return public.fizz_save_alert_rule(v_customer, p_sensor_id, 'silence', null, null, null, null,
      coalesce(p_notify_channel, 'none'), p_notify_phone, v_minutes, coalesce(p_notify_recovery, false), null);
  elsif coalesce(p_kind, 'threshold') <> 'threshold'
    or p_silence_minutes is not null or coalesce(p_notify_recovery, false) then
    return jsonb_build_object('error','invalid_rule');
  end if;

  if p_metric is null or p_metric !~ '^[a-z][a-z0-9_]{0,63}$'
    or p_comparator not in ('gt','gte','lt','lte')
    or p_threshold is null or p_threshold = 'Infinity'::float8 or p_threshold = '-Infinity'::float8
    or p_unit is null or length(p_unit) > 24 then
    return jsonb_build_object('error','invalid_rule');
  end if;
  select coalesce(unit, '') into v_unit from public.fizz_sensor_readings
  where sensor_id = p_sensor_id and metric = p_metric and numeric_value is not null
  order by received_at desc limit 1;
  if not found or v_unit <> p_unit then
    return jsonb_build_object('error','unknown_metric');
  end if;
  return public.fizz_save_alert_rule(v_customer, p_sensor_id, 'threshold', p_metric, p_comparator,
    p_threshold, p_unit, coalesce(p_notify_channel, 'none'), p_notify_phone, null, false, null);
end;
$$;

create or replace function public.fizz_agent_call(p_agent_token text, p_ip text, p_tool text, p_args jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_conn public.fizz_agent_connections%rowtype;
  v_args jsonb := coalesce(p_args, '{}'::jsonb);
  v_sensor public.fizz_sensors%rowtype;
  v_limit integer; v_metric text; v_comparator text; v_threshold double precision; v_unit text;
  v_saved jsonb;
  v_kind text; v_minutes integer; v_channel text; v_phone text; v_recovery boolean;
begin
  if p_agent_token is null or p_agent_token !~ '^fizz_agent_[0-9a-f]{64}$' then
    return jsonb_build_object('error','unauthorized');
  end if;
  select a.* into v_conn from public.fizz_agent_connections a
  where a.token_hash = extensions.digest(p_agent_token, 'sha256') and a.revoked_at is null;
  if not found then return jsonb_build_object('error','unauthorized'); end if;
  if not public.fizz_rate_limit_hit('agent', v_conn.id::text, 120, interval '1 minute') then
    return jsonb_build_object('error','rate_limited');
  end if;
  update public.fizz_agent_connections set last_used_at = now()
  where id = v_conn.id and (last_used_at is null or last_used_at < now() - interval '1 minute');
  if jsonb_typeof(v_args) <> 'object' then
    return jsonb_build_object('error','invalid_arguments','message','Arguments must be an object.');
  end if;

  if p_tool = 'connection' then
    return jsonb_build_object('result', jsonb_build_object('name', v_conn.name, 'can_create_alerts', v_conn.can_create_alerts));

  elsif p_tool = 'list_sensors' then
    perform public.fizz_tick_simulated_for(v_conn.customer_id);
    return jsonb_build_object('result', jsonb_build_object('sensors', coalesce((
      select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'type', s.kind, 'mode', s.mode,
        'status', s.status,
        'latest', (select public.fizz_agent_reading_json(r) from public.fizz_sensor_readings r
          where r.sensor_id = s.id order by r.observed_at desc, r.received_at desc limit 1))
        order by s.created_at, s.id)
      from public.fizz_sensors s where s.customer_id = v_conn.customer_id and s.deleted_at is null), '[]'::jsonb)));

  elsif p_tool = 'get_readings' then
    if coalesce(v_args->>'sensor_id', '') !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then
      return jsonb_build_object('error','invalid_arguments','message','sensor_id must be a sensor ID from list_sensors.');
    end if;
    select * into v_sensor from public.fizz_sensors
    where id = (v_args->>'sensor_id')::uuid and customer_id = v_conn.customer_id and deleted_at is null;
    if not found then
      return jsonb_build_object('error','not_found','message','No sensor with that ID. Call list_sensors for valid IDs.');
    end if;
    v_limit := case when jsonb_typeof(v_args->'limit') = 'number' then least(greatest((v_args->>'limit')::numeric::integer, 1), 100) else 20 end;
    v_metric := nullif(v_args->>'metric', '');
    perform public.fizz_tick_simulated_for(v_conn.customer_id);
    return jsonb_build_object('result', jsonb_build_object(
      'sensor', jsonb_build_object('id', v_sensor.id, 'name', v_sensor.name, 'type', v_sensor.kind),
      'readings', coalesce((select jsonb_agg(public.fizz_agent_reading_json(x) order by x.observed_at desc, x.received_at desc)
        from (select * from public.fizz_sensor_readings where sensor_id = v_sensor.id
          and (v_metric is null or metric = v_metric)
          order by observed_at desc, received_at desc limit v_limit) x), '[]'::jsonb)));

  elsif p_tool = 'list_alerts' then
    return jsonb_build_object('result', jsonb_build_object(
      'rules', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'sensor_id', r.sensor_id, 'sensor_name', s.name,
          'kind', r.kind, 'metric', r.metric, 'comparator', r.comparator, 'threshold', r.threshold, 'unit', r.unit,
          'silence_minutes', r.silence_minutes, 'notify_recovery', r.notify_recovery,
          'enabled', r.enabled, 'triggered', not r.armed, 'calls_phone', r.notify_channel = 'call')
        order by r.created_at desc)
        from public.fizz_alert_rules r join public.fizz_sensors s on s.id = r.sensor_id
        where r.customer_id = v_conn.customer_id and s.deleted_at is null), '[]'::jsonb),
      'recent_triggers', coalesce((select jsonb_agg(jsonb_build_object('sensor_id', e.sensor_id, 'sensor_name', s.name,
          'kind', e.event_kind, 'metric', e.metric, 'value', e.numeric_value, 'comparator', e.comparator, 'threshold', e.threshold,
          'unit', e.unit, 'observed_at', e.observed_at) order by e.created_at desc)
        from (select * from public.fizz_alert_events where customer_id = v_conn.customer_id
          order by created_at desc limit 20) e join public.fizz_sensors s on s.id = e.sensor_id), '[]'::jsonb)));

  elsif p_tool = 'create_alert' then
    if not v_conn.can_create_alerts then
      return jsonb_build_object('error','forbidden','message','This agent connection is read-only. The account owner can allow alert creation when connecting an agent.');
    end if;
    if coalesce(v_args->>'sensor_id', '') !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then
      return jsonb_build_object('error','invalid_arguments','message','sensor_id must be a sensor ID from list_sensors.');
    end if;
    select * into v_sensor from public.fizz_sensors
    where id = (v_args->>'sensor_id')::uuid and customer_id = v_conn.customer_id and deleted_at is null;
    if not found then
      return jsonb_build_object('error','not_found','message','No sensor with that ID. Call list_sensors for valid IDs.');
    end if;
    v_kind := coalesce(nullif(v_args->>'kind', ''), 'threshold');
    if v_kind not in ('threshold', 'silence') then
      return jsonb_build_object('error','invalid_arguments','message','kind must be threshold or silence.');
    end if;
    v_channel := 'none';
    v_phone := null;
    if nullif(v_args->>'call_phone', '') is not null then
      v_phone := public.fizz_us_phone(v_args->>'call_phone');
      if v_phone is null then
        return jsonb_build_object('error','invalid_arguments','message','call_phone must be a US number, for example (415) 555-0123.');
      end if;
      v_channel := 'call';
    end if;
    -- Agents may only reuse a number the owner has on an active alert, so pausing
    -- or deleting the last alert for a number also stops agents from calling it.
    if v_phone is not null and not exists (
      select 1 from public.fizz_alert_rules r
      join public.fizz_sensors s on s.id = r.sensor_id and s.deleted_at is null
      where r.customer_id = v_conn.customer_id and r.enabled and r.notify_phone = v_phone
    ) then
      return jsonb_build_object('error','invalid_arguments','message',
        'call_phone must already be saved on an active alert in this workspace. The owner adds it from the dashboard or by asking Fizz.');
    end if;
    if v_args ? 'notify_recovery' and jsonb_typeof(v_args->'notify_recovery') <> 'boolean' then
      return jsonb_build_object('error','invalid_arguments','message','notify_recovery must be true or false.');
    end if;
    v_recovery := coalesce((v_args->>'notify_recovery')::boolean, false);
    if v_recovery and v_kind <> 'silence' then
      return jsonb_build_object('error','invalid_arguments','message','A recovery notice is only available on a silence alert.');
    end if;

    if v_kind = 'silence' then
      if v_args ? 'silence_minutes' then
        if jsonb_typeof(v_args->'silence_minutes') <> 'number'
          or (v_args->>'silence_minutes')::numeric <> trunc((v_args->>'silence_minutes')::numeric)
          or (v_args->>'silence_minutes')::numeric < 1
          or (v_args->>'silence_minutes')::numeric > 10080 then
          return jsonb_build_object('error','invalid_arguments','message','silence_minutes must be a whole number of minutes from 1 to 10080. The default is 10.');
        end if;
        v_minutes := (v_args->>'silence_minutes')::integer;
      else
        v_minutes := 10;
      end if;
      v_saved := public.fizz_save_alert_rule(v_conn.customer_id, v_sensor.id, 'silence', null, null, null, null,
        v_channel, v_phone, v_minutes, v_recovery, 100);
    else
      v_metric := v_args->>'metric';
      v_comparator := v_args->>'comparator';
      if v_metric is null or v_metric !~ '^[a-z][a-z0-9_]{0,63}$' or v_comparator is null
        or v_comparator not in ('gt','gte','lt','lte') or jsonb_typeof(v_args->'threshold') <> 'number' then
        return jsonb_build_object('error','invalid_arguments','message','Provide metric, comparator (gt, gte, lt, lte), and a numeric threshold.');
      end if;
      v_threshold := (v_args->>'threshold')::double precision;
      select coalesce(unit, '') into v_unit from public.fizz_sensor_readings
      where sensor_id = v_sensor.id and metric = v_metric and numeric_value is not null
      order by received_at desc limit 1;
      if not found then
        return jsonb_build_object('error','invalid_arguments','message','That sensor has not reported a numeric value for this metric yet. Use get_readings to see its metrics.');
      end if;
      if v_args ? 'unit' and coalesce(v_args->>'unit', '') <> v_unit then
        return jsonb_build_object('error','invalid_arguments','message', format('This metric is reported in %s; use that unit or omit it.', coalesce(nullif(v_unit, ''), 'no unit')));
      end if;
      v_saved := public.fizz_save_alert_rule(v_conn.customer_id, v_sensor.id, 'threshold', v_metric, v_comparator,
        v_threshold, v_unit, v_channel, v_phone, null, false, 100);
    end if;
    if v_saved->>'error' = 'simulated_sensor' then
      return jsonb_build_object('error','invalid_arguments','message',
        'Sample sensors only report while someone is viewing them, so they cannot have a silence alert.');
    elsif v_saved->>'error' = 'alert_limit' then
      return jsonb_build_object('error','invalid_arguments','message','This account already has 100 active alerts. Pause or delete some first.');
    end if;
    return jsonb_build_object('result', jsonb_build_object('created', v_saved->'created', 'rule',
      jsonb_build_object('id', v_saved->'rule'->'id', 'sensor_id', v_saved->'rule'->'sensor_id',
        'kind', v_saved->'rule'->'kind', 'calls_phone', v_saved->'rule'->>'notify_channel' = 'call')
      || case when v_kind = 'silence'
        then jsonb_build_object('silence_minutes', v_saved->'rule'->'silence_minutes',
          'notify_recovery', v_saved->'rule'->'notify_recovery')
        else jsonb_build_object('metric', v_saved->'rule'->'metric', 'comparator', v_saved->'rule'->'comparator',
          'threshold', v_saved->'rule'->'threshold', 'unit', v_saved->'rule'->'unit') end));

  elsif p_tool = 'pair_device' then
    return (select case when x ? 'error' then x || jsonb_build_object('message', case x->>'error'
        when 'rate_limited' then 'Too many pairing attempts. Try again in an hour.'
        else 'That code is not valid or has expired. Run fizz pair on the device for a new code.' end)
      else jsonb_build_object('result', x || jsonb_build_object('next_step',
        'Ask the person at the device to approve the pairing in the Fizz CLI. It becomes a sensor once approved.')) end
      from public.fizz_pair_claim_for(v_conn.customer_id, v_args->>'code', 'agent', v_conn.id, v_conn.name,
        v_args->>'name') x);
  end if;
  return jsonb_build_object('error','unknown_tool');
end;
$$;

create or replace function public.fizz_update_alert(p_token text, p_rule_id uuid, p_enabled boolean, p_delete boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_customer uuid; v_rule public.fizz_alert_rules%rowtype;
begin
  select customer_id into v_customer from public.fizz_sessions
  where p_token ~ '^[0-9a-f]{64}$'
    and token_hash = extensions.digest(decode(p_token, 'hex'), 'sha256') and expires_at > now();
  if v_customer is null then return jsonb_build_object('error','unauthorized'); end if;
  -- Check ownership before cancelling anything: fizz_cancel_pending_alerts has no
  -- account filter, and a later not_found return does not undo its update.
  if coalesce(p_delete,false) then
    if not exists(select 1 from public.fizz_alert_rules
        where id = p_rule_id and customer_id = v_customer) then
      return jsonb_build_object('error','not_found');
    end if;
    -- Cancel first: deleting the rule sets the events' rule_id to null.
    perform public.fizz_cancel_pending_alerts(p_rule_id, null, 'Alert was deleted.');
    delete from public.fizz_alert_rules where id = p_rule_id and customer_id = v_customer;
    return jsonb_build_object('ok',true);
  end if;
  if p_enabled is null then return jsonb_build_object('error','invalid_rule'); end if;
  if p_enabled and not exists(select 1 from public.fizz_alert_rules r
      join public.fizz_sensors s on s.id = r.sensor_id
      where r.id = p_rule_id and r.customer_id = v_customer and s.deleted_at is null) then
    return jsonb_build_object('error','not_found');
  end if;
  update public.fizz_alert_rules r set
    enabled = p_enabled,
    armed = true,
    updated_at = now(),
    silence_due_at = case when r.kind = 'silence' and p_enabled then (
      select rd.received_at + make_interval(mins => r.silence_minutes)
      from public.fizz_sensor_readings rd
      where rd.sensor_id = r.sensor_id order by rd.received_at desc limit 1)
      else r.silence_due_at end
  where r.id = p_rule_id and r.customer_id = v_customer returning * into v_rule;
  if not found then return jsonb_build_object('error','not_found'); end if;
  if not p_enabled then
    perform public.fizz_cancel_pending_alerts(p_rule_id, null, 'Alert was paused.');
  end if;
  return jsonb_build_object('rule',to_jsonb(v_rule)-'customer_id');
end;
$$;

create or replace function public.fizz_disable_sensor_alerts() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if old.deleted_at is null and new.deleted_at is not null then
    update public.fizz_alert_rules set enabled = false, updated_at = now() where sensor_id = new.id;
    perform public.fizz_cancel_pending_alerts(null, new.id, 'Sensor was removed.');
  end if;
  if new.status = 'paused' and old.status is distinct from 'paused' then
    perform public.fizz_cancel_pending_alerts(null, new.id, 'Sensor is paused.');
  end if;
  -- Readings are rejected while paused, so the stored due time is stale on resume.
  -- Give the device a full window to report before a silence alert can fire.
  if new.status = 'active' and old.status = 'paused' then
    update public.fizz_alert_rules
    set silence_due_at = greatest(silence_due_at, now() + make_interval(mins => silence_minutes)),
        updated_at = now()
    where sensor_id = new.id and kind = 'silence' and enabled and silence_due_at is not null;
  end if;
  return new;
end;
$$;

drop trigger fizz_disable_sensor_alerts_after_delete on public.fizz_sensors;
create trigger fizz_disable_sensor_alerts_after_update
after update of deleted_at, status on public.fizz_sensors
for each row execute function public.fizz_disable_sensor_alerts();

create or replace function public.fizz_sensor_json(p_sensor public.fizz_sensors)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', p_sensor.id, 'kind', p_sensor.kind, 'name', p_sensor.name,
    'mode', p_sensor.mode, 'status', p_sensor.status,
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

-- Same as before, plus whether a scheduler has scanned in the last five minutes.
create or replace function public.fizz_list_alerts(p_token text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_customer uuid;
begin
  select customer_id into v_customer from public.fizz_sessions
  where p_token ~ '^[0-9a-f]{64}$'
    and token_hash = extensions.digest(decode(p_token, 'hex'), 'sha256') and expires_at > now();
  if v_customer is null then return jsonb_build_object('error','unauthorized'); end if;
  return jsonb_build_object(
    'rules', coalesce((select jsonb_agg(to_jsonb(r) - 'customer_id' order by r.created_at desc)
      from public.fizz_alert_rules r where r.customer_id = v_customer), '[]'::jsonb),
    'events', coalesce((select jsonb_agg(to_jsonb(e) - 'customer_id' order by e.created_at desc)
      from (select * from public.fizz_alert_events where customer_id = v_customer
        order by created_at desc limit 100) e), '[]'::jsonb),
    'silence_scheduler_active', exists(select 1 from public.fizz_scheduler_status
      where last_scan_at > now() - interval '5 minutes'));
end;
$$;

revoke execute on function public.fizz_us_phone(text),
  public.fizz_cancel_pending_alerts(uuid, uuid, text),
  public.fizz_alert_call_still_due(uuid),
  public.fizz_alert_notify_status(uuid, uuid, text),
  public.fizz_scan_silence_alerts(integer),
  public.fizz_save_alert_rule(uuid, uuid, text, text, text, double precision, text, text, text, integer, boolean, integer),
  public.fizz_create_alert(text, uuid, text, text, double precision, text, text, text, text, integer, boolean)
  from public, anon, authenticated;
grant execute on function public.fizz_alert_call_still_due(uuid),
  public.fizz_scan_silence_alerts(integer),
  public.fizz_create_alert(text, uuid, text, text, double precision, text, text, text, text, integer, boolean)
  to service_role;
