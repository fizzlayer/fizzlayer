-- Plans cap connected devices and monthly Fizz chat credits. Sample (simulated) sensors are
-- free and unlimited; API and phone sensors count as devices. One credit is one message to
-- Fizz, typed or spoken. A NULL limit means unlimited.
create table public.fizz_plans (
  id text primary key check (id ~ '^[a-z][a-z0-9_]{0,31}$'),
  name text not null,
  monthly_price_cents integer check (monthly_price_cents is null or monthly_price_cents >= 0),
  device_limit integer check (device_limit is null or device_limit >= 0),
  monthly_credits integer check (monthly_credits is null or monthly_credits > 0),
  sort_order integer not null
);
insert into public.fizz_plans(id, name, monthly_price_cents, device_limit, monthly_credits, sort_order) values
  ('hobbyist', 'Hobbyist', 0, 3, 100, 1),
  ('tinkerer', 'Tinkerer', 1000, 10, 1000, 2),
  ('pro', 'Pro', 2500, 50, 5000, 3),
  ('enterprise', 'Enterprise', null, null, null, 4);

-- Kept apart from fizz_customers so no owner policy on that table can ever change a plan.
-- Customers without a row are on Hobbyist. Billing will write here.
create table public.fizz_subscriptions (
  customer_id uuid primary key references public.fizz_customers(id) on delete cascade,
  plan text not null references public.fizz_plans(id),
  updated_at timestamptz not null default now()
);

-- Credits reset at the start of each UTC calendar month.
create table public.fizz_credit_usage (
  customer_id uuid not null references public.fizz_customers(id) on delete cascade,
  period_start date not null,
  used integer not null default 0 check (used >= 0),
  primary key (customer_id, period_start)
);

alter table public.fizz_plans enable row level security;
alter table public.fizz_subscriptions enable row level security;
alter table public.fizz_credit_usage enable row level security;
revoke all on public.fizz_plans, public.fizz_subscriptions, public.fizz_credit_usage from anon, authenticated;
grant all on public.fizz_plans, public.fizz_subscriptions, public.fizz_credit_usage to service_role;

create function public.fizz_customer_plan(p_customer uuid)
returns public.fizz_plans language sql stable security definer set search_path = '' as $$
  select p.* from public.fizz_plans p
  where p.id = coalesce((select s.plan from public.fizz_subscriptions s where s.customer_id = p_customer), 'hobbyist');
$$;

create function public.fizz_credit_period()
returns date language sql stable set search_path = '' as $$
  select date_trunc('month', now() at time zone 'utc')::date;
$$;

-- Serializes device additions per customer so concurrent requests cannot exceed the limit.
create function public.fizz_device_limit_reached(p_customer uuid)
returns boolean language plpgsql security definer set search_path = '' as $$
declare v_limit integer;
begin
  perform pg_advisory_xact_lock(hashtextextended('fizz_devices:' || p_customer::text, 0));
  v_limit := (public.fizz_customer_plan(p_customer)).device_limit;
  return v_limit is not null and (select count(*) from public.fizz_sensors s
    where s.customer_id = p_customer and s.deleted_at is null and s.mode in ('api', 'phone')) >= v_limit;
end;
$$;

create function public.fizz_plan_usage(p_customer uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', p.id, 'name', p.name, 'monthly_price_cents', p.monthly_price_cents,
    'device_limit', p.device_limit,
    'devices_used', (select count(*) from public.fizz_sensors s
      where s.customer_id = p_customer and s.deleted_at is null and s.mode in ('api', 'phone')),
    'monthly_credits', p.monthly_credits,
    'credits_used', coalesce((select u.used from public.fizz_credit_usage u
      where u.customer_id = p_customer and u.period_start = public.fizz_credit_period()), 0),
    'credits_reset_at', (public.fizz_credit_period() + interval '1 month') at time zone 'utc')
  from public.fizz_customer_plan(p_customer) p;
$$;

create or replace function public.fizz_session_account(p_token text)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('username', c.username, 'auth_user_id', c.auth_user_id,
    'plan', public.fizz_plan_usage(c.id))
  from public.fizz_customers c where c.id = public.fizz_session_customer(p_token);
$$;

-- Chat spends one credit after the rate limits pass. Voice transcription and speech only
-- run while credits remain, since every spoken turn also goes through chat.
create or replace function public.fizz_request_budget(p_token text, p_operation text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_customer uuid; v_minute integer; v_hour integer; v_credits integer; v_used integer;
begin
  v_customer := public.fizz_session_customer(p_token);
  if v_customer is null then return jsonb_build_object('error', 'unauthorized'); end if;
  case p_operation
    when 'chat' then v_minute := 20; v_hour := 200;
    when 'voice' then v_minute := 20; v_hour := 100;
    else return jsonb_build_object('error', 'invalid_operation');
  end case;
  if not public.fizz_rate_limit_hit('paid_' || p_operation || '_minute', v_customer::text, v_minute, interval '1 minute')
    or not public.fizz_rate_limit_hit('paid_' || p_operation || '_hour', v_customer::text, v_hour, interval '1 hour') then
    return jsonb_build_object('error', 'rate_limited');
  end if;
  v_credits := (public.fizz_customer_plan(v_customer)).monthly_credits;
  if p_operation = 'chat' then
    insert into public.fizz_credit_usage as u (customer_id, period_start, used)
    values (v_customer, public.fizz_credit_period(), 1)
    on conflict (customer_id, period_start) do update set used = u.used + 1
      where v_credits is null or u.used < v_credits
    returning u.used into v_used;
    if v_used is null then return jsonb_build_object('error', 'credits_exhausted'); end if;
  elsif v_credits is not null and coalesce((select u.used from public.fizz_credit_usage u
      where u.customer_id = v_customer and u.period_start = public.fizz_credit_period()), 0) >= v_credits then
    return jsonb_build_object('error', 'credits_exhausted');
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

-- The device limit applies wherever a sensor becomes an API or phone sensor.
create or replace function public.fizz_create_sensor(p_token text, p_kind text, p_name text, p_mode text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_customer uuid; v_sensor public.fizz_sensors%rowtype; v_key text;
begin
  v_customer := public.fizz_session_customer(p_token);
  if v_customer is null then return jsonb_build_object('error','unauthorized'); end if;
  if p_kind not in ('water','gas','radio','temperature','pressure','humidity','sound','phone','custom')
    or p_mode not in ('simulated','api','phone') or (p_mode = 'phone' and p_kind <> 'phone')
    or p_name is null or char_length(trim(p_name)) not between 1 and 80 then
    return jsonb_build_object('error','invalid_request');
  end if;
  if p_mode <> 'simulated' and public.fizz_device_limit_reached(v_customer) then
    return jsonb_build_object('error','device_limit');
  end if;
  if p_mode = 'api' then v_key := 'fizz_' || encode(extensions.gen_random_bytes(32), 'hex'); end if;
  insert into public.fizz_sensors(customer_id,kind,name,mode,api_key_hash)
    values(v_customer,p_kind,trim(p_name),p_mode,
      case when v_key is null then null else extensions.digest(v_key, 'sha256') end)
    returning * into v_sensor;
  return jsonb_build_object('sensor',public.fizz_sensor_json(v_sensor),'api_key',v_key);
end;
$$;

create or replace function public.fizz_update_sensor(p_token text, p_id uuid, p_name text default null, p_mode text default null, p_status text default null, p_rotate_key boolean default false)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_customer uuid; v_sensor public.fizz_sensors%rowtype; v_key text;
begin
  v_customer := public.fizz_session_customer(p_token);
  if v_customer is null then return jsonb_build_object('error','unauthorized'); end if;
  select * into v_sensor from public.fizz_sensors where id=p_id and customer_id=v_customer and deleted_at is null for update;
  if not found then return jsonb_build_object('error','not_found'); end if;
  if (p_name is not null and char_length(trim(p_name)) not between 1 and 80)
    or (p_mode is not null and (p_mode not in ('simulated','api','phone') or (p_mode='phone' and v_sensor.kind<>'phone')))
    or (p_status is not null and p_status not in ('active','paused')) then
    return jsonb_build_object('error','invalid_request');
  end if;
  if v_sensor.mode = 'simulated' and coalesce(p_mode, 'simulated') <> 'simulated'
    and public.fizz_device_limit_reached(v_customer) then
    return jsonb_build_object('error','device_limit');
  end if;
  if coalesce(p_mode,v_sensor.mode) = 'api' and (v_sensor.api_key_hash is null or p_rotate_key or v_sensor.mode <> 'api') then
    v_key := 'fizz_' || encode(extensions.gen_random_bytes(32), 'hex');
  end if;
  update public.fizz_sensors set
    name=coalesce(trim(p_name),name), mode=coalesce(p_mode,mode), status=coalesce(p_status,status),
    api_key_hash=case when coalesce(p_mode,mode) <> 'api' then null
      when v_key is not null then extensions.digest(v_key,'sha256') else api_key_hash end,
    last_sample_at=case when p_mode='simulated' and v_sensor.mode <> 'simulated' then null else last_sample_at end
  where id=p_id returning * into v_sensor;
  return jsonb_build_object('sensor',public.fizz_sensor_json(v_sensor),'api_key',v_key);
end;
$$;

create or replace function public.fizz_phone_create_pairing(p_owner_token text, p_sensor_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_customer uuid; v_token bytea; v_mode text;
begin
  select customer_id into v_customer from public.fizz_sessions
  where p_owner_token ~ '^[0-9a-f]{64}$'
    and token_hash = extensions.digest(decode(p_owner_token, 'hex'), 'sha256')
    and expires_at > now();
  if v_customer is null then return jsonb_build_object('error', 'unauthorized'); end if;
  select mode into v_mode from public.fizz_sensors
  where id = p_sensor_id and customer_id = v_customer and kind = 'phone' and deleted_at is null for update;
  if not found then return jsonb_build_object('error', 'sensor_not_found'); end if;
  if v_mode = 'simulated' and public.fizz_device_limit_reached(v_customer) then
    return jsonb_build_object('error', 'device_limit');
  end if;
  update public.fizz_sensors set mode = 'phone', status = 'active', api_key_hash = null, last_sample_at = null
  where id = p_sensor_id;
  delete from public.fizz_phone_pairings where sensor_id = p_sensor_id and claimed_at is null;
  v_token := extensions.gen_random_bytes(32);
  insert into public.fizz_phone_pairings(token_hash, sensor_id, customer_id, expires_at)
  values (extensions.digest(v_token, 'sha256'), p_sensor_id, v_customer, now() + interval '15 minutes');
  return jsonb_build_object('token', encode(v_token, 'hex'), 'expires_in_seconds', 900);
end;
$$;

-- Claiming checks early so the person learns before walking to the device; approval checks
-- again because another device may have used the last slot in between.
create or replace function public.fizz_pair_claim_for(p_customer uuid, p_code text, p_via text,
  p_agent_id uuid, p_agent_name text, p_device_name text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_code text := public.fizz_normalize_pairing_code(p_code); v_pair public.fizz_device_pairings%rowtype;
  v_name text := nullif(left(trim(coalesce(p_device_name, '')), 80), '');
begin
  if not public.fizz_rate_limit_hit('pair_claim', p_customer::text, 20, interval '1 hour') then
    return jsonb_build_object('error','rate_limited');
  end if;
  if v_code is null then return jsonb_build_object('error','invalid_code'); end if;
  select * into v_pair from public.fizz_device_pairings
  where code_hash = extensions.digest(v_code, 'sha256') for update;
  if not found or v_pair.expires_at <= now() or v_pair.status in ('approved', 'rejected') then
    return jsonb_build_object('error','invalid_code');
  end if;
  if v_pair.status = 'claimed' then
    if v_pair.customer_id = p_customer then
      return jsonb_build_object('device_name', v_pair.device_name, 'platform', v_pair.platform,
        'status', 'waiting_for_approval', 'expires_at', v_pair.expires_at);
    end if;
    return jsonb_build_object('error','invalid_code');
  end if;
  if public.fizz_device_limit_reached(p_customer) then
    return jsonb_build_object('error','device_limit');
  end if;
  update public.fizz_device_pairings
  set status = 'claimed', customer_id = p_customer, claimed_via = p_via, agent_id = p_agent_id,
      agent_name = p_agent_name, claimed_at = now(), device_name = coalesce(v_name, device_name)
  where id = v_pair.id returning * into v_pair;
  return jsonb_build_object('device_name', v_pair.device_name, 'platform', v_pair.platform,
    'status', 'waiting_for_approval', 'expires_at', v_pair.expires_at);
end;
$$;

create or replace function public.fizz_pair_decide(p_poll_secret text, p_approve boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_pair public.fizz_device_pairings%rowtype; v_key text; v_sensor public.fizz_sensors%rowtype; v_username text;
begin
  if p_poll_secret !~ '^[0-9a-f]{64}$' then return jsonb_build_object('error','not_found'); end if;
  select * into v_pair from public.fizz_device_pairings
  where poll_hash = extensions.digest(p_poll_secret, 'sha256') for update;
  if not found then return jsonb_build_object('error','not_found'); end if;
  if v_pair.expires_at <= now() and v_pair.status in ('waiting', 'claimed') then
    return jsonb_build_object('error','expired');
  end if;
  if v_pair.status <> 'claimed' then return jsonb_build_object('error','not_claimed'); end if;
  if not coalesce(p_approve, false) then
    update public.fizz_device_pairings set status = 'rejected', finished_at = now() where id = v_pair.id;
    return jsonb_build_object('status','rejected');
  end if;
  if public.fizz_device_limit_reached(v_pair.customer_id) then
    return jsonb_build_object('error','device_limit');
  end if;
  v_key := 'fizz_' || encode(extensions.gen_random_bytes(32), 'hex');
  insert into public.fizz_sensors(customer_id, kind, name, mode, api_key_hash)
  values (v_pair.customer_id, 'custom', v_pair.device_name, 'api', extensions.digest(v_key, 'sha256'))
  returning * into v_sensor;
  update public.fizz_device_pairings set status = 'approved', sensor_id = v_sensor.id, finished_at = now()
  where id = v_pair.id;
  select username into v_username from public.fizz_customers where id = v_pair.customer_id;
  return jsonb_build_object('status','approved', 'sensor_id', v_sensor.id, 'api_key', v_key,
    'account', v_username, 'device_name', v_sensor.name);
end;
$$;

revoke execute on function public.fizz_customer_plan(uuid), public.fizz_credit_period(),
  public.fizz_device_limit_reached(uuid), public.fizz_plan_usage(uuid)
  from public, anon, authenticated;
grant execute on function public.fizz_customer_plan(uuid), public.fizz_credit_period(),
  public.fizz_device_limit_reached(uuid), public.fizz_plan_usage(uuid) to service_role;
