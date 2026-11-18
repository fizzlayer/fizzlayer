-- Real phone approvals and the shared monthly call cap.
--
-- Sensor phone alerts and gateway phone approvals share one cap per account:
-- Hobbyist 0, Tinkerer 20, Pro 100, Enterprise unlimited unless the subscription
-- sets monthly_call_cap. The cap resets on the first of each UTC month.
-- Pairing calls are not counted.
--
-- gateway.reserve_phone_approval_call takes the account lock, then inserts
-- status=reserved (the only approval status the cap counts) before any dial.
-- A missing paired number or a full cap inserts skipped and does not count.
-- fizz-guard returns after that insert. /api/cron dials the queued row with the
-- same AgentPhone client sensor alerts use.
--
-- AgentPhone's create-call API cannot collect a callee keypress (its digits
-- field sends tones). The spoken call tells the owner to approve in the app.
-- gateway.apply_phone_keypress still updates gateway.approvals the same way
-- the API decision does, for a digit 1 (approve) or 2 (deny).
--
-- 20261118000100 is reserved for the gateway config pull and is not used here.

-- Plan defaults. Null means unlimited. A subscription override, when the column
-- exists, replaces the plan value (including an Enterprise contract).
do $$
begin
  if to_regclass('public.fizz_plans') is not null
     and not exists (
       select 1 from information_schema.columns
       where table_schema = 'public' and table_name = 'fizz_plans'
         and column_name = 'monthly_call_cap'
     ) then
    alter table public.fizz_plans
      add column monthly_call_cap integer check (monthly_call_cap is null or monthly_call_cap >= 0);
    update public.fizz_plans set monthly_call_cap = case id
      when 'hobbyist' then 0
      when 'tinkerer' then 20
      when 'pro' then 100
      else null
    end;
  end if;
  if to_regclass('public.fizz_subscriptions') is not null
     and not exists (
       select 1 from information_schema.columns
       where table_schema = 'public' and table_name = 'fizz_subscriptions'
         and column_name = 'monthly_call_cap'
     ) then
    alter table public.fizz_subscriptions
      add column monthly_call_cap integer check (monthly_call_cap is null or monthly_call_cap >= 0);
    comment on column public.fizz_subscriptions.monthly_call_cap is
      'Per-contract shared monthly call cap. Null uses the plan default. Enterprise stays unlimited when this is null.';
  end if;
end $$;

alter table gateway.phone_calls
  add column phone text,
  add column dial_status text,
  add column provider_call_id text,
  add column claimed_at timestamptz;

alter table gateway.phone_calls
  add constraint phone_calls_phone_check
    check (phone is null or phone ~ '^\+1[2-9][0-9]{2}[2-9][0-9]{6}$'),
  add constraint phone_calls_dial_status_check
    check (dial_status is null or dial_status in ('queued', 'dialing', 'placed', 'failed')),
  add constraint phone_calls_provider_id_check
    check (provider_call_id is null or (
      char_length(provider_call_id) between 1 and 80
      and provider_call_id !~ '[[:space:][:cntrl:]]'
    )),
  add constraint phone_calls_queue_shape_check check (
    (status = 'reserved' and phone is not null and dial_status in ('queued', 'dialing', 'placed', 'failed'))
    or (status in ('stubbed', 'skipped') and phone is null and dial_status is null and provider_call_id is null)
  );

create index phone_calls_queue_idx on gateway.phone_calls (created_at)
  where status = 'reserved' and dial_status = 'queued';

comment on table gateway.phone_calls is
  'Phone approval attempts. status=reserved counts toward the shared monthly cap and was inserted before the dial. dial_status tracks the AgentPhone queue. skipped does not count. stubbed is a historical row from the notifier stub.';

comment on column gateway.phone_calls.phone is
  'The owner paired number this attempt will call. Only the dialer reads it.';

-- Shared cap. Null means unlimited. 0 means no calls. Missing billing tables
-- return 0 so a caller that did not check reachability fails closed.
create function public.fizz_monthly_call_cap(p_customer uuid)
returns integer
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_plan text := 'hobbyist';
  v_override integer;
  v_cap integer;
  v_allowed boolean;
begin
  if p_customer is null
     or to_regclass('public.fizz_subscriptions') is null
     or to_regclass('public.fizz_plans') is null then
    return 0;
  end if;
  if to_regprocedure('public.fizz_calls_allowed(uuid)') is not null then
    execute 'select public.fizz_calls_allowed($1)' into v_allowed using p_customer;
    if not coalesce(v_allowed, false) then
      return 0;
    end if;
  end if;
  begin
    execute 'select s.plan, s.monthly_call_cap from public.fizz_subscriptions s where s.customer_id = $1'
      into v_plan, v_override using p_customer;
  exception when undefined_column then
    execute 'select s.plan from public.fizz_subscriptions s where s.customer_id = $1'
      into v_plan using p_customer;
    v_override := null;
  end;
  if v_plan is null then
    v_plan := 'hobbyist';
  end if;
  if v_override is not null then
    return greatest(v_override, 0);
  end if;
  begin
    execute 'select p.monthly_call_cap from public.fizz_plans p where p.id = $1'
      into v_cap using v_plan;
  exception when undefined_column then
    v_cap := null;
  end;
  if v_cap is null and v_plan is distinct from 'enterprise' then
    v_cap := case v_plan
      when 'tinkerer' then 20
      when 'pro' then 100
      else 0
    end;
  end if;
  return v_cap;
exception when others then
  return 0;
end;
$$;

create function public.fizz_monthly_calls_used(p_customer uuid)
returns integer
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_alerts integer := 0;
  v_reserved integer := 0;
  v_month timestamptz := date_trunc('month', now() at time zone 'utc') at time zone 'utc';
  v_workspace uuid;
begin
  if p_customer is null then
    return 0;
  end if;
  if to_regclass('public.fizz_alert_events') is not null then
    execute
      'select count(*)::integer from public.fizz_alert_events e
        where e.customer_id = $1
          and e.notify_channel = ''call''
          and e.notify_status in (''pending'', ''sending'', ''sent'')
          and e.created_at >= $2'
      into v_alerts using p_customer, v_month;
  end if;
  select w.id into v_workspace from gateway.workspaces w where w.customer_id = p_customer;
  if v_workspace is not null then
    select count(*)::integer into v_reserved
    from gateway.phone_calls c
    where c.workspace_id = v_workspace
      and c.status = 'reserved'
      and c.created_at >= v_month;
  end if;
  return coalesce(v_alerts, 0) + coalesce(v_reserved, 0);
end;
$$;

-- True when this account is already over the cap, counting a call that is
-- already pending, sending, or sent. A null cap (Enterprise) is never over.
create function public.fizz_monthly_call_over(p_customer uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_cap integer;
begin
  v_cap := public.fizz_monthly_call_cap(p_customer);
  if v_cap is null then
    return false;
  end if;
  return public.fizz_monthly_calls_used(p_customer) > v_cap;
end;
$$;

create or replace function gateway.phone_approval_budget(p_workspace uuid)
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
  v_used integer;
  v_allowed boolean;
begin
  select w.customer_id into v_customer
  from gateway.workspaces w
  where w.id = p_workspace;
  if v_customer is null
     or to_regclass('public.fizz_subscriptions') is null
     or to_regclass('public.fizz_plans') is null
     or to_regclass('public.fizz_alert_events') is null then
    return jsonb_build_object(
      'reachable', false, 'allowed', false, 'reason', 'billing_unreachable'
    );
  end if;
  begin
    execute
      'select coalesce((select s.plan from public.fizz_subscriptions s where s.customer_id = $1), ''hobbyist'')'
      into v_plan using v_customer;
  exception when others then
    return jsonb_build_object(
      'reachable', false, 'allowed', false, 'reason', 'billing_unreachable'
    );
  end;
  v_cap := public.fizz_monthly_call_cap(v_customer);
  v_used := public.fizz_monthly_calls_used(v_customer);
  if to_regprocedure('public.fizz_calls_allowed(uuid)') is not null then
    execute 'select public.fizz_calls_allowed($1)' into v_allowed using v_customer;
    if not coalesce(v_allowed, false) then
      return jsonb_build_object(
        'reachable', true,
        'allowed', false,
        'plan', v_plan,
        'cap', 0,
        'used', v_used,
        'reason', 'calls_not_included'
      );
    end if;
  end if;
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
end;
$$;

-- Lock, then reserve. Two sessions cannot both pass the count. The insert of
-- status=reserved is the consumption. Dialing happens later.
create or replace function gateway.reserve_phone_approval_call(p_workspace uuid, p_approval uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_customer uuid;
  v_budget jsonb;
  v_phone text;
  v_message text;
  v_cap_message text := 'This month''s shared call cap is used. No approval call was placed. Approve it in the app. A webhook is used when one is configured. Tinkerer is 20 a month and Pro is 100, shared with sensor alerts.';
begin
  select w.customer_id into v_customer
  from gateway.workspaces w
  where w.id = p_workspace;
  if v_customer is null or p_approval is null or not exists (
    select 1 from gateway.approvals a
    where a.id = p_approval and a.workspace_id = p_workspace and a.status = 'pending'
  ) then
    return jsonb_build_object(
      'reachable', false,
      'allowed', false,
      'reason', 'billing_unreachable',
      'recorded', 'skipped',
      'message', 'The approval could not be called. Approve it in the app.'
    );
  end if;
  perform pg_advisory_xact_lock(hashtextextended('fizz_monthly_calls:' || v_customer::text, 0));
  v_budget := gateway.phone_approval_budget(p_workspace);
  if not coalesce((v_budget ->> 'reachable')::boolean, false) then
    insert into gateway.phone_calls (workspace_id, approval_id, status)
    values (p_workspace, p_approval, 'skipped');
    return v_budget || jsonb_build_object(
      'recorded', 'skipped',
      'message', 'Phone billing could not be checked. No approval call was placed. Approve it in the app.'
    );
  end if;
  if not coalesce((v_budget ->> 'allowed')::boolean, false) then
    insert into gateway.phone_calls (workspace_id, approval_id, status)
    values (p_workspace, p_approval, 'skipped');
    v_message := case v_budget ->> 'reason'
      when 'cap_reached' then v_cap_message
      else 'Phone calls are not included on this plan. No approval call was placed. Approve it in the app.'
    end;
    return v_budget || jsonb_build_object('recorded', 'skipped', 'message', v_message);
  end if;
  if to_regclass('public.fizz_verified_phones') is not null then
    execute
      'select v.phone from public.fizz_verified_phones v
        where v.customer_id = $1
        order by v.verified_at desc
        limit 1'
      into v_phone using v_customer;
  end if;
  if v_phone is null then
    insert into gateway.phone_calls (workspace_id, approval_id, status)
    values (p_workspace, p_approval, 'skipped');
    return v_budget || jsonb_build_object(
      'allowed', false,
      'reason', 'phone_not_paired',
      'recorded', 'skipped',
      'message', 'No paired phone number is on this account. Pair a number in the dashboard. No approval call was placed. Approve it in the app.'
    );
  end if;
  insert into gateway.phone_calls (workspace_id, approval_id, status, phone, dial_status)
  values (p_workspace, p_approval, 'reserved', v_phone, 'queued');
  return v_budget || jsonb_build_object(
    'recorded', 'reserved',
    'message', 'A call to the paired number is queued.'
  );
end;
$$;

create function gateway.claim_phone_approval_calls(p_limit integer)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 1), 1), 10);
  v_rows jsonb;
begin
  -- A dial that vanished after it was claimed is not placed again. The cap
  -- stays consumed. A connect failure requeues itself before this runs.
  update gateway.phone_calls
  set dial_status = 'failed'
  where status = 'reserved'
    and dial_status = 'dialing'
    and claimed_at < now() - interval '2 minutes';
  with picked as (
    select c.id
    from gateway.phone_calls c
    where c.status = 'reserved' and c.dial_status = 'queued'
    order by c.created_at
    for update skip locked
    limit v_limit
  ), claimed as (
    update gateway.phone_calls c
    set dial_status = 'dialing', claimed_at = now()
    from picked
    where c.id = picked.id
    returning c.id, c.phone, c.approval_id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', claimed.id,
    'phone', claimed.phone,
    'approval_id', claimed.approval_id,
    'gateway_name', g.name,
    'tool', a.tool_name,
    'args_preview', a.args_preview,
    'short_id', left(replace(a.id::text, '-', ''), 8)
  )), '[]'::jsonb)
  into v_rows
  from claimed
  join gateway.approvals a on a.id = claimed.approval_id
  join gateway.gateways g on g.id = a.gateway_id;
  return v_rows;
end;
$$;

create function gateway.requeue_phone_approval_call(p_id uuid)
returns void
language sql
volatile
security definer
set search_path = ''
as $$
  update gateway.phone_calls
  set dial_status = 'queued', claimed_at = null
  where id = p_id and status = 'reserved' and dial_status = 'dialing';
$$;

create function gateway.finish_phone_approval_call(p_id uuid, p_placed boolean, p_provider_id text)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  update gateway.phone_calls
  set dial_status = case when coalesce(p_placed, false) then 'placed' else 'failed' end,
      provider_call_id = case
        when p_provider_id is null or btrim(p_provider_id) = '' then null
        when char_length(btrim(p_provider_id)) > 80 then null
        when btrim(p_provider_id) ~ '[[:space:][:cntrl:]]' then null
        else btrim(p_provider_id)
      end
  where id = p_id and status = 'reserved' and dial_status = 'dialing';
end;
$$;

-- Digit 1 approves and digit 2 denies. decided_by is the account owner, the
-- same column the API decision sets to the signed-in user. Any other digit is
-- ignored. A row that is not pending is left alone.
create function gateway.apply_phone_keypress(p_approval uuid, p_digit text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_status text;
  v_user uuid;
  v_updated integer;
begin
  v_status := case btrim(coalesce(p_digit, ''))
    when '1' then 'approved'
    when '2' then 'denied'
    else null
  end;
  if v_status is null then
    return jsonb_build_object('decided', false, 'reason', 'ignored');
  end if;
  select c.auth_user_id into v_user
  from gateway.approvals a
  join gateway.workspaces w on w.id = a.workspace_id
  join public.fizz_customers c on c.id = w.customer_id
  where a.id = p_approval;
  update gateway.approvals
  set status = v_status, decided_by = v_user
  where id = p_approval and status = 'pending' and expires_at > now();
  get diagnostics v_updated = row_count;
  if v_updated <> 1 then
    return jsonb_build_object('decided', false, 'reason', 'not_pending');
  end if;
  return jsonb_build_object('decided', true, 'id', p_approval, 'status', v_status);
end;
$$;

create function public.fizz_claim_phone_approvals(p_limit integer default 1)
returns jsonb
language sql
volatile
security definer
set search_path = ''
as $$
  select gateway.claim_phone_approval_calls(p_limit);
$$;

create function public.fizz_requeue_phone_approval_call(p_id uuid)
returns void
language sql
volatile
security definer
set search_path = ''
as $$
  select gateway.requeue_phone_approval_call(p_id);
$$;

create function public.fizz_finish_phone_approval_call(p_id uuid, p_placed boolean, p_provider_id text)
returns void
language sql
volatile
security definer
set search_path = ''
as $$
  select gateway.finish_phone_approval_call(p_id, p_placed, p_provider_id);
$$;

create function public.fizz_apply_phone_keypress(p_approval uuid, p_digit text)
returns jsonb
language sql
volatile
security definer
set search_path = ''
as $$
  select gateway.apply_phone_keypress(p_approval, p_digit);
$$;

revoke all on function public.fizz_monthly_call_cap(uuid) from public, anon, authenticated;
revoke all on function public.fizz_monthly_calls_used(uuid) from public, anon, authenticated;
revoke all on function public.fizz_monthly_call_over(uuid) from public, anon, authenticated;
grant execute on function public.fizz_monthly_call_cap(uuid) to service_role, gateway_runtime;
grant execute on function public.fizz_monthly_calls_used(uuid) to service_role, gateway_runtime;
grant execute on function public.fizz_monthly_call_over(uuid) to service_role, gateway_runtime;

revoke all on function gateway.claim_phone_approval_calls(integer) from public, anon, authenticated;
revoke all on function gateway.finish_phone_approval_call(uuid, boolean, text) from public, anon, authenticated;
revoke all on function gateway.apply_phone_keypress(uuid, text) from public, anon, authenticated;
revoke all on function gateway.requeue_phone_approval_call(uuid) from public, anon, authenticated;
grant execute on function gateway.claim_phone_approval_calls(integer) to service_role, gateway_runtime;
grant execute on function gateway.finish_phone_approval_call(uuid, boolean, text) to service_role;
grant execute on function gateway.requeue_phone_approval_call(uuid) to service_role;
grant execute on function gateway.apply_phone_keypress(uuid, text) to service_role;

revoke all on function public.fizz_claim_phone_approvals(integer) from public, anon, authenticated;
revoke all on function public.fizz_finish_phone_approval_call(uuid, boolean, text) from public, anon, authenticated;
revoke all on function public.fizz_apply_phone_keypress(uuid, text) from public, anon, authenticated;
revoke all on function public.fizz_requeue_phone_approval_call(uuid) from public, anon, authenticated;
grant execute on function public.fizz_claim_phone_approvals(integer) to service_role;
grant execute on function public.fizz_finish_phone_approval_call(uuid, boolean, text) to service_role;
grant execute on function public.fizz_requeue_phone_approval_call(uuid) to service_role;
grant execute on function public.fizz_apply_phone_keypress(uuid, text) to service_role;

-- The dialer needs to update dial_status. Owners keep select-only.
grant update on gateway.phone_calls to service_role;

-- Before a counting alert call is stored, take the same account lock the
-- approval reserve uses. Over the cap, the row stays on the dashboard as
-- skipped and does not count. Email and webhook deliveries are queued by the
-- later insert trigger from the channels still on the rule.
do $$
begin
  if to_regclass('public.fizz_alert_events') is null then
    return;
  end if;
  execute $fn$
    create function public.fizz_enforce_monthly_call_cap()
    returns trigger
    language plpgsql
    security definer
    set search_path = ''
    as $body$
    declare
      v_cap integer;
      v_used integer;
    begin
      if new.notify_channel is distinct from 'call'
         or new.notify_status not in ('pending', 'sending', 'sent') then
        return new;
      end if;
      if to_regclass('public.fizz_plans') is null then
        return new;
      end if;
      perform pg_advisory_xact_lock(hashtextextended('fizz_monthly_calls:' || new.customer_id::text, 0));
      v_cap := public.fizz_monthly_call_cap(new.customer_id);
      if v_cap is null then
        return new;
      end if;
      v_used := public.fizz_monthly_calls_used(new.customer_id);
      if v_used >= v_cap then
        new.notify_status := 'skipped';
        new.notify_error := left(
          'This month''s shared call cap is used. The alert stays on the dashboard. Email and webhook still send when those channels are on. Tinkerer is 20 a month and Pro is 100.',
          200
        );
      end if;
      return new;
    end;
    $body$;
  $fn$;
  execute 'drop trigger if exists fizz_enforce_monthly_call_cap on public.fizz_alert_events';
  execute 'create trigger fizz_enforce_monthly_call_cap
    before insert on public.fizz_alert_events
    for each row execute function public.fizz_enforce_monthly_call_cap()';
  execute 'revoke all on function public.fizz_enforce_monthly_call_cap() from public, anon, authenticated';
end $$;

-- A call already queued can still be over the cap by the time it is dialed.
do $$
declare
  def text;
  old text := $old$elsif not public.fizz_calls_allowed(v_event.customer_id) then
    v_reason := 'Phone calls are not included on this plan.';$old$;
  extra text := $extra$elsif not public.fizz_calls_allowed(v_event.customer_id) then
    v_reason := 'Phone calls are not included on this plan.';
  elsif public.fizz_monthly_call_over(v_event.customer_id) then
    v_reason := 'This month''s shared call cap is used. The alert stays on the dashboard. Email and webhook still send when those channels are on. Tinkerer is 20 a month and Pro is 100.';$extra$;
begin
  if to_regprocedure('public.fizz_alert_call_still_due(uuid)') is null then
    return;
  end if;
  select pg_get_functiondef('public.fizz_alert_call_still_due(uuid)'::regprocedure) into def;
  if def is null or position('fizz_monthly_call_over' in def) > 0 then
    return;
  end if;
  if position(old in def) = 0 then
    raise exception 'fizz_alert_call_still_due is missing the plan check';
  end if;
  execute replace(def, old, extra);
end $$;

-- The agent-facing sentence from 20261116000000, now that the cap is enforced.
do $$
declare
  def text;
  old text := 'Phone-call alerts are on Tinkerer, Pro, and Enterprise. Tinkerer and Pro share one monthly call cap with phone approvals. That cap is not enforced yet. Hobbyist includes dashboard and webhook alerts. Email alerts are included on every plan when mail is configured. Leave the phone channel off, or ask the owner to upgrade.';
  new text := 'Phone-call alerts are on Tinkerer, Pro, and Enterprise. Tinkerer and Pro share one monthly call cap with phone approvals: 20 calls a month on Tinkerer and 100 on Pro. Enterprise is unlimited unless a contract sets a cap. Hobbyist includes dashboard and webhook alerts. Email alerts are included on every plan when mail is configured. Leave the phone channel off, or ask the owner to upgrade.';
begin
  if to_regprocedure('public.fizz_agent_call(text, text, text, jsonb)') is null then
    return;
  end if;
  select pg_get_functiondef('public.fizz_agent_call(text, text, text, jsonb)'::regprocedure) into def;
  if def is null or position(new in def) > 0 then
    return;
  end if;
  if position(old in def) = 0 then
    raise exception 'fizz_agent_call is missing the calls_not_included sentence';
  end if;
  execute replace(def, old, new);
end $$;
