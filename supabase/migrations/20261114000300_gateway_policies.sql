-- Tool-description pins, pin alerts, and the shared phone-call budget hook.
-- 20261114000400 is reserved for the control-plane API and is not used here.
--
-- gateway.tool_pins already exists. This adds the observation the guard compares
-- with the approved hash:
--   unreviewed  no one has approved this description; list visibility follows
--               gateway.gateways.unreviewed_tools (hide or show)
--   approved    pin_sha256 is the approved description and matches the last list
--   changed     the listed description differs from the approved hash; the tool
--               is removed from tools/list and tools/call is denied
-- A BEFORE trigger fills the new columns when an older insert omits them.

alter table gateway.gateways
  add column unreviewed_tools text not null default 'hide'
    check (unreviewed_tools in ('hide', 'show'));

comment on column gateway.gateways.unreviewed_tools is
  'hide removes an unreviewed tool from tools/list. show leaves it listed. tools/call stays denied until the pin is approved. A changed description is always removed.';

alter table gateway.tool_pins
  add column observed_sha256 text,
  add column status text;

update gateway.tool_pins
set observed_sha256 = pin_sha256,
    status = case when approved_at is null then 'unreviewed' else 'approved' end
where observed_sha256 is null or status is null;

create function gateway.tool_pins_fill()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.observed_sha256 is null then
    new.observed_sha256 := new.pin_sha256;
  end if;
  if new.status is null then
    if new.approved_at is null then
      new.status := 'unreviewed';
    elsif new.pin_sha256 = new.observed_sha256 then
      new.status := 'approved';
    else
      new.status := 'changed';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists tool_pins_fill on gateway.tool_pins;
create trigger tool_pins_fill
  before insert or update on gateway.tool_pins
  for each row execute function gateway.tool_pins_fill();

alter table gateway.tool_pins
  alter column observed_sha256 set not null,
  alter column status set not null;

alter table gateway.tool_pins
  add constraint tool_pins_observed_sha check (observed_sha256 ~ '^[0-9a-f]{64}$'),
  add constraint tool_pins_status check (status in ('unreviewed', 'approved', 'changed')),
  add constraint tool_pins_status_shape check (
    (status = 'unreviewed' and approved_at is null)
    or (status = 'approved' and approved_at is not null and pin_sha256 = observed_sha256)
    or (status = 'changed' and pin_sha256 <> observed_sha256)
  );

alter table gateway.policies
  add column notify_channel text not null default 'log'
    check (notify_channel in ('log', 'webhook', 'phone'));

alter table gateway.approvals
  add column args_preview text not null default '' check (char_length(args_preview) <= 120),
  add column notify_channel text not null default 'log'
    check (notify_channel in ('log', 'webhook', 'phone'));

comment on column gateway.approvals.args_preview is
  'Key names only. Argument values are not stored.';

create table gateway.pin_alerts (
  id uuid primary key default gen_random_uuid(),
  gateway_id uuid not null references gateway.gateways(id) on delete cascade,
  workspace_id uuid not null references gateway.workspaces(id) on delete cascade,
  server_id uuid not null references gateway.servers(id) on delete cascade,
  tool_name text not null check (tool_name ~ '^[A-Za-z0-9_.:-]{1,128}$'),
  approved_sha256 text check (approved_sha256 is null or approved_sha256 ~ '^[0-9a-f]{64}$'),
  observed_sha256 text not null check (observed_sha256 ~ '^[0-9a-f]{64}$'),
  description_preview text not null default '' check (char_length(description_preview) <= 200),
  kind text not null check (kind in ('changed')),
  created_at timestamptz not null default now(),
  acknowledged_at timestamptz
);
create index pin_alerts_open_idx
  on gateway.pin_alerts (server_id, tool_name)
  where acknowledged_at is null;

comment on table gateway.pin_alerts is
  'A listed tool description no longer matches the approved pin. description_preview is untrusted text from the MCP server, truncated.';

create table gateway.phone_calls (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references gateway.workspaces(id) on delete cascade,
  approval_id uuid references gateway.approvals(id) on delete set null,
  status text not null check (status in ('reserved', 'stubbed', 'skipped')),
  created_at timestamptz not null default now()
);
create index phone_calls_month_idx on gateway.phone_calls (workspace_id, created_at);

comment on table gateway.phone_calls is
  'Phone approval attempts. Only status=reserved counts toward the monthly cap. stubbed means the budget allowed a call but fizz-guard did not place one. skipped means the cap or the billing lookup blocked the call.';

-- Shared monthly cap for sensor phone alerts and gateway phone approvals.
-- Hobbyist 0, Tinkerer 20, Pro 100. Enterprise is unlimited. An unknown plan
-- gets no calls. If the billing tables are not in this database, the function
-- reports billing_unreachable and allowed=false so the guard does not dial.
create function gateway.phone_approval_budget(p_workspace uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_customer uuid;
  v_plan text;
  v_cap integer;
  v_alerts integer := 0;
  v_reserved integer := 0;
  v_used integer;
  v_month timestamptz;
begin
  select w.customer_id into v_customer
  from gateway.workspaces w
  where w.id = p_workspace;
  if v_customer is null then
    return jsonb_build_object(
      'reachable', false, 'allowed', false, 'reason', 'billing_unreachable'
    );
  end if;

  if to_regclass('public.fizz_subscriptions') is null
     or to_regclass('public.fizz_plans') is null
     or to_regclass('public.fizz_alert_events') is null then
    return jsonb_build_object(
      'reachable', false, 'allowed', false, 'reason', 'billing_unreachable'
    );
  end if;

  execute
    'select coalesce((select s.plan from public.fizz_subscriptions s where s.customer_id = $1), ''hobbyist'')'
    into v_plan using v_customer;

  v_cap := case v_plan
    when 'hobbyist' then 0
    when 'tinkerer' then 20
    when 'pro' then 100
    when 'enterprise' then null
    else 0
  end;

  v_month := date_trunc('month', now() at time zone 'utc') at time zone 'utc';

  execute
    'select count(*)::integer from public.fizz_alert_events e
      where e.customer_id = $1
        and e.notify_channel = ''call''
        and e.notify_status in (''pending'', ''sending'', ''sent'')
        and e.created_at >= $2'
    into v_alerts using v_customer, v_month;

  select count(*)::integer into v_reserved
  from gateway.phone_calls c
  where c.workspace_id = p_workspace
    and c.status = 'reserved'
    and c.created_at >= v_month;

  v_used := coalesce(v_alerts, 0) + coalesce(v_reserved, 0);
  if v_cap is null then
    return jsonb_build_object(
      'reachable', true,
      'allowed', true,
      'plan', v_plan,
      'cap', null,
      'used', v_used,
      'reason', 'unlimited'
    );
  end if;
  return jsonb_build_object(
    'reachable', true,
    'allowed', v_used < v_cap,
    'plan', v_plan,
    'cap', v_cap,
    'used', v_used,
    'reason', case when v_used < v_cap then 'ok' else 'cap_reached' end
  );
exception when others then
  return jsonb_build_object(
    'reachable', false, 'allowed', false, 'reason', 'billing_unreachable'
  );
end;
$$;

-- Live dialer hook. fizz-guard's phone stub does not call this: a stub must
-- not consume the cap. The real AgentPhone path should reserve first, and
-- only then place the call. reserved is the only status the budget counts.
create function gateway.reserve_phone_approval_call(p_workspace uuid, p_approval uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_budget jsonb;
begin
  if p_workspace is null or not exists (
    select 1 from gateway.workspaces w where w.id = p_workspace
  ) then
    return jsonb_build_object(
      'reachable', false, 'allowed', false, 'reason', 'billing_unreachable', 'recorded', 'skipped'
    );
  end if;
  v_budget := gateway.phone_approval_budget(p_workspace);
  if coalesce((v_budget ->> 'allowed')::boolean, false) then
    insert into gateway.phone_calls (workspace_id, approval_id, status)
    values (p_workspace, p_approval, 'reserved');
    return v_budget || jsonb_build_object('recorded', 'reserved');
  end if;
  insert into gateway.phone_calls (workspace_id, approval_id, status)
  values (p_workspace, p_approval, 'skipped');
  return v_budget || jsonb_build_object('recorded', 'skipped');
end;
$$;

revoke all on function gateway.tool_pins_fill() from public;
grant execute on function gateway.tool_pins_fill() to authenticated, service_role, gateway_runtime;

revoke all on function gateway.phone_approval_budget(uuid) from public;
grant execute on function gateway.phone_approval_budget(uuid) to gateway_runtime, service_role;

revoke all on function gateway.reserve_phone_approval_call(uuid, uuid) from public;
grant execute on function gateway.reserve_phone_approval_call(uuid, uuid) to gateway_runtime, service_role;

alter table gateway.pin_alerts enable row level security;
alter table gateway.phone_calls enable row level security;

create policy pin_alerts_owner_select on gateway.pin_alerts
  for select to authenticated
  using (
    exists (
      select 1 from gateway.workspaces w
      where w.id = workspace_id and gateway.owns_customer(w.customer_id)
    )
  );

create policy pin_alerts_owner_update on gateway.pin_alerts
  for update to authenticated
  using (
    exists (
      select 1 from gateway.workspaces w
      where w.id = workspace_id and gateway.owns_customer(w.customer_id)
    )
  )
  with check (
    exists (
      select 1 from gateway.workspaces w
      where w.id = workspace_id and gateway.owns_customer(w.customer_id)
    )
  );

create policy phone_calls_owner_select on gateway.phone_calls
  for select to authenticated
  using (
    exists (
      select 1 from gateway.workspaces w
      where w.id = workspace_id and gateway.owns_customer(w.customer_id)
    )
  );

create policy runtime_tool_pins on gateway.tool_pins
  for all to gateway_runtime using (true) with check (true);
create policy runtime_pin_alerts on gateway.pin_alerts
  for all to gateway_runtime using (true) with check (true);
create policy runtime_phone_calls on gateway.phone_calls
  for all to gateway_runtime using (true) with check (true);

revoke all on gateway.pin_alerts, gateway.phone_calls from public, anon, authenticated;
grant all on gateway.pin_alerts, gateway.phone_calls to service_role;
grant select, insert, update on gateway.tool_pins, gateway.pin_alerts to gateway_runtime;
grant select, insert on gateway.phone_calls to gateway_runtime;
