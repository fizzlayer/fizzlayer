-- The Allow page must not trust a link by itself. Home Assistant registers a 6-digit code
-- that it shows on its own screen; fizz_ha_authorize accepts the link only when the signed-in
-- person sends that same code. Re-adding a Home Assistant entity turns its alerts back on
-- only if they were on when the entity was removed.

alter table public.fizz_device_pairings
  add column ha_confirm_hash bytea,
  add column ha_version text,
  add constraint fizz_device_pairings_ha_version_check
    check (ha_version is null or (char_length(ha_version) between 1 and 40 and ha_version !~ '[[:cntrl:]]'));

-- Null until a removal suspends the rule. The value is the enabled flag from before that
-- removal, so a rule the owner had already turned off stays off when the sensor returns.
alter table public.fizz_alert_rules
  add column resume_enabled boolean;

create or replace function public.fizz_disable_sensor_alerts() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if old.deleted_at is null and new.deleted_at is not null then
    update public.fizz_alert_rules
    set resume_enabled = enabled, enabled = false, updated_at = now()
    where sensor_id = new.id;
    perform public.fizz_cancel_pending_alerts(null, new.id, 'Sensor was removed.');
  end if;
  -- The entity was shared again. Restore the flag captured above, and give a silence
  -- rule a fresh window so the gap while it was removed does not place a call.
  if old.deleted_at is not null and new.deleted_at is null then
    update public.fizz_alert_rules
    set enabled = resume_enabled,
        armed = case when resume_enabled then true else armed end,
        silence_due_at = case
          when kind = 'silence' and resume_enabled then
            greatest(coalesce(silence_due_at, now()), now() + make_interval(mins => silence_minutes))
          else silence_due_at end,
        resume_enabled = null,
        updated_at = now()
    where sensor_id = new.id and resume_enabled is not null;
  end if;
  if new.status = 'paused' and old.status is distinct from 'paused' then
    perform public.fizz_cancel_pending_alerts(null, new.id, 'Sensor is paused.');
  end if;
  if new.status = 'active' and old.status = 'paused' then
    update public.fizz_alert_rules
    set silence_due_at = greatest(silence_due_at, now() + make_interval(mins => silence_minutes)),
        updated_at = now()
    where sensor_id = new.id and kind = 'silence' and enabled and silence_due_at is not null;
  end if;
  return new;
end;
$$;

-- While the sensor is removed, the owner's on/off choice is remembered and applied on return.
create or replace function public.fizz_update_alert(p_token text, p_rule_id uuid, p_enabled boolean, p_delete boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_customer uuid; v_rule public.fizz_alert_rules%rowtype; v_removed boolean;
begin
  select customer_id into v_customer from public.fizz_sessions
  where p_token ~ '^[0-9a-f]{64}$'
    and token_hash = extensions.digest(decode(p_token, 'hex'), 'sha256') and expires_at > now();
  if v_customer is null then return jsonb_build_object('error','unauthorized'); end if;
  if coalesce(p_delete,false) then
    if not exists(select 1 from public.fizz_alert_rules
        where id = p_rule_id and customer_id = v_customer) then
      return jsonb_build_object('error','not_found');
    end if;
    perform public.fizz_cancel_pending_alerts(p_rule_id, null, 'Alert was deleted.');
    delete from public.fizz_alert_rules where id = p_rule_id and customer_id = v_customer;
    return jsonb_build_object('ok',true);
  end if;
  if p_enabled is null then return jsonb_build_object('error','invalid_rule'); end if;
  select s.deleted_at is not null into v_removed
  from public.fizz_alert_rules r
  join public.fizz_sensors s on s.id = r.sensor_id
  where r.id = p_rule_id and r.customer_id = v_customer;
  if not found then return jsonb_build_object('error','not_found'); end if;
  update public.fizz_alert_rules r set
    enabled = case when v_removed then false else p_enabled end,
    resume_enabled = case when v_removed then p_enabled else null end,
    armed = true,
    updated_at = now(),
    silence_due_at = case when r.kind = 'silence' and p_enabled and not v_removed then (
      select rd.received_at + make_interval(mins => r.silence_minutes)
      from public.fizz_sensor_readings rd
      where rd.sensor_id = r.sensor_id order by rd.received_at desc limit 1)
      else r.silence_due_at end
  where r.id = p_rule_id and r.customer_id = v_customer returning * into v_rule;
  if not found then return jsonb_build_object('error','not_found'); end if;
  if not p_enabled then
    perform public.fizz_cancel_pending_alerts(p_rule_id, null, 'Alert was paused.');
  end if;
  return jsonb_build_object('rule',to_jsonb(v_rule)-'customer_id');
end;
$$;

-- Home Assistant polls with the code it is showing. The first poll records that code.
-- Later polls cannot replace it. The code is never sent back.
drop function public.fizz_ha_exchange(text, text);
create function public.fizz_ha_exchange(p_state text, p_ip text, p_code text, p_name text, p_ha_version text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_pair public.fizz_device_pairings%rowtype;
  v_ip text := left(coalesce(p_ip, ''), 80);
  v_code text := regexp_replace(coalesce(p_code, ''), '\s', '', 'g');
  v_name text := left(regexp_replace(trim(coalesce(p_name, '')), '[[:cntrl:]]', '', 'g'), 80);
  v_version text := nullif(left(regexp_replace(trim(coalesce(p_ha_version, '')), '[[:cntrl:]]', '', 'g'), 40), '');
  v_alphabet constant text := '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  v_bytes bytea; v_pairing_code text; v_secret text; v_id uuid; v_existing uuid;
begin
  if p_state is null or p_state !~ '^[0-9a-f]{64}$' then
    return jsonb_build_object('error', 'invalid_request');
  end if;
  if not public.fizz_rate_limit_hit('ha_exchange_ip', v_ip, 40, interval '1 minute') then
    return jsonb_build_object('error', 'rate_limited');
  end if;
  if v_name = '' then v_name := 'Home Assistant'; end if;
  select * into v_pair from public.fizz_device_pairings
  where ha_state_hash = extensions.digest(p_state, 'sha256') for update;
  if not found then
    if v_code !~ '^[0-9]{6}$' then return jsonb_build_object('error', 'invalid_request'); end if;
    v_secret := encode(extensions.gen_random_bytes(32), 'hex');
    for attempt in 1..5 loop
      v_bytes := extensions.gen_random_bytes(8);
      v_pairing_code := '';
      for j in 0..7 loop
        v_pairing_code := v_pairing_code || substr(v_alphabet, get_byte(v_bytes, j) % 32 + 1, 1);
      end loop;
      begin
        insert into public.fizz_device_pairings(
          code_hash, poll_hash, device_name, platform, status, expires_at,
          ha_state_hash, ha_confirm_hash, ha_version)
        values (
          extensions.digest(v_pairing_code, 'sha256'), extensions.digest(v_secret, 'sha256'),
          v_name, 'homeassistant', 'waiting', now() + interval '15 minutes',
          extensions.digest(p_state, 'sha256'), extensions.digest(v_code, 'sha256'), v_version)
        returning id into v_id;
        exit;
      exception when unique_violation then
        select id into v_existing from public.fizz_device_pairings
        where ha_state_hash = extensions.digest(p_state, 'sha256');
        if v_existing is not null then exit; end if;
      end;
    end loop;
    if v_id is null and v_existing is null then
      return jsonb_build_object('error', 'unavailable');
    end if;
    select * into v_pair from public.fizz_device_pairings where id = coalesce(v_existing, v_id);
  end if;
  if v_pair.platform is distinct from 'homeassistant' then
    return jsonb_build_object('status', 'pending');
  end if;
  if v_pair.status = 'approved' then return jsonb_build_object('error', 'already_linked'); end if;
  if v_pair.expires_at <= now() then return jsonb_build_object('error', 'expired'); end if;
  if v_pair.status = 'claimed' and v_pair.customer_id is not null then
    return public.fizz_ha_finish(v_pair.id);
  end if;
  return jsonb_build_object('status', 'pending', 'name', v_pair.device_name, 'ha_version', v_pair.ha_version);
end;
$$;

-- The code is the one Home Assistant is displaying. A link alone is not approval.
-- Postgres rejects CREATE OR REPLACE when a parameter is renamed (p_name -> p_code).
drop function public.fizz_ha_authorize(text, text, text);
create function public.fizz_ha_authorize(p_token text, p_state text, p_code text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_customer uuid;
  v_pair public.fizz_device_pairings%rowtype;
  v_code text := regexp_replace(coalesce(p_code, ''), '\s', '', 'g');
begin
  v_customer := public.fizz_session_customer(p_token);
  if v_customer is null then return jsonb_build_object('error', 'unauthorized'); end if;
  if p_state is null or p_state !~ '^[0-9a-f]{64}$' then
    return jsonb_build_object('error', 'invalid_request');
  end if;
  if not public.fizz_rate_limit_hit('ha_authorize', v_customer::text, 20, interval '1 hour') then
    return jsonb_build_object('error', 'rate_limited');
  end if;
  if v_code !~ '^[0-9]{6}$' then return jsonb_build_object('error', 'invalid_code'); end if;
  select * into v_pair from public.fizz_device_pairings
  where ha_state_hash = extensions.digest(p_state, 'sha256') for update;
  if not found or v_pair.platform is distinct from 'homeassistant' then
    return jsonb_build_object('error', 'not_ready');
  end if;
  if v_pair.status = 'approved' then return jsonb_build_object('error', 'already_linked'); end if;
  if v_pair.expires_at <= now() then return jsonb_build_object('error', 'expired'); end if;
  if not public.fizz_hash_equals(v_pair.ha_confirm_hash, extensions.digest(v_code, 'sha256')) then
    return jsonb_build_object('error', 'invalid_code');
  end if;
  if v_pair.customer_id is not null and v_pair.customer_id is distinct from v_customer then
    return jsonb_build_object('error', 'invalid_request');
  end if;
  update public.fizz_device_pairings
  set status = 'claimed', customer_id = v_customer, claimed_via = 'dashboard', claimed_at = coalesce(claimed_at, now())
  where id = v_pair.id;
  return jsonb_build_object(
    'ok', true, 'expires_at', v_pair.expires_at,
    'name', v_pair.device_name, 'ha_version', v_pair.ha_version);
end;
$$;

-- Name and version for the Allow page. The confirmation code is not included.
create function public.fizz_ha_preview(p_state text, p_ip text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_pair public.fizz_device_pairings%rowtype; v_ip text := left(coalesce(p_ip, ''), 80);
begin
  if p_state is null or p_state !~ '^[0-9a-f]{64}$' then
    return jsonb_build_object('error', 'invalid_request');
  end if;
  if not public.fizz_rate_limit_hit('ha_preview_ip', v_ip, 60, interval '1 minute') then
    return jsonb_build_object('error', 'rate_limited');
  end if;
  select * into v_pair from public.fizz_device_pairings
  where ha_state_hash = extensions.digest(p_state, 'sha256');
  if not found or v_pair.platform is distinct from 'homeassistant' then
    return jsonb_build_object('status', 'waiting');
  end if;
  return jsonb_build_object(
    'status', case when v_pair.status = 'approved' then 'approved' else 'pending' end,
    'name', v_pair.device_name, 'ha_version', v_pair.ha_version);
end;
$$;

revoke execute on function
  public.fizz_ha_exchange(text, text, text, text, text),
  public.fizz_ha_preview(text, text)
from public, anon, authenticated;
grant execute on function
  public.fizz_ha_exchange(text, text, text, text, text),
  public.fizz_ha_preview(text, text)
to service_role;

revoke execute on function public.fizz_ha_authorize(text, text, text) from public, anon, authenticated;
grant execute on function public.fizz_ha_authorize(text, text, text) to service_role;
