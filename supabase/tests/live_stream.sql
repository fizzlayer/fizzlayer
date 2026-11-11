-- Stream grants and the live feed stay inside one workspace. Rolls back.
begin;
create temporary table live_results(label text);
create function pg_temp.live_assert(ok boolean, label text) returns void
language plpgsql as $$ begin
  if ok is distinct from true then raise exception 'Live stream assertion failed: %', label; end if;
  insert into pg_temp.live_results values(label);
end $$;

create temporary table live_ids as
select n, gen_random_uuid() auth_id, gen_random_uuid() customer_id,
  md5(gen_random_uuid()::text) || md5(gen_random_uuid()::text) token
from generate_series(1, 2) n;
insert into auth.users(id, email, encrypted_password, is_anonymous)
select auth_id, 'live-' || auth_id || '@example.invalid', 'hash', false from live_ids;
insert into public.fizz_customers(id, auth_user_id, username)
select customer_id, auth_id, 'live_' || left(replace(customer_id::text, '-', ''), 16) from live_ids;
insert into public.fizz_sessions(token_hash, customer_id, expires_at)
select extensions.digest(decode(token, 'hex'), 'sha256'), customer_id, now() + interval '1 hour' from live_ids;

grant execute on function pg_temp.live_assert(boolean, text) to service_role;
grant select on live_ids to service_role;
grant insert on live_results to service_role;
set local role service_role;

do $$
declare
  a record; b record;
  sensor_a uuid; sensor_b uuid; key_a text; key_b text;
  grant_a jsonb; workspace jsonb; agent jsonb; agent_token text;
  principal jsonb; feed jsonb; before timestamptz;
begin
  select * into a from pg_temp.live_ids where n = 1;
  select * into b from pg_temp.live_ids where n = 2;

  grant_a := public.fizz_create_sensor(a.token, 'temperature', 'Cold room', 'api');
  key_a := grant_a->>'api_key';
  sensor_a := (grant_a->'sensor'->>'id')::uuid;
  grant_a := public.fizz_create_sensor(b.token, 'temperature', 'Other room', 'api');
  key_b := grant_a->>'api_key';
  sensor_b := (grant_a->'sensor'->>'id')::uuid;
  perform pg_temp.live_assert(key_a ~ '^fizz_[0-9a-f]{64}$' and sensor_a is not null, 'api sensors exist');

  grant_a := public.fizz_stream_issue(a.token, sensor_a);
  perform pg_temp.live_assert(grant_a->>'token' ~ '^fizz_stream_[0-9a-f]{64}$', 'session issues a stream token');
  perform pg_temp.live_assert(public.fizz_stream_issue(a.token, sensor_b)->>'error' = 'not_found', 'cannot grant another workspace sensor');
  perform pg_temp.live_assert(public.fizz_stream_issue('nope', sensor_a)->>'error' = 'unauthorized', 'stream issue needs a session');

  principal := public.fizz_live_principal(grant_a->>'token', sensor_a);
  perform pg_temp.live_assert(principal->>'role' = 'viewer' and principal->>'can_publish' = 'false'
    and (principal->>'sensor_id')::uuid = sensor_a, 'stream token reads its sensor');
  perform pg_temp.live_assert(public.fizz_live_principal(grant_a->>'token', sensor_b)->>'error' = 'unauthorized', 'stream token cannot cross workspaces');

  workspace := public.fizz_stream_issue(a.token, null);
  perform pg_temp.live_assert(public.fizz_live_principal(workspace->>'token', sensor_a)->>'role' = 'viewer', 'workspace grant reads an owned sensor');
  perform pg_temp.live_assert(public.fizz_live_principal(workspace->>'token', null)->>'sensor_id' is null, 'workspace grant can name every owned sensor');
  perform pg_temp.live_assert(public.fizz_live_principal(workspace->>'token', sensor_b)->>'error' = 'unauthorized', 'workspace grant stops at the workspace');

  principal := public.fizz_live_principal(key_a, sensor_a);
  perform pg_temp.live_assert(principal->>'role' = 'device' and principal->>'can_publish' = 'true'
    and (principal->>'customer_id')::uuid = a.customer_id, 'sensor key is that device');
  perform pg_temp.live_assert(public.fizz_live_principal(key_a, sensor_b)->>'error' = 'unauthorized', 'sensor key does not open another sensor');
  perform pg_temp.live_assert(public.fizz_live_principal(key_b, sensor_a)->>'error' = 'unauthorized', 'the other key does not open this sensor');

  perform public.fizz_update_sensor(a.token, sensor_a, null, null, 'paused', false);
  perform pg_temp.live_assert(public.fizz_live_principal(key_a, sensor_a)->>'error' = 'paused', 'paused sensor cannot connect');
  perform public.fizz_update_sensor(a.token, sensor_a, null, null, 'active', false);

  -- expires_at must stay after created_at. Backdate both so the row is already expired.
  update public.fizz_stream_tokens
  set created_at = now() - interval '2 minutes',
      expires_at = now() - interval '1 minute'
  where token_hash = extensions.digest(grant_a->>'token', 'sha256');
  perform pg_temp.live_assert(public.fizz_live_principal(grant_a->>'token', sensor_a)->>'error' = 'unauthorized', 'expired stream token is refused');

  agent_token := 'fizz_agent_' || encode(extensions.gen_random_bytes(32), 'hex');
  insert into public.fizz_agent_connections(customer_id, name, token_hash, can_create_alerts)
  values (a.customer_id, 'desk', extensions.digest(agent_token, 'sha256'), false);
  agent := public.fizz_stream_issue_agent(agent_token, sensor_a);
  perform pg_temp.live_assert(agent->>'token' ~ '^fizz_stream_' and public.fizz_live_principal(agent_token, sensor_b)->>'error' = 'unauthorized', 'agent token is a viewer of its own workspace');
  perform pg_temp.live_assert(public.fizz_live_principal(agent_token, sensor_a)->>'role' = 'viewer', 'agent token can subscribe to its sensor');

  before := now() - interval '1 minute';
  perform pg_temp.live_assert(public.fizz_ingest_event(sensor_a, key_a, 'live-a', null, '{"temperature_c": 19.5}'::jsonb) ? 'accepted', 'https-shaped ingest still stores');
  perform pg_temp.live_assert(public.fizz_ingest_event(sensor_b, key_b, 'live-b', null, '{"temperature_c": 22}'::jsonb) ? 'accepted', 'the other workspace stores too');
  feed := public.fizz_live_since(before, null, 50);
  perform pg_temp.live_assert(
    (select count(*) from jsonb_array_elements(feed->'readings') row where (row->>'sensor_id')::uuid = sensor_a) >= 1
    and (select count(*) from jsonb_array_elements(feed->'readings') row where (row->>'sensor_id')::uuid = sensor_b) >= 1,
    'the service feed sees both workspaces so the worker can filter');
  perform pg_temp.live_assert(public.fizz_live_since(null, null, 10)->'readings' = '[]'::jsonb, 'a fresh cursor does not replay history');
end;
$$;

set local role anon;
do $$ begin
  perform public.fizz_live_since(null, null, 10);
  raise exception 'anon could read the live feed';
exception when insufficient_privilege then
  null;
end $$;

reset role;
insert into live_results values ('anon cannot read the live feed');
select label from live_results order by label;
rollback;
