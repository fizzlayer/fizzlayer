-- User-facing sentence only. Who may place a call, and every limit, stay as they are.
-- Hobbyist still cannot place a phone call. Email and webhook stay on every plan.

do $$
declare
  def text;
  old text := 'Phone calls are included with Tinkerer, Pro, and Enterprise. Create a dashboard-only alert, or ask the owner to upgrade.';
  new text := 'Phone-call alerts are on Tinkerer, Pro, and Enterprise. Tinkerer and Pro share one monthly call cap with phone approvals. That cap is not enforced yet. Hobbyist includes dashboard and webhook alerts. Email alerts are included on every plan when mail is configured. Leave the phone channel off, or ask the owner to upgrade.';
begin
  select pg_get_functiondef('public.fizz_agent_call(text, text, text, jsonb)'::regprocedure) into def;
  if def is null or position(old in def) = 0 then
    raise exception 'fizz_agent_call is missing the calls_not_included sentence';
  end if;
  execute replace(def, old, new);
end $$;
