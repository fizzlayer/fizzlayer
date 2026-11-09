(() => {
  const message = document.getElementById('ha-message');
  const install = document.getElementById('ha-install');
  const form = document.getElementById('ha-form');
  const codeInput = document.getElementById('ha-confirm');
  const allow = document.getElementById('ha-allow');
  const next = document.getElementById('ha-next');
  const retry = document.getElementById('ha-retry');
  const state = new URLSearchParams(location.search).get('state') || '';
  const valid = /^[0-9a-f]{64}$/.test(state);
  let username = '';

  function show(text) {
    message.textContent = text;
  }

  async function account() {
    const response = await fetch('/api/me', { credentials: 'same-origin' });
    if (!response.ok) return null;
    return response.json();
  }

  async function preview() {
    const response = await fetch('/api/devices', {
      method: 'POST',
      credentials: 'same-origin',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ action: 'ha_preview', state }),
    });
    if (!response.ok) return null;
    return response.json();
  }

  function describe(info) {
    if (!info || info.status === 'waiting') {
      install.hidden = true;
      return;
    }
    const version = info.ha_version ? `, version ${info.ha_version}` : '';
    install.hidden = false;
    install.textContent = `${info.name || 'Home Assistant'}${version} is asking to connect.`;
  }

  async function allowLink(event) {
    event.preventDefault();
    allow.disabled = true;
    show('Linking Home Assistant…');
    try {
      const response = await fetch('/api/devices', {
        method: 'POST',
        credentials: 'same-origin',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ action: 'ha_authorize', state, code: codeInput.value }),
      });
      const data = await response.json();
      if (!response.ok) throw new Error(data.error?.message || 'Fizzlayer could not link Home Assistant.');
      form.hidden = true;
      show(`Home Assistant is allowed for ${username}. Go back and choose which sensors to share. You can close this tab.`);
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
      show('Sign in to Fizzlayer in this browser, then come back to this tab and enter the code.');
      next.hidden = false;
      return;
    }
    username = me.username;
    show(`Type the 6-digit code shown on your Home Assistant screen to connect it to ${username}. Do not use a code from a message.`);
    form.hidden = false;
    codeInput.focus();
    const watch = async () => {
      if (form.hidden) return;
      try {
        describe(await preview());
      } catch {
        // The next poll retries.
      }
      setTimeout(watch, 2000);
    };
    watch();
  }

  form.addEventListener('submit', (event) => { allowLink(event); });
  retry.addEventListener('click', () => {
    next.hidden = true;
    show('Checking your Fizzlayer account…');
    start();
  });
  start();
})();