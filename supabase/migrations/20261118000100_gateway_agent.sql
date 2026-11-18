-- Last report from fizz-agent. The detail is a short scrubbed phrase, not a
-- credential and not a registration token. Applying this does not change
-- phone approval or notification behavior.

alter table gateway.gateways
  add column agent_revision bigint,
  add column agent_status text,
  add column agent_detail text,
  add column agent_reported_at timestamptz;

alter table gateway.gateways
  add constraint gateways_agent_revision_check
  check (agent_revision is null or agent_revision >= 0);

alter table gateway.gateways
  add constraint gateways_agent_status_check
  check (agent_status is null or agent_status in ('applied', 'rejected'));

alter table gateway.gateways
  add constraint gateways_agent_detail_check
  check (
    agent_detail is null
    or (
      char_length(agent_detail) between 1 and 300
      and agent_detail !~ '[[:cntrl:]]'
      and agent_detail !~* 'fizz_reg_'
      and agent_detail !~ 'eyJ'
      and position('Bearer ' in agent_detail) = 0
    )
  );

comment on column gateway.gateways.agent_status is
  'Last fizz-agent report: applied or rejected. Null until the agent has reported.';
comment on column gateway.gateways.agent_detail is
  'Scrubbed reason from fizz-agent. Not a registration token or upstream credential.';

create or replace function gateway.gateway_json(p_gateway uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id', g.id,
    'workspace_id', g.workspace_id,
    'name', g.name,
    'mode', g.mode,
    'region', g.region,
    'public_url', g.public_url,
    'listen_port', g.listen_port,
    'status', g.status,
    'config_revision', g.config_revision,
    'ag_version', g.ag_version,
    'unreviewed_tools', g.unreviewed_tools,
    'agent_revision', g.agent_revision,
    'agent_status', g.agent_status,
    'agent_detail', g.agent_detail,
    'agent_reported_at', g.agent_reported_at,
    'created_at', g.created_at
  )
  from gateway.gateways g
  where g.id = p_gateway;
$$;

create function gateway.ctl_agent_status(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hash text;
  v_limited jsonb;
  v_gateway uuid;
  v_status text;
  v_revision bigint;
  v_detail text;
begin
  v_hash := p_payload->>'token_hash';
  if v_hash is null or v_hash !~ '^[0-9a-f]{64}$' then
    return jsonb_build_object('error', 'not_found');
  end if;
  v_limited := gateway.rate('gateway_agent_status', v_hash, 30);
  if v_limited is not null then return v_limited; end if;
  select t.gateway_id into v_gateway
  from gateway.registration_tokens t
  where t.token_hash = decode(v_hash, 'hex') and t.revoked_at is null;
  if v_gateway is null then
    return jsonb_build_object('error', 'not_found');
  end if;
  v_status := p_payload->>'status';
  if v_status is null or v_status not in ('applied', 'rejected') then
    return jsonb_build_object('error', 'invalid_request');
  end if;
  begin
    v_revision := (p_payload->>'revision')::bigint;
  exception
    when invalid_text_representation or numeric_value_out_of_range then
      return jsonb_build_object('error', 'invalid_request');
  end;
  if v_revision is null or v_revision < 0 then
    return jsonb_build_object('error', 'invalid_request');
  end if;
  if p_payload ? 'detail'
    and jsonb_typeof(p_payload->'detail') <> 'null'
    and jsonb_typeof(p_payload->'detail') <> 'string' then
    return jsonb_build_object('error', 'invalid_request');
  end if;
  v_detail := p_payload->>'detail';
  if v_detail is not null and (
    char_length(v_detail) < 1
    or char_length(v_detail) > 300
    or v_detail ~ '[[:cntrl:]]'
    or v_detail ~* 'fizz_reg_'
    or v_detail ~ 'eyJ'
    or position('Bearer ' in v_detail) > 0
  ) then
    return jsonb_build_object('error', 'invalid_request');
  end if;
  update gateway.gateways
  set agent_revision = v_revision,
      agent_status = v_status,
      agent_detail = v_detail,
      agent_reported_at = now()
  where id = v_gateway;
  if not found then
    return jsonb_build_object('error', 'not_found');
  end if;
  return jsonb_build_object('ok', true);
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

revoke all on function gateway.ctl_agent_status(jsonb) from public, anon, authenticated;
grant execute on function gateway.ctl_agent_status(jsonb) to service_role;
