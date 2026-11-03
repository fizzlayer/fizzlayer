-- Pair a phone before any alert can call it, and place calls only on paid plans.
--
-- Migration of existing numbers: nothing already stored is treated as paired.
-- Alert rules keep their notify_phone so a later pairing can resume calls, but
-- every pending or sending call is skipped. Owners pair a number from the
-- dashboard (a call reads a one-time code) before that number can be dialed again.

alter table public.fizz_plans
  add column calls_enabled boolean not null default false;
update public.fizz_plans set calls_enabled = true where id in ('tinkerer', 'pro', 'enterprise');

-- Recreate so the row type includes calls_enabled for callers that expand fizz_plans.
create or replace function public.fizz_customer_plan(p_customer uuid)
returns public.fizz_plans language sql stable security definer set search_path = '' as $$
  select p.* from public.fizz_plans p
  where p.id = coalesce((select s.plan from public.fizz_subscriptions s where s.customer_id = p_customer), 'hobbyist');
$$;

-- past_due and trialing stay paid (Stripe is still retrying or the trial is open).
-- canceled, unpaid, and incomplete do not, even if the plan column was not rewritten.
-- A null status means the plan was set by hand (self-hosted or Enterprise).
create function public.fizz_calls_allowed(p_customer uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((
    select p.calls_enabled
      and (s.status is null or public.fizz_billing_active(s.status))
    from public.fizz_plans p
    left join public.fizz_subscriptions s on s.customer_id = p_customer
    where p.id = coalesce(s.plan, 'hobbyist')
  ), false);
$$;

-- Numbers this workspace has proved it can answer. Distinct from phone-sensor pairings.
create table public.fizz_verified_phones (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.fizz_customers(id) on delete cascade,
  phone text not null check (phone ~ '^\+1[2-9][0-9]{2}[2-9][0-9]{6}$'),
  verified_at timestamptz not null default now(),
  unique (customer_id, phone)
);
create index fizz_verified_phones_customer_idx on public.fizz_verified_phones(customer_id);

-- The code itself is never stored. Each row has its own salt, mixed with a pepper that
-- clients cannot read, so a leaked hash is not a single rainbow table of every code.
-- The table has no client policies even if a grant is added later.
create table public.fizz_call_code_pepper (
  id boolean primary key default true check (id),
  pepper bytea not null
);
insert into public.fizz_call_code_pepper(pepper) values (extensions.gen_random_bytes(32));
alter table public.fizz_call_code_pepper enable row level security;
revoke all on public.fizz_call_code_pepper from public, anon, authenticated;
grant all on public.fizz_call_code_pepper to service_role;

create table public.fizz_call_verifications (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.fizz_customers(id) on delete cascade,
  phone text not null check (phone ~ '^\+1[2-9][0-9]{2}[2-9][0-9]{6}$'),
  code_salt bytea not null,
  code_hash bytea not null,
  expires_at timestamptz not null,
  attempts smallint not null default 0 check (attempts between 0 and 5),
  consumed_at timestamptz,
  cancelled_at timestamptz,
  created_at timestamptz not null default now()
);
create index fizz_call_verifications_customer_phone_idx
  on public.fizz_call_verifications(customer_id, phone, created_at desc);

alter table public.fizz_verified_phones enable row level security;
alter table public.fizz_call_verifications enable row level security;
revoke all on public.fizz_verified_phones, public.fizz_call_verifications from public, anon, authenticated;
grant all on public.fizz_verified_phones, public.fizz_call_verifications to service_role;

-- Select and delete only. Insert and update stay denied so a future table grant
-- cannot mark a number verified without the code.
create policy fizz_verified_phones_owner_select on public.fizz_verified_phones
  for select to authenticated using (
    coalesce((select auth.jwt() ->> 'is_anonymous'), 'false') <> 'true'
    and exists (select 1 from public.fizz_customers c
      where c.id = customer_id and c.auth_user_id = (select auth.uid()))
  );
create policy fizz_verified_phones_owner_delete on public.fizz_verified_phones
  for delete to authenticated using (
    coalesce((select auth.jwt() ->> 'is_anonymous'), 'false') <> 'true'
    and exists (select 1 from public.fizz_customers c
      where c.id = customer_id and c.auth_user_id = (select auth.uid()))
  );

-- Any delete, including one a future client grant would allow through the policy above,
-- drops queued calls to that number. The API remove path hits this trigger too.
create function public.fizz_verified_phone_removed() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform public.fizz_skip_call_events(old.customer_id, old.phone, 'Phone number was removed.');
  return old;
end;
$$;
create trigger fizz_verified_phone_removed
  before delete on public.fizz_verified_phones
  for each row execute function public.fizz_verified_phone_removed();
revoke execute on function public.fizz_verified_phone_removed() from public, anon, authenticated, service_role;

-- Six digits, rejection-sampled so 000000 through 999999 are equally likely.
create function public.fizz_pairing_code()
returns text language plpgsql volatile set search_path = '' as $$
declare v_bytes bytea; v_n integer; v_try integer := 0;
begin
  loop
    v_try := v_try + 1;
    v_bytes := extensions.gen_random_bytes(3);
    v_n := pg_catalog.get_byte(v_bytes, 0) * 65536
      + pg_catalog.get_byte(v_bytes, 1) * 256
      + pg_catalog.get_byte(v_bytes, 2);
    exit when v_n < 16000000 or v_try >= 8;
  end loop;
  if v_n >= 16000000 then v_n := v_n % 16000000; end if;
  return lpad((v_n % 1000000)::text, 6, '0');
end;
$$;

-- p_phone null skips every queued call for the account (downgrade or unverified backlog).
create function public.fizz_skip_call_events(p_customer uuid, p_phone text, p_reason text)
returns void language sql security definer set search_path = '' as $$
  update public.fizz_alert_events
  set notify_status = 'skipped', notify_error = left(p_reason, 200)
  where customer_id = p_customer and notify_channel = 'call'
    and notify_status in ('pending', 'sending')
    and (p_phone is null or notify_phone = p_phone);
$$;

-- Null when a call is not blocked by the plan or by pairing. Rate-limit skips stay null
-- so the dashboard can keep its "sent one recently" wording for those.
create function public.fizz_alert_call_skip_reason(p_customer uuid, p_rule uuid, p_channel text)
returns text language plpgsql stable security definer set search_path = '' as $$
begin
  if p_channel is distinct from 'call' then return null; end if;
  if not public.fizz_calls_allowed(p_customer) then
    return 'Phone calls are not included on this plan.';
  end if;
  if not exists (
    select 1 from public.fizz_verified_phones v
    join public.fizz_alert_rules r on r.id = p_rule and r.notify_phone = v.phone
    where v.customer_id = p_customer
  ) then
    return 'Phone number is not paired.';
  end if;
  return null;
end;
$$;

create or replace function public.fizz_alert_notify_status(p_customer uuid, p_rule uuid, p_channel text)
returns text language plpgsql security definer set search_path = '' as $$
begin
  if p_channel is distinct from 'call' then return 'none'; end if;
  if public.fizz_alert_call_skip_reason(p_customer, p_rule, p_channel) is not null then
    return 'skipped';
  end if;
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

create or replace function public.fizz_alert_call_still_due(p_event_id uuid)
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
  elsif not public.fizz_calls_allowed(v_event.customer_id) then
    v_reason := 'Phone calls are not included on this plan.';
  elsif v_event.notify_phone is null or not exists (
    select 1 from public.fizz_verified_phones
    where customer_id = v_event.customer_id and phone = v_event.notify_phone
  ) then
    v_reason := 'Phone number is not paired.';
  elsif public.fizz_callable_us_phone(v_event.notify_phone) is null then
    v_reason := 'That phone number cannot be called.';
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

create or replace function public.fizz_save_alert_rule(p_customer uuid, p_sensor_id uuid, p_kind text,
  p_metric text, p_comparator text, p_threshold double precision, p_unit text,
  p_channel text, p_phone text, p_minutes integer, p_recovery boolean, p_max_active integer)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_rule public.fizz_alert_rules%rowtype;
begin
  perform pg_advisory_xact_lock(hashtextextended(p_customer::text, 0));
  if p_kind = 'silence' and exists(select 1 from public.fizz_sensors
      where id = p_sensor_id and mode = 'simulated') then
    return jsonb_build_object('error','simulated_sensor');
  end if;
  if p_channel = 'call' then
    if public.fizz_callable_us_phone(p_phone) is null then
      return jsonb_build_object('error','invalid_phone');
    end if;
    if not public.fizz_calls_allowed(p_customer) then
      return jsonb_build_object('error','calls_not_included');
    end if;
    if p_phone is null or not exists (
      select 1 from public.fizz_verified_phones where customer_id = p_customer and phone = p_phone
    ) then
      return jsonb_build_object('error','phone_not_paired');
    end if;
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

-- Toll-free, premium, personal-communication, and fictional numbers are not geographic lines.
-- 555 is the fictional exchange. 976 is a premium exchange. 8xx and 900 are not local numbers.
create function public.fizz_callable_us_phone(p_phone text)
returns text language plpgsql immutable set search_path = '' as $$
declare v_phone text := public.fizz_us_phone(p_phone); v_npa text; v_nxx text;
begin
  if v_phone is null then return null; end if;
  v_npa := substr(v_phone, 3, 3);
  v_nxx := substr(v_phone, 6, 3);
  if v_nxx in ('555', '976') or v_npa in (
    '500','521','522','523','524','525','526','527','528','529',
    '532','533','535','538','542','543','544','545','546','547','549',
    '550','552','553','554','556','558','566','569','577','578','588','589',
    '700','710',
    '800','822','833','844','855','866','877','880','881','882','883','884','885','886','887','888',
    '900'
  ) then
    return null;
  end if;
  return v_phone;
end;
$$;

-- Seconds until the current fixed rate-limit window ends. At least 1.
create function public.fizz_rate_retry_seconds(p_window interval)
returns integer language sql stable set search_path = '' as $$
  select greatest(1, ceil(extract(epoch from (
    to_timestamp((floor(extract(epoch from now()) / extract(epoch from p_window)) + 1)
      * extract(epoch from p_window))
    - now()
  )))::integer);
$$;

create function public.fizz_code_hash(p_salt bytea, p_code text)
returns bytea language sql stable security definer set search_path = '' as $$
  select extensions.digest(
    (select pepper from public.fizz_call_code_pepper where id)
      || p_salt
      || convert_to(p_code, 'UTF8'),
    'sha256');
$$;

-- Compare both 32-byte hashes without returning on the first differing byte.
create function public.fizz_hash_equals(p_left bytea, p_right bytea)
returns boolean language plpgsql immutable set search_path = '' as $$
declare v_diff integer := 0; v_i integer;
begin
  if p_left is null or p_right is null
    or octet_length(p_left) <> 32 or octet_length(p_right) <> 32 then
    return false;
  end if;
  for v_i in 0..31 loop
    v_diff := v_diff | (pg_catalog.get_byte(p_left, v_i) # pg_catalog.get_byte(p_right, v_i));
  end loop;
  return v_diff = 0;
end;
$$;

-- Owner session only. Agent tokens are not fizz_sessions rows, so they cannot start,
-- confirm, list, or remove a pairing. The plaintext code is returned to the service
-- role so it can be spoken on the call; the HTTP handler must not send it to the browser.
create function public.fizz_call_phone_start(p_token text, p_phone text, p_ip text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_customer uuid;
  v_phone text;
  v_code text;
  v_id uuid;
  v_salt bytea;
  v_site text;
  v_recent timestamptz;
  v_network text := coalesce(nullif(btrim(p_ip), ''), 'unknown');
begin
  v_customer := public.fizz_session_customer(p_token);
  if v_customer is null then return jsonb_build_object('error','unauthorized'); end if;
  delete from public.fizz_call_verifications
  where expires_at < now() - interval '1 day'
     or (consumed_at is not null and consumed_at < now() - interval '1 day')
     or (cancelled_at is not null and cancelled_at < now() - interval '1 day');
  if not public.fizz_rate_limit_hit('call_pair_request', v_customer::text, 30, interval '1 hour') then
    return jsonb_build_object('error','rate_limited','retry_after_seconds', public.fizz_rate_retry_seconds(interval '1 hour'));
  end if;
  v_phone := public.fizz_callable_us_phone(p_phone);
  if v_phone is null then return jsonb_build_object('error','invalid_phone'); end if;
  if not public.fizz_calls_allowed(v_customer) then
    return jsonb_build_object('error','calls_not_included');
  end if;
  -- One lock for this workspace covers the cooldown, the cap, and confirm.
  perform pg_advisory_xact_lock(hashtextextended('fizz_call_phones:' || v_customer::text, 0));
  if exists (select 1 from public.fizz_verified_phones where customer_id = v_customer and phone = v_phone) then
    return jsonb_build_object('already_paired', true, 'phone', v_phone);
  end if;
  if (select count(*) from public.fizz_verified_phones where customer_id = v_customer) >= 10 then
    return jsonb_build_object('error','phone_limit');
  end if;
  select created_at into v_recent from public.fizz_call_verifications
  where customer_id = v_customer and phone = v_phone
  order by created_at desc
  limit 1
  for update;
  if v_recent is not null and v_recent > now() - interval '60 seconds' then
    return jsonb_build_object('error','cooldown','retry_after_seconds',
      greatest(1, ceil(extract(epoch from (v_recent + interval '60 seconds' - now())))::integer));
  end if;
  begin
    if family(v_network::inet) = 6 then
      v_site := network(set_masklen(v_network::inet, 48))::text;
    end if;
  exception when others then
    v_site := null;
  end;
  if not public.fizz_rate_limit_hit('call_pair_account_hour', v_customer::text, 5, interval '1 hour') then
    return jsonb_build_object('error','rate_limited','retry_after_seconds', public.fizz_rate_retry_seconds(interval '1 hour'));
  end if;
  if not public.fizz_rate_limit_hit('call_pair_account_day', v_customer::text, 10, interval '1 day') then
    return jsonb_build_object('error','rate_limited','retry_after_seconds', public.fizz_rate_retry_seconds(interval '1 day'));
  end if;
  if not public.fizz_rate_limit_hit('call_pair_number_hour', v_phone, 3, interval '1 hour') then
    return jsonb_build_object('error','rate_limited','retry_after_seconds', public.fizz_rate_retry_seconds(interval '1 hour'));
  end if;
  if not public.fizz_rate_limit_hit('call_pair_number_day', v_phone, 5, interval '1 day') then
    return jsonb_build_object('error','rate_limited','retry_after_seconds', public.fizz_rate_retry_seconds(interval '1 day'));
  end if;
  if not public.fizz_rate_limit_hit('call_pair_network_hour', v_network, 8, interval '1 hour') then
    return jsonb_build_object('error','rate_limited','retry_after_seconds', public.fizz_rate_retry_seconds(interval '1 hour'));
  end if;
  if v_site is not null and not public.fizz_rate_limit_hit('call_pair_network48_hour', v_site, 20, interval '1 hour') then
    return jsonb_build_object('error','rate_limited','retry_after_seconds', public.fizz_rate_retry_seconds(interval '1 hour'));
  end if;
  if not public.fizz_rate_limit_hit('call_pair_all_hour', 'all', 100, interval '1 hour') then
    return jsonb_build_object('error','rate_limited','retry_after_seconds', public.fizz_rate_retry_seconds(interval '1 hour'));
  end if;
  update public.fizz_call_verifications
  set cancelled_at = now()
  where customer_id = v_customer and phone = v_phone and consumed_at is null and cancelled_at is null;
  v_code := public.fizz_pairing_code();
  v_salt := extensions.gen_random_bytes(16);
  insert into public.fizz_call_verifications(customer_id, phone, code_salt, code_hash, expires_at)
  values (v_customer, v_phone, v_salt, public.fizz_code_hash(v_salt, v_code), now() + interval '10 minutes')
  returning id into v_id;
  return jsonb_build_object(
    'verification_id', v_id, 'phone', v_phone, 'code', v_code, 'expires_in_seconds', 600);
end;
$$;

create function public.fizz_call_phone_cancel(p_token text, p_verification_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_customer uuid;
begin
  v_customer := public.fizz_session_customer(p_token);
  if v_customer is null then return jsonb_build_object('error','unauthorized'); end if;
  update public.fizz_call_verifications
  set cancelled_at = now()
  where id = p_verification_id and customer_id = v_customer
    and consumed_at is null and cancelled_at is null;
  return jsonb_build_object('ok', true);
end;
$$;

create function public.fizz_call_phone_confirm(p_token text, p_phone text, p_code text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_customer uuid;
  v_phone text;
  v_digits text;
  v_row public.fizz_call_verifications%rowtype;
begin
  v_customer := public.fizz_session_customer(p_token);
  if v_customer is null then return jsonb_build_object('error','unauthorized'); end if;
  v_phone := public.fizz_us_phone(p_phone);
  if v_phone is null then return jsonb_build_object('error','invalid_phone'); end if;
  perform pg_advisory_xact_lock(hashtextextended('fizz_call_phones:' || v_customer::text, 0));
  if exists (select 1 from public.fizz_verified_phones where customer_id = v_customer and phone = v_phone) then
    return jsonb_build_object('already_paired', true, 'phone', v_phone);
  end if;
  if (select count(*) from public.fizz_verified_phones where customer_id = v_customer) >= 10 then
    return jsonb_build_object('error','phone_limit');
  end if;
  select * into v_row from public.fizz_call_verifications
  where customer_id = v_customer and phone = v_phone
    and consumed_at is null and cancelled_at is null
  order by created_at desc
  limit 1
  for update;
  if not found then return jsonb_build_object('error','invalid_code'); end if;
  if v_row.expires_at <= now() then
    update public.fizz_call_verifications set cancelled_at = now() where id = v_row.id;
    return jsonb_build_object('error','expired');
  end if;
  if v_row.attempts >= 5 then return jsonb_build_object('error','too_many_attempts'); end if;
  v_digits := regexp_replace(coalesce(p_code, ''), '[^0-9]', '', 'g');
  if v_digits !~ '^[0-9]{6}$' then return jsonb_build_object('error','invalid_code'); end if;
  update public.fizz_call_verifications set attempts = attempts + 1 where id = v_row.id;
  if public.fizz_hash_equals(v_row.code_hash, public.fizz_code_hash(v_row.code_salt, v_digits)) then
    -- Recount under the same lock. Two codes started while nine numbers were paired
    -- must not both insert.
    if (select count(*) from public.fizz_verified_phones where customer_id = v_customer) >= 10 then
      return jsonb_build_object('error','phone_limit');
    end if;
    update public.fizz_call_verifications set consumed_at = now() where id = v_row.id;
    update public.fizz_call_verifications set cancelled_at = now()
    where customer_id = v_customer and phone = v_phone and id <> v_row.id
      and consumed_at is null and cancelled_at is null;
    insert into public.fizz_verified_phones(customer_id, phone) values (v_customer, v_phone)
    on conflict (customer_id, phone) do nothing;
    return jsonb_build_object('ok', true, 'phone', v_phone);
  end if;
  if v_row.attempts + 1 >= 5 then return jsonb_build_object('error','too_many_attempts'); end if;
  return jsonb_build_object('error','invalid_code','attempts_remaining', 5 - (v_row.attempts + 1));
end;
$$;

create function public.fizz_call_phone_list(p_token text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_customer uuid;
begin
  v_customer := public.fizz_session_customer(p_token);
  if v_customer is null then return jsonb_build_object('error','unauthorized'); end if;
  return jsonb_build_object(
    'calls_included', public.fizz_calls_allowed(v_customer),
    'phones', coalesce((
      select jsonb_agg(jsonb_build_object('phone', phone, 'verified_at', verified_at) order by verified_at desc)
      from public.fizz_verified_phones where customer_id = v_customer
    ), '[]'::jsonb),
    'pending', (
      select jsonb_build_object(
        'phone', phone, 'expires_at', expires_at,
        'attempts_remaining', 5 - attempts,
        'resend_at', created_at + interval '60 seconds')
      from public.fizz_call_verifications
      where customer_id = v_customer and consumed_at is null and cancelled_at is null and expires_at > now()
      order by created_at desc limit 1
    )
  );
end;
$$;

create function public.fizz_call_phone_remove(p_token text, p_phone text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_customer uuid; v_phone text; v_deleted integer;
begin
  v_customer := public.fizz_session_customer(p_token);
  if v_customer is null then return jsonb_build_object('error','unauthorized'); end if;
  v_phone := public.fizz_us_phone(p_phone);
  if v_phone is null then return jsonb_build_object('error','invalid_phone'); end if;
  delete from public.fizz_verified_phones where customer_id = v_customer and phone = v_phone;
  get diagnostics v_deleted = row_count;
  if v_deleted = 0 then return jsonb_build_object('error','not_found'); end if;
  update public.fizz_call_verifications set cancelled_at = now()
  where customer_id = v_customer and phone = v_phone and consumed_at is null and cancelled_at is null;
  perform public.fizz_skip_call_events(v_customer, v_phone, 'Phone number was removed.');
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.fizz_evaluate_alerts() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_rule public.fizz_alert_rules%rowtype;
  v_hit boolean;
  v_notify text;
  v_skip text;
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
        v_skip := public.fizz_alert_call_skip_reason(v_rule.customer_id, v_rule.id, v_rule.notify_channel);
        insert into public.fizz_alert_events
          (rule_id, reading_id, customer_id, sensor_id, metric, numeric_value, threshold, comparator, unit, observed_at,
           notify_channel, notify_phone, notify_status, notify_error, event_kind)
        values
          (v_rule.id, new.id, v_rule.customer_id, new.sensor_id, 'silence',
           0, v_rule.silence_minutes, 'gte', 'min', new.observed_at,
           v_rule.notify_channel, v_rule.notify_phone, v_notify, v_skip, 'recovery')
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
        v_skip := public.fizz_alert_call_skip_reason(v_rule.customer_id, v_rule.id, v_rule.notify_channel);
      insert into public.fizz_alert_events
        (rule_id, reading_id, customer_id, sensor_id, metric, numeric_value, threshold, comparator, unit, observed_at,
         notify_channel, notify_phone, notify_status, notify_error)
      values
        (v_rule.id, new.id, v_rule.customer_id, new.sensor_id, new.metric,
         new.numeric_value, v_rule.threshold, v_rule.comparator, v_rule.unit, new.observed_at,
         v_rule.notify_channel, v_rule.notify_phone, v_notify, v_skip)
      on conflict (rule_id, reading_id, event_kind) do nothing;
      update public.fizz_alert_rules set armed = false, updated_at = now() where id = v_rule.id;
    elsif not v_hit and not v_rule.armed then
      update public.fizz_alert_rules set armed = true, updated_at = now() where id = v_rule.id;
    end if;
  end loop;
  return new;
end;
$$;

create or replace function public.fizz_scan_silence_alerts(p_limit integer default 50)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_rule public.fizz_alert_rules%rowtype;
  v_reading_id uuid;
  v_received timestamptz;
  v_minutes double precision;
  v_notify text;
  v_skip text;
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
        v_skip := public.fizz_alert_call_skip_reason(v_rule.customer_id, v_rule.id, v_rule.notify_channel);
    insert into public.fizz_alert_events
      (rule_id, reading_id, customer_id, sensor_id, metric, numeric_value, threshold, comparator, unit, observed_at,
       notify_channel, notify_phone, notify_status, notify_error, event_kind)
    values
      (v_rule.id, v_reading_id, v_rule.customer_id, v_rule.sensor_id, 'silence',
       v_minutes, v_rule.silence_minutes, 'gte', 'min', now(),
       v_rule.notify_channel, v_rule.notify_phone, v_notify, v_skip, 'silence')
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
    elsif v_saved->>'error' = 'invalid_phone' then
      return jsonb_build_object('error','invalid_arguments','message','call_phone must be a real geographic US number. Toll-free, premium, and fictional numbers cannot be called.');
    elsif v_saved->>'error' = 'phone_not_paired' then
      return jsonb_build_object('error','invalid_arguments','message','Pair this phone number in the Fizzlayer dashboard before an alert can call it. Open Phones, have Fizzlayer call the number, and enter the code.');
    elsif v_saved->>'error' = 'calls_not_included' then
      return jsonb_build_object('error','invalid_arguments','message','Phone calls are included with Tinkerer, Pro, and Enterprise. Create a dashboard-only alert, or ask the owner to upgrade.');
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

create or replace function public.fizz_plan_usage(p_customer uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', p.id, 'name', p.name, 'monthly_price_cents', p.monthly_price_cents,
    'device_limit', p.device_limit,
    'devices_used', (select count(*) from public.fizz_sensors s
      where s.customer_id = p_customer and s.deleted_at is null and s.mode in ('api', 'phone')),
    'calls_included', public.fizz_calls_allowed(p_customer),
    'monthly_credits', public.fizz_monthly_credits(p_customer),
    'credits_used', coalesce((select u.used from public.fizz_credit_usage u
      where u.customer_id = p_customer and u.period_start = public.fizz_credit_period()), 0),
    'credits_reset_at', (public.fizz_credit_period() + interval '1 month') at time zone 'utc',
    'subscription', (select jsonb_build_object('status', s.status, 'current_period_end', s.current_period_end,
        'cancel_at_period_end', s.cancel_at_period_end, 'has_billing_account', s.stripe_customer_id is not null)
      from public.fizz_subscriptions s where s.customer_id = p_customer))
  from public.fizz_customer_plan(p_customer) p;
$$;

create or replace function public.fizz_billing_sync(p_stripe_customer text, p_customer uuid, p_subscription_id text,
  p_status text, p_plan text, p_current_period_end bigint, p_cancel_at_period_end boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_sub public.fizz_subscriptions%rowtype;
begin
  if p_plan is not null and p_plan not in ('tinkerer', 'pro') then
    return jsonb_build_object('error', 'invalid_plan');
  end if;
  select * into v_sub from public.fizz_subscriptions where stripe_customer_id = p_stripe_customer for update;
  if not found and p_customer is not null then
    perform public.fizz_billing_link_customer(p_customer, p_stripe_customer);
    select * into v_sub from public.fizz_subscriptions
    where customer_id = p_customer and stripe_customer_id = p_stripe_customer for update;
  end if;
  if not found then return jsonb_build_object('error', 'unknown_customer'); end if;
  -- Enterprise is arranged outside Stripe; never let a webhook change it.
  if v_sub.plan = 'enterprise' then return jsonb_build_object('ignored', 'enterprise'); end if;
  -- A second subscription ending must not cancel the one that is still paying.
  if v_sub.stripe_subscription_id is distinct from p_subscription_id
    and public.fizz_billing_active(v_sub.status) and not public.fizz_billing_active(p_status) then
    return jsonb_build_object('ignored', 'inactive_other_subscription');
  end if;
  update public.fizz_subscriptions set
    plan = case when public.fizz_billing_active(p_status) and p_plan is not null then p_plan else 'hobbyist' end,
    stripe_subscription_id = p_subscription_id, status = p_status,
    current_period_end = to_timestamp(p_current_period_end), cancel_at_period_end = coalesce(p_cancel_at_period_end, false),
    updated_at = now()
  where customer_id = v_sub.customer_id returning * into v_sub;
  if not public.fizz_calls_allowed(v_sub.customer_id) then
    perform public.fizz_skip_call_events(v_sub.customer_id, null, 'Phone calls are not included on this plan.');
  end if;
  return jsonb_build_object('plan', v_sub.plan, 'status', v_sub.status);
end;
$$;

create or replace function public.fizz_auth_changed() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if old.encrypted_password is distinct from new.encrypted_password
    or old.email is distinct from new.email
    or old.banned_until is distinct from new.banned_until
    or old.deleted_at is distinct from new.deleted_at
    or old.is_anonymous is distinct from new.is_anonymous then
    delete from public.fizz_sessions where customer_id in
      (select id from public.fizz_customers where auth_user_id = new.id);
  end if;
  if new.banned_until > now() or new.deleted_at is not null or coalesce(new.is_anonymous, false) then
    update public.fizz_agent_connections set revoked_at = now()
      where revoked_at is null and customer_id in (select id from public.fizz_customers where auth_user_id = new.id);
    update public.fizz_phone_devices set revoked_at = now()
      where revoked_at is null and sensor_id in (select s.id from public.fizz_sensors s
        join public.fizz_customers c on c.id = s.customer_id where c.auth_user_id = new.id);
    update public.fizz_sensors set api_key_hash = null, status = 'paused'
      where customer_id in (select id from public.fizz_customers where auth_user_id = new.id);
    update public.fizz_alert_rules set enabled = false where customer_id in
      (select id from public.fizz_customers where auth_user_id = new.id);
    update public.fizz_alert_events set notify_status = 'skipped', notify_error = 'Account suspended.'
      where notify_status in ('pending', 'sending') and customer_id in
        (select id from public.fizz_customers where auth_user_id = new.id);
    delete from public.fizz_phone_pairings where customer_id in
      (select id from public.fizz_customers where auth_user_id = new.id);
    delete from public.fizz_call_verifications where customer_id in
      (select id from public.fizz_customers where auth_user_id = new.id);
    update public.fizz_device_pairings set status = 'rejected', finished_at = now()
      where status in ('waiting', 'claimed') and customer_id in
        (select id from public.fizz_customers where auth_user_id = new.id);
  end if;
  return new;
end;
$$;


-- Existing numbers stay on their rules and are not inserted as verified.
-- Queued calls stop until the owner pairs the number (and is on a plan that includes calls).
select public.fizz_skip_call_events(c.id, null,
  'Phone number is not paired. Pair it in the dashboard before calls can resume.')
from public.fizz_customers c
where exists (
  select 1 from public.fizz_alert_events e
  where e.customer_id = c.id and e.notify_channel = 'call' and e.notify_status in ('pending', 'sending')
);

-- Paired numbers are part of the chat context so Fizz can call one the owner already verified.
create or replace function public.fizz_chat_context(p_token text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_customer uuid;
begin
  select customer_id into v_customer from public.fizz_sessions
  where p_token ~ '^[0-9a-f]{64}$'
    and token_hash = extensions.digest(decode(p_token, 'hex'), 'sha256') and expires_at > now();
  if v_customer is null then return jsonb_build_object('error','unauthorized'); end if;
  return jsonb_build_object(
    'sensors', coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'name',s.name,'kind',s.kind,'mode',s.mode))
      from public.fizz_sensors s where s.customer_id = v_customer and s.deleted_at is null), '[]'::jsonb),
    'latest', coalesce((select jsonb_agg(jsonb_build_object('sensor_id',q.sensor_id,'metric',q.metric,
      'numeric_value',q.numeric_value,'boolean_value',q.boolean_value,'text_value',q.text_value,
      'unit',q.unit,'observed_at',q.observed_at,'source',q.source))
      from (select * from (select distinct on (r.sensor_id,r.metric) r.*
        from public.fizz_sensor_readings r join public.fizz_sensors s on s.id = r.sensor_id
        where s.customer_id = v_customer and s.deleted_at is null
        order by r.sensor_id,r.metric,r.observed_at desc,r.received_at desc) latest_rows
        order by observed_at desc limit 100) q), '[]'::jsonb),
    'readings', coalesce((select jsonb_agg(jsonb_build_object('sensor_id',q.sensor_id,'metric',q.metric,
      'numeric_value',q.numeric_value,'boolean_value',q.boolean_value,'text_value',q.text_value,
      'unit',q.unit,'observed_at',q.observed_at,'source',q.source))
      from (select r.* from public.fizz_sensor_readings r join public.fizz_sensors s on s.id = r.sensor_id
        where s.customer_id = v_customer and s.deleted_at is null
        order by r.observed_at desc limit 100) q), '[]'::jsonb),
    'transcripts', coalesce((select jsonb_agg(jsonb_build_object('sensor_id',q.sensor_id,
      'text_value',q.text_value,'observed_at',q.observed_at))
      from (select r.* from public.fizz_sensor_readings r join public.fizz_sensors s on s.id = r.sensor_id
        where s.customer_id = v_customer and s.deleted_at is null and r.metric = 'voice_transcript'
        order by r.observed_at desc limit 20) q), '[]'::jsonb),
    'rules', coalesce((select jsonb_agg(jsonb_build_object('sensor_id',r.sensor_id,'metric',r.metric,
      'comparator',r.comparator,'threshold',r.threshold,'unit',r.unit,'enabled',r.enabled))
      from public.fizz_alert_rules r join public.fizz_sensors s on s.id = r.sensor_id
      where r.customer_id = v_customer and s.deleted_at is null), '[]'::jsonb),
    'alerts', coalesce((select jsonb_agg(jsonb_build_object('sensor_id',e.sensor_id,'metric',e.metric,
      'numeric_value',e.numeric_value,'threshold',e.threshold,'unit',e.unit,'observed_at',e.observed_at))
      from (select * from public.fizz_alert_events where customer_id = v_customer
        order by created_at desc limit 20) e), '[]'::jsonb),
    'paired_phones', coalesce((select jsonb_agg(phone order by verified_at desc)
      from public.fizz_verified_phones where customer_id = v_customer), '[]'::jsonb));
end;
$$;

revoke execute on function
  public.fizz_calls_allowed(uuid),
  public.fizz_pairing_code(),
  public.fizz_callable_us_phone(text),
  public.fizz_rate_retry_seconds(interval),
  public.fizz_code_hash(bytea, text),
  public.fizz_hash_equals(bytea, bytea),
  public.fizz_skip_call_events(uuid, text, text),
  public.fizz_alert_call_skip_reason(uuid, uuid, text),
  public.fizz_call_phone_start(text, text, text),
  public.fizz_call_phone_cancel(text, uuid),
  public.fizz_call_phone_confirm(text, text, text),
  public.fizz_call_phone_list(text),
  public.fizz_call_phone_remove(text, text)
from public, anon, authenticated;
grant execute on function
  public.fizz_calls_allowed(uuid),
  public.fizz_call_phone_start(text, text, text),
  public.fizz_call_phone_cancel(text, uuid),
  public.fizz_call_phone_confirm(text, text, text),
  public.fizz_call_phone_list(text),
  public.fizz_call_phone_remove(text, text)
to service_role;
