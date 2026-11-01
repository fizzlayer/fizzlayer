(() => {
  const $ = (id) => document.getElementById(id);
  const passkey = window.fizzPasskey;
  const providerNames = { email: 'Email and password', google: 'Google' };
  let canAddPasskey = false;

  async function api(path, method = 'GET', body) {
    const response = await fetch(path, { method, credentials: 'same-origin', headers: { 'content-type': 'application/json' }, body: body ? JSON.stringify(body) : undefined });
    const data = await response.json().catch(() => ({}));
    if (!response.ok) throw Object.assign(new Error(data.error?.message || 'Please try again.'), { code: data.error?.code, status: response.status });
    return data;
  }
  function node(tag, className, content) {
    const el = document.createElement(tag);
    if (className) el.className = className;
    if (content !== undefined) el.textContent = content;
    return el;
  }
  const date = (value) => value ? new Date(value).toLocaleDateString([], { dateStyle: 'medium' }) : 'Not available';
  const keyIcon = () => $('key-icon').content.firstElementChild.cloneNode(true);
  function keyBadge() {
    const badge = node('span', 'key-badge');
    badge.append(keyIcon());
    return badge;
  }
  function message(text) { $('passkey-message').textContent = text; }

  // A label for a new passkey, such as "Chrome on Mac", so the list tells them apart.
  function deviceName() {
    const ua = navigator.userAgent;
    const browser = /Edg\//.test(ua) ? 'Edge' : /Firefox\//.test(ua) ? 'Firefox' : /OPR\//.test(ua) ? 'Opera'
      : /Chrome\//.test(ua) ? 'Chrome' : /Safari\//.test(ua) ? 'Safari' : 'Browser';
    const device = /iPhone/.test(ua) ? 'iPhone' : /iPad/.test(ua) ? 'iPad' : /Android/.test(ua) ? 'Android'
      : /Macintosh|Mac OS X/.test(ua) ? 'Mac' : /Windows/.test(ua) ? 'Windows' : /CrOS/.test(ua) ? 'ChromeOS'
      : /Linux/.test(ua) ? 'Linux' : 'this device';
    return `${browser} on ${device}`;
  }

  const count = (value) => Number(value).toLocaleString();
  const paying = (status) => ['active', 'trialing', 'past_due'].includes(status);
  function renderPlan(plan, billingAvailable) {
    if (!plan) return;
    const subscription = plan.subscription || {};
    const subscribed = paying(subscription.status);
    const status = $('plan-status');
    status.hidden = !subscribed;
    if (subscription.status === 'past_due') status.textContent = 'Your last payment failed. Update your payment method in Manage billing to keep this plan.';
    else if (subscribed && subscription.current_period_end) {
      status.textContent = `${subscription.cancel_at_period_end ? 'Ends' : 'Renews'} ${date(subscription.current_period_end)}.`;
    }
    // Enterprise is arranged with us directly, so it has no self-serve billing.
    const selfServe = billingAvailable && plan.id !== 'enterprise';
    $('plan-actions').hidden = !selfServe;
    for (const button of document.querySelectorAll('[data-plan]')) button.hidden = !selfServe || subscribed;
    $('manage-billing').hidden = !selfServe || !subscription.has_billing_account;
    const price = plan.monthly_price_cents ? ` · $${count(plan.monthly_price_cents / 100)}/month` : plan.monthly_price_cents === 0 ? ' · Free' : '';
    $('plan-name').textContent = plan.name + price;
    $('plan-devices').textContent = plan.device_limit === null ? `${count(plan.devices_used)} · Unlimited` : `${count(plan.devices_used)} of ${count(plan.device_limit)}`;
    const reset = new Date(plan.credits_reset_at).toLocaleDateString([], { month: 'long', day: 'numeric', timeZone: 'UTC' });
    $('plan-credits').textContent = plan.monthly_credits === null ? `${count(plan.credits_used)} used this month · Unlimited`
      : `${count(plan.credits_used)} of ${count(plan.monthly_credits)} used · Resets ${reset}`;
  }
  function render(account) {
    $('settings-username').textContent = account.username;
    $('account-username').textContent = account.username;
    $('account-email').textContent = account.email || 'Not available';
    const methods = (account.providers || []).map((p) => providerNames[p] || p.charAt(0).toUpperCase() + p.slice(1));
    if (account.passkeys.length) methods.push('Passkey');
    $('account-methods').textContent = methods.join(', ') || 'Not available';
    $('account-since').textContent = date(account.created_at);
    canAddPasskey = account.can_add_passkey;
    renderPlan(account.plan, account.billing_available);

    const list = $('passkey-list');
    list.replaceChildren();
    for (const key of account.passkeys) {
      const item = node('li', 'passkey-item');
      const text = node('div', 'passkey-text');
      const used = key.last_used_at ? `Last used ${date(key.last_used_at)}` : 'Not used yet';
      text.append(node('strong', '', key.name || 'Passkey'), node('span', 'passkey-meta', `Added ${date(key.created_at)} · ${used}`));
      const remove = node('button', 'sensor-remove', 'Remove');
      remove.type = 'button';
      remove.setAttribute('aria-label', `Remove ${key.name || 'passkey'}`);
      remove.addEventListener('click', async () => {
        if (!confirm(`Remove ${key.name || 'this passkey'}? You will no longer be able to sign in with it. You can also delete it from your device's password manager.`)) return;
        remove.disabled = true;
        try {
          await api('/api/account', 'DELETE', { passkey_id: key.id });
          message('Passkey removed.');
          await refresh();
        } catch (error) {
          message(error.message);
          remove.disabled = false;
        }
      });
      item.append(keyBadge(), text, remove);
      list.append(item);
    }
    $('passkey-empty').hidden = account.passkeys.length > 0;
  }

  async function refresh() {
    const account = await api('/api/account');
    render(account);
    return account;
  }

  // Checkout and the billing portal are Stripe pages; the API answers with where to go.
  async function openBilling(button, body) {
    button.disabled = true;
    $('billing-message').textContent = '';
    try { location.href = (await api('/api/billing', 'POST', body)).url; }
    catch (error) { $('billing-message').textContent = error.message; button.disabled = false; }
  }
  for (const button of document.querySelectorAll('[data-plan]')) {
    button.addEventListener('click', () => openBilling(button, { action: 'checkout', plan: button.dataset.plan }));
  }
  $('manage-billing').addEventListener('click', () => openBilling($('manage-billing'), { action: 'portal' }));
  // Going Back from Stripe can restore this page exactly as it was left, mid-redirect with
  // its button disabled. Re-enable the buttons and reload the plan, which may have changed.
  addEventListener('pageshow', (event) => {
    if (!event.persisted) return;
    for (const button of $('plan-actions').querySelectorAll('button')) button.disabled = false;
    refresh().catch(() => {});
  });

  // Stripe confirms a checkout through a webhook, which can land a moment after the redirect.
  async function afterCheckout(account) {
    const result = new URLSearchParams(location.search).get('billing');
    if (!result) return;
    history.replaceState(null, '', location.pathname);
    if (result === 'cancelled') { $('billing-message').textContent = 'Checkout cancelled. Your plan has not changed.'; return; }
    if (result !== 'success') return;
    $('billing-message').textContent = 'Payment received. Updating your plan…';
    for (let attempt = 0; attempt < 10 && !paying(account.plan?.subscription?.status); attempt++) {
      await new Promise((resolve) => setTimeout(resolve, 2000));
      account = await refresh();
    }
    $('billing-message').textContent = paying(account.plan?.subscription?.status)
      ? `You're on ${account.plan.name}. Thanks for supporting Fizzlayer!`
      : 'Payment received. Your plan will update shortly; refresh this page in a minute.';
  }

  // Supabase only registers a passkey for someone who signed in within the last hour.
  function needsRecentSignIn() {
    message('For security, adding a passkey needs a sign-in from the last hour. Sign in again, then press + right away.');
    $('sign-in-again').hidden = false;
  }

  $('add-passkey').addEventListener('click', async () => {
    message('');
    if (!passkey.supported) { message('This browser does not support passkeys. Try a current version of Chrome, Safari, Edge, or Firefox.'); return; }
    if (!canAddPasskey) { needsRecentSignIn(); return; }
    const button = $('add-passkey');
    button.disabled = true;
    try {
      const start = await api('/api/auth', 'POST', { action: 'passkey_add_options' });
      const credential = await passkey.credential(start.options, true);
      await api('/api/auth', 'POST', { action: 'passkey_add', challenge_id: start.challenge_id, credential, name: deviceName() });
      message('Passkey added. Next time, choose "Sign in with a passkey".');
      await refresh();
    } catch (error) {
      if (passkey.cancelled(error)) return;
      if (error.code === 'sign_in_again') { needsRecentSignIn(); return; }
      message(error instanceof DOMException ? 'That passkey could not be saved. Try again.' : error.message);
    } finally {
      button.disabled = false;
    }
  });

  async function signOut(next) {
    try { await api('/api/session', 'DELETE'); location.href = next; }
    catch (error) { $('page-error').textContent = error.message; }
  }
  $('settings-sign-out').addEventListener('click', () => signOut('/app.html'));
  $('sign-in-again').addEventListener('click', () => signOut('/app.html#sign-in'));

  for (const slot of document.querySelectorAll('[data-key-icon]')) slot.append(keyIcon());
  refresh().then(afterCheckout).catch((error) => {
    if (error.status === 401) location.href = '/app.html#sign-in';
    else $('page-error').textContent = error.message;
  });
})();
