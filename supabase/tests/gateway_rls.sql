-- Gateway ownership policies. All fixtures roll back.
-- Run on a linked project:
--   supabase db query --linked --file supabase/tests/gateway_rls.sql
-- Local compose runs the same file against its Postgres stub.
begin;

create temporary table gw_ids as
select n,
  gen_random_uuid() auth_id,
  gen_random_uuid() customer_id,
  gen_random_uuid() workspace_id,
  gen_random_uuid() gateway_id,
  gen_random_uuid() server_id,
  gen_random_uuid() policy_id,
  gen_random_uuid() token_id,
  gen_random_uuid() approval_id,
  gen_random_uuid() audit_id,
  gen_random_uuid() secret_id
from generate_series(1, 2) n;

insert into auth.users(id, email, encrypted_password, is_anonymous)
select auth_id, 'gw-' || auth_id || '@example.invalid', 'not-a-password', false from gw_ids;

insert into public.fizz_customers(id, username, auth_user_id)
select customer_id, 'gw_' || left(replace(customer_id::text, '-', ''), 16), auth_id from gw_ids;

insert into gateway.workspaces(id, customer_id)
select workspace_id, customer_id from gw_ids;

insert into gateway.gateways(id, workspace_id, name, mode, public_url)
select gateway_id, workspace_id, 'gw' || n::text, 'shared', 'https://gw.example.invalid/mcp' from gw_ids;

insert into gateway.servers(id, gateway_id, name, transport, url_or_cmd)
select server_id, gateway_id, 'sample', 'http', 'https://mcp.example.invalid/mcp' from gw_ids;

insert into gateway.policies(id, gateway_id, server_id, tool_name, effect)
select policy_id, gateway_id, server_id, 'ping', 'allow' from gw_ids;

insert into gateway.tool_pins(server_id, tool_name, pin_sha256)
select server_id, 'ping', repeat('ab', 32) from gw_ids;

insert into gateway.client_tokens(id, gateway_id, user_id, name, jti, expires_at)
select token_id, gateway_id, auth_id, 'laptop', gen_random_uuid()::text, now() + interval '1 day' from gw_ids;

insert into gateway.approvals(
  id, gateway_id, workspace_id, server_name, tool_name, args_hash, status, expires_at
)
select approval_id, gateway_id, workspace_id, 'sample', 'move_funds', repeat('cd', 32), 'pending', now() + interval '10 minutes'
from gw_ids;

insert into gateway.audit_log(
  id, gateway_id, workspace_id, server_name, tool_name, args_hash, decision
)
select audit_id, gateway_id, workspace_id, 'sample', 'admin_reset', repeat('ef', 32), 'deny' from gw_ids;

insert into gateway.secrets(id, server_id, ciphertext, key_id)
select secret_id, server_id, decode('00', 'hex'), 'local' from gw_ids;

insert into gateway.usage_daily(gateway_id, usage_date, tool_calls)
select gateway_id, current_date, 1 from gw_ids;

insert into gateway.pin_alerts(
  gateway_id, workspace_id, server_id, tool_name, approved_sha256, observed_sha256,
  description_preview, kind
)
select gateway_id, workspace_id, server_id, 'note', repeat('ab', 32), repeat('cd', 32),
  'Leave a note.', 'changed'
from gw_ids;

insert into gateway.phone_calls(workspace_id, approval_id, status)
select workspace_id, approval_id, 'skipped' from gw_ids;

grant select on gw_ids to authenticated, anon, gateway_runtime;
grant select, insert, update, delete on
  gateway.workspaces, gateway.gateways, gateway.servers, gateway.policies, gateway.tool_pins,
  gateway.client_tokens, gateway.approvals, gateway.audit_log, gateway.usage_daily, gateway.secrets,
  gateway.pin_alerts, gateway.phone_calls
  to authenticated, anon;

create temporary table gw_results(label text);
create function pg_temp.gw_assert(ok boolean, label text) returns void
language plpgsql as $$
begin
  if ok is distinct from true then
    raise exception 'gateway assertion failed: %', label;
  end if;
  insert into pg_temp.gw_results values (label);
end
$$;

create function pg_temp.gw_denied(sql text, label text) returns void
language plpgsql as $$
begin
  begin
    execute sql;
  exception when insufficient_privilege then
    insert into pg_temp.gw_results values (label);
    return;
  end;
  raise exception '%: statement unexpectedly allowed', label;
end
$$;

grant insert on gw_results to authenticated, anon, gateway_runtime;
grant execute on function pg_temp.gw_assert(boolean, text), pg_temp.gw_denied(text, text) to authenticated, anon, gateway_runtime;

set local role authenticated;
select set_config('request.jwt.claims', jsonb_build_object('sub', auth_id, 'role', 'authenticated', 'is_anonymous', false)::text, true),
  set_config('request.jwt.claim.sub', auth_id::text, true)
from gw_ids where n = 1;

do $$
declare
  own_gateway uuid;
  foreign_gateway uuid;
  own_workspace uuid;
  foreign_workspace uuid;
  own_approval uuid;
  own_server uuid;
begin
  select gateway_id, workspace_id, approval_id, server_id
    into own_gateway, own_workspace, own_approval, own_server
  from gw_ids where n = 1;
  select gateway_id, workspace_id into foreign_gateway, foreign_workspace from gw_ids where n = 2;

  perform pg_temp.gw_assert((select count(*) from gateway.gateways) = 1, 'select own gateway');
  perform pg_temp.gw_assert((select count(*) from gateway.workspaces) = 1, 'select own workspace');
  perform pg_temp.gw_assert((select count(*) from gateway.servers) = 1, 'select own server');
  perform pg_temp.gw_assert((select count(*) from gateway.policies) = 1, 'select own policy');
  perform pg_temp.gw_assert((select count(*) from gateway.audit_log) = 1, 'select own audit');
  perform pg_temp.gw_assert((select count(*) from gateway.approvals) = 1, 'select own approval');
  perform pg_temp.gw_assert((select count(*) from gateway.client_tokens) = 1, 'select own token');
  perform pg_temp.gw_assert((select count(*) from gateway.usage_daily) = 1, 'select own usage');
  perform pg_temp.gw_assert((select count(*) from gateway.tool_pins) = 1, 'select own pin');
  perform pg_temp.gw_assert((select count(*) from gateway.pin_alerts) = 1, 'select own pin alert');
  perform pg_temp.gw_assert((select count(*) from gateway.phone_calls) = 1, 'select own phone attempt');
  perform pg_temp.gw_assert((select count(*) from gateway.secrets) = 0, 'secrets stay hidden');
  perform pg_temp.gw_assert(
    (select count(*) from gateway.gateways where id = foreign_gateway) = 0,
    'hide foreign gateway'
  );

  update gateway.approvals set status = 'approved' where id = own_approval;
  perform pg_temp.gw_assert(
    (select status from gateway.approvals where id = own_approval) = 'approved',
    'owner can approve'
  );

  perform pg_temp.gw_denied(format(
    'update gateway.gateways set workspace_id = %L where id = %L',
    foreign_workspace, own_gateway
  ), 'cannot move gateway to another workspace');

  perform pg_temp.gw_denied(format(
    'insert into gateway.audit_log (gateway_id, workspace_id, server_name, tool_name, args_hash, decision)
     values (%L, %L, ''sample'', ''ping'', repeat(''ab'', 32), ''allow'')',
    own_gateway, own_workspace
  ), 'owner cannot insert audit');

  perform pg_temp.gw_denied(format(
    'insert into gateway.servers (gateway_id, name, transport, url_or_cmd)
     values (%L, ''other'', ''http'', ''https://other.example.invalid/mcp'')',
    foreign_gateway
  ), 'cannot attach a server to a foreign gateway');

  delete from gateway.servers where id = own_server;
  perform pg_temp.gw_assert(found, 'delete own server');
end
$$;

-- Anonymous sign-in uses the authenticated role and must see nothing.
select set_config('request.jwt.claims', jsonb_build_object('sub', auth_id, 'is_anonymous', true)::text, true)
from gw_ids where n = 1;
do $$
begin
  perform pg_temp.gw_assert((select count(*) from gateway.gateways) = 0, 'anonymous sees no gateways');
  perform pg_temp.gw_assert((select count(*) from gateway.audit_log) = 0, 'anonymous sees no audit');
  perform pg_temp.gw_assert((select count(*) from gateway.pin_alerts) = 0, 'anonymous sees no pin alerts');
  perform pg_temp.gw_assert((select count(*) from gateway.phone_calls) = 0, 'anonymous sees no phone attempts');
end
$$;

set local role anon;
select set_config('request.jwt.claims', jsonb_build_object('sub', auth_id, 'is_anonymous', false)::text, true),
  set_config('request.jwt.claim.sub', auth_id::text, true)
from gw_ids where n = 1;
do $$
begin
  perform pg_temp.gw_assert((select count(*) from gateway.gateways) = 0, 'anon role sees no gateways');
  perform pg_temp.gw_assert((select count(*) from gateway.audit_log) = 0, 'anon role sees no audit');
end
$$;

reset role;
set local role gateway_runtime;
do $$
declare own_gateway uuid; own_workspace uuid;
begin
  select gateway_id, workspace_id into own_gateway, own_workspace from gw_ids where n = 1;
  insert into gateway.audit_log (gateway_id, workspace_id, server_name, tool_name, args_hash, decision, args_preview)
  values (own_gateway, own_workspace, 'sample', 'admin_reset', repeat('11', 32), 'deny', 'keys:');
  perform pg_temp.gw_assert(true, 'runtime inserted audit');

  perform pg_temp.gw_assert(
    (gateway.phone_approval_budget(own_workspace) ->> 'allowed')::boolean is false,
    'fixture without a paid plan cannot place a phone approval'
  );
  perform pg_temp.gw_assert(
    gateway.phone_approval_budget(own_workspace) ? 'reachable',
    'phone budget returns a document'
  );
end
$$;

reset role;
set local role authenticated;
select set_config('request.jwt.claims', jsonb_build_object('sub', auth_id, 'is_anonymous', false)::text, true),
  set_config('request.jwt.claim.sub', auth_id::text, true)
from gw_ids where n = 1;
do $$
begin
  perform pg_temp.gw_assert((select count(*) from gateway.audit_log where tool_name = 'admin_reset') = 2, 'owner sees runtime audit');
end
$$;

select set_config('request.jwt.claims', jsonb_build_object('sub', auth_id, 'is_anonymous', false)::text, true),
  set_config('request.jwt.claim.sub', auth_id::text, true)
from gw_ids where n = 2;
do $$
begin
  perform pg_temp.gw_assert((select count(*) from gateway.audit_log) = 1, 'other owner does not see the new audit');
  perform pg_temp.gw_assert((select count(*) from gateway.pin_alerts) = 1, 'other owner does not see the foreign pin alert');
end
$$;

reset role;
select count(*) as passed_assertions, 'gateway RLS' as coverage from gw_results;
rollback;
