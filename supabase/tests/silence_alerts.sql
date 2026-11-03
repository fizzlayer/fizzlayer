-- Silence alerts: firing, re-arming, rate limits, RLS, and no double dispatch.
-- Run with: supabase db query --linked --file supabase/tests/silence_alerts.sql
-- All fixtures roll back. No existing customer data is used.
begin;
create temporary table silence_results(label text);
create function pg_temp.silence_assert(ok boolean, label text) returns void
language plpgsql as $$ begin
  if ok is distinct from true then raise exception 'Silence assertion failed: %', label; end if;
  insert into pg_temp.silence_results values (label);
end $$;

create temporary table silence_ids as
select n,
  gen_random_uuid() auth_id,
  gen_random_uuid() customer_id,
  gen_random_uuid() sensor_id,
  gen_random_uuid() agent_id,
  md5(gen_random_uuid()::text) || md5(gen_random_uuid()::text) session_token,
  'fizz_agent_' || md5(gen_random_uuid()::text) || md5(gen_random_uuid()::text) agent_token
from generate_series(1, 2) n;

insert into auth.users(id, email, encrypted_password, is_anonymous)
select auth_id, 'silence-' || auth_id || '@example.invalid', 'not-a-password', false from silence_ids;
insert into public.fizz_customers(id, auth_user_id, username)
select customer_id, auth_id, 'silence_' || left(replace(customer_id::text, '-', ''), 12) from silence_ids;
insert into public.fizz_sessions(token_hash, customer_id, expires_at)
select extensions.digest(decode(session_token, 'hex'), 'sha256'), customer_id, now() + interval '1 hour' from silence_ids;
insert into public.fizz_sensors(id, customer_id, kind, name, mode, status)
select sensor_id, customer_id, 'temperature', 'Closet ' || n, 'api', 'active' from silence_ids;
insert into public.fizz_agent_connections(id, customer_id, name, token_hash, can_create_alerts)
select agent_id, customer_id, 'Silence test agent', extensions.digest(agent_token, 'sha256'), true from silence_ids;

-- Owner 1's closet has been quiet for 30 minutes. Owner 2's reported a minute ago.
insert into public.fizz_sensor_readings(sensor_id, event_id, observed_at, received_at, metric, numeric_value, unit, source)
select sensor_id, 'old', now() - interval '30 minutes', now() - interval '30 minutes', 'temperature_c', 22, 'C', 'api'
from silence_ids where n = 1;
insert into public.fizz_sensor_readings(sensor_id, event_id, observed_at, received_at, metric, numeric_value, unit, source)
select sensor_id, 'fresh', now() - interval '1 minute', now() - interval '1 minute', 'temperature_c', 22, 'C', 'api'
from silence_ids where n = 2;

do $$
declare
  a record; b record;
  created jsonb; listed jsonb; scan jsonb; claimed jsonb;
  v_event uuid; v_rule uuid; v_reading uuid;
begin
  select * into a from pg_temp.silence_ids where n = 1;
  select * into b from pg_temp.silence_ids where n = 2;

  perform pg_temp.silence_assert(public.fizz_us_phone('(415) 555-0199') = '+14155550199', 'formats a US number');
  perform pg_temp.silence_assert(public.fizz_us_phone('415-055-0199') is null, 'rejects an invalid exchange');

  created := public.fizz_create_alert(a.session_token, a.sensor_id, p_kind => 'silence', p_notify_channel => 'call', p_notify_phone => '+14155550100');
  perform pg_temp.silence_assert(created->'rule'->>'kind' = 'silence', 'creates a silence rule');
  perform pg_temp.silence_assert((created->'rule'->>'silence_minutes')::int = 10, 'defaults to 10 minutes');
  perform pg_temp.silence_assert(created->'rule'->>'notify_channel' = 'call', 'stores the call number');
  perform pg_temp.silence_assert(created->>'created' = 'true', 'the first save is new');
  perform pg_temp.silence_assert(
    public.fizz_create_alert(a.session_token, a.sensor_id, p_kind => 'silence', p_notify_channel => 'call', p_notify_phone => '+14155550100')->'rule'->>'id' = created->'rule'->>'id'
    and public.fizz_create_alert(a.session_token, a.sensor_id, p_kind => 'silence', p_notify_channel => 'call', p_notify_phone => '+14155550100')->>'created' = 'false',
    'posting the same silence alert again returns it');
  perform pg_temp.silence_assert((select count(*) from public.fizz_alert_rules where customer_id = a.customer_id and kind = 'silence') = 1, 'a repeated save does not add a second rule');
  perform pg_temp.silence_assert(public.fizz_create_alert(a.session_token, a.sensor_id, p_kind => 'silence', p_silence_minutes => 0)->>'error' = 'invalid_rule', 'rejects a window under a minute');
  perform pg_temp.silence_assert(public.fizz_create_alert(a.session_token, a.sensor_id, p_kind => 'silence', p_silence_minutes => 10081)->>'error' = 'invalid_rule', 'rejects a window over 7 days');
  perform pg_temp.silence_assert(public.fizz_create_alert(a.session_token, b.sensor_id, p_kind => 'silence')->>'error' = 'sensor_not_found', 'cannot watch another account');
  perform pg_temp.silence_assert(public.fizz_create_alert(a.session_token, a.sensor_id, 'nope', 'gt', 1, 'C')->>'error' = 'unknown_metric', 'threshold rules still require a reported metric');

  listed := public.fizz_list_alerts(a.session_token);
  perform pg_temp.silence_assert(listed->'rules'->0->>'kind' = 'silence', 'list_alerts includes the silence rule');
  perform pg_temp.silence_assert((listed->'rules'->0->>'silence_minutes')::int = 10, 'list_alerts includes the window');

  perform pg_temp.silence_assert(to_regproc('public.fizz_create_chat_alert') is null, 'chat uses fizz_create_alert, not a second copy');

  created := public.fizz_agent_call(a.agent_token, '127.0.0.1', 'create_alert', jsonb_build_object('sensor_id', a.sensor_id, 'kind', 'silence', 'call_phone', '(415) 555-0100'));
  perform pg_temp.silence_assert(created->'result'->>'created' = 'false', 'MCP reuses the same silence rule');
  perform pg_temp.silence_assert(created->'result'->'rule'->>'kind' = 'silence', 'MCP result names the silence rule');
  listed := public.fizz_agent_call(a.agent_token, '127.0.0.1', 'list_alerts', '{}'::jsonb);
  perform pg_temp.silence_assert(listed->'result'->'rules'->0->>'kind' = 'silence', 'MCP list_alerts shows silence');
  perform pg_temp.silence_assert((listed->'result'->'rules'->0->>'silence_minutes')::int = 10, 'MCP list_alerts shows the window');
  perform pg_temp.silence_assert(public.fizz_agent_call(a.agent_token, '127.0.0.1', 'create_alert', jsonb_build_object('sensor_id', a.sensor_id, 'kind', 'silence', 'silence_minutes', 0))->>'error' = 'invalid_arguments', 'MCP rejects a window under a minute');
  perform pg_temp.silence_assert(public.fizz_agent_call(a.agent_token, '127.0.0.1', 'create_alert', jsonb_build_object('sensor_id', a.sensor_id, 'kind', 'silence', 'call_phone', '(415) 555-0198'))->>'error' = 'invalid_arguments', 'MCP cannot introduce a new phone number');

  -- Not quiet long enough, never reported, paused, and removed sensors stay armed.
  perform pg_temp.silence_assert(public.fizz_create_alert(b.session_token, b.sensor_id, p_kind => 'silence', p_silence_minutes => 10) ? 'rule', 'second account can create a silence rule');
  scan := public.fizz_scan_silence_alerts(50);
  perform pg_temp.silence_assert((scan->>'fired')::int = 1 and (scan->>'queued')::int = 1, 'fires once and queues the call');
  perform pg_temp.silence_assert((select not armed from public.fizz_alert_rules where customer_id = a.customer_id and kind = 'silence'), 'disarms after firing');
  perform pg_temp.silence_assert((select armed from public.fizz_alert_rules where customer_id = b.customer_id and kind = 'silence'), 'a fresh sensor does not fire');
  perform pg_temp.silence_assert((select count(*) from public.fizz_alert_events where customer_id = a.customer_id and event_kind = 'silence') = 1, 'one silence event');
  select id into v_event from public.fizz_alert_events where customer_id = a.customer_id and event_kind = 'silence';
  perform pg_temp.silence_assert((select notify_status from public.fizz_alert_events where id = v_event) = 'pending', 'call is pending');

  scan := public.fizz_scan_silence_alerts(50);
  perform pg_temp.silence_assert((scan->>'fired')::int = 0, 'a second scan does not fire again');
  perform pg_temp.silence_assert((select count(*) from public.fizz_alert_events where customer_id = a.customer_id and event_kind = 'silence') = 1, 'still one silence event');

  update public.fizz_alert_rules set armed = true where customer_id = a.customer_id and kind = 'silence';
  scan := public.fizz_scan_silence_alerts(50);
  perform pg_temp.silence_assert((scan->>'fired')::int = 0, 'the same quiet period cannot queue a second call');
  perform pg_temp.silence_assert((select not armed from public.fizz_alert_rules where customer_id = a.customer_id and kind = 'silence'), 'stays disarmed when the event already exists');
  perform pg_temp.silence_assert((select count(*) from public.fizz_alert_events where customer_id = a.customer_id and event_kind = 'silence') = 1, 'unique quiet period');

  claimed := public.fizz_claim_alert_notifications(3);
  perform pg_temp.silence_assert(jsonb_array_length(claimed) = 1, 'claims the queued call');
  perform pg_temp.silence_assert(claimed->0->>'event_kind' = 'silence', 'claim tells the caller this is silence');
  perform pg_temp.silence_assert(claimed->0->>'phone' = '+14155550100', 'claim includes the phone number');
  perform pg_temp.silence_assert((select notify_status from public.fizz_alert_events where id = v_event) = 'sending', 'marks the call sending');
  perform pg_temp.silence_assert((select notify_attempts from public.fizz_alert_events where id = v_event) = 1, 'counts one attempt');
  claimed := public.fizz_claim_alert_notifications(3);
  perform pg_temp.silence_assert(jsonb_array_length(claimed) = 0, 'a second claim takes nothing');
  perform pg_temp.silence_assert((select notify_attempts from public.fizz_alert_events where id = v_event) = 1, 'attempts do not increase');
  perform pg_temp.silence_assert(pg_get_functiondef('public.fizz_claim_alert_notifications(integer)'::regprocedure) ilike '%skip locked%', 'claim skips rows another worker holds');
  perform pg_temp.silence_assert(pg_get_functiondef('public.fizz_scan_silence_alerts(integer)'::regprocedure) ilike '%for update of r skip locked%', 'scan skips rules another worker holds');

  -- A new reading re-arms and drops a call that has not been placed.
  update public.fizz_alert_events set notify_status = 'pending', notify_attempts = 0, notify_claimed_at = null where id = v_event;
  update public.fizz_alert_rules set armed = false where customer_id = a.customer_id and kind = 'silence';
  insert into public.fizz_sensor_readings(sensor_id, event_id, observed_at, metric, numeric_value, unit, source)
  values (a.sensor_id, 'back', now(), 'temperature_c', 23, 'C', 'api');
  perform pg_temp.silence_assert((select armed from public.fizz_alert_rules where customer_id = a.customer_id and kind = 'silence'), 'a new reading re-arms');
  perform pg_temp.silence_assert((select notify_status from public.fizz_alert_events where id = v_event) = 'skipped', 'an unsent call is cancelled');
  perform pg_temp.silence_assert((select count(*) from public.fizz_alert_events where customer_id = a.customer_id and event_kind = 'recovery') = 0, 'recovery stays off unless asked');

  -- Opt-in recovery is a dashboard notice, and a call still obeys the 5-minute rule limit.
  update public.fizz_alert_rules set notify_recovery = true, armed = false, notify_channel = 'call', notify_phone = '+14155550100'
  where customer_id = a.customer_id and kind = 'silence';
  update public.fizz_alert_events set notify_status = 'sent', notified_at = now() where id = v_event;
  update public.fizz_sensor_readings set received_at = now() - interval '40 minutes'
  where sensor_id = a.sensor_id and event_id = 'back';
  -- The row above is now old, so insert a genuinely new reading to re-arm into recovery.
  insert into public.fizz_sensor_readings(sensor_id, event_id, observed_at, metric, numeric_value, unit, source)
  values (a.sensor_id, 'back-again', now(), 'temperature_c', 24, 'C', 'api');
  perform pg_temp.silence_assert((select count(*) from public.fizz_alert_events where customer_id = a.customer_id and event_kind = 'recovery') = 1, 'records that the sensor is back');
  perform pg_temp.silence_assert((select notify_status from public.fizz_alert_events where customer_id = a.customer_id and event_kind = 'recovery') = 'skipped', 'the return call waits out the rule limit');

  -- The recovery row and the next silence share that reading. A second and third
  -- quiet period must still be recorded.
  update public.fizz_sensor_readings set received_at = now() - interval '20 minutes'
  where sensor_id = a.sensor_id and event_id = 'back-again';
  update public.fizz_alert_rules set silence_due_at = now() - interval '1 minute'
  where customer_id = a.customer_id and kind = 'silence';
  scan := public.fizz_scan_silence_alerts(50);
  perform pg_temp.silence_assert((scan->>'fired')::int = 1, 'the quiet period after recovery fires');
  perform pg_temp.silence_assert((select count(*) from public.fizz_alert_events where customer_id = a.customer_id and event_kind = 'silence') = 2, 'the second silence is stored beside the recovery');
  perform pg_temp.silence_assert((select not armed from public.fizz_alert_rules where customer_id = a.customer_id and kind = 'silence'), 'the second quiet period disarms the rule');
  insert into public.fizz_sensor_readings(sensor_id, event_id, observed_at, metric, numeric_value, unit, source)
  values (a.sensor_id, 'back-third', now(), 'temperature_c', 25, 'C', 'api');
  update public.fizz_sensor_readings set received_at = now() - interval '15 minutes'
  where sensor_id = a.sensor_id and event_id = 'back-third';
  update public.fizz_alert_rules set silence_due_at = now() - interval '1 minute'
  where customer_id = a.customer_id and kind = 'silence';
  scan := public.fizz_scan_silence_alerts(50);
  perform pg_temp.silence_assert((scan->>'fired')::int = 1, 'a third quiet period fires');
  perform pg_temp.silence_assert((select count(*) from public.fizz_alert_events where customer_id = a.customer_id and event_kind = 'silence') = 3, 'three quiet periods are stored');
  perform pg_temp.silence_assert((select count(*) from public.fizz_alert_events where customer_id = a.customer_id and event_kind = 'recovery') = 2, 'each resume can record its own recovery');

  -- Per-rule cooldown and the account cap both skip the call but still record the event.
  insert into public.fizz_sensors(id, customer_id, kind, name, mode)
  values ('00000000-0000-4000-8000-0000000000c1', a.customer_id, 'temperature', 'Cap closet', 'api');
  insert into public.fizz_sensor_readings(sensor_id, event_id, observed_at, received_at, metric, numeric_value, unit, source)
  select '00000000-0000-4000-8000-0000000000c1', 'cap-' || i, now() - interval '3 hours', now() - interval '3 hours', 'temperature_c', 1, 'C', 'api'
  from generate_series(1, 20) i;
  insert into public.fizz_sensor_readings(sensor_id, event_id, observed_at, received_at, metric, numeric_value, unit, source)
  values ('00000000-0000-4000-8000-0000000000c1', 'cap-latest', now() - interval '30 minutes', now() - interval '30 minutes', 'temperature_c', 1, 'C', 'api');
  insert into public.fizz_alert_rules(id, customer_id, sensor_id, metric, comparator, threshold, unit, enabled, notify_channel)
  values ('00000000-0000-4000-8000-0000000000d1', a.customer_id, '00000000-0000-4000-8000-0000000000c1', 'temperature_c', 'gt', 100, 'C', false, 'none');
  insert into public.fizz_alert_events(rule_id, reading_id, customer_id, sensor_id, metric, numeric_value, threshold, comparator, unit, observed_at, notify_channel, notify_status)
  select '00000000-0000-4000-8000-0000000000d1', r.id, a.customer_id, r.sensor_id, 'temperature_c', 1, 100, 'gt', 'C', r.observed_at, 'call', 'sent'
  from public.fizz_sensor_readings r
  where r.sensor_id = '00000000-0000-4000-8000-0000000000c1' and r.event_id like 'cap-%' and r.event_id <> 'cap-latest';
  insert into public.fizz_alert_rules(customer_id, sensor_id, metric, comparator, threshold, unit, kind, silence_minutes, notify_channel, notify_phone, silence_due_at)
  values (a.customer_id, '00000000-0000-4000-8000-0000000000c1', 'silence', 'gte', 10, 'min', 'silence', 10, 'call', '+14155550100', now() - interval '1 minute')
  returning id into v_rule;
  scan := public.fizz_scan_silence_alerts(50);
  perform pg_temp.silence_assert((scan->>'skipped')::int = 1 and (scan->>'queued')::int = 0, 'the account cap skips the call');
  perform pg_temp.silence_assert((select notify_status from public.fizz_alert_events e where e.rule_id = v_rule) = 'skipped', 'the capped event is recorded as skipped');

  -- A paused or removed sensor, and a sensor with no readings, do not fire.
  insert into public.fizz_sensors(id, customer_id, kind, name, mode, status)
  values ('00000000-0000-4000-8000-0000000000c2', a.customer_id, 'temperature', 'Paused closet', 'api', 'paused');
  insert into public.fizz_sensor_readings(sensor_id, event_id, observed_at, received_at, metric, numeric_value, unit, source)
  values ('00000000-0000-4000-8000-0000000000c2', 'paused', now() - interval '1 day', now() - interval '1 day', 'temperature_c', 1, 'C', 'api');
  insert into public.fizz_alert_rules(customer_id, sensor_id, metric, comparator, threshold, unit, kind, silence_minutes, silence_due_at)
  values (a.customer_id, '00000000-0000-4000-8000-0000000000c2', 'silence', 'gte', 10, 'min', 'silence', 10, now() - interval '1 day');
  insert into public.fizz_sensors(id, customer_id, kind, name, mode, deleted_at)
  values ('00000000-0000-4000-8000-0000000000c3', a.customer_id, 'temperature', 'Removed closet', 'api', now());
  insert into public.fizz_sensor_readings(sensor_id, event_id, observed_at, received_at, metric, numeric_value, unit, source)
  values ('00000000-0000-4000-8000-0000000000c3', 'removed', now() - interval '1 day', now() - interval '1 day', 'temperature_c', 1, 'C', 'api');
  insert into public.fizz_alert_rules(customer_id, sensor_id, metric, comparator, threshold, unit, kind, silence_minutes, silence_due_at)
  values (a.customer_id, '00000000-0000-4000-8000-0000000000c3', 'silence', 'gte', 10, 'min', 'silence', 10, now() - interval '1 day');
  insert into public.fizz_sensors(id, customer_id, kind, name, mode)
  values ('00000000-0000-4000-8000-0000000000c4', a.customer_id, 'temperature', 'New closet', 'api');
  insert into public.fizz_alert_rules(customer_id, sensor_id, metric, comparator, threshold, unit, kind, silence_minutes)
  values (a.customer_id, '00000000-0000-4000-8000-0000000000c4', 'silence', 'gte', 10, 'min', 'silence', 10);
  scan := public.fizz_scan_silence_alerts(50);
  perform pg_temp.silence_assert((scan->>'fired')::int = 0, 'paused, removed, and unread sensors do not fire');

  -- Threshold evaluation is unchanged, and a silence rule does not steal its reading.
  insert into public.fizz_alert_rules(customer_id, sensor_id, metric, comparator, threshold, unit, notify_channel, notify_phone)
  values (b.customer_id, b.sensor_id, 'temperature_c', 'gt', 20, 'C', 'call', '+14155550199');
  insert into public.fizz_sensor_readings(sensor_id, event_id, observed_at, metric, numeric_value, unit, source)
  values (b.sensor_id, 'hot', now(), 'temperature_c', 30, 'C', 'api')
  returning id into v_reading;
  perform pg_temp.silence_assert((select count(*) from public.fizz_alert_events e where e.reading_id = v_reading and e.event_kind = 'threshold') = 1, 'threshold alerts still fire');
  perform pg_temp.silence_assert((select armed from public.fizz_alert_rules where customer_id = b.customer_id and kind = 'silence'), 'the fresh reading keeps the silence rule armed');

  select id into v_rule from public.fizz_alert_rules where customer_id = b.customer_id and kind = 'threshold';
  perform public.fizz_update_alert(b.session_token, v_rule, false, false);
  perform pg_temp.silence_assert((select notify_status from public.fizz_alert_events e where e.reading_id = v_reading) = 'skipped', 'pausing the rule cancels a pending call');
  perform pg_temp.silence_assert((select notify_error from public.fizz_alert_events e where e.reading_id = v_reading) = 'Alert was paused.', 'the cancel says the alert was paused');

  insert into public.fizz_sensors(id, customer_id, kind, name, mode)
  values ('00000000-0000-4000-8000-0000000000c5', b.customer_id, 'temperature', 'Dial closet', 'api');
  insert into public.fizz_sensor_readings(sensor_id, event_id, observed_at, received_at, metric, numeric_value, unit, source)
  values ('00000000-0000-4000-8000-0000000000c5', 'dial', now() - interval '30 minutes', now() - interval '30 minutes', 'temperature_c', 21, 'C', 'api');
  insert into public.fizz_alert_rules(customer_id, sensor_id, metric, comparator, threshold, unit, kind, silence_minutes, notify_channel, notify_phone, silence_due_at)
  values (b.customer_id, '00000000-0000-4000-8000-0000000000c5', 'silence', 'gte', 10, 'min', 'silence', 10, 'call', '+14155550199', now() - interval '1 minute');
  scan := public.fizz_scan_silence_alerts(50);
  perform pg_temp.silence_assert((scan->>'queued')::int = 1, 'a due silence rule queues a call');
  claimed := public.fizz_claim_alert_notifications(1);
  perform pg_temp.silence_assert(jsonb_array_length(claimed) = 1, 'the queued call is claimed');
  update public.fizz_sensors set status = 'paused' where id = '00000000-0000-4000-8000-0000000000c5';
  perform pg_temp.silence_assert(public.fizz_alert_call_still_due((claimed->0->>'id')::uuid)->>'send' = 'false', 'a claimed call is not dialed after the sensor is paused');
  perform pg_temp.silence_assert((select notify_status from public.fizz_alert_events where id = (claimed->0->>'id')::uuid) = 'skipped', 'the claimed call is marked skipped');

  -- Another account cannot cancel this account's queued calls by deleting or pausing its rule.
  select id into v_rule from public.fizz_alert_rules where customer_id = b.customer_id and sensor_id = b.sensor_id and kind = 'silence';
  insert into public.fizz_alert_events(rule_id, reading_id, customer_id, sensor_id, metric, numeric_value, threshold, comparator, unit, observed_at, notify_channel, notify_phone, notify_status, event_kind)
  select v_rule, r.id, b.customer_id, b.sensor_id, 'silence', 30, 10, 'gte', 'min', now(), 'call', '+14155550199', 'pending', 'silence'
  from public.fizz_sensor_readings r where r.sensor_id = b.sensor_id and r.event_id = 'fresh'
  returning id into v_event;
  perform pg_temp.silence_assert(public.fizz_update_alert(a.session_token, v_rule, null, true)->>'error' = 'not_found', 'cannot delete another account''s rule');
  perform pg_temp.silence_assert(public.fizz_update_alert(a.session_token, v_rule, false, false)->>'error' = 'not_found', 'cannot pause another account''s rule');
  perform pg_temp.silence_assert((select notify_status from public.fizz_alert_events where id = v_event) = 'pending', 'another account''s queued call is left alone');
  perform pg_temp.silence_assert((select enabled from public.fizz_alert_rules where id = v_rule), 'another account''s rule stays enabled');
  perform pg_temp.silence_assert(public.fizz_update_alert(b.session_token, v_rule, null, true)->>'ok' = 'true', 'the owner can delete the rule');
  perform pg_temp.silence_assert((select notify_status from public.fizz_alert_events where id = v_event) = 'skipped', 'deleting your own rule cancels its queued call');

  -- A disabled silence rule is not rewritten by readings.
  insert into public.fizz_alert_rules(customer_id, sensor_id, metric, comparator, threshold, unit, kind, silence_minutes, enabled, silence_due_at)
  values (b.customer_id, b.sensor_id, 'silence', 'gte', 30, 'min', 'silence', 30, false, '2000-01-01')
  returning id into v_rule;
  insert into public.fizz_sensor_readings(sensor_id, event_id, observed_at, metric, numeric_value, unit, source)
  values (b.sensor_id, 'while-disabled', now(), 'temperature_c', 21, 'C', 'api');
  perform pg_temp.silence_assert((select silence_due_at from public.fizz_alert_rules where id = v_rule) = '2000-01-01', 'readings skip disabled silence rules');
  perform public.fizz_update_alert(b.session_token, v_rule, true, false);
  perform pg_temp.silence_assert((select silence_due_at from public.fizz_alert_rules where id = v_rule) > now() + interval '29 minutes', 'resuming the rule recomputes its due time');

  -- Sample sensors only report while viewed, so they cannot have silence alerts.
  insert into public.fizz_sensors(id, customer_id, kind, name, mode)
  values ('00000000-0000-4000-8000-0000000000c6', a.customer_id, 'temperature', 'Sample closet', 'simulated');
  perform pg_temp.silence_assert(public.fizz_create_alert(a.session_token, '00000000-0000-4000-8000-0000000000c6', p_kind => 'silence')->>'error' = 'simulated_sensor', 'dashboard rejects silence on a sample sensor');
  perform pg_temp.silence_assert(public.fizz_agent_call(a.agent_token, '127.0.0.1', 'create_alert', jsonb_build_object('sensor_id', '00000000-0000-4000-8000-0000000000c6', 'kind', 'silence'))->>'error' = 'invalid_arguments', 'MCP rejects silence on a sample sensor');
  insert into public.fizz_sensor_readings(sensor_id, event_id, observed_at, received_at, metric, numeric_value, unit, source)
  values ('00000000-0000-4000-8000-0000000000c6', 'sample', now() - interval '1 day', now() - interval '1 day', 'temperature_c', 1, 'C', 'simulated');
  insert into public.fizz_alert_rules(customer_id, sensor_id, metric, comparator, threshold, unit, kind, silence_minutes, silence_due_at)
  values (a.customer_id, '00000000-0000-4000-8000-0000000000c6', 'silence', 'gte', 10, 'min', 'silence', 10, now() - interval '1 day');
  scan := public.fizz_scan_silence_alerts(50);
  perform pg_temp.silence_assert((scan->>'fired')::int = 0, 'an older sample-sensor silence rule does not fire');

  -- Resuming a paused sensor gives it a full window before silence can fire.
  update public.fizz_sensors set status = 'active' where id = '00000000-0000-4000-8000-0000000000c2';
  perform pg_temp.silence_assert((select silence_due_at from public.fizz_alert_rules where sensor_id = '00000000-0000-4000-8000-0000000000c2') > now() + interval '9 minutes', 'resuming a sensor pushes the due time out');
  scan := public.fizz_scan_silence_alerts(50);
  perform pg_temp.silence_assert((scan->>'fired')::int = 0, 'a just-resumed sensor does not fire');

  -- The scan records that a scheduler is running.
  perform pg_temp.silence_assert((public.fizz_list_alerts(a.session_token)->>'silence_scheduler_active')::boolean, 'list_alerts reports a recent scan');

  -- MCP may only reuse a number that is on an active alert.
  update public.fizz_alert_rules set enabled = false where customer_id = a.customer_id;
  perform pg_temp.silence_assert(public.fizz_agent_call(a.agent_token, '127.0.0.1', 'create_alert', jsonb_build_object('sensor_id', a.sensor_id, 'kind', 'silence', 'call_phone', '(415) 555-0100'))->>'error' = 'invalid_arguments', 'MCP cannot reuse a number from a paused alert');
end $$;

-- Clients cannot run the scanner or read another account's silence rule.
select pg_temp.silence_assert(
  not has_function_privilege('anon', 'public.fizz_scan_silence_alerts(integer)', 'execute')
  and not has_function_privilege('authenticated', 'public.fizz_scan_silence_alerts(integer)', 'execute')
  and not has_function_privilege('anon', 'public.fizz_alert_notify_status(uuid,uuid,text)', 'execute')
  and not has_function_privilege('authenticated', 'public.fizz_alert_notify_status(uuid,uuid,text)', 'execute'),
  'clients cannot execute silence functions');

grant select on public.fizz_customers, public.fizz_sensors to authenticated;
grant select, insert on public.fizz_alert_rules to authenticated;
grant select on pg_temp.silence_ids to authenticated;
grant insert on pg_temp.silence_results to authenticated;
grant execute on function pg_temp.silence_assert(boolean, text) to authenticated;
set local role authenticated;
select set_config('request.jwt.claims', jsonb_build_object('sub', auth_id, 'role', 'authenticated', 'is_anonymous', false)::text, true),
  set_config('request.jwt.claim.sub', auth_id::text, true)
from pg_temp.silence_ids where n = 1;
do $$
declare a uuid; b uuid;
begin
  select customer_id into a from pg_temp.silence_ids where n = 1;
  select customer_id into b from pg_temp.silence_ids where n = 2;
  perform pg_temp.silence_assert((select count(*) from public.fizz_alert_rules where customer_id = a and kind = 'silence') >= 1, 'owner can read silence rules');
  perform pg_temp.silence_assert((select count(*) from public.fizz_alert_rules where customer_id = b and kind = 'silence') = 0, 'owner cannot read another account');
  begin
    insert into public.fizz_alert_rules(customer_id, sensor_id, metric, comparator, threshold, unit, kind, silence_minutes)
    select b, sensor_id, 'silence', 'gte', 10, 'min', 'silence', 10 from pg_temp.silence_ids where n = 2;
    raise exception 'foreign silence insert was allowed';
  exception when insufficient_privilege then
    perform pg_temp.silence_assert(true, 'owner cannot insert a silence rule for someone else');
  end;
  begin
    perform public.fizz_scan_silence_alerts(1);
    raise exception 'authenticated scan was allowed';
  exception when insufficient_privilege then
    perform pg_temp.silence_assert(true, 'authenticated cannot scan');
  end;
end $$;
reset role;

select count(*) as silence_assertions_passed from silence_results;
rollback;
