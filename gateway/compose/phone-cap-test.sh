# Concurrent reserves against gateway.reserve_phone_approval_call.
# Sourced by test.sh so compose() and set -e stay in effect.
# The fixture is committed, exercised from eight sessions, then removed.

compose exec -T postgres psql -U fizz -d fizz -v ON_ERROR_STOP=1 <<'SQL'
insert into auth.users(id, email, encrypted_password, is_anonymous)
values ('01999999-0000-4000-8000-0000000000aa', 'cap@example.invalid', 'not-a-password', false);

insert into public.fizz_customers(id, username, auth_user_id)
values ('01999999-0000-4000-8000-000000000001', 'cap_owner', '01999999-0000-4000-8000-0000000000aa');

create table if not exists public.fizz_plans (
  id text primary key,
  monthly_call_cap integer
);
insert into public.fizz_plans(id, monthly_call_cap) values ('tinkerer', 2)
on conflict (id) do update set monthly_call_cap = excluded.monthly_call_cap;

create table if not exists public.fizz_subscriptions (
  customer_id uuid primary key,
  plan text,
  monthly_call_cap integer
);
insert into public.fizz_subscriptions(customer_id, plan, monthly_call_cap)
values ('01999999-0000-4000-8000-000000000001', 'tinkerer', null)
on conflict (customer_id) do update set plan = excluded.plan, monthly_call_cap = excluded.monthly_call_cap;

create table if not exists public.fizz_alert_events (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid,
  notify_channel text,
  notify_status text,
  created_at timestamptz not null default now()
);

create table if not exists public.fizz_verified_phones (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid,
  phone text,
  verified_at timestamptz not null default now()
);
insert into public.fizz_verified_phones(customer_id, phone)
values ('01999999-0000-4000-8000-000000000001', '+14155550100');

insert into gateway.workspaces(id, customer_id)
values ('01999999-0000-4000-8000-000000000002', '01999999-0000-4000-8000-000000000001');
insert into gateway.gateways(id, workspace_id, name, mode, public_url)
values (
  '01999999-0000-4000-8000-000000000003',
  '01999999-0000-4000-8000-000000000002',
  'capgw', 'shared', 'https://cap.example.invalid/mcp'
);
insert into gateway.approvals(
  id, gateway_id, workspace_id, server_name, tool_name, args_hash, status, expires_at
)
select
  ('01999999-0000-4000-8000-00000000001' || n)::uuid,
  '01999999-0000-4000-8000-000000000003',
  '01999999-0000-4000-8000-000000000002',
  'sample', 'move_funds', repeat('ab', 32), 'pending', now() + interval '10 minutes'
from generate_series(0, 7) as n;
SQL

workspace=01999999-0000-4000-8000-000000000002
pids=""
n=0
while [ "$n" -lt 8 ]; do
  approval=$(printf '01999999-0000-4000-8000-00000000001%s' "$n")
  compose exec -T postgres psql -U fizz -d fizz -v ON_ERROR_STOP=1 \
    -c "select gateway.reserve_phone_approval_call('${workspace}', '${approval}');" \
    >/dev/null &
  pids="$pids $!"
  n=$((n + 1))
done
for pid in $pids; do
  wait "$pid"
done

reserved=$(compose exec -T postgres psql -U fizz -d fizz -tAc \
  "select count(*) from gateway.phone_calls where workspace_id = '${workspace}' and status = 'reserved'")
skipped=$(compose exec -T postgres psql -U fizz -d fizz -tAc \
  "select count(*) from gateway.phone_calls where workspace_id = '${workspace}' and status = 'skipped'")
reserved=$(printf '%s' "$reserved" | tr -d '[:space:]')
skipped=$(printf '%s' "$skipped" | tr -d '[:space:]')
if [ "$reserved" != "2" ] || [ "$skipped" != "6" ]; then
  echo "phone cap reservation was not atomic: reserved=$reserved skipped=$skipped" >&2
  exit 1
fi

over=$(compose exec -T postgres psql -U fizz -d fizz -tAc \
  "select gateway.reserve_phone_approval_call('${workspace}', '01999999-0000-4000-8000-000000000010') ->> 'reason'")
over=$(printf '%s' "$over" | tr -d '[:space:]')
if [ "$over" != "cap_reached" ]; then
  echo "over-cap reserve returned $over" >&2
  exit 1
fi

compose exec -T postgres psql -U fizz -d fizz -v ON_ERROR_STOP=1 <<'SQL'
delete from gateway.phone_calls where workspace_id = '01999999-0000-4000-8000-000000000002';
delete from public.fizz_verified_phones where customer_id = '01999999-0000-4000-8000-000000000001';
SQL
unpaired=$(compose exec -T postgres psql -U fizz -d fizz -tAc \
  "select gateway.reserve_phone_approval_call('${workspace}', '01999999-0000-4000-8000-000000000010') ->> 'reason'")
unpaired=$(printf '%s' "$unpaired" | tr -d '[:space:]')
if [ "$unpaired" != "phone_not_paired" ]; then
  echo "unpaired reserve returned $unpaired" >&2
  exit 1
fi
still_reserved=$(compose exec -T postgres psql -U fizz -d fizz -tAc \
  "select count(*) from gateway.phone_calls where workspace_id = '${workspace}' and status = 'reserved'")
still_reserved=$(printf '%s' "$still_reserved" | tr -d '[:space:]')
if [ "$still_reserved" != "0" ]; then
  echo "an unpaired number consumed the cap" >&2
  exit 1
fi

compose exec -T postgres psql -U fizz -d fizz -v ON_ERROR_STOP=1 <<'SQL'
delete from gateway.phone_calls where workspace_id = '01999999-0000-4000-8000-000000000002';
delete from gateway.approvals where gateway_id = '01999999-0000-4000-8000-000000000003';
delete from gateway.gateways where id = '01999999-0000-4000-8000-000000000003';
delete from gateway.workspaces where id = '01999999-0000-4000-8000-000000000002';
delete from public.fizz_subscriptions where customer_id = '01999999-0000-4000-8000-000000000001';
delete from public.fizz_customers where id = '01999999-0000-4000-8000-000000000001';
delete from auth.users where id = '01999999-0000-4000-8000-0000000000aa';
SQL
