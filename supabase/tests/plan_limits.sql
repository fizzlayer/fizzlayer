-- Plan device limits and monthly Fizz credits. Uses synthetic users only; everything rolls back.
begin;
create temporary table plan_results(label text);
create function pg_temp.plan_assert(ok boolean, label text) returns void
language plpgsql as $$ begin
  if ok is distinct from true then raise exception 'Plan assertion failed: %', label; end if;
  insert into pg_temp.plan_results values(label);
end $$;

create temporary table plan_ids as
select n, gen_random_uuid() auth_id, gen_random_uuid() customer_id,
  md5(gen_random_uuid()::text) || md5(gen_random_uuid()::text) token
from generate_series(1, 2) n;
insert into auth.users(id, email, encrypted_password, is_anonymous)
select auth_id, 'plan-' || auth_id || '@example.invalid', 'hash', false from plan_ids;
insert into public.fizz_customers(id, auth_user_id, username)
select customer_id, auth_id, 'plan_' || left(replace(customer_id::text, '-', ''), 16) from plan_ids;
insert into public.fizz_sessions(token_hash, customer_id, expires_at)
select extensions.digest(decode(token, 'hex'), 'sha256'), customer_id, now() + interval '1 hour' from plan_ids;

-- Exercise the service-role RPCs through their real permission boundary.
grant execute on function pg_temp.plan_assert(boolean,text) to service_role;
grant select on plan_ids to service_role;
grant insert on plan_results to service_role;
set local role service_role;
do $$ declare a record; b record; result jsonb; sample uuid; phone uuid; api uuid; pairing jsonb; i integer; begin
  select * into a from pg_temp.plan_ids where n=1;
  select * into b from pg_temp.plan_ids where n=2;

  result := public.fizz_session_account(a.token)->'plan';
  perform pg_temp.plan_assert(result->>'id' = 'hobbyist' and (result->>'device_limit')::int = 3
    and (result->>'monthly_credits')::int = 10 and (result->>'devices_used')::int = 0, 'new accounts start on Hobbyist');

  -- Hobbyist: three devices, sample sensors are free.
  for i in 1..3 loop
    result := public.fizz_create_sensor(a.token, 'temperature', 'Device ' || i, 'api');
    perform pg_temp.plan_assert(result ? 'sensor' and result->>'api_key' like 'fizz_%', 'device within limit ' || i);
  end loop;
  api := (result->'sensor'->>'id')::uuid;
  perform pg_temp.plan_assert(public.fizz_create_sensor(a.token, 'water', 'Fourth', 'api')->>'error' = 'device_limit', 'API sensor over limit');
  perform pg_temp.plan_assert(public.fizz_create_sensor(a.token, 'phone', 'Phone', 'phone')->>'error' = 'device_limit', 'phone sensor over limit');
  result := public.fizz_create_sensor(a.token, 'water', 'Sample', 'simulated');
  perform pg_temp.plan_assert(result ? 'sensor', 'sample sensors ignore the limit');
  sample := (result->'sensor'->>'id')::uuid;
  phone := (public.fizz_create_sensor(a.token, 'phone', 'Sample phone', 'simulated')->'sensor'->>'id')::uuid;
  perform pg_temp.plan_assert(public.fizz_update_sensor(a.token, sample, null, 'api')->>'error' = 'device_limit', 'sample to API over limit');
  perform pg_temp.plan_assert(public.fizz_phone_create_pairing(a.token, phone)->>'error' = 'device_limit', 'phone link over limit');
  perform pg_temp.plan_assert(public.fizz_update_sensor(a.token, api, 'Renamed')->'sensor'->>'name' = 'Renamed', 'existing devices stay editable at the limit');
  perform pg_temp.plan_assert(public.fizz_update_sensor(a.token, api, null, null, null, true)->>'api_key' like 'fizz_%', 'key rotation works at the limit');

  -- Paired devices are checked at claim and at approval.
  pairing := public.fizz_pair_start('Garage Pi', 'linux', 'plan-test-1');
  perform pg_temp.plan_assert(public.fizz_pair_claim(a.token, pairing->>'code', null)->>'error' = 'device_limit', 'pairing claim over limit');
  perform pg_temp.plan_assert(public.fizz_pair_claim(b.token, pairing->>'code', null)->>'status' = 'waiting_for_approval', 'device limits are per customer');

  -- Switching back to a sample stream frees a slot.
  perform pg_temp.plan_assert(public.fizz_update_sensor(a.token, api, null, 'simulated')->'sensor'->>'mode' = 'simulated', 'device returns to sample stream');
  pairing := public.fizz_pair_start('Shed Pi', 'linux', 'plan-test-2');
  perform pg_temp.plan_assert(public.fizz_pair_claim(a.token, pairing->>'code', null)->>'status' = 'waiting_for_approval', 'claim after freeing a slot');
  perform pg_temp.plan_assert(public.fizz_phone_create_pairing(a.token, phone) ? 'token', 'phone link uses the free slot');
  perform pg_temp.plan_assert(public.fizz_pair_decide(pairing->>'poll_secret', true)->>'error' = 'device_limit', 'approval rechecks the limit');
  perform pg_temp.plan_assert(public.fizz_phone_create_pairing(a.token, phone) ? 'token', 'existing phone sensors can create new links');

  -- Deleting a device frees a slot; upgrading raises the limit.
  perform pg_temp.plan_assert(public.fizz_delete_sensor(a.token, phone)->>'ok' = 'true', 'delete phone sensor');
  perform pg_temp.plan_assert(public.fizz_pair_decide(pairing->>'poll_secret', true)->>'status' = 'approved', 'approval after deleting a device');
  insert into public.fizz_subscriptions(customer_id, plan) values (a.customer_id, 'tinkerer');
  perform pg_temp.plan_assert(public.fizz_update_sensor(a.token, sample, null, 'api')->>'api_key' like 'fizz_%', 'upgrade raises the limit');
  perform pg_temp.plan_assert((public.fizz_session_account(a.token)->'plan'->>'devices_used')::int = 4, 'usage counts API and phone sensors');

  -- Credits: chat spends one per message until the monthly allowance is used.
  perform pg_temp.plan_assert(public.fizz_request_budget(b.token, 'chat')->>'ok' = 'true', 'chat spends a credit');
  perform pg_temp.plan_assert((public.fizz_session_account(b.token)->'plan'->>'credits_used')::int = 1, 'credit usage is reported');
  update public.fizz_credit_usage set used = 9 where customer_id = b.customer_id;
  perform pg_temp.plan_assert(public.fizz_request_budget(b.token, 'voice')->>'ok' = 'true', 'voice allowed while credits remain');
  perform pg_temp.plan_assert(public.fizz_request_budget(b.token, 'chat')->>'ok' = 'true', 'last credit');
  perform pg_temp.plan_assert(public.fizz_request_budget(b.token, 'chat')->>'error' = 'credits_exhausted', 'chat over monthly credits');
  perform pg_temp.plan_assert(public.fizz_request_budget(b.token, 'voice')->>'error' = 'credits_exhausted', 'voice stops when credits run out');
  perform pg_temp.plan_assert((public.fizz_session_account(b.token)->'plan'->>'credits_used')::int = 10, 'refused chat spends nothing');
  perform pg_temp.plan_assert(public.fizz_request_budget(a.token, 'chat')->>'ok' = 'true', 'credits are per customer');
  perform pg_temp.plan_assert((select string_agg(id || '=' || monthly_credits, ',' order by sort_order) from public.fizz_plans where monthly_credits is not null)
    = 'hobbyist=10,tinkerer=100,pro=1000', 'plan credit allowances');
  update public.fizz_credit_usage set period_start = period_start - interval '1 month' where customer_id = b.customer_id;
  perform pg_temp.plan_assert(public.fizz_request_budget(b.token, 'chat')->>'ok' = 'true', 'credits reset each month');
  insert into public.fizz_subscriptions(customer_id, plan) values (b.customer_id, 'enterprise');
  update public.fizz_credit_usage set used = 1000000 where customer_id = b.customer_id;
  perform pg_temp.plan_assert(public.fizz_request_budget(b.token, 'chat')->>'ok' = 'true', 'Enterprise credits are unlimited');
end $$;
reset role;

select pg_temp.plan_assert(not has_table_privilege(r, t, p), format('%s cannot %s %s', r, p, t))
from unnest(array['anon', 'authenticated']) r,
  unnest(array['public.fizz_plans', 'public.fizz_subscriptions', 'public.fizz_credit_usage']) t,
  unnest(array['SELECT', 'INSERT', 'UPDATE']) p;
select count(*) as plan_assertions_passed from plan_results;
rollback;
