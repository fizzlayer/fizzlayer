const list = document.getElementById('status-list');
const checked = document.getElementById('status-checked');

function row(name, state, label, detail) {
  const item = document.createElement('li');
  const copy = document.createElement('div');
  const title = document.createElement('strong');
  title.textContent = name;
  const note = document.createElement('p');
  note.textContent = detail;
  copy.append(title, note);
  const badge = document.createElement('span');
  badge.className = 'status-state';
  badge.dataset.state = state;
  badge.textContent = label;
  item.append(copy, badge);
  return item;
}

async function read(path) {
  const response = await fetch(path, { cache: 'no-store' });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(data.error?.message || 'The check failed.');
  return data;
}

async function load() {
  const items = [];
  try {
    const data = await read('/api/status');
    const ok = data.status === 'ok';
    const database = data.database === 'connected'
      ? 'The API and its database responded.'
      : `Database: ${data.database || 'unknown'}.`;
    items.push(row('API', ok ? 'operational' : 'degraded', ok ? 'Operational' : 'Degraded', database));
  } catch {
    items.push(row('API', 'unavailable', 'Unavailable', 'The status check did not answer.'));
  }
  items.push(row(
    'Alert scheduler',
    'unreported',
    'Not reported',
    'The public status check does not include silence scans or queued calls.',
  ));
  try {
    const data = await read('/api/stream');
    items.push(row(
      'Live streaming',
      data.enabled === true ? 'operational' : 'degraded',
      data.enabled === true ? 'Operational' : 'Degraded',
      data.enabled === true
        ? 'WebSocket and MQTT-over-WebSocket addresses are available.'
        : 'Live streaming is not configured.',
    ));
  } catch {
    items.push(row('Live streaming', 'unavailable', 'Unavailable', 'The stream check did not answer.'));
  }
  list.replaceChildren(...items);
  checked.textContent = `Checked just now from this browser (${new Date().toLocaleString()}). This page does not keep an uptime history or state an SLA.`;
}

load();
