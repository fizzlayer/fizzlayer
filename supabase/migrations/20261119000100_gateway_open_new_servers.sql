-- Servers added from now on are open by default, and the API can list a
-- server's tools as soon as it is added.
--
-- ctl_add_server also writes an allow rule for '*' on the new server. Together
-- with gateway.servers.trust_new_tools (previous migration), its tools are
-- listed and callable without a review step. Rules and pins still apply: the
-- owner can narrow the default rule, and a changed description is still held.
--
-- ctl_server_source returns what the API needs to call the server's
-- tools/list itself: URL, transport, auth kind, and the encrypted key. The
-- browser cannot make that call: the CSP limits connect-src to this origin,
-- and the key never leaves the server.

create or replace function gateway.server_json(p_server uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id', s.id,
    'gateway_id', s.gateway_id,
    'name', s.name,
    'transport', s.transport,
    'url', s.url_or_cmd,
    'args', to_jsonb(s.command_args),
    'auth_kind', s.auth_kind,
    'has_secret', exists (select 1 from gateway.secrets c where c.server_id = s.id),
    'enabled', s.enabled,
    'trust_new_tools', s.trust_new_tools,
    'created_at', s.created_at
  )
  from gateway.servers s
  where s.id = p_server;
$$;

create or replace function gateway.ctl_add_server(p_user uuid, p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_access jsonb;
  v_id uuid;
  v_workspace uuid;
  v_mode text;
  v_name text;
  v_transport text;
  v_url text;
  v_args text[];
  v_auth text;
  v_cipher text;
  v_key text;
  v_stdio boolean;
  v_limit integer;
  v_count integer;
  v_server uuid;
begin
  v_access := gateway.rate('gateway_write', p_user::text, 60);
  if v_access is not null then return v_access; end if;
  v_id := (p_payload->>'gateway_id')::uuid;
  v_access := gateway.access(p_user, v_id, true);
  if v_access ? 'error' then return v_access; end if;
  v_workspace := (v_access->>'workspace_id')::uuid;
  select g.mode into v_mode from gateway.gateways g where g.id = v_id;
  v_name := p_payload->>'name';
  v_transport := coalesce(p_payload->>'transport', 'http');
  v_url := p_payload->>'url';
  v_auth := coalesce(p_payload->>'auth_kind', 'none');
  v_cipher := nullif(p_payload->>'ciphertext', '');
  v_key := nullif(p_payload->>'key_id', '');
  select coalesce(array_agg(elem), '{}') into v_args
  from jsonb_array_elements_text(coalesce(p_payload->'args', '[]'::jsonb)) elem;
  if v_name is null or v_name !~ '^[a-z][a-z0-9_-]{0,40}$'
    or v_transport not in ('http', 'sse', 'stdio')
    or v_auth not in ('none', 'key', 'passthrough')
    or v_url is null or char_length(v_url) < 1 or char_length(v_url) > 500 or v_url ~ '[[:cntrl:]]'
    or cardinality(v_args) > 32
    or exists (
      select 1 from unnest(v_args) arg
      where char_length(arg) > 200 or arg ~ '[[:cntrl:]]'
    ) then
    return jsonb_build_object('error', 'invalid_request');
  end if;
  if v_transport in ('http', 'sse')
    and (v_url !~ '^https?://[^[:space:]@]+$' or char_length(v_url) < 8) then
    return jsonb_build_object('error', 'invalid_request');
  end if;
  if v_transport = 'stdio' and v_url ~ '[[:space:]]' then
    return jsonb_build_object('error', 'invalid_request');
  end if;
  if v_auth = 'key' and (v_cipher is null or v_key is null or v_key <> 'v1') then
    return jsonb_build_object('error', 'invalid_request');
  end if;
  if v_auth <> 'key' and v_cipher is not null then
    return jsonb_build_object('error', 'invalid_request');
  end if;
  select pl.gateway_stdio, pl.mcp_server_limit into v_stdio, v_limit
  from gateway.limits(v_workspace) pl;
  if v_transport = 'stdio' and not coalesce(v_stdio, false) then
    return jsonb_build_object('error', 'stdio_not_included');
  end if;
  if v_transport = 'stdio' and v_mode = 'shared' then
    return jsonb_build_object('error', 'stdio_shared');
  end if;
  select count(*) into v_count from gateway.servers where gateway_id = v_id;
  if v_limit is not null and v_count >= v_limit then
    return jsonb_build_object('error', 'server_limit');
  end if;
  v_server := gen_random_uuid();
  insert into gateway.servers (id, gateway_id, name, transport, url_or_cmd, command_args, auth_kind)
  values (v_server, v_id, v_name, v_transport, v_url, v_args, v_auth);
  if v_auth = 'key' then
    insert into gateway.secrets (server_id, ciphertext, key_id)
    values (v_server, decode(v_cipher, 'base64'), v_key);
  end if;
  -- A new server starts open: every tool on it is allowed until a narrower
  -- rule says otherwise. The owner can change this default rule like any other.
  insert into gateway.policies (gateway_id, server_id, tool_name, effect, notify_channel)
  values (v_id, v_server, '*', 'allow', 'log');
  perform gateway.touch(v_id);
  return jsonb_build_object('server', gateway.server_json(v_server));
end;
$$;

create function gateway.ctl_server_source(p_user uuid, p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_access jsonb;
  v_id uuid;
  v_server uuid;
  v_row record;
begin
  v_access := gateway.rate('gateway_probe', p_user::text, 30);
  if v_access is not null then return v_access; end if;
  v_id := (p_payload->>'gateway_id')::uuid;
  v_server := (p_payload->>'server_id')::uuid;
  -- Write access: the answer carries the encrypted upstream key, which the API
  -- decrypts to list the server's tools. It is never sent to the browser.
  v_access := gateway.access(p_user, v_id, true);
  if v_access ? 'error' then return v_access; end if;
  select s.name, s.transport, s.url_or_cmd, s.auth_kind,
         encode(c.ciphertext, 'base64') as ciphertext, c.key_id
    into v_row
  from gateway.servers s
  left join lateral (
    select x.ciphertext, x.key_id from gateway.secrets x
    where x.server_id = s.id order by x.created_at desc limit 1
  ) c on true
  where s.id = v_server and s.gateway_id = v_id;
  if not found then
    return jsonb_build_object('error', 'not_found');
  end if;
  return jsonb_build_object(
    'name', v_row.name,
    'transport', v_row.transport,
    'url', v_row.url_or_cmd,
    'auth_kind', v_row.auth_kind,
    'ciphertext', v_row.ciphertext,
    'key_id', v_row.key_id
  );
end;
$$;

create or replace function public.fizz_gateway(p_user uuid, p_action text, p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_payload jsonb := coalesce(p_payload, '{}'::jsonb);
begin
  if jsonb_typeof(v_payload) <> 'object' or p_action is null then
    return jsonb_build_object('error', 'invalid_request');
  end if;
  case p_action
    when 'context' then return gateway.ctl_context(p_user);
    when 'create_gateway' then return gateway.ctl_create(p_user, v_payload);
    when 'delete_gateway' then return gateway.ctl_delete(p_user, v_payload);
    when 'list_servers' then return gateway.ctl_servers(p_user, v_payload);
    when 'add_server' then return gateway.ctl_add_server(p_user, v_payload);
    when 'server_source' then return gateway.ctl_server_source(p_user, v_payload);
    when 'remove_server' then return gateway.ctl_remove_server(p_user, v_payload);
    when 'list_policies' then return gateway.ctl_policies(p_user, v_payload);
    when 'set_policy' then return gateway.ctl_set_policy(p_user, v_payload);
    when 'delete_policy' then return gateway.ctl_delete_policy(p_user, v_payload);
    when 'set_unreviewed' then return gateway.ctl_unreviewed(p_user, v_payload);
    when 'list_pins' then return gateway.ctl_pins(p_user, v_payload);
    when 'approve_pin' then return gateway.ctl_approve_pin(p_user, v_payload);
    when 'list_pin_alerts' then return gateway.ctl_pin_alerts(p_user, v_payload);
    when 'ack_pin_alert' then return gateway.ctl_ack_alert(p_user, v_payload);
    when 'list_approvals' then return gateway.ctl_approvals(p_user, v_payload);
    when 'decide_approval' then return gateway.ctl_decide_approval(p_user, v_payload);
    when 'render_source' then return gateway.ctl_render(p_user, v_payload);
    when 'agent_config' then return gateway.ctl_agent(v_payload);
    when 'agent_status' then return gateway.ctl_agent_status(v_payload);
    when 'fleet_config' then return gateway.ctl_fleet(v_payload);
    when 'fleet_status' then return gateway.ctl_fleet_status(v_payload);
    when 'insert_token' then return gateway.ctl_insert_token(p_user, v_payload);
    when 'list_tokens' then return gateway.ctl_tokens(p_user, v_payload);
    when 'revoke_token' then return gateway.ctl_revoke_token(p_user, v_payload);
    when 'rotate_registration' then return gateway.ctl_rotate(p_user, v_payload);
    else return jsonb_build_object('error', 'invalid_request');
  end case;
exception
  when unique_violation then
    return jsonb_build_object('error', 'conflict');
  when check_violation or not_null_violation or invalid_text_representation or invalid_parameter_value then
    return jsonb_build_object('error', 'invalid_request');
end;
$$;

revoke all on function public.fizz_gateway(uuid, text, jsonb) from public, anon, authenticated;
grant execute on function public.fizz_gateway(uuid, text, jsonb) to service_role;

revoke all on function
  gateway.server_json(uuid),
  gateway.ctl_add_server(uuid, jsonb),
  gateway.ctl_server_source(uuid, jsonb)
from public, anon, authenticated;
