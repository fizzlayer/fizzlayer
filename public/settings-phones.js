// Settings: pair the US numbers Fizzlayer may call for phone approvals (and Sensors alerts).
// The same flow as Phones on the Sensors dashboard (dashboard.js), through /api/phones, so it
// works on every server, with or without Sensors. Kept apart from settings.js, which owns the
// account, plan, and passkey sections.
(() => {
  const $ = (id) => document.getElementById(id);
  if (!$('phones')) return;
  let data = { calls_included: false, phones: [], pending: null };

  async function api(path, method = 'GET', body) {
    const response = await fetch(path, { method, credentials: 'same-origin', cache: 'no-store', headers: { 'content-type': 'application/json' }, body: body ? JSON.stringify(body) : undefined });
    const json = await response.json().catch(() => ({}));
    if (!response.ok) throw Object.assign(new Error(json.error?.message || 'Please try again.'), { code: json.error?.code, status: response.status });
    return json;
  }
  function node(tag, className, content) {
    const el = document.createElement(tag);
    if (className) el.className = className;
    if (content !== undefined) el.textContent = content;
    return el;
  }
  function formatPhone(phone) {
    const match = /^\+1(\d{3})(\d{3})(\d{4})$/.exec(phone || '');
    return match ? `(${match[1]}) ${match[2]}-${match[3]}` : phone || '';
  }
  const say = (text) => { $('phone-message').textContent = text; };

  function render() {
    const list = $('phone-list');
    list.replaceChildren();
    for (const phone of data.phones) {
      const item = node('li', 'phone-row');
      item.append(node('strong', '', formatPhone(phone.phone)));
      const remove = node('button', 'secondary', 'Remove');
      remove.type = 'button';
      remove.setAttribute('aria-label', `Remove ${formatPhone(phone.phone)}`);
      remove.addEventListener('click', async () => {
        remove.disabled = true;
        say('');
        try {
          await api('/api/phones', 'POST', { action: 'remove', phone: phone.phone });
          say(`${formatPhone(phone.phone)} was removed. Fizzlayer will not call it.`);
          await refresh();
        } catch (error) {
          say(error.message);
          remove.disabled = false;
        }
      });
      item.append(remove);
      list.append(item);
    }
    $('phones-empty').hidden = data.phones.length > 0;

    // Paired numbers are kept across a downgrade, so they stay listed and removable.
    const upgrade = $('phones-upgrade');
    upgrade.replaceChildren();
    if (!data.calls_included) {
      upgrade.hidden = false;
      const link = node('a', '', 'Upgrade in Plan and usage');
      link.href = '#plan-title';
      upgrade.append('Phone calls are not included on Hobbyist. Tinkerer, Pro, and Enterprise place approval calls. ', link, '. Hobbyist can log approvals or send a webhook.');
      $('phone-pair-form').hidden = true;
      $('phone-confirm-form').hidden = true;
      return;
    }
    upgrade.hidden = true;
    $('phone-pair-form').hidden = false;
    const pending = data.pending;
    const confirm = $('phone-confirm-form');
    if (pending?.phone) {
      if (confirm.hidden || confirm.dataset.phone !== pending.phone) {
        confirm.dataset.phone = pending.phone;
        $('phone-code').value = '';
      }
      confirm.hidden = false;
      if (!$('phone-number').value) $('phone-number').value = formatPhone(pending.phone);
      const left = Number(pending.attempts_remaining);
      if (!$('phone-message').textContent && Number.isFinite(left) && left < 5) {
        say(`${left} ${left === 1 ? 'try' : 'tries'} left for this code.`);
      }
    }
  }

  async function refresh() {
    try {
      const phones = await api('/api/phones');
      data = { calls_included: phones.calls_included === true, phones: phones.phones || [], pending: phones.pending || null };
      render();
    } catch (error) {
      // settings.js sends a signed-out visitor to sign in.
      if (error.status !== 401) say(error.message);
    }
  }

  async function startPairing(phone) {
    say('');
    $('phone-start').disabled = true;
    $('phone-resend').disabled = true;
    try {
      const result = await api('/api/phones', 'POST', { action: 'start', phone });
      if (result.already_paired) {
        say(`${formatPhone(result.phone)} is already paired.`);
      } else {
        $('phone-confirm-form').hidden = false;
        $('phone-confirm-form').dataset.phone = result.phone;
        $('phone-code').value = '';
        say(`Calling ${formatPhone(result.phone)}. Enter the 6-digit code from the call. It expires in 10 minutes. You can call again after one minute.`);
        $('phone-code').focus();
      }
      await refresh();
    } catch (error) {
      say(error.message);
    } finally {
      $('phone-start').disabled = false;
      $('phone-resend').disabled = false;
    }
  }

  $('phone-pair-form').addEventListener('submit', (event) => {
    event.preventDefault();
    void startPairing($('phone-number').value.trim());
  });
  $('phone-resend').addEventListener('click', () => {
    void startPairing($('phone-confirm-form').dataset.phone || $('phone-number').value.trim());
  });
  $('phone-confirm-form').addEventListener('submit', async (event) => {
    event.preventDefault();
    say('');
    const button = event.submitter;
    if (button) button.disabled = true;
    try {
      const phone = $('phone-confirm-form').dataset.phone || $('phone-number').value.trim();
      const result = await api('/api/phones', 'POST', { action: 'confirm', phone, code: $('phone-code').value.trim() });
      $('phone-code').value = '';
      $('phone-confirm-form').hidden = true;
      say(`${formatPhone(result.phone || phone)} is paired. Fizzlayer can call it for approvals.`);
      await refresh();
    } catch (error) {
      say(error.message);
    } finally {
      if (button) button.disabled = false;
    }
  });
  // A plan change (checkout, a WebMCP tool) can turn calls on or off.
  addEventListener('fizz:changed', () => { void refresh(); });
  addEventListener('pageshow', (event) => { if (event.persisted) void refresh(); });
  void refresh();
})();
