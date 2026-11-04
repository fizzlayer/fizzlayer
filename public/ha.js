(() => {
  const message = document.getElementById('ha-message');
  const allow = document.getElementById('ha-allow');
  const next = document.getElementById('ha-next');
  const retry = document.getElementById('ha-retry');
  const state = new URLSearchParams(location.search).get('state') || '';
  const valid = /^[0-9a-f]{64}$/.test(state);

  function show(text) {
    message.textContent = text;
  }

  async function account() {
    const response = await fetch('/api/me', { credentials: 'same-origin' });
    if (!response.ok) return null;
    return response.json();
  }

  async function allowLink() {
    allow.disabled = true;
    show('Linking Home Assistant…');
    try {
      const response = await fetch('/api/devices', {
        method: 'POST',
        credentials: 'same-origin',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ action: 'ha_authorize', state }),
      });
      const data = await response.json();
      if (!response.ok) throw new Error(data.error?.message || 'Fizzlayer could not link Home Assistant.');
      allow.hidden = true;
      show('Home Assistant is allowed. Go back to Home Assistant and choose which sensors to share. You can close this tab.');
    } catch (error) {
      allow.disabled = false;
      show(error.message);
    }
  }

  async function start() {
    if (!valid) {
      show('This link is missing its pairing state. Start again from Home Assistant or the Fizzlayer Sensors page.');
      return;
    }
    let me = null;
    try {
      me = await account();
    } catch {
      show('Fizzlayer could not be reached. Try again in a moment.');
      next.hidden = false;
      return;
    }
    if (!me) {
      show('Sign in to Fizzlayer in this browser, then come back to this tab and choose Allow.');
      next.hidden = false;
      return;
    }
    show(`Allow Home Assistant to send sensor readings to ${me.username}? The token stays on Home Assistant. You do not copy it.`);
    allow.hidden = false;
    allow.focus();
  }

  allow.addEventListener('click', () => { allowLink(); });
  retry.addEventListener('click', () => {
    next.hidden = true;
    show('Checking your Fizzlayer account…');
    start();
  });
  start();
})();
