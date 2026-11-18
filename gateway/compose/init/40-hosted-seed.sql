-- Local shared-fleet sample. Production does not load this file.
insert into auth.users (id, email, is_anonymous) values
  ('44444444-4444-4444-8444-444444444444', 'gateway-a@example.invalid', false),
  ('88888888-8888-4888-8888-888888888888', 'gateway-b@example.invalid', false);

insert into public.fizz_customers (id, username, auth_user_id) values
  ('33333333-3333-4333-8333-333333333333', 'gw_hosted_a', '44444444-4444-4444-8444-444444444444'),
  ('99999999-9999-4999-8999-999999999999', 'gw_hosted_b', '88888888-8888-4888-8888-888888888888');

insert into gateway.workspaces (id, customer_id) values
  ('11111111-1111-4111-8111-111111111111', '33333333-3333-4333-8333-333333333333'),
  ('66666666-6666-4666-8666-666666666666', '99999999-9999-4999-8999-999999999999');

insert into gateway.gateways (
  id, workspace_id, name, mode, public_url, listen_port, status, config_revision, ag_version, unreviewed_tools
) values
  (
    '22222222-2222-4222-8222-222222222222',
    '11111111-1111-4111-8111-111111111111',
    'alpha', 'shared',
    'http://agentgateway:3000/w/22222222-2222-4222-8222-222222222222/mcp',
    3000, 'active', 1, '1.7.0', 'show'
  ),
  (
    '33333333-3333-4333-8333-333333333333',
    '66666666-6666-4666-8666-666666666666',
    'beta', 'shared',
    'http://agentgateway:3000/w/33333333-3333-4333-8333-333333333333/mcp',
    3000, 'active', 1, '1.7.0', 'show'
  ),
  (
    '77777777-7777-4777-8777-777777777777',
    '11111111-1111-4111-8111-111111111111',
    'burst', 'shared',
    'http://agentgateway:3000/w/77777777-7777-4777-8777-777777777777/mcp',
    3000, 'active', 1, '1.7.0', 'show'
  );

insert into gateway.servers (id, gateway_id, name, transport, url_or_cmd, auth_kind) values
  (
    '55555555-5555-4555-8555-555555555555',
    '22222222-2222-4222-8222-222222222222',
    'sample', 'http', 'http://sample-mcp:8080/mcp', 'none'
  ),
  (
    '55555555-5555-4555-8555-555555555556',
    '33333333-3333-4333-8333-333333333333',
    'other', 'http', 'http://sample-b:8082/mcp', 'none'
  ),
  (
    '55555555-5555-4555-8555-555555555557',
    '77777777-7777-4777-8777-777777777777',
    'sample', 'http', 'http://sample-mcp:8080/mcp', 'none'
  );

insert into gateway.policies (gateway_id, server_id, tool_name, effect, notify_channel) values
  ('22222222-2222-4222-8222-222222222222', '55555555-5555-4555-8555-555555555555', 'ping', 'allow', 'log'),
  ('22222222-2222-4222-8222-222222222222', '55555555-5555-4555-8555-555555555555', 'admin_reset', 'deny', 'log'),
  ('33333333-3333-4333-8333-333333333333', '55555555-5555-4555-8555-555555555556', 'ping', 'deny', 'log'),
  ('77777777-7777-4777-8777-777777777777', '55555555-5555-4555-8555-555555555557', 'ping', 'allow', 'log');
