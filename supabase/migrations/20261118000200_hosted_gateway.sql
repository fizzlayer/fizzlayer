-- Hosted shared fleet. One agentgateway process serves every active shared
-- gateway. The control plane renders that document for a fleet token held
-- outside the database. This file does not store the token.
--
-- Audit rows older than the plan's retention are deleted by
-- public.fizz_purge_gateway_audit. usage_daily is kept: later Stripe metering
-- reads it. Enterprise (null retention) is not purged.

create table gateway.hosted_fleet (
  id boolean primary key default true check (id),
  revision bigint not null default 1 check (revision >= 1),
  agent_revision bigint,
  agent_status text,
  agent_detail text,
  agent_reported_at timestamptz,
  updated_at timestamptz not null default now(),
  constraint hosted_fleet_agent_revision_check
    check (agent_revision is null or agent_revision >= 0),
  constraint hosted_fleet_agent_status_check
    check (agent_status is null or agent_status in ('applied', 'rejected')),
  constraint hosted_fleet_agent_detail_check
    check (
      agent_detail is null
      or (
        char_length(agent_detail) between 1 and 300
        and agent_detail !~ '[[:cntrl:]]'
        and agent_detail !~* 'fizz_reg_'
        and agent_detail !~* 'fizz_fleet_'
        and agent_detail !~ 'eyJ'
        and position('Bearer ' in agent_detail) = 0
      )
    )
);

insert into gateway.hosted_fleet (id) values (true);

comment on table gateway.hosted_fleet is
  'Revision of the shared fleet document. The fleet token is an environment variable, not a row.';

create function gateway.note_hosted_fleet()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update gateway.hosted_fleet
  set revision = revision + 1, updated_at = now()
  where id;
  return null;
end;
$$;

create trigger gateways_hosted_fleet
after insert or update or delete on gateway.gateways
for each statement execute function gateway.note_hosted_fleet();

create trigger servers_hosted_fleet
after insert or update or delete on gateway.servers
for each statement execute function gateway.note_hosted_fleet();

create trigger secrets_hosted_fleet
after insert or update or delete on gateway.secrets
for each statement execute function gateway.note_hosted_fleet();

-- Operational request budget for one shared proxy process. Not a price change.
-- Hobbyist 30/min, Tinkerer 120, Pro 240, Enterprise 600.
-- Keep aligned with src/gateway/limits.rs shared_rpm.
create function gateway.shared_rpm(p_workspace uuid)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select case p.id
    when 'tinkerer' then 120
    when 'pro' then 240
    when 'enterprise' then 600
    else 30
  end
  from gateway.limits(p_workspace) p;
$$;

create function gateway.ctl_fleet(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_limited jsonb;
  v_revision bigint;
  v_rows jsonb;
begin
  v_limited := gateway.rate('gateway_fleet', 'hosted', 30);
  if v_limited is not null then return v_limited; end if;
  select f.revision into v_revision from gateway.hosted_fleet f where f.id;
  select coalesce(jsonb_agg(jsonb_build_object(
    'gateway_id', g.id,
    'workspace_id', g.workspace_id,
    'mode', g.mode,
    'public_url', g.public_url,
    'listen_port', g.listen_port,
    'config_revision', g.config_revision,
    'ag_version', g.ag_version,
    'status', g.status,
    'requests_per_minute', coalesce(gateway.shared_rpm(g.workspace_id), 30),
    'servers', gateway.enabled_servers(g.id, true)
  ) order by g.id), '[]'::jsonb)
  into v_rows
  from gateway.gateways g
  where g.mode = 'shared'
    and g.status = 'active'
    and not exists (
      select 1 from gateway.servers s
      where s.gateway_id = g.id and s.enabled and s.transport = 'stdio'
    );
  return jsonb_build_object('revision', v_revision, 'gateways', v_rows);
end;
$$;

create function gateway.ctl_fleet_status(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_status text;
  v_revision bigint;
  v_detail text;
begin
  v_status := p_payload->>'status';
  v_revision := (p_payload->>'revision')::bigint;
  v_detail := nullif(p_payload->>'detail', '');
  if v_status is null or v_status not in ('applied', 'rejected')
    or v_revision is null or v_revision < 0 then
    return jsonb_build_object('error', 'invalid_request');
  end if;
  if v_detail is not null and (
    char_length(v_detail) > 300
    or v_detail ~ '[[:cntrl:]]'
    or v_detail ~* 'fizz_reg_'
    or v_detail ~* 'fizz_fleet_'
    or v_detail ~ 'eyJ'
    or position('Bearer ' in v_detail) > 0
  ) then
    return jsonb_build_object('error', 'invalid_request');
  end if;
  update gateway.hosted_fleet
  set agent_revision = v_revision,
      agent_status = v_status,
      agent_detail = v_detail,
      agent_reported_at = now()
  where id;
  return jsonb_build_object('ok', true);
end;
$$;

-- Counts tool calls the guard has already recorded this UTC month.
create function gateway.tool_quota(p_gateway uuid)
returns table (allowed boolean, used integer, cap integer)
language sql
stable
security definer
set search_path = ''
as $$
  select
    (p.tool_calls_per_month is null or coalesce(u.used, 0) < p.tool_calls_per_month),
    coalesce(u.used, 0)::integer,
    p.tool_calls_per_month
  from gateway.gateways g
  join gateway.workspaces w on w.id = g.workspace_id
  join lateral public.fizz_customer_plan(w.customer_id) p on true
  left join lateral (
    select sum(d.tool_calls)::integer as used
    from gateway.usage_daily d
    where d.gateway_id = g.id
      and d.usage_date >= (date_trunc('month', now() at time zone 'utc'))::date
      and d.usage_date < (date_trunc('month', now() at time zone 'utc') + interval '1 month')::date
  ) u on true
  where g.id = p_gateway and g.status = 'active';
$$;

alter table gateway.audit_log drop constraint audit_log_decision_check;
alter table gateway.audit_log add constraint audit_log_decision_check
  check (decision in ('allow', 'deny', 'approval_required', 'approval_consumed', 'quota'));

create function gateway.purge_audit()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_deleted integer;
begin
  with doomed as (
    select a.id
    from gateway.audit_log a
    join gateway.gateways g on g.id = a.gateway_id
    join gateway.workspaces w on w.id = g.workspace_id
    join lateral public.fizz_customer_plan(w.customer_id) p on true
    where p.audit_retention_days is not null
      and a.created_at < now() - make_interval(days => p.audit_retention_days)
  ),
  removed as (
    delete from gateway.audit_log a
    using doomed
    where a.id = doomed.id
    returning a.id
  )
  select count(*)::integer into v_deleted from removed;
  return jsonb_build_object('deleted', coalesce(v_deleted, 0));
end;
$$;

comment on function gateway.purge_audit() is
  'Deletes audit rows older than the plan retention. Does not delete usage_daily.';

create function public.fizz_purge_gateway_audit()
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select gateway.purge_audit();
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

revoke all on function
  gateway.note_hosted_fleet(),
  gateway.shared_rpm(uuid),
  gateway.ctl_fleet(jsonb),
  gateway.ctl_fleet_status(jsonb),
  gateway.purge_audit(),
  public.fizz_purge_gateway_audit()
from public, anon, authenticated;

grant execute on function gateway.note_hosted_fleet() to service_role;
grant execute on function gateway.shared_rpm(uuid) to service_role;
grant execute on function gateway.ctl_fleet(jsonb) to service_role;
grant execute on function gateway.ctl_fleet_status(jsonb) to service_role;
grant execute on function gateway.tool_quota(uuid) to service_role, gateway_runtime;
grant execute on function gateway.purge_audit() to service_role;
grant execute on function public.fizz_purge_gateway_audit() to service_role;

alter table gateway.hosted_fleet enable row level security;
revoke all on gateway.hosted_fleet from public, anon, authenticated;

comment on function gateway.tool_quota(uuid) is
  'True when this UTC month is still under the plan tool-call cap. Null cap means unlimited.';
