-- Email and webhook join dashboard and phone as alert channels.
--
-- Existing rows keep their behavior: notify_channel 'none' is dashboard only,
-- and 'call' is dashboard plus a phone call. Phone calls stay on paid plans.
-- Email and webhook are on every plan while fizz_message_channels_on_all_plans()
-- returns true. Replace that body with `select false` to require a paid plan
-- later, and set MESSAGE_CHANNELS_ON_ALL_PLANS in src/channels.rs to false too.
-- Prices do not change.

-- Single switch for email and webhook plan access. True means every plan.
create function public.fizz_message_channels_on_all_plans()
returns boolean language sql immutable parallel safe set search_path = '' as $$
  select true;
$$;

create function public.fizz_channels_ok(p_channels text[])
returns boolean language sql immutable set search_path = '' as $$
  select coalesce(
    p_channels is not null
    and cardinality(p_channels) between 1 and 4
    and p_channels <@ array['dashboard', 'phone', 'email', 'webhook']::text[]
    and not exists (select 1 from unnest(p_channels) as item where item is null)
    and (
      select count(distinct item) = cardinality(p_channels)
      from unnest(p_channels) as item
    ),
    false
  );
$$;

-- Canonical order, duplicates removed. Null when the list is empty or unknown.
create function public.fizz_normalize_channels(p_channels text[])
returns text[] language sql immutable set search_path = '' as $$
  select case
    when p_channels is null or cardinality(p_channels) < 1 or cardinality(p_channels) > 4 then null
    when exists (
      select 1 from unnest(p_channels) as item
      where item is null or item not in ('dashboard', 'phone', 'email', 'webhook')
    ) then null
    else array(
      select name
      from unnest(array['dashboard', 'phone', 'email', 'webhook']::text[]) as name
      where name = any (p_channels)
    )
  end;
$$;

-- HTTPS only, and not a literal private, loopback, or link-local address.
-- Names are checked again at send time, after DNS, so a public name that
-- points at an internal address is still refused.
create function public.fizz_webhook_url_ok(p_url text)
returns boolean language plpgsql immutable set search_path = '' as $$
declare
  v_rest text;
  v_authority text;
  v_host text;
  v_ip inet;
begin
  if p_url is null or char_length(p_url) < 12 or char_length(p_url) > 2000 then
    return false;
  end if;
  if p_url !~ '^https://' or p_url ~ '[[:space:][:cntrl:]\\]' then
    return false;
  end if;
  v_rest := substr(p_url, 9);
  v_authority := split_part(split_part(split_part(v_rest, '/', 1), '?', 1), '#', 1);
  if v_authority = '' or position('@' in v_authority) > 0 then
    return false;
  end if;
  if left(v_authority, 1) = '[' then
    v_host := split_part(substr(v_authority, 2), ']', 1);
    if v_host = '' or position(']' in v_authority) = 0 then
      return false;
    end if;
  elsif position(':' in v_authority) > 0 then
    v_host := split_part(v_authority, ':', 1);
  else
    v_host := v_authority;
  end if;
  v_host := lower(v_host);
  if v_host = '' or v_host = 'localhost' or v_host = 'localhost.localdomain'
    or v_host = 'metadata.google.internal'
    or v_host ~ '\.(local|localhost|internal|localdomain)$' then
    return false;
  end if;
  begin
    v_ip := v_host::inet;
  exception when others then
    v_ip := null;
  end;
  if v_ip is not null then
    if family(v_ip) = 4 then
      return not (
        v_ip <<= '0.0.0.0/8' or v_ip <<= '10.0.0.0/8' or v_ip <<= '100.64.0.0/10'
        or v_ip <<= '127.0.0.0/8' or v_ip <<= '169.254.0.0/16' or v_ip <<= '172.16.0.0/12'
        or v_ip <<= '192.0.0.0/24' or v_ip <<= '192.0.2.0/24' or v_ip <<= '192.168.0.0/16'
        or v_ip <<= '198.18.0.0/15' or v_ip <<= '198.51.100.0/24' or v_ip <<= '203.0.113.0/24'
        or v_ip <<= '224.0.0.0/4' or v_ip <<= '240.0.0.0/4'
      );
    end if;
    return not (
      v_ip <<= '::/128' or v_ip <<= '::1/128' or v_ip <<= 'fc00::/7'
      or v_ip <<= 'fe80::/10' or v_ip <<= 'ff00::/8' or v_ip <<= '2001:db8::/32'
      or v_ip <<= '::ffff:0:0/96'
    );
  end if;
  if position('.' in v_host) = 0 then
    return false;
  end if;
  return v_host ~ '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$';
end;
$$;

alter table public.fizz_alert_rules
  add column channels text[] not null default array['dashboard']::text[],
  add column webhook_url text,
  add column webhook_secret text;

update public.fizz_alert_rules
set channels = case
  when notify_channel = 'call' then array['dashboard', 'phone']::text[]
  else array['dashboard']::text[]
end;

-- Inserts that only set notify_channel, including the existing tests, keep
-- working: a call implies the phone channel, and the phone channel implies a call.
create function public.fizz_sync_alert_channels()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.channels is null then
    new.channels := array['dashboard']::text[];
  end if;
  if new.notify_channel = 'call' and not ('phone' = any (new.channels)) then
    new.channels := new.channels || array['phone']::text[];
  elsif new.notify_channel is distinct from 'call'
    and 'phone' = any (new.channels)
    and new.notify_phone is not null then
    new.notify_channel := 'call';
  end if;
  return new;
end;
$$;

create trigger fizz_sync_alert_channels
  before insert or update of channels, notify_channel, notify_phone
  on public.fizz_alert_rules
  for each row execute function public.fizz_sync_alert_channels();

alter table public.fizz_alert_rules
  add constraint fizz_alert_rules_channels_check check (public.fizz_channels_ok(channels)),
  add constraint fizz_alert_rules_phone_channel_check check (
    ('phone' = any (channels)) = (notify_channel = 'call')
  ),
  add constraint fizz_alert_rules_webhook_target_check check (
    ('webhook' = any (channels)) = (webhook_url is not null)
  ),
  add constraint fizz_alert_rules_webhook_url_check check (
    webhook_url is null or public.fizz_webhook_url_ok(webhook_url)
  ),
  add constraint fizz_alert_rules_webhook_secret_check check (
    webhook_secret is null
    or (char_length(webhook_secret) between 16 and 128
        and webhook_secret !~ '[[:space:][:cntrl:]]')
  );

-- Per-account signing secret. No client policies: the session API returns it
-- to the owner, and a later table grant must not expose it through the Data API.
create table public.fizz_alert_webhook_secrets (
  customer_id uuid primary key references public.fizz_customers(id) on delete cascade,
  secret text not null check (
    char_length(secret) between 16 and 128 and secret !~ '[[:space:][:cntrl:]]'
  ),
  created_at timestamptz not null default now()
);
alter table public.fizz_alert_webhook_secrets enable row level security;
revoke all on public.fizz_alert_webhook_secrets from public, anon, authenticated;
grant all on public.fizz_alert_webhook_secrets to service_role;

create function public.fizz_ensure_webhook_secret(p_customer uuid)
returns text language plpgsql security definer set search_path = '' as $$
declare v_secret text;
begin
  select secret into v_secret from public.fizz_alert_webhook_secrets where customer_id = p_customer;
  if found then return v_secret; end if;
  v_secret := encode(extensions.gen_random_bytes(32), 'hex');
  insert into public.fizz_alert_webhook_secrets(customer_id, secret)
  values (p_customer, v_secret)
  on conflict (customer_id) do nothing;
  select secret into v_secret from public.fizz_alert_webhook_secrets where customer_id = p_customer;
  return v_secret;
end;
$$;

-- One row per email or webhook send. Phone delivery stays on the event, so the
-- existing call queue is unchanged.
create table public.fizz_alert_deliveries (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.fizz_alert_events(id) on delete cascade,
  customer_id uuid not null references public.fizz_customers(id) on delete cascade,
  channel text not null check (channel in ('email', 'webhook')),
  status text not null default 'pending' check (status in ('pending', 'sending', 'sent', 'failed', 'skipped')),
  attempts integer not null default 0 check (attempts between 0 and 10),
  error text,
  response_status integer,
  claimed_at timestamptz,
  next_attempt_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index fizz_alert_deliveries_event_idx on public.fizz_alert_deliveries(event_id);
create index fizz_alert_deliveries_pending_idx
  on public.fizz_alert_deliveries(next_attempt_at, created_at)
  where status = 'pending';

alter table public.fizz_alert_deliveries enable row level security;
revoke all on public.fizz_alert_deliveries from public, anon, authenticated;
grant all on public.fizz_alert_deliveries to service_role;

-- Read-only if a future grant opens the table. Inserts and updates stay denied.
create policy fizz_alert_deliveries_owner_select on public.fizz_alert_deliveries
  for select to authenticated using (
    coalesce((select auth.jwt() ->> 'is_anonymous'), 'false') <> 'true'
    and exists (
      select 1 from public.fizz_customers c
      where c.id = customer_id and c.auth_user_id = (select auth.uid())
    )
  );

-- Same 5-minute per-rule cooldown as phone calls. The event insert is already
-- deduped by the armed flag and the reading key; this skips a second email or
-- webhook when another outbound notice for the rule went out moments ago.
create function public.fizz_enqueue_alert_deliveries()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_channels text[];
  v_channel text;
  v_status text;
  v_error text;
begin
  if new.rule_id is null then return new; end if;
  select channels into v_channels from public.fizz_alert_rules where id = new.rule_id;
  if v_channels is null then return new; end if;
  foreach v_channel in array array['email', 'webhook']::text[] loop
    if not (v_channel = any (v_channels)) then continue; end if;
    v_status := 'pending';
    v_error := null;
    if exists (
      select 1 from public.fizz_alert_events e
      where e.rule_id = new.rule_id and e.id <> new.id
        and e.notify_status in ('pending', 'sending', 'sent')
        and e.created_at > now() - interval '5 minutes'
    ) or exists (
      select 1 from public.fizz_alert_deliveries d
      join public.fizz_alert_events e on e.id = d.event_id
      where e.rule_id = new.rule_id and d.channel = v_channel
        and d.status in ('pending', 'sending', 'sent')
        and d.created_at > now() - interval '5 minutes'
    ) then
      v_status := 'skipped';
      v_error := 'Sent one recently.';
    end if;
    insert into public.fizz_alert_deliveries(event_id, customer_id, channel, status, error)
    values (new.id, new.customer_id, v_channel, v_status, v_error);
  end loop;
  return new;
end;
$$;

create trigger fizz_enqueue_alert_deliveries
  after insert on public.fizz_alert_events
  for each row execute function public.fizz_enqueue_alert_deliveries();

create or replace function public.fizz_cancel_pending_alerts(p_rule uuid, p_sensor uuid, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  update public.fizz_alert_events
  set notify_status = 'skipped', notify_error = left(p_reason, 200)
  where notify_status = 'pending'
    and (p_rule is null or rule_id = p_rule)
    and (p_sensor is null or sensor_id = p_sensor);
  update public.fizz_alert_deliveries d
  set status = 'skipped', error = left(p_reason, 200), updated_at = now()
  from public.fizz_alert_events e
  where d.event_id = e.id and d.status = 'pending'
    and (p_rule is null or e.rule_id = p_rule)
    and (p_sensor is null or e.sensor_id = p_sensor);
end;
$$;

create function public.fizz_claim_alert_deliveries(p_limit integer default 3, p_include_email boolean default true)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_batch jsonb;
begin
  update public.fizz_alert_deliveries
  set status = case when attempts >= 3 then 'failed' else 'pending' end,
      error = case when attempts >= 3 then 'Send outcome unknown.' else error end,
      next_attempt_at = case when attempts >= 3 then null else now() end,
      updated_at = now()
  where status = 'sending' and claimed_at < now() - interval '2 minutes';
  update public.fizz_alert_deliveries
  set status = 'failed', error = 'Expired before it could be sent.', updated_at = now()
  where status = 'pending' and created_at < now() - interval '24 hours';
  with claimed as (
    update public.fizz_alert_deliveries d
    set status = 'sending', claimed_at = now(), attempts = d.attempts + 1, updated_at = now()
    where d.id in (
      select q.id from public.fizz_alert_deliveries q
      join public.fizz_alert_events e on e.id = q.event_id
      join public.fizz_alert_rules r on r.id = e.rule_id and r.enabled
      join public.fizz_sensors s on s.id = e.sensor_id
        and s.deleted_at is null and s.status = 'active'
      where q.status = 'pending' and q.attempts < 3
        and (q.next_attempt_at is null or q.next_attempt_at <= now())
        and (p_include_email or q.channel <> 'email')
        and (e.event_kind <> 'silence' or not exists (
          select 1 from public.fizz_sensor_readings newer
          join public.fizz_sensor_readings basis on basis.id = e.reading_id
          where newer.sensor_id = e.sensor_id and newer.received_at > basis.received_at))
      order by q.created_at
      limit least(greatest(coalesce(p_limit, 3), 1), 10)
      for update of q skip locked)
    returning d.*)
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', c.id, 'event_id', c.event_id, 'channel', c.channel, 'attempts', c.attempts,
      'sensor_name', s.name, 'metric', e.metric, 'numeric_value', e.numeric_value,
      'threshold', e.threshold, 'comparator', e.comparator, 'unit', e.unit,
      'observed_at', e.observed_at, 'event_kind', e.event_kind,
      'webhook_url', r.webhook_url,
      'webhook_secret', coalesce(r.webhook_secret, sec.secret),
      'email', case when u.email_confirmed_at is not null then u.email else null end)), '[]'::jsonb)
  into v_batch
  from claimed c
  join public.fizz_alert_events e on e.id = c.event_id
  join public.fizz_alert_rules r on r.id = e.rule_id
  join public.fizz_sensors s on s.id = e.sensor_id
  left join public.fizz_alert_webhook_secrets sec on sec.customer_id = c.customer_id
  left join public.fizz_customers cust on cust.id = c.customer_id
  left join auth.users u on u.id = cust.auth_user_id;
  return v_batch;
end;
$$;

create function public.fizz_alert_delivery_still_due(p_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_row public.fizz_alert_deliveries%rowtype;
  v_event public.fizz_alert_events%rowtype;
  v_reason text;
  v_email text;
begin
  select * into v_row from public.fizz_alert_deliveries where id = p_id for update;
  if not found or v_row.status <> 'sending' then
    return jsonb_build_object('send', false);
  end if;
  select * into v_event from public.fizz_alert_events where id = v_row.event_id;
  if not exists (
    select 1 from public.fizz_alert_rules r
    join public.fizz_sensors s on s.id = r.sensor_id
    where r.id = v_event.rule_id and r.enabled
      and s.deleted_at is null and s.status = 'active'
      and v_row.channel = any (r.channels)
  ) then
    v_reason := 'Alert or sensor is no longer active.';
  elsif v_event.event_kind = 'silence' and exists (
    select 1 from public.fizz_sensor_readings newer
    join public.fizz_sensor_readings basis on basis.id = v_event.reading_id
    where newer.sensor_id = v_event.sensor_id and newer.received_at > basis.received_at
  ) then
    v_reason := 'Sensor reported again before the notice was sent.';
  elsif v_row.channel = 'email' then
    select u.email into v_email
    from public.fizz_customers c
    join auth.users u on u.id = c.auth_user_id
    where c.id = v_row.customer_id and u.email_confirmed_at is not null;
    if v_email is null then
      v_reason := 'Account email is not verified.';
    end if;
  elsif v_row.channel = 'webhook' and not exists (
    select 1 from public.fizz_alert_rules r
    where r.id = v_event.rule_id and public.fizz_webhook_url_ok(r.webhook_url)
  ) then
    v_reason := 'Webhook URL is not allowed.';
  end if;
  if v_reason is not null then
    update public.fizz_alert_deliveries
    set status = 'skipped', error = v_reason, updated_at = now()
    where id = p_id;
    return jsonb_build_object('send', false);
  end if;
  return jsonb_build_object('send', true);
end;
$$;

create function public.fizz_finish_alert_delivery(
  p_id uuid, p_status text, p_error text default null, p_response_status integer default null)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if p_status not in ('sent', 'failed', 'skipped', 'pending') then
    return;
  end if;
  update public.fizz_alert_deliveries set
    status = case
      when p_status = 'pending' and attempts >= 3 then 'failed'
      else p_status end,
    error = case when p_status = 'sent' then null else left(p_error, 200) end,
    response_status = p_response_status,
    next_attempt_at = case
      when p_status = 'pending' and attempts < 3 then now() + make_interval(secs => attempts * 30)
      else null end,
    updated_at = now()
  where id = p_id and status = 'sending';
end;
$$;

-- p_channels null keeps the previous meaning of p_channel: none is dashboard,
-- call is dashboard plus phone. An explicit list can add email and webhook.
create function public.fizz_save_alert_rule(p_customer uuid, p_sensor_id uuid, p_kind text,
  p_metric text, p_comparator text, p_threshold double precision, p_unit text,
  p_channel text, p_phone text, p_minutes integer, p_recovery boolean, p_max_active integer,
  p_channels text[] default null, p_webhook_url text default null, p_webhook_secret text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_rule public.fizz_alert_rules%rowtype;
  v_channels text[];
  v_phone text;
  v_url text;
  v_notify text;
begin
  perform pg_advisory_xact_lock(hashtextextended(p_customer::text, 0));
  if p_kind = 'silence' and exists(select 1 from public.fizz_sensors
      where id = p_sensor_id and mode = 'simulated') then
    return jsonb_build_object('error','simulated_sensor');
  end if;
  if p_channels is null then
    if coalesce(p_channel, 'none') = 'call' then
      v_channels := array['dashboard', 'phone'];
    elsif coalesce(p_channel, 'none') = 'none' then
      v_channels := array['dashboard'];
    else
      return jsonb_build_object('error','invalid_channels');
    end if;
  else
    v_channels := public.fizz_normalize_channels(p_channels);
    if v_channels is null then
      return jsonb_build_object('error','invalid_channels');
    end if;
  end if;
  if 'phone' = any (v_channels) then
    v_phone := public.fizz_callable_us_phone(p_phone);
    if v_phone is null then
      return jsonb_build_object('error','invalid_phone');
    end if;
    if not public.fizz_calls_allowed(p_customer) then
      return jsonb_build_object('error','calls_not_included');
    end if;
    if not exists (
      select 1 from public.fizz_verified_phones where customer_id = p_customer and phone = v_phone
    ) then
      return jsonb_build_object('error','phone_not_paired');
    end if;
    v_notify := 'call';
  else
    if p_phone is not null and p_channels is null and coalesce(p_channel, 'none') = 'call' then
      return jsonb_build_object('error','invalid_phone');
    end if;
    v_phone := null;
    v_notify := 'none';
  end if;
  if ('email' = any (v_channels) or 'webhook' = any (v_channels))
    and not public.fizz_message_channels_on_all_plans()
    and not public.fizz_calls_allowed(p_customer) then
    return jsonb_build_object('error','channels_not_included');
  end if;
  v_url := nullif(btrim(coalesce(p_webhook_url, '')), '');
  if 'webhook' = any (v_channels) then
    if v_url is null or not public.fizz_webhook_url_ok(v_url) then
      return jsonb_build_object('error','invalid_webhook');
    end if;
    if p_webhook_secret is not null and (
      char_length(p_webhook_secret) < 16 or char_length(p_webhook_secret) > 128
      or p_webhook_secret ~ '[[:space:][:cntrl:]]'
    ) then
      return jsonb_build_object('error','invalid_webhook');
    end if;
    if p_webhook_secret is null then
      perform public.fizz_ensure_webhook_secret(p_customer);
    end if;
  elsif v_url is not null or p_webhook_secret is not null then
    return jsonb_build_object('error','invalid_webhook');
  end if;
  select r.* into v_rule from public.fizz_alert_rules r
  join public.fizz_sensors s on s.id = r.sensor_id
  where r.customer_id = p_customer and s.deleted_at is null and r.enabled
    and r.kind = p_kind and r.sensor_id = p_sensor_id
    and r.channels = v_channels and r.notify_phone is not distinct from v_phone
    and r.webhook_url is not distinct from v_url
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
      notify_channel, notify_phone, kind, silence_minutes, notify_recovery, silence_due_at,
      channels, webhook_url, webhook_secret)
    values (
      p_customer, p_sensor_id, 'silence', 'gte', p_minutes, 'min',
      v_notify, v_phone, 'silence', p_minutes, p_recovery,
      (select rd.received_at + make_interval(mins => p_minutes)
       from public.fizz_sensor_readings rd
       where rd.sensor_id = p_sensor_id order by rd.received_at desc limit 1),
      v_channels, v_url, case when 'webhook' = any (v_channels) then p_webhook_secret else null end)
    returning * into v_rule;
  else
    insert into public.fizz_alert_rules(
      customer_id, sensor_id, metric, comparator, threshold, unit,
      notify_channel, notify_phone, channels, webhook_url, webhook_secret)
    values (
      p_customer, p_sensor_id, p_metric, p_comparator, p_threshold, p_unit,
      v_notify, v_phone, v_channels, v_url,
      case when 'webhook' = any (v_channels) then p_webhook_secret else null end)
    returning * into v_rule;
  end if;
  return jsonb_build_object('rule', to_jsonb(v_rule) - 'customer_id', 'created', true);
end;
$$;

drop function public.fizz_create_alert(text, uuid, text, text, double precision, text, text, text, text, integer, boolean);
create function public.fizz_create_alert(p_token text, p_sensor_id uuid, p_metric text default null,
  p_comparator text default null, p_threshold double precision default null, p_unit text default null,
  p_notify_channel text default 'none', p_notify_phone text default null,
  p_kind text default 'threshold', p_silence_minutes integer default null,
  p_notify_recovery boolean default false,
  p_channels text[] default null, p_webhook_url text default null, p_webhook_secret text default null)
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
  if p_channels is null and (
    coalesce(p_notify_channel, 'none') not in ('none','call')
    or (coalesce(p_notify_channel, 'none') = 'none') <> (p_notify_phone is null)
    or (p_notify_phone is not null and p_notify_phone !~ '^\+1[2-9][0-9]{2}[2-9][0-9]{6}$')
  ) then
    return jsonb_build_object('error','invalid_notify');
  end if;

  if coalesce(p_kind, 'threshold') = 'silence' then
    v_minutes := coalesce(p_silence_minutes, 10);
    if v_minutes < 1 or v_minutes > 10080 then
      return jsonb_build_object('error','invalid_rule');
    end if;
    return public.fizz_save_alert_rule(v_customer, p_sensor_id, 'silence', null, null, null, null,
      coalesce(p_notify_channel, 'none'), p_notify_phone, v_minutes, coalesce(p_notify_recovery, false), null,
      p_channels, p_webhook_url, p_webhook_secret);
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
    p_threshold, p_unit, coalesce(p_notify_channel, 'none'), p_notify_phone, null, false, null,
    p_channels, p_webhook_url, p_webhook_secret);
end;
$$;

drop function public.fizz_save_alert_rule(uuid, uuid, text, text, text, double precision, text, text, text, integer, boolean, integer);

drop function public.fizz_update_alert(text, uuid, boolean, boolean);
create function public.fizz_update_alert(p_token text, p_rule_id uuid, p_enabled boolean, p_delete boolean,
  p_channels text[] default null, p_notify_phone text default null,
  p_webhook_url text default null, p_webhook_secret text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_customer uuid;
  v_rule public.fizz_alert_rules%rowtype;
  v_removed boolean;
  v_channels text[];
  v_phone text;
  v_url text;
  v_notify text;
begin
  select customer_id into v_customer from public.fizz_sessions
  where p_token ~ '^[0-9a-f]{64}$'
    and token_hash = extensions.digest(decode(p_token, 'hex'), 'sha256') and expires_at > now();
  if v_customer is null then return jsonb_build_object('error','unauthorized'); end if;
  if coalesce(p_delete,false) then
    if not exists(select 1 from public.fizz_alert_rules
        where id = p_rule_id and customer_id = v_customer) then
      return jsonb_build_object('error','not_found');
    end if;
    perform public.fizz_cancel_pending_alerts(p_rule_id, null, 'Alert was deleted.');
    delete from public.fizz_alert_rules where id = p_rule_id and customer_id = v_customer;
    return jsonb_build_object('ok',true);
  end if;
  if p_enabled is null and p_channels is null then
    return jsonb_build_object('error','invalid_rule');
  end if;
  select s.deleted_at is not null into v_removed
  from public.fizz_alert_rules r
  join public.fizz_sensors s on s.id = r.sensor_id
  where r.id = p_rule_id and r.customer_id = v_customer;
  if not found then return jsonb_build_object('error','not_found'); end if;
  if p_channels is not null then
    v_channels := public.fizz_normalize_channels(p_channels);
    if v_channels is null then return jsonb_build_object('error','invalid_channels'); end if;
    if 'phone' = any (v_channels) then
      v_phone := public.fizz_callable_us_phone(p_notify_phone);
      if v_phone is null then return jsonb_build_object('error','invalid_phone'); end if;
      if not public.fizz_calls_allowed(v_customer) then
        return jsonb_build_object('error','calls_not_included');
      end if;
      if not exists (
        select 1 from public.fizz_verified_phones where customer_id = v_customer and phone = v_phone
      ) then
        return jsonb_build_object('error','phone_not_paired');
      end if;
      v_notify := 'call';
    else
      v_phone := null;
      v_notify := 'none';
    end if;
    if ('email' = any (v_channels) or 'webhook' = any (v_channels))
      and not public.fizz_message_channels_on_all_plans()
      and not public.fizz_calls_allowed(v_customer) then
      return jsonb_build_object('error','channels_not_included');
    end if;
    v_url := nullif(btrim(coalesce(p_webhook_url, '')), '');
    if 'webhook' = any (v_channels) then
      if v_url is null or not public.fizz_webhook_url_ok(v_url) then
        return jsonb_build_object('error','invalid_webhook');
      end if;
      if p_webhook_secret is not null and (
        char_length(p_webhook_secret) < 16 or char_length(p_webhook_secret) > 128
        or p_webhook_secret ~ '[[:space:][:cntrl:]]'
      ) then
        return jsonb_build_object('error','invalid_webhook');
      end if;
      if p_webhook_secret is null then
        perform public.fizz_ensure_webhook_secret(v_customer);
      end if;
    elsif v_url is not null or p_webhook_secret is not null then
      return jsonb_build_object('error','invalid_webhook');
    end if;
  end if;
  update public.fizz_alert_rules r set
    enabled = case when v_removed then false when p_enabled is null then r.enabled else p_enabled end,
    resume_enabled = case
      when v_removed then coalesce(p_enabled, r.resume_enabled)
      else null end,
    armed = case when p_enabled is null then r.armed else true end,
    channels = coalesce(v_channels, r.channels),
    notify_channel = coalesce(v_notify, r.notify_channel),
    notify_phone = case when v_channels is null then r.notify_phone else v_phone end,
    webhook_url = case when v_channels is null then r.webhook_url else v_url end,
    webhook_secret = case
      when v_channels is null then r.webhook_secret
      when 'webhook' = any (v_channels) then p_webhook_secret
      else null end,
    updated_at = now(),
    silence_due_at = case when r.kind = 'silence' and coalesce(p_enabled, r.enabled) and not v_removed and p_enabled is not null then (
      select rd.received_at + make_interval(mins => r.silence_minutes)
      from public.fizz_sensor_readings rd
      where rd.sensor_id = r.sensor_id order by rd.received_at desc limit 1)
      else r.silence_due_at end
  where r.id = p_rule_id and r.customer_id = v_customer returning * into v_rule;
  if not found then return jsonb_build_object('error','not_found'); end if;
  if p_enabled is false then
    perform public.fizz_cancel_pending_alerts(p_rule_id, null, 'Alert was paused.');
  elsif v_channels is not null then
    if v_notify = 'none' then
      update public.fizz_alert_events
      set notify_status = 'skipped', notify_error = 'Phone channel was removed.'
      where rule_id = p_rule_id and notify_channel = 'call' and notify_status = 'pending';
    end if;
    update public.fizz_alert_deliveries d
    set status = 'skipped', error = 'Channel was removed.', updated_at = now()
    from public.fizz_alert_events e
    where d.event_id = e.id and e.rule_id = p_rule_id and d.status = 'pending'
      and not (d.channel = any (v_channels));
  end if;
  return jsonb_build_object('rule', to_jsonb(v_rule) - 'customer_id');
end;
$$;

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
    'events', coalesce((select jsonb_agg(
        (to_jsonb(e) - 'customer_id') || jsonb_build_object('deliveries', coalesce((
          select jsonb_agg(jsonb_build_object(
              'channel', d.channel, 'status', d.status, 'error', d.error, 'attempts', d.attempts
            ) order by d.channel)
          from public.fizz_alert_deliveries d where d.event_id = e.id
        ), '[]'::jsonb))
        order by e.created_at desc)
      from (select * from public.fizz_alert_events where customer_id = v_customer
        order by created_at desc limit 100) e), '[]'::jsonb),
    'silence_scheduler_active', exists(select 1 from public.fizz_scheduler_status
      where last_scan_at > now() - interval '5 minutes'),
    'message_channels_on_all_plans', public.fizz_message_channels_on_all_plans(),
    'message_channels_included',
      public.fizz_message_channels_on_all_plans() or public.fizz_calls_allowed(v_customer),
    'account_webhook_secret', (
      select secret from public.fizz_alert_webhook_secrets where customer_id = v_customer));
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
  v_channels text[]; v_list text[]; v_url text; v_secret text;
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
          'enabled', r.enabled, 'triggered', not r.armed, 'calls_phone', r.notify_channel = 'call',
          'channels', r.channels, 'webhook_url', r.webhook_url)
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
    v_url := nullif(btrim(coalesce(v_args->>'webhook_url', '')), '');
    v_secret := nullif(v_args->>'webhook_secret', '');
    if v_args ? 'channels' then
      if jsonb_typeof(v_args->'channels') <> 'array' then
        return jsonb_build_object('error','invalid_arguments','message','channels must be an array of dashboard, phone, email, and webhook.');
      end if;
      if exists (select 1 from jsonb_array_elements(v_args->'channels') item where jsonb_typeof(item) <> 'string') then
        return jsonb_build_object('error','invalid_arguments','message','channels must be an array of dashboard, phone, email, and webhook.');
      end if;
      select coalesce(array_agg(item), '{}') into v_list from jsonb_array_elements_text(v_args->'channels') item;
      v_channels := public.fizz_normalize_channels(v_list);
      if v_channels is null then
        return jsonb_build_object('error','invalid_arguments','message','channels must be dashboard, phone, email, webhook, or a combination.');
      end if;
    else
      v_channels := array['dashboard'];
    end if;
    v_phone := null;
    v_channel := 'none';
    if nullif(v_args->>'call_phone', '') is not null and not (v_args ? 'channels') then
      v_channels := array['dashboard', 'phone'];
    elsif nullif(v_args->>'call_phone', '') is not null and not ('phone' = any (v_channels)) then
      return jsonb_build_object('error','invalid_arguments','message','call_phone needs the phone channel.');
    end if;
    if 'phone' = any (v_channels) then
      v_phone := public.fizz_us_phone(coalesce(nullif(v_args->>'call_phone', ''), v_args->>'notify_phone'));
      if v_phone is null then
        return jsonb_build_object('error','invalid_arguments','message','call_phone must be a US number, for example (415) 555-0123.');
      end if;
      v_channel := 'call';
    end if;
    if 'webhook' = any (v_channels) then
      if v_url is null then
        return jsonb_build_object('error','invalid_arguments','message','webhook_url is required for the webhook channel and must be a public https URL.');
      end if;
    elsif v_url is not null or v_secret is not null then
      return jsonb_build_object('error','invalid_arguments','message','webhook_url is only used with the webhook channel.');
    end if;
    if v_secret is not null and (char_length(v_secret) < 16 or char_length(v_secret) > 128 or v_secret ~ '[[:space:][:cntrl:]]') then
      return jsonb_build_object('error','invalid_arguments','message','webhook_secret is 16 to 128 characters, without spaces.');
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
        v_channel, v_phone, v_minutes, v_recovery, 100, v_channels, v_url, v_secret);
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
        v_threshold, v_unit, v_channel, v_phone, null, false, 100, v_channels, v_url, v_secret);
    end if;
    if v_saved->>'error' = 'simulated_sensor' then
      return jsonb_build_object('error','invalid_arguments','message',
        'Sample sensors only report while someone is viewing them, so they cannot have a silence alert.');
    elsif v_saved->>'error' = 'alert_limit' then
      return jsonb_build_object('error','invalid_arguments','message','This account already has 100 active alerts. Pause or delete some first.');
    elsif v_saved->>'error' = 'invalid_phone' then
      return jsonb_build_object('error','invalid_arguments','message','call_phone must be a real geographic US number. Toll-free, premium, and fictional numbers cannot be called.');
    elsif v_saved->>'error' = 'phone_not_paired' then
      return jsonb_build_object('error','invalid_arguments','message','Pair this phone number in the Fizzlayer dashboard before an alert can call it. Open Phones, have Fizzlayer call the number, and enter the code.');
    elsif v_saved->>'error' = 'calls_not_included' then
      return jsonb_build_object('error','invalid_arguments','message','Phone calls are included with Tinkerer, Pro, and Enterprise. Create a dashboard-only alert, or ask the owner to upgrade.');
    elsif v_saved->>'error' = 'channels_not_included' then
      return jsonb_build_object('error','invalid_arguments','message','Email and webhook alerts are not included on this plan.');
    elsif v_saved->>'error' = 'invalid_webhook' then
      return jsonb_build_object('error','invalid_arguments','message','webhook_url must be a public https URL. Private and loopback addresses are refused. webhook_secret, when set, is 16 to 128 characters.');
    elsif v_saved->>'error' = 'invalid_channels' then
      return jsonb_build_object('error','invalid_arguments','message','channels must be dashboard, phone, email, webhook, or a combination.');
    elsif v_saved ? 'error' then
      return jsonb_build_object('error','invalid_arguments','message','That alert could not be saved.');
    end if;
    return jsonb_build_object('result', jsonb_build_object('created', v_saved->'created', 'rule',
      jsonb_build_object('id', v_saved->'rule'->'id', 'sensor_id', v_saved->'rule'->'sensor_id',
        'kind', v_saved->'rule'->'kind', 'calls_phone', v_saved->'rule'->>'notify_channel' = 'call',
        'channels', v_saved->'rule'->'channels', 'webhook_url', v_saved->'rule'->'webhook_url')
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



revoke execute on function
  public.fizz_message_channels_on_all_plans(),
  public.fizz_channels_ok(text[]),
  public.fizz_normalize_channels(text[]),
  public.fizz_webhook_url_ok(text),
  public.fizz_sync_alert_channels(),
  public.fizz_ensure_webhook_secret(uuid),
  public.fizz_enqueue_alert_deliveries(),
  public.fizz_claim_alert_deliveries(integer, boolean),
  public.fizz_alert_delivery_still_due(uuid),
  public.fizz_finish_alert_delivery(uuid, text, text, integer),
  public.fizz_save_alert_rule(uuid, uuid, text, text, text, double precision, text, text, text, integer, boolean, integer, text[], text, text),
  public.fizz_create_alert(text, uuid, text, text, double precision, text, text, text, text, integer, boolean, text[], text, text),
  public.fizz_update_alert(text, uuid, boolean, boolean, text[], text, text, text)
from public, anon, authenticated;
grant execute on function
  public.fizz_claim_alert_deliveries(integer, boolean),
  public.fizz_alert_delivery_still_due(uuid),
  public.fizz_finish_alert_delivery(uuid, text, text, integer),
  public.fizz_create_alert(text, uuid, text, text, double precision, text, text, text, text, integer, boolean, text[], text, text),
  public.fizz_update_alert(text, uuid, boolean, boolean, text[], text, text, text)
to service_role;
