-- Stripe billing. Stripe is the source of truth: webhooks fetch the current subscription and
-- store its state here, so retries and out-of-order events converge on the same row.
alter table public.fizz_subscriptions
  add column stripe_customer_id text unique check (stripe_customer_id ~ '^cus_[A-Za-z0-9]+$'),
  add column stripe_subscription_id text unique check (stripe_subscription_id ~ '^sub_[A-Za-z0-9]+$'),
  add column status text,
  add column current_period_end timestamptz,
  add column cancel_at_period_end boolean not null default false;

-- Statuses that keep a paid plan. past_due keeps access while Stripe retries the payment.
create function public.fizz_billing_active(p_status text)
returns boolean language sql immutable set search_path = '' as $$
  select coalesce(p_status in ('active', 'trialing', 'past_due'), false);
$$;

create or replace function public.fizz_plan_usage(p_customer uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', p.id, 'name', p.name, 'monthly_price_cents', p.monthly_price_cents,
    'device_limit', p.device_limit,
    'devices_used', (select count(*) from public.fizz_sensors s
      where s.customer_id = p_customer and s.deleted_at is null and s.mode in ('api', 'phone')),
    'monthly_credits', p.monthly_credits,
    'credits_used', coalesce((select u.used from public.fizz_credit_usage u
      where u.customer_id = p_customer and u.period_start = public.fizz_credit_period()), 0),
    'credits_reset_at', (public.fizz_credit_period() + interval '1 month') at time zone 'utc',
    'subscription', (select jsonb_build_object('status', s.status, 'current_period_end', s.current_period_end,
        'cancel_at_period_end', s.cancel_at_period_end, 'has_billing_account', s.stripe_customer_id is not null)
      from public.fizz_subscriptions s where s.customer_id = p_customer))
  from public.fizz_customer_plan(p_customer) p;
$$;

-- What checkout and the billing portal need about the signed-in customer.
create function public.fizz_billing_account(p_token text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_customer uuid; v_sub public.fizz_subscriptions%rowtype; v_email text;
begin
  v_customer := public.fizz_session_customer(p_token);
  if v_customer is null then return jsonb_build_object('error', 'unauthorized'); end if;
  if not public.fizz_rate_limit_hit('billing', v_customer::text, 20, interval '1 hour') then
    return jsonb_build_object('error', 'rate_limited');
  end if;
  select * into v_sub from public.fizz_subscriptions where customer_id = v_customer;
  select u.email into v_email from public.fizz_customers c join auth.users u on u.id = c.auth_user_id
  where c.id = v_customer;
  return jsonb_build_object('customer_id', v_customer, 'email', v_email,
    'plan', coalesce(v_sub.plan, 'hobbyist'), 'stripe_customer_id', v_sub.stripe_customer_id,
    'subscribed', public.fizz_billing_active(v_sub.status) and v_sub.stripe_subscription_id is not null);
end;
$$;

-- Remembers the Stripe customer created for checkout. Keeps the first one if two requests race.
create function public.fizz_billing_link_customer(p_customer uuid, p_stripe_customer text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_linked text;
begin
  insert into public.fizz_subscriptions as s (customer_id, plan, stripe_customer_id)
  values (p_customer, 'hobbyist', p_stripe_customer)
  on conflict (customer_id) do update set stripe_customer_id = coalesce(s.stripe_customer_id, excluded.stripe_customer_id)
  returning stripe_customer_id into v_linked;
  return jsonb_build_object('stripe_customer_id', v_linked);
end;
$$;

-- Applies a subscription's current state from Stripe. p_customer comes from a completed
-- checkout's client_reference_id and links the Stripe customer when it is not linked yet.
-- p_plan is the plan matching the subscription's price, or NULL for an unrecognized price.
-- p_current_period_end is in Unix seconds, as Stripe sends it.
create function public.fizz_billing_sync(p_stripe_customer text, p_customer uuid, p_subscription_id text,
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
  return jsonb_build_object('plan', v_sub.plan, 'status', v_sub.status);
end;
$$;

revoke execute on function public.fizz_billing_active(text), public.fizz_billing_account(text),
  public.fizz_billing_link_customer(uuid, text),
  public.fizz_billing_sync(text, uuid, text, text, text, bigint, boolean)
  from public, anon, authenticated;
grant execute on function public.fizz_billing_active(text), public.fizz_billing_account(text),
  public.fizz_billing_link_customer(uuid, text),
  public.fizz_billing_sync(text, uuid, text, text, text, bigint, boolean) to service_role;
