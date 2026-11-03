-- Fizzlayer is open to everyone: sign-up no longer needs an invite and the public
-- waitlist is closed. The fizz_waitlist and fizz_invite_codes tables are kept so the
-- people who joined the list can still be emailed, and so redeemed invites keep their
-- history. Only the functions that wrote to them or required them are removed.

-- Monthly Fizz chat credits per plan.
update public.fizz_plans set monthly_credits = 10 where id = 'hobbyist';
update public.fizz_plans set monthly_credits = 100 where id = 'tinkerer';
update public.fizz_plans set monthly_credits = 1000 where id = 'pro';

drop function public.fizz_oauth_sign_in(uuid, text, text, text);
drop function public.fizz_check_invite(text, text);
drop function public.fizz_join_waitlist(text, text);
drop function public.fizz_create_invites(integer, text, interval);
drop function public.fizz_normalize_invite(text);

-- Link a verified Supabase user to its customer, creating the customer on first use.
-- New accounts are still limited to 10 an hour per network.
create function public.fizz_oauth_sign_in(p_user_id uuid, p_email text, p_ip text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_customer public.fizz_customers%rowtype;
  v_base text;
  v_username text;
  v_token bytea;
begin
  if not exists (select 1 from auth.users u where u.id = p_user_id
    and not coalesce(u.is_anonymous, false) and u.deleted_at is null
    and (u.banned_until is null or u.banned_until <= now())) then
    return jsonb_build_object('error', 'unavailable');
  end if;
  select * into v_customer from public.fizz_customers where auth_user_id = p_user_id;
  if not found then
    if not public.fizz_rate_limit_hit('register_ip', p_ip, 10, interval '1 hour') then
      return jsonb_build_object('error', 'rate_limited');
    end if;
    v_base := regexp_replace(lower(split_part(coalesce(p_email, ''), '@', 1)), '[^a-z0-9_]', '', 'g');
    if v_base !~ '^[a-z]' then v_base := 'fizz_' || v_base; end if;
    v_base := left(v_base, 18);
    if length(v_base) < 3 then v_base := 'fizz_user'; end if;
    for i in 0..9 loop
      v_username := case when i = 0 then v_base
        else v_base || '_' || lpad(floor(random() * 10000)::int::text, 4, '0') end;
      begin
        insert into public.fizz_customers(username, auth_user_id)
        values (v_username, p_user_id)
        returning * into v_customer;
        exit;
      exception when unique_violation then
        null;
      end;
    end loop;
    if v_customer.id is null then
      return jsonb_build_object('error', 'unavailable');
    end if;
  end if;
  v_token := extensions.gen_random_bytes(32);
  insert into public.fizz_sessions(token_hash, customer_id, expires_at)
  values (extensions.digest(v_token, 'sha256'), v_customer.id, now() + interval '12 hours');
  return jsonb_build_object('username', v_customer.username, 'token', encode(v_token, 'hex'));
end;
$$;

-- Email sign-up used to be rate limited by the invite check. Keep that limit:
-- 10 sign-up attempts an hour per network, before Supabase sends any email.
create function public.fizz_sign_up_allowed(p_ip text)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if not public.fizz_rate_limit_hit('register_ip', p_ip, 10, interval '1 hour') then
    return jsonb_build_object('error', 'rate_limited');
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

revoke execute on function public.fizz_oauth_sign_in(uuid, text, text),
  public.fizz_sign_up_allowed(text)
  from public, anon, authenticated;
grant execute on function public.fizz_oauth_sign_in(uuid, text, text),
  public.fizz_sign_up_allowed(text)
  to service_role;
