-- Stripe subscription sync. Uses synthetic users only; everything rolls back.
begin;
create temporary table billing_results(label text);
create function pg_temp.billing_assert(ok boolean, label text) returns void
language plpgsql as $$ begin
  if ok is distinct from true then raise exception 'Billing assertion failed: %', label; end if;
  insert into pg_temp.billing_results values(label);
end $$;

create temporary table billing_ids as
select n, gen_random_uuid() auth_id, gen_random_uuid() customer_id,
  md5(gen_random_uuid()::text) || md5(gen_random_uuid()::text) token
from generate_series(1, 3) n;
insert into auth.users(id, email, encrypted_password, is_anonymous)
select auth_id, 'billing-' || n || '@example.invalid', 'hash', false from billing_ids;
insert into public.fizz_customers(id, auth_user_id, username)
select customer_id, auth_id, 'billing_' || left(replace(customer_id::text, '-', ''), 16) from billing_ids;
insert into public.fizz_sessions(token_hash, customer_id, expires_at)
select extensions.digest(decode(token, 'hex'), 'sha256'), customer_id, now() + interval '1 hour' from billing_ids;

grant execute on function pg_temp.billing_assert(boolean,text) to service_role;
grant select on billing_ids to service_role;
grant insert on billing_results to service_role;
set local role service_role;
do $$ declare a record; b record; c record; result jsonb; i integer; begin
  select * into a from pg_temp.billing_ids where n=1;
  select * into b from pg_temp.billing_ids where n=2;
  select * into c from pg_temp.billing_ids where n=3;

  perform pg_temp.billing_assert(public.fizz_billing_account('junk')->>'error' = 'unauthorized', 'billing requires a session');
  result := public.fizz_billing_account(a.token);
  perform pg_temp.billing_assert(result->>'customer_id' = a.customer_id::text and result->>'email' = 'billing-1@example.invalid'
    and result->>'plan' = 'hobbyist' and result->>'subscribed' = 'false' and result->'stripe_customer_id' = 'null', 'new account has no billing');

  -- The first linked Stripe customer wins a race.
  perform pg_temp.billing_assert(public.fizz_billing_link_customer(a.customer_id, 'cus_A1')->>'stripe_customer_id' = 'cus_A1', 'link Stripe customer');
  perform pg_temp.billing_assert(public.fizz_billing_link_customer(a.customer_id, 'cus_A2')->>'stripe_customer_id' = 'cus_A1', 'first linked customer kept');
  perform pg_temp.billing_assert(public.fizz_billing_account(a.token)->>'stripe_customer_id' = 'cus_A1', 'account reports linked customer');

  perform pg_temp.billing_assert(public.fizz_billing_sync('cus_Unknown', null, 'sub_X', 'active', 'pro', 1, false)->>'error' = 'unknown_customer', 'unknown Stripe customer ignored');
  perform pg_temp.billing_assert(public.fizz_billing_sync('cus_A1', null, 'sub_A1', 'active', 'enterprise', 1, false)->>'error' = 'invalid_plan', 'webhooks cannot grant Enterprise');

  -- Subscribing, upgrading, payment trouble, and cancellation.
  result := public.fizz_billing_sync('cus_A1', null, 'sub_A1', 'active', 'tinkerer', 1893456000, false);
  perform pg_temp.billing_assert(result->>'plan' = 'tinkerer', 'active subscription sets plan');
  result := public.fizz_session_account(a.token)->'plan';
  perform pg_temp.billing_assert(result->>'id' = 'tinkerer' and (result->>'device_limit')::int = 10
    and result->'subscription'->>'status' = 'active' and (result->'subscription'->>'current_period_end')::timestamptz = to_timestamp(1893456000),
    'usage reports subscription');
  perform pg_temp.billing_assert(public.fizz_billing_account(a.token)->>'subscribed' = 'true', 'account reports subscription');
  perform pg_temp.billing_assert(public.fizz_billing_sync('cus_A1', null, 'sub_A1', 'active', 'pro', 1893456000, false)->>'plan' = 'pro', 'upgrade');
  perform pg_temp.billing_assert(public.fizz_billing_sync('cus_A1', null, 'sub_A1', 'past_due', 'pro', 1893456000, false)->>'plan' = 'pro', 'past due keeps access during retries');
  perform pg_temp.billing_assert(public.fizz_billing_sync('cus_A1', null, 'sub_Other', 'canceled', 'tinkerer', 1, false) ? 'ignored', 'another ended subscription is ignored');
  perform public.fizz_billing_sync('cus_A1', null, 'sub_A1', 'active', 'pro', 1893456000, true);
  perform pg_temp.billing_assert((public.fizz_session_account(a.token)->'plan'->'subscription'->>'cancel_at_period_end')::boolean,
    'scheduled cancellation is reported');
  perform pg_temp.billing_assert(public.fizz_billing_sync('cus_A1', null, 'sub_A1', 'unpaid', 'pro', 1893456000, false)->>'plan' = 'hobbyist', 'unpaid returns to Hobbyist');
  perform pg_temp.billing_assert(public.fizz_billing_sync('cus_A1', null, 'sub_A1', 'active', null, 1893456000, false)->>'plan' = 'hobbyist', 'unrecognized price grants nothing');
  perform pg_temp.billing_assert(public.fizz_billing_sync('cus_A1', null, 'sub_A1', 'canceled', 'pro', 1893456000, false)->>'plan' = 'hobbyist', 'cancellation returns to Hobbyist');
  perform pg_temp.billing_assert(public.fizz_billing_account(a.token)->>'subscribed' = 'false', 'canceled account can subscribe again');
  perform pg_temp.billing_assert(public.fizz_billing_sync('cus_A1', null, 'sub_A2', 'active', 'tinkerer', 1893456000, false)->>'plan' = 'tinkerer', 'resubscribe');

  -- A completed checkout links a customer that was not linked yet, but never steals one.
  perform pg_temp.billing_assert(public.fizz_billing_sync('cus_B1', b.customer_id, 'sub_B1', 'active', 'pro', 1, false)->>'plan' = 'pro', 'checkout links customer');
  perform pg_temp.billing_assert(public.fizz_billing_sync('cus_B2', b.customer_id, 'sub_B2', 'active', 'pro', 1, false)->>'error' = 'unknown_customer', 'checkout cannot replace a linked customer');
  perform pg_temp.billing_assert((public.fizz_customer_plan(c.customer_id)).id = 'hobbyist', 'other customers unaffected');

  -- Enterprise is managed by hand.
  insert into public.fizz_subscriptions(customer_id, plan, stripe_customer_id) values (c.customer_id, 'enterprise', 'cus_C1');
  perform pg_temp.billing_assert(public.fizz_billing_sync('cus_C1', null, 'sub_C1', 'canceled', null, 1, false) ? 'ignored'
    and (public.fizz_customer_plan(c.customer_id)).id = 'enterprise', 'webhooks leave Enterprise alone');

  for i in 1..18 loop perform public.fizz_billing_account(a.token); end loop;
  perform pg_temp.billing_assert(public.fizz_billing_account(a.token)->>'error' = 'rate_limited', 'billing requests are rate limited');
end $$;
reset role;

select pg_temp.billing_assert(not has_function_privilege(r, f, 'EXECUTE'), format('%s cannot run %s', r, f))
from unnest(array['anon', 'authenticated']) r,
  unnest(array['public.fizz_billing_account(text)', 'public.fizz_billing_link_customer(uuid,text)',
    'public.fizz_billing_sync(text,uuid,text,text,text,bigint,boolean)']) f;
select count(*) as billing_assertions_passed from billing_results;
rollback;
