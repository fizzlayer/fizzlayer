-- Silence alerts fire when a sensor stops reporting. A reading trigger cannot see
-- that absence, so fizz_scan_silence_alerts runs about once a minute from the
-- protected /api/cron function. A rule fires once per quiet period and arms
-- again when a reading arrives. Calls use the same per-rule and per-account
-- limits as threshold alerts.

alter table public.fizz_alert_rules
  add column kind text not null default 'threshold',
  add column silence_minutes integer,
  add column notify_recovery boolean not null default false;

alter table public.fizz_alert_rules
  add constraint fizz_alert_rules_kind_check check (kind in ('threshold', 'silence')),
  add constraint fizz_alert_rules_kind_shape check (
    (kind = 'threshold' and silence_minutes is null and not notify_recovery)
    or (kind = 'silence' and silence_minutes between 1 and 10080));

alter table public.fizz_alert_events
  add column event_kind text not null default 'threshold'
    check (event_kind in ('threshold', 'silence', 'recovery'));

create index fizz_alert_rules_silence_armed_idx
  on public.fizz_alert_rules (sensor_id)
  where kind = 'silence' and enabled and armed;
create index fizz_readings_sensor_received_idx
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
        on conflict (rule_id, reading_id) do nothing;
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
      on conflict (rule_id, reading_id) do nothing;
      update public.fizz_alert_rules set armed = false, updated_at = now() where id = v_rule.id;
    elsif not v_hit and not v_rule.armed then
      update public.fizz_alert_rules set armed = true, updated_at = now() where id = v_rule.id;
    end if;
  end loop;
  return new;
end;
$$;

-- One pass over armed silence rules whose newest server-received reading is
-- already older than the rule. Locks are skipped when another worker holds
-- them, and (rule, last reading) can be recorded only once.
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
  for v_rule in
    select r.*
    from public.fizz_alert_rules r
    join public.fizz_sensors s
      on s.id = r.sensor_id and s.deleted_at is null and s.status = 'active'
    join lateral (
      select rd.received_at
      from public.fizz_sensor_readings rd
      where rd.sensor_id = r.sensor_id
      order by rd.received_at desc
      limit 1
    ) last on last.received_at <= now() - make_interval(mins => r.silence_minutes)
    where r.kind = 'silence' and r.enabled and r.armed
    order by last.received_at, r.id
    limit least(greatest(coalesce(p_limit, 50), 1), 200)
    for update of r skip locked
  loop
    select rd.id, rd.received_at into v_reading_id, v_received
    from public.fizz_sensor_readings rd
    where rd.sensor_id = v_rule.sensor_id
    order by rd.received_at desc
    limit 1;
    if not found or v_received > now() - make_interval(mins => v_rule.silence_minutes) then
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
    on conflict (rule_id, reading_id) do nothing;
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
      select id from public.fizz_alert_events
      where notify_status = 'pending' and notify_channel = 'call'
        and notify_attempts < 3
      order by created_at
      limit least(greatest(coalesce(p_limit, 3), 1), 10)
      for update skip locked)
    returning e.*)
  select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'channel', c.notify_channel, 'phone', c.notify_phone,
      'sensor_name', s.name, 'metric', c.metric, 'numeric_value', c.numeric_value, 'threshold', c.threshold,
      'comparator', c.comparator, 'unit', c.unit, 'observed_at', c.observed_at, 'event_kind', c.event_kind)), '[]'::jsonb)
  into v_batch
  from claimed c join public.fizz_sensors s on s.id = c.sensor_id;
  return v_batch;
end;
$$;

drop function public.fizz_create_chat_alert(text, uuid, text, text, double precision, text, text, text);
drop function public.fizz_create_alert(text, uuid, text, text, double precision, text, text, text);

create function public.fizz_create_alert(p_token text, p_sensor_id uuid, p_metric text default null,
  p_comparator text default null, p_threshold double precision default null, p_unit text default null,
  p_notify_channel text default 'none', p_notify_phone text default null,
  p_kind text default 'threshold', p_silence_minutes integer default null,
  p_notify_recovery boolean default false)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_customer uuid;
  v_rule public.fizz_alert_rules%rowtype;
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
    insert into public.fizz_alert_rules(
      customer_id, sensor_id, metric, comparator, threshold, unit,
      notify_channel, notify_phone, kind, silence_minutes, notify_recovery)
    values (
      v_customer, p_sensor_id, 'silence', 'gte', v_minutes, 'min',
      coalesce(p_notify_channel, 'none'), p_notify_phone,
      'silence', v_minutes, coalesce(p_notify_recovery, false))
    returning * into v_rule;
    return jsonb_build_object('rule', to_jsonb(v_rule) - 'customer_id');
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
  insert into public.fizz_alert_rules(customer_id,sensor_id,metric,comparator,threshold,unit,notify_channel,notify_phone)
  values(v_customer,p_sensor_id,p_metric,p_comparator,p_threshold,p_unit,coalesce(p_notify_channel,'none'),p_notify_phone)
  returning * into v_rule;
  return jsonb_build_object('rule',to_jsonb(v_rule)-'customer_id');
end;
$$;

create function public.fizz_create_chat_alert(p_token text, p_sensor_id uuid, p_metric text default null,
  p_comparator text default null, p_threshold double precision default null, p_unit text default null,
  p_notify_channel text default 'none', p_notify_phone text default null,
  p_kind text default 'threshold', p_silence_minutes integer default null,
  p_notify_recovery boolean default false)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_customer uuid; v_rule public.fizz_alert_rules%rowtype; v_result jsonb; v_minutes integer;
begin
  v_customer := public.fizz_session_customer(p_token);
  if v_customer is null then return jsonb_build_object('error','unauthorized'); end if;
  perform pg_advisory_xact_lock(hashtextextended(v_customer::text, 0));
  if coalesce(p_kind, 'threshold') = 'silence' then
    v_minutes := coalesce(p_silence_minutes, 10);
    select r.* into v_rule from public.fizz_alert_rules r
    join public.fizz_sensors s on s.id = r.sensor_id
    where r.customer_id = v_customer and s.deleted_at is null and r.enabled
      and r.kind = 'silence' and r.sensor_id = p_sensor_id and r.silence_minutes = v_minutes
      and r.notify_recovery = coalesce(p_notify_recovery, false)
      and r.notify_channel = coalesce(p_notify_channel, 'none')
      and r.notify_phone is not distinct from p_notify_phone
    limit 1;
  else
    select r.* into v_rule from public.fizz_alert_rules r
    join public.fizz_sensors s on s.id = r.sensor_id
    where r.customer_id = v_customer and s.deleted_at is null and r.enabled and r.kind = 'threshold'
      and r.sensor_id = p_sensor_id and r.metric = p_metric
      and r.comparator = p_comparator and r.threshold = p_threshold and r.unit = p_unit
      and r.notify_channel = coalesce(p_notify_channel, 'none')
      and r.notify_phone is not distinct from p_notify_phone
    limit 1;
  end if;
  if found then
    return jsonb_build_object('rule',to_jsonb(v_rule)-'customer_id','created',false);
  end if;
  v_result := public.fizz_create_alert(p_token, p_sensor_id, p_metric,
    p_comparator, p_threshold, p_unit, p_notify_channel, p_notify_phone,
    p_kind, p_silence_minutes, p_notify_recovery);
  if v_result ? 'error' then return v_result; end if;
  return v_result || jsonb_build_object('created',true);
end;
$$;

create or replace function public.fizz_agent_call(p_agent_token text, p_ip text, p_tool text, p_args jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_conn public.fizz_agent_connections%rowtype;
  v_args jsonb := coalesce(p_args, '{}'::jsonb);
  v_sensor public.fizz_sensors%rowtype;
  v_limit integer; v_metric text; v_comparator text; v_threshold double precision; v_unit text;
  v_rule public.fizz_alert_rules%rowtype;
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
      perform pg_advisory_xact_lock(hashtextextended(v_conn.customer_id::text, 0));
      select r.* into v_rule from public.fizz_alert_rules r
      where r.customer_id = v_conn.customer_id and r.enabled and r.kind = 'silence' and r.sensor_id = v_sensor.id
        and r.silence_minutes = v_minutes and r.notify_recovery = v_recovery
        and r.notify_channel = v_channel and r.notify_phone is not distinct from v_phone
      limit 1;
      if found then
        return jsonb_build_object('result', jsonb_build_object('created', false, 'rule', jsonb_build_object(
          'id', v_rule.id, 'sensor_id', v_rule.sensor_id, 'kind', v_rule.kind,
          'silence_minutes', v_rule.silence_minutes, 'notify_recovery', v_rule.notify_recovery,
          'calls_phone', v_rule.notify_channel = 'call')));
      end if;
      if (select count(*) from public.fizz_alert_rules where customer_id = v_conn.customer_id and enabled) >= 100 then
        return jsonb_build_object('error','invalid_arguments','message','This account already has 100 active alerts. Pause or delete some first.');
      end if;
      insert into public.fizz_alert_rules(
        customer_id, sensor_id, metric, comparator, threshold, unit,
        notify_channel, notify_phone, kind, silence_minutes, notify_recovery)
      values (
        v_conn.customer_id, v_sensor.id, 'silence', 'gte', v_minutes, 'min',
        v_channel, v_phone, 'silence', v_minutes, v_recovery)
      returning * into v_rule;
      return jsonb_build_object('result', jsonb_build_object('created', true, 'rule', jsonb_build_object(
        'id', v_rule.id, 'sensor_id', v_rule.sensor_id, 'kind', v_rule.kind,
        'silence_minutes', v_rule.silence_minutes, 'notify_recovery', v_rule.notify_recovery,
        'calls_phone', v_rule.notify_channel = 'call')));
    end if;

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
    perform pg_advisory_xact_lock(hashtextextended(v_conn.customer_id::text, 0));
    select r.* into v_rule from public.fizz_alert_rules r
    where r.customer_id = v_conn.customer_id and r.enabled and r.kind = 'threshold'
      and r.sensor_id = v_sensor.id and r.metric = v_metric
      and r.comparator = v_comparator and r.threshold = v_threshold and r.unit = v_unit
      and r.notify_channel = v_channel and r.notify_phone is not distinct from v_phone
    limit 1;
    if found then
      return jsonb_build_object('result', jsonb_build_object('created', false, 'rule', jsonb_build_object('id', v_rule.id,
        'sensor_id', v_rule.sensor_id, 'kind', v_rule.kind, 'metric', v_rule.metric, 'comparator', v_rule.comparator,
        'threshold', v_rule.threshold, 'unit', v_rule.unit, 'calls_phone', v_rule.notify_channel = 'call')));
    end if;
    if (select count(*) from public.fizz_alert_rules where customer_id = v_conn.customer_id and enabled) >= 100 then
      return jsonb_build_object('error','invalid_arguments','message','This account already has 100 active alerts. Pause or delete some first.');
    end if;
    insert into public.fizz_alert_rules(customer_id, sensor_id, metric, comparator, threshold, unit, notify_channel, notify_phone)
    values (v_conn.customer_id, v_sensor.id, v_metric, v_comparator, v_threshold, v_unit, v_channel, v_phone)
    returning * into v_rule;
    return jsonb_build_object('result', jsonb_build_object('created', true, 'rule', jsonb_build_object('id', v_rule.id,
      'sensor_id', v_rule.sensor_id, 'kind', v_rule.kind, 'metric', v_rule.metric, 'comparator', v_rule.comparator,
      'threshold', v_rule.threshold, 'unit', v_rule.unit, 'calls_phone', v_rule.notify_channel = 'call')));

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

revoke execute on function public.fizz_us_phone(text),
  public.fizz_alert_notify_status(uuid, uuid, text),
  public.fizz_scan_silence_alerts(integer),
  public.fizz_create_alert(text, uuid, text, text, double precision, text, text, text, text, integer, boolean),
  public.fizz_create_chat_alert(text, uuid, text, text, double precision, text, text, text, text, integer, boolean)
  from public, anon, authenticated;
grant execute on function public.fizz_scan_silence_alerts(integer),
  public.fizz_create_alert(text, uuid, text, text, double precision, text, text, text, text, integer, boolean),
  public.fizz_create_chat_alert(text, uuid, text, text, double precision, text, text, text, text, integer, boolean)
  to service_role;
