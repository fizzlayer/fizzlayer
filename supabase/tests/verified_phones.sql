-- Phone pairing and paid-only calls. All fixtures roll back.
-- Run with: supabase db query --linked --file supabase/tests/verified_phones.sql
begin;
create temporary table phone_results(label text);
create function pg_temp.phone_assert(ok boolean, label text) returns void
language plpgsql as $$ begin
  if ok is distinct from true then raise exception 'Phone assertion failed: %', label; end if;
  insert into pg_temp.phone_results values (label);
end $$;

create temporary table phone_ids as
select n,
  gen_random_uuid() auth_id,
  gen_random_uuid() customer_id,
  gen_random_uuid() sensor_id,
  md5(gen_random_uuid()::text) || md5(gen_random_uuid()::text) session_token,
  'fizz_agent_' || md5(gen_random_uuid()::text) || md5(gen_random_uuid()::text) agent_token
from generate_series(1, 2) n;

insert into auth.users(id, email, encrypted_password, is_anonymous)
select auth_id, 'phones-' || n || '@example.invalid', 'not-a-password', false from phone_ids;
insert into public.fizz_customers(id, auth_user_id, username)
select customer_id, auth_id, 'phones_' || left(replace(customer_id::text, '-', ''), 12) from phone_ids;
insert into public.fizz_sessions(token_hash, customer_id, expires_at)
select extensions.digest(decode(session_token, 'hex'), 'sha256'), customer_id, now() + interval '1 hour' from phone_ids;
insert into public.fizz_sensors(id, customer_id, kind, name, mode, status)
select sensor_id, customer_id, 'temperature', 'Closet ' || n, 'api', 'active' from phone_ids;
insert into public.fizz_sensor_readings(sensor_id, event_id, observed_at, metric, numeric_value, unit, source)
select sensor_id, 'base', now(), 'temperature_c', 21, 'C', 'api' from phone_ids;
insert into public.fizz_agent_connections(customer_id, name, token_hash, can_create_alerts)
select customer_id, 'Phone test agent', extensions.digest(agent_token, 'sha256'), true from phone_ids where n = 1;
insert into public.fizz_subscriptions(customer_id, plan)
select customer_id, 'tinkerer' from phone_ids where n = 1;

do $$
declare
  paid record; free record;
  started jsonb; listed jsonb; created jsonb;
  v_code text; v_id uuid; v_event uuid; v_rule uuid;
  v_codes text[] := '{}';
  i integer;
  v_customer uuid;
  v_token text;
  v_phone text;
begin
  select * into paid from pg_temp.phone_ids where n = 1;
  select * into free from pg_temp.phone_ids where n = 2;

  perform pg_temp.phone_assert(not public.fizz_calls_allowed(free.customer_id), 'hobbyist cannot place calls');
  perform pg_temp.phone_assert(public.fizz_calls_allowed(paid.customer_id), 'tinkerer can place calls');
  perform pg_temp.phone_assert(
    (public.fizz_plan_usage(paid.customer_id)->>'calls_included')::boolean
    and not (public.fizz_plan_usage(free.customer_id)->>'calls_included')::boolean,
    'plan usage reports whether calls are included');

  perform pg_temp.phone_assert(public.fizz_call_phone_start(paid.agent_token, '4155550100', '203.0.113.10')->>'error' = 'unauthorized', 'an agent token cannot start pairing');
  perform pg_temp.phone_assert(public.fizz_call_phone_confirm(paid.agent_token, '4155550100', '123456')->>'error' = 'unauthorized', 'an agent token cannot confirm pairing');
  perform pg_temp.phone_assert((select count(*) from public.fizz_call_verifications) = 0, 'a rejected agent token stores nothing');

  perform pg_temp.phone_assert(public.fizz_call_phone_start(free.session_token, '(415) 555-0100', '203.0.113.11')->>'error' = 'calls_not_included', 'hobbyist cannot start a pairing call');
  perform pg_temp.phone_assert(public.fizz_create_alert(free.session_token, free.sensor_id, 'temperature_c', 'gt', 30, 'C', 'call', '+14155550100')->>'error' = 'calls_not_included', 'hobbyist cannot create a call alert');
  perform pg_temp.phone_assert(public.fizz_create_alert(free.session_token, free.sensor_id, 'temperature_c', 'gt', 30, 'C') ? 'rule', 'hobbyist can create a dashboard alert');
  perform pg_temp.phone_assert(public.fizz_agent_call(paid.agent_token, '127.0.0.1', 'create_alert', jsonb_build_object('sensor_id', paid.sensor_id, 'metric', 'temperature_c', 'comparator', 'gt', 'threshold', 30, 'call_phone', '4155550100'))->>'error' = 'invalid_arguments', 'MCP cannot call an unpaired number');

  started := public.fizz_call_phone_start(paid.session_token, 'not a phone', '203.0.113.10');
  perform pg_temp.phone_assert(started->>'error' = 'invalid_phone', 'rejects a number that is not a US phone');

  started := public.fizz_call_phone_start(paid.session_token, '(415) 555-0100', '203.0.113.10');
  v_code := started->>'code';
  v_id := (started->>'verification_id')::uuid;
  perform pg_temp.phone_assert(v_code ~ '^[0-9]{6}$' and started->>'phone' = '+14155550100' and (started->>'expires_in_seconds')::int = 600, 'start returns a 6-digit code to the service role');
  perform pg_temp.phone_assert(
    (select code_hash = extensions.digest(v_code, 'sha256') and octet_length(code_hash) = 32 and expires_at > now() + interval '9 minutes'
      from public.fizz_call_verifications where id = v_id),
    'the code is stored only as a hash and expires in about 10 minutes');
  perform pg_temp.phone_assert(
    not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'fizz_call_verifications' and column_name = 'code'),
    'there is no plaintext code column');
  perform pg_temp.phone_assert(public.fizz_call_phone_start(paid.session_token, '+1 415 555 0100', '203.0.113.10')->>'error' = 'cooldown', 'the same number cannot be called again immediately');
  perform pg_temp.phone_assert((select count(*) from public.fizz_call_verifications where customer_id = paid.customer_id and phone = '+14155550100' and cancelled_at is null) = 1, 'a cooldown does not replace the live code');

  perform pg_temp.phone_assert(public.fizz_call_phone_confirm(paid.session_token, '+14155550100', '12')->>'error' = 'invalid_code', 'a short code is rejected');
  perform pg_temp.phone_assert((select attempts from public.fizz_call_verifications where id = v_id) = 0, 'a malformed code does not use an attempt');
  perform pg_temp.phone_assert(public.fizz_call_phone_confirm(free.session_token, '+14155550100', v_code)->>'error' = 'invalid_code', 'another account cannot confirm the code');
  perform pg_temp.phone_assert(public.fizz_call_phone_confirm(paid.session_token, '(415) 555-0100', '000000')->>'error' = 'invalid_code', 'a wrong code is rejected');
  perform pg_temp.phone_assert((select attempts from public.fizz_call_verifications where id = v_id) = 1, 'a wrong code uses one attempt');
  perform pg_temp.phone_assert(public.fizz_call_phone_confirm(paid.session_token, '4155550100', v_code)->>'ok' = 'true', 'the right code pairs the number');
  perform pg_temp.phone_assert((select consumed_at is not null from public.fizz_call_verifications where id = v_id), 'the code is single use');
  perform pg_temp.phone_assert(public.fizz_call_phone_confirm(paid.session_token, '+14155550100', v_code)->>'already_paired' = 'true', 'confirming again does not create a second row');
  perform pg_temp.phone_assert((select count(*) from public.fizz_verified_phones where customer_id = paid.customer_id and phone = '+14155550100') = 1, 'the number belongs to the workspace');

  listed := public.fizz_call_phone_list(paid.session_token);
  perform pg_temp.phone_assert(listed->'phones'->0->>'phone' = '+14155550100' and not (coalesce(listed->'pending', '{}'::jsonb) ? 'code') and position(v_code in listed::text) = 0, 'the list shows the number and not the code');
  perform pg_temp.phone_assert(public.fizz_call_phone_list(free.session_token)->'phones' = '[]'::jsonb, 'another account does not see the number');
  started := public.fizz_call_phone_start(paid.session_token, '4155550100', '203.0.113.10');
  perform pg_temp.phone_assert(started->>'already_paired' = 'true' and not (started ? 'code'), 'an already paired number is not called');

  created := public.fizz_create_alert(paid.session_token, paid.sensor_id, 'temperature_c', 'gt', 30, 'C', 'call', '+14155550100');
  perform pg_temp.phone_assert(created->>'created' = 'true' and created->'rule'->>'notify_phone' = '+14155550100', 'a paired number can be used on an alert');
  perform pg_temp.phone_assert(public.fizz_create_alert(paid.session_token, paid.sensor_id, 'temperature_c', 'gt', 40, 'C', 'call', '+14155550198')->>'error' = 'phone_not_paired', 'an unpaired number is rejected');
  created := public.fizz_agent_call(paid.agent_token, '127.0.0.1', 'create_alert', jsonb_build_object('sensor_id', paid.sensor_id, 'metric', 'temperature_c', 'comparator', 'gt', 'threshold', 30, 'call_phone', '(415) 555-0100'));
  perform pg_temp.phone_assert(created->'result'->>'created' = 'false', 'MCP can use a paired number and returns the existing alert');

  insert into public.fizz_alert_events(rule_id, reading_id, customer_id, sensor_id, metric, numeric_value, threshold, comparator, unit, observed_at, notify_channel, notify_phone, notify_status)
  select r.id, rd.id, paid.customer_id, paid.sensor_id, 'temperature_c', 31, 30, 'gt', 'C', now(), 'call', '+14155550100', 'pending'
  from public.fizz_alert_rules r
  join public.fizz_sensor_readings rd on rd.sensor_id = paid.sensor_id and rd.event_id = 'base'
  where r.customer_id = paid.customer_id and r.notify_phone = '+14155550100'
  returning id into v_event;
  perform pg_temp.phone_assert(public.fizz_call_phone_remove(paid.session_token, '(415) 555-0100')->>'ok' = 'true', 'the owner can remove a paired number');
  perform pg_temp.phone_assert((select notify_status from public.fizz_alert_events where id = v_event) = 'skipped' and (select notify_error from public.fizz_alert_events where id = v_event) = 'Phone number was removed.', 'removing a number skips its queued call');
  perform pg_temp.phone_assert(public.fizz_create_alert(paid.session_token, paid.sensor_id, 'temperature_c', 'lt', 10, 'C', 'call', '+14155550100')->>'error' = 'phone_not_paired', 'a removed number cannot be used');

  -- A fresh number, then expire it. Move created_at so the cooldown does not block the assertion setup.
  started := public.fizz_call_phone_start(paid.session_token, '4155550191', '203.0.113.10');
  perform pg_temp.phone_assert(started->>'code' ~ '^[0-9]{6}$', 'a second number can be called');
  update public.fizz_call_verifications set expires_at = now() - interval '1 second', created_at = now() - interval '2 minutes'
  where id = (started->>'verification_id')::uuid;
  perform pg_temp.phone_assert(public.fizz_call_phone_confirm(paid.session_token, '4155550191', started->>'code')->>'error' = 'expired', 'an expired code cannot be used');

  started := public.fizz_call_phone_start(paid.session_token, '4155550192', '203.0.113.10');
  v_code := started->>'code';
  for i in 1..4 loop
    perform pg_temp.phone_assert(public.fizz_call_phone_confirm(paid.session_token, '4155550192', '111111')->>'error' = 'invalid_code', 'wrong codes are limited');
  end loop;
  perform pg_temp.phone_assert(public.fizz_call_phone_confirm(paid.session_token, '4155550192', '111111')->>'error' = 'too_many_attempts', 'the fifth wrong code locks the challenge');
  perform pg_temp.phone_assert(public.fizz_call_phone_confirm(paid.session_token, '4155550192', v_code)->>'error' = 'too_many_attempts', 'the right code does not work after the attempt limit');
  perform pg_temp.phone_assert(not exists (select 1 from public.fizz_verified_phones where phone = '+14155550192'), 'a locked code does not pair the number');

  started := public.fizz_call_phone_start(paid.session_token, '4155550193', '203.0.113.10');
  perform pg_temp.phone_assert(public.fizz_call_phone_cancel(paid.session_token, (started->>'verification_id')::uuid)->>'ok' = 'true', 'the owner can cancel a code that was not delivered');
  perform pg_temp.phone_assert(public.fizz_call_phone_confirm(paid.session_token, '4155550193', started->>'code')->>'error' = 'invalid_code', 'a cancelled code cannot be confirmed');

  -- Dial-time checks. Pair 4155550194 by confirming, then prove a downgrade and a removal both refuse to dial.
  update public.fizz_call_verifications set created_at = now() - interval '2 minutes' where customer_id = paid.customer_id;
  started := public.fizz_call_phone_start(paid.session_token, '4155550194', '203.0.113.12');
  perform pg_temp.phone_assert(public.fizz_call_phone_confirm(paid.session_token, '4155550194', started->>'code')->>'ok' = 'true', 'pairs a number used for the dial check');
  insert into public.fizz_alert_rules(customer_id, sensor_id, metric, comparator, threshold, unit, notify_channel, notify_phone)
  values (paid.customer_id, paid.sensor_id, 'temperature_c', 'gt', 80, 'C', 'call', '+14155550194')
  returning id into v_rule;
  insert into public.fizz_alert_events(rule_id, reading_id, customer_id, sensor_id, metric, numeric_value, threshold, comparator, unit, observed_at, notify_channel, notify_phone, notify_status)
  select v_rule, rd.id, paid.customer_id, paid.sensor_id, 'temperature_c', 90, 80, 'gt', 'C', now(), 'call', '+14155550194', 'sending'
  from public.fizz_sensor_readings rd where rd.sensor_id = paid.sensor_id and rd.event_id = 'base'
  returning id into v_event;
  perform pg_temp.phone_assert(public.fizz_alert_call_still_due(v_event)->>'send' = 'true', 'a paired paid number is still due at dial time');
  update public.fizz_subscriptions set plan = 'hobbyist' where customer_id = paid.customer_id;
  update public.fizz_alert_events set notify_status = 'sending', notify_error = null where id = v_event;
  perform pg_temp.phone_assert(public.fizz_alert_call_still_due(v_event)->>'send' = 'false', 'a downgraded account is not dialed');
  perform pg_temp.phone_assert((select notify_error from public.fizz_alert_events where id = v_event) = 'Phone calls are not included on this plan.', 'the dial check says the plan does not include calls');
  update public.fizz_subscriptions set plan = 'tinkerer' where customer_id = paid.customer_id;
  delete from public.fizz_verified_phones where customer_id = paid.customer_id and phone = '+14155550194';
  update public.fizz_alert_events set notify_status = 'sending', notify_error = null where id = v_event;
  perform pg_temp.phone_assert(public.fizz_alert_call_still_due(v_event)->>'send' = 'false', 'an unpaired number is not dialed');
  perform pg_temp.phone_assert((select notify_error from public.fizz_alert_events where id = v_event) = 'Phone number is not paired.', 'the dial check says the number is not paired');

  perform pg_temp.phone_assert(public.fizz_alert_notify_status(free.customer_id, v_rule, 'call') = 'skipped', 'queueing skips a hobbyist call');
  perform pg_temp.phone_assert(public.fizz_alert_call_skip_reason(free.customer_id, v_rule, 'call') = 'Phone calls are not included on this plan.', 'the skip reason names the plan');

  -- Billing sync drops queued calls when the subscription ends.
  perform public.fizz_billing_link_customer(free.customer_id, 'cus_PhoneFree1');
  perform pg_temp.phone_assert(public.fizz_billing_sync('cus_PhoneFree1', free.customer_id, 'sub_PhoneFree1', 'active', 'pro', extract(epoch from now())::bigint + 86400, false)->>'plan' = 'pro', 'a paid subscription includes calls');
  insert into public.fizz_verified_phones(customer_id, phone) values (free.customer_id, '+14155550197');
  insert into public.fizz_sensor_readings(sensor_id, event_id, observed_at, metric, numeric_value, unit, source)
  values (free.sensor_id, 'second', now(), 'temperature_c', 91, 'C', 'api');
  insert into public.fizz_alert_rules(customer_id, sensor_id, metric, comparator, threshold, unit, notify_channel, notify_phone)
  values (free.customer_id, free.sensor_id, 'temperature_c', 'gt', 70, 'C', 'call', '+14155550197')
  returning id into v_rule;
  insert into public.fizz_alert_events(rule_id, reading_id, customer_id, sensor_id, metric, numeric_value, threshold, comparator, unit, observed_at, notify_channel, notify_phone, notify_status)
  select v_rule, rd.id, free.customer_id, free.sensor_id, 'temperature_c', 90, 70, 'gt', 'C', now(), 'call', '+14155550197', 'pending'
  from public.fizz_sensor_readings rd where rd.sensor_id = free.sensor_id and rd.event_id = 'base';
  insert into public.fizz_alert_events(rule_id, reading_id, customer_id, sensor_id, metric, numeric_value, threshold, comparator, unit, observed_at, notify_channel, notify_phone, notify_status)
  select v_rule, rd.id, free.customer_id, free.sensor_id, 'temperature_c', 91, 70, 'gt', 'C', now(), 'call', '+14155550197', 'sending'
  from public.fizz_sensor_readings rd where rd.sensor_id = free.sensor_id and rd.event_id = 'second';
  perform pg_temp.phone_assert(public.fizz_billing_sync('cus_PhoneFree1', free.customer_id, 'sub_PhoneFree1', 'canceled', 'pro', extract(epoch from now())::bigint, false)->>'plan' = 'hobbyist', 'cancellation returns the account to hobbyist');
  perform pg_temp.phone_assert((select count(*) from public.fizz_alert_events where customer_id = free.customer_id and notify_channel = 'call' and notify_status = 'skipped' and notify_error = 'Phone calls are not included on this plan.') = 2, 'downgrade skips pending and sending calls');
  perform pg_temp.phone_assert(public.fizz_create_alert(free.session_token, free.sensor_id, 'temperature_c', 'gt', 50, 'C', 'call', '+14155550197')->>'error' = 'calls_not_included', 'after downgrade a call alert is rejected');
  perform pg_temp.phone_assert(public.fizz_create_alert(free.session_token, free.sensor_id, 'temperature_c', 'lt', 5, 'C') ? 'rule', 'after downgrade a dashboard alert still works');

  for i in 1..20 loop
    v_codes := v_codes || public.fizz_pairing_code();
  end loop;
  perform pg_temp.phone_assert((select bool_and(c ~ '^[0-9]{6}$') and count(distinct c) > 1 from unnest(v_codes) c), 'pairing codes are random 6-digit strings');

  -- Per-account hourly cap: 5 calls, then the 6th is refused. A fresh account, so earlier
  -- pairing calls in this test are not what trips the limit. Different numbers, so the
  -- per-number cap is not the cause either.
  v_customer := gen_random_uuid();
  v_token := md5(gen_random_uuid()::text) || md5(gen_random_uuid()::text);
  insert into auth.users(id, email, encrypted_password, is_anonymous)
  values (v_customer, 'acct-cap@example.invalid', 'not-a-password', false);
  insert into public.fizz_customers(id, auth_user_id, username)
  values (v_customer, v_customer, 'acct_' || left(replace(v_customer::text, '-', ''), 8));
  insert into public.fizz_sessions(token_hash, customer_id, expires_at)
  values (extensions.digest(decode(v_token, 'hex'), 'sha256'), v_customer, now() + interval '1 hour');
  insert into public.fizz_subscriptions(customer_id, plan) values (v_customer, 'tinkerer');
  for i in 1..5 loop
    v_phone := '41555502' || lpad(i::text, 2, '0');
    started := public.fizz_call_phone_start(v_token, v_phone, '203.0.113.77');
    perform pg_temp.phone_assert(started->>'code' ~ '^[0-9]{6}$', 'account call ' || i || ' is allowed');
  end loop;
  perform pg_temp.phone_assert(public.fizz_call_phone_start(v_token, '4155550299', '203.0.113.77')->>'error' = 'rate_limited', 'a sixth pairing call in an hour is refused');

  -- Per-number cap across accounts, and per-network cap. New paid customers so the account cap above does not apply.
  for i in 1..4 loop
    v_customer := gen_random_uuid();
    v_token := md5(gen_random_uuid()::text) || md5(gen_random_uuid()::text);
    insert into auth.users(id, email, encrypted_password, is_anonymous)
    values (v_customer, 'num-' || i || '@example.invalid', 'not-a-password', false);
    insert into public.fizz_customers(id, auth_user_id, username)
    values (v_customer, v_customer, 'num_' || i || '_' || left(replace(v_customer::text, '-', ''), 8));
    insert into public.fizz_sessions(token_hash, customer_id, expires_at)
    values (extensions.digest(decode(v_token, 'hex'), 'sha256'), v_customer, now() + interval '1 hour');
    insert into public.fizz_subscriptions(customer_id, plan) values (v_customer, 'pro');
    started := public.fizz_call_phone_start(v_token, '4155550300', '203.0.113.' || (30 + i));
    if i <= 3 then
      perform pg_temp.phone_assert(started->>'code' ~ '^[0-9]{6}$', 'number call ' || i || ' from a different account is allowed');
    else
      perform pg_temp.phone_assert(started->>'error' = 'rate_limited', 'a number cannot be called a fourth time in an hour');
    end if;
  end loop;

  for i in 1..9 loop
    v_customer := gen_random_uuid();
    v_token := md5(gen_random_uuid()::text) || md5(gen_random_uuid()::text);
    insert into auth.users(id, email, encrypted_password, is_anonymous)
    values (v_customer, 'net-' || i || '@example.invalid', 'not-a-password', false);
    insert into public.fizz_customers(id, auth_user_id, username)
    values (v_customer, v_customer, 'net_' || i || '_' || left(replace(v_customer::text, '-', ''), 8));
    insert into public.fizz_sessions(token_hash, customer_id, expires_at)
    values (extensions.digest(decode(v_token, 'hex'), 'sha256'), v_customer, now() + interval '1 hour');
    insert into public.fizz_subscriptions(customer_id, plan) values (v_customer, 'enterprise');
    v_phone := '41555504' || lpad(i::text, 2, '0');
    started := public.fizz_call_phone_start(v_token, v_phone, '198.51.100.50');
    if i <= 8 then
      perform pg_temp.phone_assert(started->>'code' ~ '^[0-9]{6}$', 'network call ' || i || ' is allowed');
    else
      perform pg_temp.phone_assert(started->>'error' = 'rate_limited', 'a ninth pairing call from one network in an hour is refused');
    end if;
  end loop;

  perform pg_temp.phone_assert(public.fizz_calls_allowed((select id from public.fizz_customers where username like 'net_1_%')), 'enterprise includes calls');
  perform pg_temp.phone_assert(pg_get_functiondef('public.fizz_call_phone_start(text,text,text)'::regprocedure) like '%call_pair_all_hour%', 'pairing has a service-wide cap');
  perform pg_temp.phone_assert(pg_get_functiondef('public.fizz_alert_call_still_due(uuid)'::regprocedure) like '%fizz_calls_allowed%', 'dial time rechecks the plan');
  perform pg_temp.phone_assert(pg_get_functiondef('public.fizz_alert_call_still_due(uuid)'::regprocedure) like '%fizz_verified_phones%', 'dial time rechecks pairing');
end $$;

select pg_temp.phone_assert(
  not has_table_privilege('anon', 'public.fizz_verified_phones', 'select')
  and not has_table_privilege('authenticated', 'public.fizz_verified_phones', 'insert')
  and not has_table_privilege('anon', 'public.fizz_call_verifications', 'select')
  and not has_table_privilege('authenticated', 'public.fizz_call_verifications', 'select')
  and not has_function_privilege('anon', 'public.fizz_call_phone_start(text,text,text)', 'execute')
  and not has_function_privilege('authenticated', 'public.fizz_call_phone_confirm(text,text,text)', 'execute')
  and not has_function_privilege('anon', 'public.fizz_pairing_code()', 'execute'),
  'clients cannot read codes or pair a number directly');
select pg_temp.phone_assert(
  exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'fizz_verified_phones' and cmd = 'SELECT')
  and exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'fizz_verified_phones' and cmd = 'DELETE')
  and not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'fizz_verified_phones' and cmd = 'INSERT')
  and not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'fizz_call_verifications'),
  'verified numbers can be read or removed by an owner policy, and codes have no client policy');

select format('Verified phone tests passed: %s', count(*)) from phone_results;
rollback;
