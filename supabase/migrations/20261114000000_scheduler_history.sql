-- The silence scan already writes fizz_scheduler_status.last_scan_at. Keep the
-- last eight successful passes so GET /api/status can show a short history.
alter table public.fizz_scheduler_status
  add column if not exists recent_scans timestamptz[] not null default '{}';

create or replace function public.fizz_note_scheduler_run()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_at timestamptz := now();
  v_recent timestamptz[];
begin
  insert into public.fizz_scheduler_status (id, last_scan_at, recent_scans)
  values (true, v_at, array[v_at])
  on conflict (id) do update set
    last_scan_at = excluded.last_scan_at,
    recent_scans = (
      array[excluded.last_scan_at] || public.fizz_scheduler_status.recent_scans
    )[1:8]
  returning recent_scans into v_recent;
  return jsonb_build_object(
    'ok', true,
    'last_scan_at', v_at,
    'recent_scans', to_jsonb(v_recent)
  );
end;
$$;

revoke all on function public.fizz_note_scheduler_run() from public, anon, authenticated;
grant execute on function public.fizz_note_scheduler_run() to service_role;
