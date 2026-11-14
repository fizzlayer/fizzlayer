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

function when(value) {
  if (!value) return '';
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? '' : date.toLocaleString();
}

function schedulerRow(scheduler) {
  const status = scheduler && scheduler.status;
  const last = when(scheduler && scheduler.last_success_at);
  const recent = Array.isArray(scheduler && scheduler.recent)
    ? scheduler.recent.map(when).filter(Boolean)
    : [];
  const history = recent.length ? ` Recent runs: ${recent.join(', ')}.` : '';
  if (status === 'healthy') {
    return row('Alert scheduler', 'operational', 'Healthy', `Last successful run ${last}. A run is healthy for five minutes.${history}`);
  }
  if (status === 'stale') {
    const detail = last
      ? `Last successful run ${last}, which is more than five minutes ago. Silence alerts may not fire.${history}`
      : 'No successful run is recorded. Silence alerts are not being checked.';
    return row('Alert scheduler', 'degraded', 'Stale', detail);
  }
  if (status === 'unconfigured') {
    return row('Alert scheduler', 'unreported', 'Not configured', 'The database is not configured, so there is no scheduler record.');
  }
  return row('Alert scheduler', 'unavailable', 'Unknown', 'The scheduler record could not be read.');
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
    items.push(schedulerRow(data.scheduler));
  } catch {
    items.push(row('API', 'unavailable', 'Unavailable', 'The status check did not answer.'));
    items.push(row('Alert scheduler', 'unavailable', 'Unavailable', 'The status check did not answer.'));
  }
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
