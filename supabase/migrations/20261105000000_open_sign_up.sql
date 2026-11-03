-- Fizzlayer is open to everyone: sign-up no longer needs an invite and the public
-- waitlist is closed. The fizz_waitlist and fizz_invite_codes tables are kept so the
-- people who joined the list can still be emailed, and so redeemed invites keep their
-- history.
--
-- Deploy order: apply this migration first, then deploy the matching code. The new code
-- calls functions this migration adds, so deploying it first breaks sign-in. The code
-- that is live while the migration runs keeps working, because the invite-era functions
-- (4-argument fizz_oauth_sign_in, fizz_check_invite, fizz_join_waitlist,
-- fizz_create_invites, fizz_normalize_invite) are left in place and still require an
-- invite. Drop them in a later migration once the new code is deployed everywhere.
--
-- SELF-HOSTED INSTANCES: once the new code is deployed, anyone who can reach your
-- deployment can create an account. That includes people who already have a Supabase
-- Auth user, for example from a Google sign-in that was turned away for lack of an
-- invite. To keep a private instance closed, run this after applying the migration and
-- before deploying the code:
--   update public.fizz_instance_settings set sign_up_open = false;
-- Existing accounts can still sign in.

create table public.fizz_instance_settings (
  id boolean primary key default true check (id),
  sign_up_open boolean not null default true
);
insert into public.fizz_instance_settings default values;
alter table public.fizz_instance_settings enable row level security;
revoke all on public.fizz_instance_settings from anon, authenticated;
grant all on public.fizz_instance_settings to service_role;

-- ---- Monthly credits ---------------------------------------------------------------------

-- Existing customers keep their current allowance until it would next renew: paid
-- subscribers until the end of the billing period they already paid for, everyone else
-- until the next monthly credit reset. The row only applies while the customer is still
-- on the plan it was recorded for, so a later downgrade does not keep the old allowance.
create table public.fizz_credit_grandfather (
  customer_id uuid primary key references public.fizz_customers(id) on delete cascade,
  plan text not null references public.fizz_plans(id),
  monthly_credits integer not null check (monthly_credits > 0),
  until timestamptz not null
);
alter table public.fizz_credit_grandfather enable row level security;
revoke all on public.fizz_credit_grandfather from anon, authenticated;
grant all on public.fizz_credit_grandfather to service_role;

insert into public.fizz_credit_grandfather(customer_id, plan, monthly_credits, until)
select c.id, p.id, p.monthly_credits,
  greatest(
    (public.fizz_credit_period() + interval '1 month') at time zone 'utc',
    case when public.fizz_billing_active(s.status) then s.current_period_end end)
from public.fizz_customers c
left join public.fizz_subscriptions s on s.customer_id = c.id
join public.fizz_plans p on p.id = coalesce(s.plan, 'hobbyist')
where p.monthly_credits is not null;

update public.fizz_plans set monthly_credits = 10 where id = 'hobbyist';
update public.fizz_plans set monthly_credits = 100 where id = 'tinkerer';
update public.fizz_plans set monthly_credits = 1000 where id = 'pro';

-- The allowance in force for a customer right now. Null means unlimited.
create function public.fizz_monthly_credits(p_customer uuid)
returns integer language sql stable security definer set search_path = '' as $$
  select case when p.monthly_credits is null then null
    else greatest(p.monthly_credits, coalesce((select g.monthly_credits
      from public.fizz_credit_grandfather g
      where g.customer_id = p_customer and g.plan = p.id and g.until > now()), 0)) end
  from public.fizz_customer_plan(p_customer) p;
$$;

create or replace function public.fizz_plan_usage(p_customer uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', p.id, 'name', p.name, 'monthly_price_cents', p.monthly_price_cents,
    'device_limit', p.device_limit,
    'devices_used', (select count(*) from public.fizz_sensors s
      where s.customer_id = p_customer and s.deleted_at is null and s.mode in ('api', 'phone')),
    'monthly_credits', public.fizz_monthly_credits(p_customer),
    'credits_used', coalesce((select u.used from public.fizz_credit_usage u
      where u.customer_id = p_customer and u.period_start = public.fizz_credit_period()), 0),
    'credits_reset_at', (public.fizz_credit_period() + interval '1 month') at time zone 'utc',
    'subscription', (select jsonb_build_object('status', s.status, 'current_period_end', s.current_period_end,
        'cancel_at_period_end', s.cancel_at_period_end, 'has_billing_account', s.stripe_customer_id is not null)
      from public.fizz_subscriptions s where s.customer_id = p_customer))
  from public.fizz_customer_plan(p_customer) p;
$$;

-- Same as before, reading the allowance through fizz_monthly_credits.
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
  v_credits := public.fizz_monthly_credits(v_customer);
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

-- Give back the chat credit spent on a request that failed before Fizz could answer.
create function public.fizz_refund_credit(p_token text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_customer uuid;
begin
  v_customer := public.fizz_session_customer(p_token);
  if v_customer is null then return jsonb_build_object('error', 'unauthorized'); end if;
  update public.fizz_credit_usage set used = used - 1
  where customer_id = v_customer and period_start = public.fizz_credit_period() and used > 0;
  return jsonb_build_object('ok', true);
end;
$$;

-- ---- Sign-up -----------------------------------------------------------------------------

-- Count one sign-up step for a caller. p_ip is an IPv4 address or an IPv6 /64 (the API
-- groups IPv6 by /64). Each network gets 10 an hour. IPv6 callers also share 50 an hour
-- per /48, since one site is often given a /48 and could otherwise rotate through its
-- 65,536 /64s. The global limit is a circuit breaker for a distributed flood, set high
-- enough that no single network can reach it.
--
-- The two steps use separate buckets: 'sign_up_email' when Supabase is asked to send a
-- confirmation email, and 'sign_up_account' when a customer is created, for every
-- provider. An email sign-up passes both, once each.
create function public.fizz_sign_up_hit(p_step text, p_ip text)
returns boolean language plpgsql security definer set search_path = '' as $$
declare v_site text;
begin
  begin
    if family(p_ip::inet) = 6 then
      v_site := network(set_masklen(p_ip::inet, 48))::text;
    end if;
  exception when others then
    v_site := null;
  end;
  if not public.fizz_rate_limit_hit(p_step || '_ip', p_ip, 10, interval '1 hour') then
    return false;
  end if;
  if v_site is not null
    and not public.fizz_rate_limit_hit(p_step || '_site', v_site, 50, interval '1 hour') then
    return false;
  end if;
  return public.fizz_rate_limit_hit(p_step || '_all', 'all', 5000, interval '1 hour');
end;
$$;

-- Before Supabase sends a confirmation email.
create function public.fizz_sign_up_allowed(p_ip text)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if not (select s.sign_up_open from public.fizz_instance_settings s) then
    return jsonb_build_object('error', 'sign_up_closed');
  end if;
  if not public.fizz_sign_up_hit('sign_up_email', p_ip) then
    return jsonb_build_object('error', 'rate_limited');
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

-- Link a verified Supabase user to its customer, creating the customer on first use.
create function public.fizz_oauth_sign_in(p_user_id uuid, p_email text, p_ip text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_customer public.fizz_customers%rowtype;
  v_base text;
  v_username text;
  v_token bytea;
begin
  perform 1 from auth.users u where u.id = p_user_id
    and not coalesce(u.is_anonymous, false) and u.deleted_at is null
    and (u.banned_until is null or u.banned_until <= now());
  if not found then
    return jsonb_build_object('error', 'unavailable');
  end if;
  select * into v_customer from public.fizz_customers where auth_user_id = p_user_id;
  if not found then
    -- Counts every provider, including email users created outside this app.
    if not (select s.sign_up_open from public.fizz_instance_settings s) then
      return jsonb_build_object('error', 'sign_up_closed');
    end if;
    if not public.fizz_sign_up_hit('sign_up_account', p_ip) then
      return jsonb_build_object('error', 'rate_limited');
    end if;
    v_base := regexp_replace(lower(split_part(coalesce(p_email, ''), '@', 1)), '[^a-z0-9_]', '', 'g');
    if v_base !~ '^[a-z]' then v_base := 'fizz_' || v_base; end if;
    v_base := left(v_base, 18);
    if length(v_base) < 3 then v_base := 'fizz_user'; end if;
    for i in 0..9 loop
      v_username := case when i = 0 then v_base
        else v_base || '_' || lpad(floor(random() * 10000)::int::text, 4, '0') end;
      begin
        insert into public.fizz_customers(username, auth_user_id)
        values (v_username, p_user_id)
        returning * into v_customer;
        exit;
      exception when unique_violation then
        null;
      end;
    end loop;
    if v_customer.id is null then
      return jsonb_build_object('error', 'unavailable');
    end if;
  end if;
  v_token := extensions.gen_random_bytes(32);
  insert into public.fizz_sessions(token_hash, customer_id, expires_at)
  values (extensions.digest(v_token, 'sha256'), v_customer.id, now() + interval '12 hours');
  return jsonb_build_object('username', v_customer.username, 'token', encode(v_token, 'hex'));
end;
$$;

revoke execute on function public.fizz_oauth_sign_in(uuid, text, text),
  public.fizz_sign_up_hit(text, text),
  public.fizz_sign_up_allowed(text),
  public.fizz_refund_credit(text),
  public.fizz_monthly_credits(uuid)
  from public, anon, authenticated;
grant execute on function public.fizz_oauth_sign_in(uuid, text, text),
  public.fizz_sign_up_hit(text, text),
  public.fizz_sign_up_allowed(text),
  public.fizz_refund_credit(text),
  public.fizz_monthly_credits(uuid)
  to service_role;
