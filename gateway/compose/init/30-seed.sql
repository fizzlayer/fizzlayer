-- Local sample only. Production does not load this file.
insert into auth.users (id, email, is_anonymous)
values ('44444444-4444-4444-8444-444444444444', 'gateway-local@example.invalid', false);

insert into public.fizz_customers (id, username, auth_user_id)
values (
  '33333333-3333-4333-8333-333333333333',
  'gw_local_dev',
  '44444444-4444-4444-8444-444444444444'
);

insert into gateway.workspaces (id, customer_id)
values ('11111111-1111-4111-8111-111111111111', '33333333-3333-4333-8333-333333333333');

insert into gateway.gateways (
  id, workspace_id, name, mode, public_url, listen_port, status, config_revision, ag_version
) values (
  '22222222-2222-4222-8222-222222222222',
  '11111111-1111-4111-8111-111111111111',
  'local',
  'shared',
  'http://agentgateway:3000/mcp',
  3000,
  'active',
  1,
  '1.7.0'
);

update gateway.gateways
set unreviewed_tools = 'show'
where id = '22222222-2222-4222-8222-222222222222';

insert into gateway.servers (id, gateway_id, name, transport, url_or_cmd, auth_kind)
values (
  '55555555-5555-4555-8555-555555555555',
  '22222222-2222-4222-8222-222222222222',
  'sample',
  'http',
  'http://sample-mcp:8080/mcp',
  'none'
);

insert into gateway.policies (gateway_id, server_id, tool_name, effect, notify_channel) values
  ('22222222-2222-4222-8222-222222222222', '55555555-5555-4555-8555-555555555555', 'ping', 'allow', 'log'),
  ('22222222-2222-4222-8222-222222222222', '55555555-5555-4555-8555-555555555555', 'admin_reset', 'deny', 'log'),
  ('22222222-2222-4222-8222-222222222222', '55555555-5555-4555-8555-555555555555', 'move_funds', 'approve', 'phone'),
  ('22222222-2222-4222-8222-222222222222', '55555555-5555-4555-8555-555555555555', 'note', 'allow', 'log');
