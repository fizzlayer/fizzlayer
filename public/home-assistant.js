(() => {
  const redirect = 'https://my.home-assistant.io/redirect/config_flow_start?domain=fizzlayer';

  function openHomeAssistant() {
    const popup = window.open(redirect, '_blank', 'noopener');
    return popup;
  }

  document.querySelectorAll('[data-connect-ha]').forEach((button) => {
    button.addEventListener('click', (event) => {
      const popup = openHomeAssistant();
      if (popup) event.preventDefault();
      const note = document.getElementById('ha-connect-message');
      if (!note) return;
      note.textContent = popup
        ? 'Home Assistant is opening. Choose Allow on the Fizzlayer tab, then pick the sensors to share.'
        : 'Your browser blocked the window. Allow pop-ups, or open the Sensors page and use Connect Home Assistant there.';
    });
  });

  const list = document.getElementById('ha-connections');
  const codeBox = document.getElementById('ha-code');
  const codeDetails = document.getElementById('ha-code-details');
  if (!list) return;

  async function api(path, method = 'GET', body) {
    const response = await fetch(path, {
      method,
      credentials: 'same-origin',
      headers: { 'content-type': 'application/json' },
      body: body ? JSON.stringify(body) : undefined,
    });
    const data = await response.json();
    if (!response.ok) throw new Error(data.error?.message || 'Please try again.');
    return data;
  }

  function render(connections) {
    list.replaceChildren();
    const visible = connections.filter((item) => !item.revoked);
    if (!visible.length) {
      list.hidden = true;
      return;
    }
    list.hidden = false;
    for (const connection of visible) {
      const item = document.createElement('li');
      const seen = connection.last_seen_at ? `Last reading ${new Date(connection.last_seen_at).toLocaleString()}.` : 'No readings yet.';
      const text = document.createElement('span');
      text.textContent = `${connection.name} · ${connection.sensors} ${connection.sensors === 1 ? 'sensor' : 'sensors'}. ${seen}`;
      const revoke = document.createElement('button');
      revoke.type = 'button';
      revoke.className = 'secondary';
      revoke.textContent = 'Revoke';
      revoke.addEventListener('click', async () => {
        if (!confirm(`Revoke ${connection.name}? Its sensors will stop and the device slots will free.`)) return;
        revoke.disabled = true;
        try {
          await api('/api/devices', 'POST', { action: 'ha_revoke', id: connection.id });
          await refresh();
          document.dispatchEvent(new CustomEvent('fizz:changed'));
        } catch (error) {
          const note = document.getElementById('ha-connect-message');
          if (note) note.textContent = error.message;
          revoke.disabled = false;
        }
      });
      item.append(text, revoke);
      list.append(item);
    }
  }

  async function refresh() {
    const result = await api('/api/devices', 'POST', { action: 'ha_list' });
    render(result.connections || []);
  }

  if (codeDetails && codeBox) {
    codeDetails.addEventListener('toggle', async () => {
      if (!codeDetails.open || codeBox.dataset.ready === 'true') return;
      codeBox.textContent = 'Creating a code…';
      try {
        const prepared = await api('/api/devices', 'POST', { action: 'ha_prepare' });
        codeBox.dataset.ready = 'true';
        const expires = new Date(prepared.expires_at).toLocaleTimeString();
        codeBox.textContent = `${prepared.code} · expires ${expires}`;
      } catch (error) {
        codeBox.textContent = error.message;
      }
    });
  }

  refresh().catch(() => {});
  addEventListener('fizz:changed', () => { refresh().catch(() => {}); });
})();
