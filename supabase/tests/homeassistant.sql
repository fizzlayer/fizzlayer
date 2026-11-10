-- Home Assistant pairing, entity sync, ingest, revocation, and device limits.
-- Synthetic users only; everything rolls back.
begin;
create temporary table ha_results(label text);
create function pg_temp.ha_assert(ok boolean, label text) returns void
language plpgsql as $$ begin
  if ok is distinct from true then raise exception 'Home Assistant assertion failed: %', label; end if;
  insert into pg_temp.ha_results values(label);
end $$;

create temporary table ha_ids as
select n, gen_random_uuid() auth_id, gen_random_uuid() customer_id,
  md5(gen_random_uuid()::text) || md5(gen_random_uuid()::text) token,
  encode(extensions.gen_random_bytes(32), 'hex') state
from generate_series(1, 2) n;
insert into auth.users(id, email, encrypted_password, is_anonymous)
select auth_id, 'ha-' || auth_id || '@example.invalid', 'hash', false from ha_ids;
insert into public.fizz_customers(id, auth_user_id, username)
select customer_id, auth_id, 'ha_' || left(replace(customer_id::text, '-', ''), 16) from ha_ids;
insert into public.fizz_sessions(token_hash, customer_id, expires_at)
select extensions.digest(decode(token, 'hex'), 'sha256'), customer_id, now() + interval '1 hour' from ha_ids;

grant execute on function pg_temp.ha_assert(boolean, text) to service_role;
grant select on ha_ids to service_role;
grant insert on ha_results to service_role;
set local role service_role;
do $$
declare
  a record; b record; result jsonb;   synced jsonb; sensor uuid; door uuid; other uuid;
  linux jsonb; reading jsonb; spec jsonb; due timestamptz;
  kept uuid; paused uuid; prepared text; preview jsonb;
begin
  select * into a from pg_temp.ha_ids where n = 1;
  select * into b from pg_temp.ha_ids where n = 2;

  perform pg_temp.ha_assert(public.fizz_ha_prepare(null)->>'error' = 'unauthorized', 'prepare requires a session');
  perform pg_temp.ha_assert(public.fizz_ha_authorize(a.token, 'abcd', '482913')->>'error' = 'invalid_request', 'state must be 64 hex characters');
  perform pg_temp.ha_assert(public.fizz_ha_exchange(a.state, 'ha-test', null, 'Cabin', '2026.11.0')->>'error' = 'invalid_request', 'a poll without the screen code is rejected');
  perform pg_temp.ha_assert(public.fizz_ha_authorize(a.token, a.state, '482913')->>'error' = 'not_ready', 'approval waits until Home Assistant has registered');
  perform pg_temp.ha_assert(public.fizz_ha_exchange(a.state, 'ha-test', '482913', 'Cabin', '2026.11.0')->>'status' = 'pending', 'Home Assistant registers its code');
  preview := public.fizz_ha_preview(a.state, 'ha-test');
  perform pg_temp.ha_assert(preview->>'name' = 'Cabin' and preview->>'ha_version' = '2026.11.0'
    and preview::text not like '%482913%', 'the allow page can see the install but not the code');
  perform pg_temp.ha_assert(public.fizz_ha_authorize(a.token, a.state, null)->>'error' = 'invalid_code', 'approval without the code fails');
  perform pg_temp.ha_assert(public.fizz_ha_authorize(a.token, a.state, '000000')->>'error' = 'invalid_code', 'the wrong code fails');
  prepared := public.fizz_ha_prepare(a.token)->>'code';
  perform pg_temp.ha_assert(public.fizz_ha_authorize(a.token, a.state, prepared)->>'error' = 'invalid_code', 'a pairing code is not the screen code');
  perform pg_temp.ha_assert(public.fizz_ha_exchange_code('482913', 'ha-test')->>'error' = 'invalid_code', 'the screen code is not a pairing code');
  perform pg_temp.ha_assert(public.fizz_ha_authorize(a.token, a.state, '482913')->>'ok' = 'true', 'the signed-in owner allows the matching code');
  perform pg_temp.ha_assert(public.fizz_ha_authorize(b.token, a.state, '482913')->>'error' = 'invalid_request', 'another account cannot take the link');
  result := public.fizz_ha_exchange(a.state, 'ha-test', '482913', 'Cabin', '2026.11.0');
  perform pg_temp.ha_assert(result->>'connection_id' is not null and result->>'api_key' like 'fizz_%'
    and result->>'account' like 'ha_%' and result->>'device_name' = 'Cabin', 'exchange returns the device key once');
  perform pg_temp.ha_assert((result->>'devices_used')::int = 0, 'linking alone does not spend a device slot');
  perform pg_temp.ha_assert(public.fizz_ha_exchange(a.state, 'ha-test', '000000', 'Cabin', '2026.11.0')->>'error' = 'already_linked', 'the device key is not returned again');
  perform pg_temp.ha_assert(public.fizz_ha_list(a.token)->'connections'->0->>'name' = 'Cabin', 'the owner sees the connection');
  perform pg_temp.ha_assert(jsonb_array_length(public.fizz_ha_list(b.token)->'connections') = 0, 'connections are not visible to other accounts');

  -- A Linux pairing code must not be approvable through the Home Assistant exchange.
  linux := public.fizz_pair_start('Garage Pi', 'linux', 'ha-linux');
  perform pg_temp.ha_assert(public.fizz_ha_exchange_code(linux->>'code', 'ha-test')->>'error' = 'invalid_code', 'a CLI code is not a Home Assistant link');
  result := public.fizz_ha_prepare(a.token);
  perform pg_temp.ha_assert(result->>'code' ~ '^[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}$', 'fallback code looks like a device code');
  synced := public.fizz_ha_exchange_code(result->>'code', 'ha-test');
  perform pg_temp.ha_assert(synced->>'api_key' like 'fizz_%', 'the fallback code approves the pairing');

  spec := public.fizz_ha_entity_spec('sensor.rack_temp', 'temperature', '°F');
  perform pg_temp.ha_assert(spec->>'kind' = 'temperature' and spec->>'metric' = 'temperature_c' and spec->>'unit' = '°C', 'temperature maps to celsius');
  spec := public.fizz_ha_entity_spec('binary_sensor.closet_door', 'door', null);
  perform pg_temp.ha_assert(spec->>'kind' = 'custom' and spec->>'metric' = 'open' and (spec->>'boolean')::boolean, 'a door is a boolean contact');
  spec := public.fizz_ha_entity_spec('binary_sensor.leak', 'moisture', null);
  perform pg_temp.ha_assert(spec->>'kind' = 'water' and spec->>'metric' = 'leak', 'a leak sensor is a water sensor');
  perform pg_temp.ha_assert(public.fizz_ha_entity_spec('light.lamp', 'none', null) is null, 'only sensor entities are accepted');

  result := public.fizz_ha_sync(synced->>'api_key', jsonb_build_array(
    jsonb_build_object('entity_id', 'sensor.rack_temp', 'name', 'Rack temperature', 'device_class', 'temperature'),
    jsonb_build_object('entity_id', 'binary_sensor.closet_door', 'name', 'Closet door', 'device_class', 'door'),
    jsonb_build_object('entity_id', 'sensor.ups_power', 'name', 'UPS power', 'device_class', 'power', 'unit', 'W'),
    jsonb_build_object('entity_id', 'not an entity', 'name', 'Bad')
  ), 'Rack Home Assistant', '2026.11.0', true);
  perform pg_temp.ha_assert(jsonb_array_length(result->'sensors') = 3, 'valid entities become sensors');
  perform pg_temp.ha_assert(result->'skipped'->0->>'error' = 'invalid_entity', 'a bad entity is skipped');
  perform pg_temp.ha_assert((result->>'devices_used')::int = 3, 'each Home Assistant entity counts as a device');
  other := (result->>'connection_id')::uuid;
  sensor := (result->'sensors'->0->>'sensor_id')::uuid;
  door := (result->'sensors'->1->>'sensor_id')::uuid;
  perform pg_temp.ha_assert(public.fizz_list_sensors(a.token)->'sensors' @> jsonb_build_array(jsonb_build_object(
    'id', sensor, 'source', 'homeassistant', 'device_class', 'temperature', 'unit', '°C',
    'ha_entity_id', 'sensor.rack_temp')), 'sensors are labeled Home Assistant');

  reading := public.fizz_ingest_event(sensor, synced->>'api_key', 'ha-temp-1', now(), '{"temperature_c": 27.5}'::jsonb);
  perform pg_temp.ha_assert(reading->'accepted'->0->>'source' = 'homeassistant'
    and reading->'accepted'->0->>'unit' = '°C'
    and (reading->'accepted'->0->>'numeric_value')::float = 27.5, 'ingest reuses the device key and labels the reading');
  perform pg_temp.ha_assert(public.fizz_ingest_event(sensor, b.token, 'foreign', now(), '{"temperature_c": 1}'::jsonb)->>'error' = 'unauthorized', 'another account key is rejected');
  reading := public.fizz_ingest_batch(synced->>'api_key', jsonb_build_array(
    jsonb_build_object('sensor_id', door, 'event_id', 'ha-door-1', 'metrics', jsonb_build_object('open', true)),
    jsonb_build_object('sensor_id', result->'sensors'->2->>'sensor_id', 'event_id', 'ha-power-1', 'metrics', jsonb_build_object('power_w', 180))
  ));
  perform pg_temp.ha_assert(reading->'results'->0->>'boolean_value' = 'true'
    and reading->'results'->1->>'unit' = 'W', 'a batch keeps each sensor unit');
  perform pg_temp.ha_assert(public.fizz_ingest_batch('fizz_' || repeat('ab', 32), jsonb_build_array(
    jsonb_build_object('sensor_id', sensor, 'event_id', 'nope', 'metrics', jsonb_build_object('temperature_c', 1))
  ))->>'error' = 'unauthorized', 'an unknown key fails the batch');

  -- Silence is anchored to received_at. Inside one transaction now() does not move, so this
  -- checks the rule is armed from the stored reading; a later request's heartbeat moves it.
  perform pg_temp.ha_assert(public.fizz_save_alert_rule(a.customer_id, sensor, 'silence', null, null, null, null, 'none', null, 10, false, null) ? 'rule', 'silence rule on a Home Assistant sensor');
  select silence_due_at into due from public.fizz_alert_rules where sensor_id = sensor and kind = 'silence';
  perform pg_temp.ha_assert(due = (select received_at + interval '10 minutes' from public.fizz_sensor_readings
    where sensor_id = sensor and event_id = 'ha-temp-1'), 'silence is measured from when the reading was stored');
  perform pg_temp.ha_assert(public.fizz_ingest_event(sensor, synced->>'api_key', 'ha-temp-heartbeat', now(), '{"temperature_c": 27.5}'::jsonb) ? 'accepted', 'a new event id stores the heartbeat');

  -- Hobbyist allows 3 devices. The three above fill it, so another entity is refused.
  perform pg_temp.ha_assert(public.fizz_ha_sync(synced->>'api_key', jsonb_build_array(
    jsonb_build_object('entity_id', 'sensor.rack_temp', 'name', 'Rack temperature', 'device_class', 'temperature'),
    jsonb_build_object('entity_id', 'sensor.extra', 'name', 'Extra', 'device_class', 'humidity')
  ), null, null, false)->'skipped'->0->>'error' = 'device_limit', 'the plan limit stops a new entity');
  perform pg_temp.ha_assert(public.fizz_update_sensor(a.token, sensor, 'Renamed rack', null, null, true)->>'error' = 'invalid_request', 'connection sensors do not rotate a private key');
  perform pg_temp.ha_assert(public.fizz_update_sensor(a.token, sensor, 'Renamed rack')->'sensor'->>'name' = 'Renamed rack', 'the owner can rename the sensor');
  perform pg_temp.ha_assert(public.fizz_update_sensor(a.token, sensor, null, null, 'paused')->>'error' is null, 'the owner can pause it');
  perform pg_temp.ha_assert(public.fizz_ingest_event(sensor, synced->>'api_key', 'while-paused', now(), '{"temperature_c": 20}'::jsonb)->>'error' = 'paused', 'a paused sensor is not a revoked key');
  perform pg_temp.ha_assert(public.fizz_update_sensor(a.token, sensor, null, null, 'active')->>'error' is null, 'resume');

  kept := (select id from public.fizz_alert_rules where sensor_id = sensor and kind = 'silence');
  paused := (public.fizz_save_alert_rule(a.customer_id, sensor, 'threshold', 'temperature_c', 'gt', 80, '°C', 'none', null, null, false, null)->'rule'->>'id')::uuid;
  perform pg_temp.ha_assert(public.fizz_update_alert(a.token, paused, false, false)->>'rule' is not null, 'the owner turns one alert off');
  perform pg_temp.ha_assert(public.fizz_ha_sync(synced->>'api_key', jsonb_build_array(
    jsonb_build_object('entity_id', 'binary_sensor.closet_door', 'name', 'Closet door', 'device_class', 'door'),
    jsonb_build_object('entity_id', 'sensor.ups_power', 'name', 'UPS power', 'device_class', 'power')
  ), null, null, true)->>'shared' = '2', 'removing the entity soft-deletes its sensor');
  perform pg_temp.ha_assert((select not enabled and resume_enabled from public.fizz_alert_rules where id = kept), 'an active alert is suspended with the sensor');
  perform pg_temp.ha_assert((select not enabled and not resume_enabled from public.fizz_alert_rules where id = paused), 'an alert the owner turned off stays marked off');
  perform pg_temp.ha_assert(public.fizz_ha_sync(synced->>'api_key', jsonb_build_array(
    jsonb_build_object('entity_id', 'sensor.rack_temp', 'name', 'Rack temperature', 'device_class', 'temperature'),
    jsonb_build_object('entity_id', 'binary_sensor.closet_door', 'name', 'Closet door', 'device_class', 'door'),
    jsonb_build_object('entity_id', 'sensor.ups_power', 'name', 'UPS power', 'device_class', 'power')
  ), null, null, true)->'sensors'->0->>'sensor_id' = sensor::text, 'adding the entity back reuses its sensor');
  perform pg_temp.ha_assert((select enabled and resume_enabled is null and silence_due_at > now()
    from public.fizz_alert_rules where id = kept), 'the alert that was on comes back, with a fresh silence window');
  perform pg_temp.ha_assert((select not enabled from public.fizz_alert_rules where id = paused), 'the alert that was off stays off');

  perform pg_temp.ha_assert(public.fizz_ha_revoke(b.token, other)->>'error' = 'not_found', 'another account cannot revoke the connection');
  result := public.fizz_ha_sync(synced->>'api_key', jsonb_build_array(
    jsonb_build_object('entity_id', 'sensor.rack_temp', 'name', 'Rack temperature', 'device_class', 'temperature')
  ), null, null, true);
  perform pg_temp.ha_assert(jsonb_array_length(result->'sensors') = 1 and (result->>'shared')::int = 1, 'dropping an entity frees its device slot');
  perform pg_temp.ha_assert(public.fizz_ha_revoke_key(synced->>'api_key')->>'revoked' = 'true', 'the install can revoke itself');
  perform pg_temp.ha_assert(public.fizz_ingest_event(sensor, synced->>'api_key', 'after-revoke', now(), '{"temperature_c": 20}'::jsonb)->>'error' = 'unauthorized', 'a revoked key stops ingest');
  perform pg_temp.ha_assert((select count(*) from public.fizz_sensors where customer_id = a.customer_id and deleted_at is null and mode = 'api') = 0, 'revoking frees the device slots');
  perform pg_temp.ha_assert(public.fizz_ha_revoke_key(synced->>'api_key')->>'error' = 'unauthorized', 'the key cannot revoke twice');
end $$;
reset role;

select format('%s checks passed', count(*)) from ha_results;
rollback;
