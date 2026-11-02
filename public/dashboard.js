(() => {
  const $ = (id) => document.getElementById(id);
  const kinds = window.fizzKinds;
  const detail = window.fizzSensorDetail;
  const comparatorText = { gt: 'above', gte: 'at or above', lt: 'below', lte: 'at or below' };
  const statusText = { watching: 'WATCHING', triggered: 'TRIGGERED', paused: 'PAUSED' };
  const notifyNoun = { call: 'Call' };
  const freshMs = 15 * 60 * 1000;
  const eventPreview = 5;
  let timer = null;
  let sensors = [];
  let alertData = { rules: [], events: [] };
  let showAllEvents = false;
  let requestInFlight = false;
  let refreshQueued = false;
  let sessionGeneration = 0;
  let chatHistory = [];
  let chatBusy = false;
  let voiceLocked = false;
  let chatController = null;
  let sensorFilter = 'all';
  const readingHistory = new Map();

  async function api(path, method = 'GET', body, signal) {
    const response = await fetch(path, { method, credentials: 'same-origin', signal, headers: { 'content-type': 'application/json' }, body: body ? JSON.stringify(body) : undefined });
    const data = await response.json();
    if (!response.ok) throw new Error(data.error?.message || 'Please try again.');
    return data;
  }

  function node(tag, className, content) {
    const element = document.createElement(tag);
    if (className) element.className = className;
    if (content !== undefined) element.textContent = content;
    return element;
  }
  function icon(name) {
    const element = node('span', `fa fa-${name}`);
    element.setAttribute('aria-hidden', 'true');
    return element;
  }

  function sensorName(sensor) {
    return sensor ? sensor.name || kinds.get(sensor.kind).label : 'Removed sensor';
  }

  // Keep an honest, bounded trend from readings actually seen in this session.
  // Do not turn simulated values into a claimed history or invent missing samples.
  function recordReading(sensor) {
    const reading = sensor.latest_reading;
    if (!Number.isFinite(reading?.numeric_value)) return;
    const stamp = reading.observed_at || reading.received_at;
    if (!stamp) return;
    let history = readingHistory.get(sensor.id);
    if (!history || history.metric !== reading.metric || history.unit !== reading.unit) {
      history = { metric: reading.metric, unit: reading.unit, points: [] };
      readingHistory.set(sensor.id, history);
    }
    if (!history.points.some((point) => point.stamp === stamp)) {
      history.points.push({ stamp, value: reading.numeric_value });
      history.points.sort((a, b) => new Date(a.stamp) - new Date(b.stamp));
      history.points = history.points.slice(-24);
    }
  }

  function sensorTrend(sensor) {
    const history = readingHistory.get(sensor.id);
    if (!history || history.points.length < 2) return node('p', 'trend-waiting', 'Collecting recent readings…');
    const svgNS = 'http://www.w3.org/2000/svg';
    const svg = document.createElementNS(svgNS, 'svg');
    svg.setAttribute('viewBox', '0 0 240 32');
    svg.setAttribute('preserveAspectRatio', 'none');
    svg.setAttribute('class', 'sensor-trend');
    svg.setAttribute('role', 'img');
    const values = history.points.map((point) => point.value);
    const min = Math.min(...values);
    const max = Math.max(...values);
    svg.setAttribute('aria-label', `${kinds.metricLabel(history.metric)}: ${values.length} readings since opening this workspace, ranging from ${kinds.formatValue(min, history.unit)} to ${kinds.formatValue(max, history.unit)}.`);
    const path = document.createElementNS(svgNS, 'path');
    const firstTime = new Date(history.points[0].stamp).getTime();
    const timeRange = new Date(history.points.at(-1).stamp).getTime() - firstTime;
    const points = history.points.map((point, index) => {
      const x = timeRange > 0 ? 3 + ((new Date(point.stamp).getTime() - firstTime) / timeRange) * 234 : 3 + (index / (values.length - 1)) * 234;
      const y = max === min ? 16 : 28 - ((point.value - min) / (max - min)) * 24;
      return `${index ? 'L' : 'M'}${x.toFixed(1)},${y.toFixed(1)}`;
    });
    path.setAttribute('d', points.join(' '));
    path.setAttribute('fill', 'none');
    path.setAttribute('stroke', 'currentColor');
    path.setAttribute('stroke-width', '1.5');
    path.setAttribute('stroke-linecap', 'round');
    path.setAttribute('stroke-linejoin', 'round');
    path.setAttribute('vector-effect', 'non-scaling-stroke');
    svg.append(path);
    return svg;
  }

  function renderSummary() {
    $('total-sensors').textContent = sensors.length;
    $('live-devices').textContent = sensors.filter((sensor) => sensor.mode !== 'simulated').length;
    const samples = sensors.filter((sensor) => sensor.mode === 'simulated').length;
    $('sample-sensors').textContent = samples;
    $('active-alerts').textContent = alertData.rules.filter((rule) => rule.enabled !== false).length;
    $('sample-notice').hidden = samples === 0;
  }

  function renderSensors() {
    const list = $('live-sensors');
    list.replaceChildren();
    $('live-empty').hidden = sensors.length > 0;
    for (const id of readingHistory.keys()) {
      if (!sensors.some((sensor) => sensor.id === id)) readingHistory.delete(id);
    }
    const visibleSensors = sensors.filter((sensor) => sensorFilter === 'all' || (sensorFilter === 'sample' ? sensor.mode === 'simulated' : sensor.mode !== 'simulated'));
    $('filter-empty').hidden = sensors.length === 0 || visibleSensors.length > 0;
    renderSummary();
    for (const sensor of sensors) {
      recordReading(sensor);
      if (!visibleSensors.includes(sensor)) continue;
      const info = kinds.get(sensor.kind);
      const card = node('article', 'live-card');
      card.dataset.sensorId = sensor.id;
      card.style.setProperty('--sensor-color', info.color);
      const top = node('div', 'live-card-top');
      const title = node('div', 'live-card-title');
      // The whole card opens the detail view; this button is the accessible target and covers the card.
      const open = node('button', 'live-card-open');
      open.type = 'button';
      open.setAttribute('aria-label', `Open details for ${sensorName(sensor)}`);
      open.addEventListener('click', () => detail.open(sensor, open));
      title.append(node('h3', '', sensorName(sensor)), node('span', '', info.label.toUpperCase()));
      const mode = node('span', `mode-pill ${sensor.mode}`, sensor.mode === 'simulated' ? 'SAMPLE' : sensor.mode === 'phone' ? 'PHONE' : 'API');
      mode.title = sensor.mode === 'simulated' ? 'Simulated sample data' : sensor.mode === 'phone' ? 'Paired phone sensor' : 'API sensor';
      top.append(kinds.badge(sensor.kind), title, mode);
      const latest = sensor.latest_reading;
      const foot = node('p', 'live-foot');
      foot.append(node('span', '', latest ? `Updated ${new Date(latest.observed_at || latest.received_at).toLocaleTimeString()}` : sensor.mode === 'simulated' ? 'A sample will appear shortly' : 'Connect your sensor to send its first reading'));
      const more = node('span', 'live-card-more', 'Details');
      more.setAttribute('aria-hidden', 'true');
      more.append(node('span', 'fa-arrow fa-arrow-right'));
      foot.append(more);
      if (detail.metricCount(sensor) > 1) {
        // Devices that report several metrics (a laptop's CPU, memory, and disk) show each one.
        card.classList.add('multi-metric');
        card.append(open, top, detail.tiles(sensor), foot);
      } else {
        const metric = node('p', 'live-metric', latest?.metric ? kinds.metricLabel(latest.metric) : 'Awaiting first reading');
        const value = node('p', 'live-value', kinds.formatReading(latest));
        card.append(open, top, metric, value, sensorTrend(sensor), foot);
      }
      list.append(card);
    }
    const picker = $('alert-sensor');
    const prior = picker.value;
    picker.replaceChildren();
    for (const sensor of sensors) {
      const option = document.createElement('option');
      option.value = sensor.id;
      option.textContent = `${sensorName(sensor)} · ${kinds.get(sensor.kind).label}`;
      picker.append(option);
    }
    if (sensors.some((sensor) => sensor.id === prior)) picker.value = prior;
    updateMetricHint();
  }

  function updateMetricHint() {
    const sensor = sensors.find((item) => item.id === $('alert-sensor').value);
    if (sensor && (!$('alert-metric').value || $('alert-metric').dataset.autofill === 'true')) {
      $('alert-metric').value = sensor.latest_reading?.numeric_value != null ? sensor.latest_reading.metric : kinds.get(sensor.kind).metric;
      $('alert-metric').dataset.autofill = 'true';
    }
    if (sensor && (!$('alert-unit').value || $('alert-unit').dataset.autofill === 'true')) {
      $('alert-unit').value = sensor.latest_reading?.numeric_value != null ? sensor.latest_reading.unit : kinds.get(sensor.kind).unit;
      $('alert-unit').dataset.autofill = 'true';
    }
  }

  async function refresh() {
    if ($('dashboard').hidden) return;
    if (requestInFlight) { refreshQueued = true; return; }
    requestInFlight = true;
    $('dashboard-refresh').disabled = true;
    const version = sessionGeneration;
    try {
      const [inventory, alerts] = await Promise.all([api('/api/sensors'), api('/api/alerts')]);
      if (version !== sessionGeneration || $('dashboard').hidden) return;
      sensors = inventory.sensors || [];
      alertData = { rules: alerts.rules || [], events: alerts.events || [] };
      renderSensors();
      renderAlerts();
      detail.update(sensors);
      $('dashboard-subtitle').textContent = 'A clear view of your sensors, signals, and alerts.';
      $('dashboard-subtitle').classList.remove('refresh-error');
      $('dashboard-updated').textContent = `LAST SYNCED ${new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' })}`;
      void window.fizzVoiceClips.refresh(sensors);
    } catch (error) {
      if (version !== sessionGeneration || $('dashboard').hidden) return;
      $('dashboard-subtitle').textContent = `Unable to refresh sensor data: ${error.message}`;
      $('dashboard-subtitle').classList.add('refresh-error');
      $('dashboard-updated').textContent = 'SYNC UNAVAILABLE · RETRY WITH REFRESH';
    } finally {
      requestInFlight = false;
      $('dashboard-refresh').disabled = false;
      if (refreshQueued) { refreshQueued = false; void refresh(); }
    }
  }

  function conditionMet(value, comparator, threshold) {
    if (comparator === 'gt') return value > threshold;
    if (comparator === 'gte') return value >= threshold;
    if (comparator === 'lt') return value < threshold;
    return value <= threshold;
  }

  function limitText(item) {
    return `${comparatorText[item.comparator] || item.comparator} ${kinds.formatValue(item.threshold, item.unit)}`;
  }

  function silenceRule(rule) {
    return rule.kind === 'silence';
  }

  function minutesLabel(value) {
    const minutes = Number(value);
    if (!Number.isFinite(minutes)) return 'some time';
    const rounded = Math.abs(minutes) >= 10 ? Math.round(minutes) : Math.round(minutes * 10) / 10;
    return `${rounded} minute${rounded === 1 ? '' : 's'}`;
  }

  function timeElement(value) {
    const time = node('time', '', kinds.timeAgo(value));
    time.dateTime = new Date(value).toISOString();
    time.title = new Date(value).toLocaleString();
    return time;
  }

  function formatPhone(phone) {
    const match = /^\+1(\d{3})(\d{3})(\d{4})$/.exec(phone || '');
    return match ? `(${match[1]}) ${match[2]}-${match[3]}` : phone || '';
  }

  // How a triggered alert reached the owner's phone.
  function notifyNote(event) {
    if (!notifyNoun[event.notify_channel]) return null;
    const noun = notifyNoun[event.notify_channel];
    const phone = formatPhone(event.notify_phone);
    const text = {
      pending: `${noun} to ${phone} queued`,
      sending: `Calling ${phone}…`,
      sent: `Called ${phone}`,
      failed: `${noun} to ${phone} failed${event.notify_error ? `: ${event.notify_error}` : ''}`,
      skipped: event.notify_error || `${noun} skipped: sent one recently`,
    }[event.notify_status];
    if (!text) return null;
    const note = node('span', `notify${event.notify_status === 'failed' ? ' failed' : ''}`, text);
    if (event.notify_status === 'sent') note.append(' ', icon('check'));
    return note;
  }

  function ruleStatus(rule) {
    if (rule.enabled === false) return 'paused';
    return rule.armed === false ? 'triggered' : 'watching';
  }

  function alertButton(label, className, action, ruleId, handler) {
    const button = node('button', className, label);
    button.type = 'button';
    button.dataset.action = action;
    button.dataset.ruleId = ruleId;
    button.addEventListener('click', async () => {
      button.disabled = true;
      $('alert-message').textContent = '';
      try { await handler(); await refresh(); }
      catch (error) { $('alert-message').textContent = error.message; button.disabled = false; }
    });
    return button;
  }

  function eventItem(event) {
    const sensor = sensors.find((item) => item.id === event.sensor_id);
    const fresh = Date.now() - new Date(event.created_at || event.observed_at).getTime() < freshMs;
    const item = node('li', `alert-item event${fresh ? ' fresh' : ''}`);
    item.style.setProperty('--sensor-color', kinds.get(sensor?.kind).color);
    const body = node('div', 'alert-body');
    const head = node('div', 'alert-item-head');
    head.append(node('strong', '', sensorName(sensor)));
    if (fresh) head.append(node('span', 'alert-new', 'NEW'));
    head.append(timeElement(event.observed_at || event.created_at));
    const silence = event.event_kind === 'silence';
    const recovery = event.event_kind === 'recovery';
    const line = node('p', 'alert-line', recovery ? 'Reporting again' : silence ? 'No reading for ' : `${kinds.metricLabel(event.metric)} hit `);
    if (silence) line.append(node('span', 'alert-value', minutesLabel(event.numeric_value)));
    else if (!recovery) line.append(node('span', 'alert-value', kinds.formatValue(event.numeric_value, event.unit)));
    const meta = node('p', 'alert-meta');
    if (recovery) {
      meta.append(node('span', '', 'The sensor sent a reading'));
    } else if (silence) {
      meta.append(node('span', '', `Limit: ${minutesLabel(event.threshold)} without a reading`));
    } else {
      meta.append(
        node('span', '', `Limit: ${limitText(event)}`),
        node('span', 'over', event.numeric_value === event.threshold ? 'At the limit' : `${kinds.formatValue(Math.abs(event.numeric_value - event.threshold), event.unit)} past the limit`),
      );
    }
    meta.append(node('span', '', new Date(event.observed_at || event.created_at).toLocaleString([], { dateStyle: 'medium', timeStyle: 'short' })));
    const note = notifyNote(event);
    if (note) meta.append(note);
    body.append(head, line, meta);
    item.append(kinds.badge(sensor?.kind), body);
    return item;
  }

  function ruleItem(rule) {
    const sensor = sensors.find((item) => item.id === rule.sensor_id);
    const status = ruleStatus(rule);
    const item = node('li', `alert-item rule ${status}`);
    item.style.setProperty('--sensor-color', kinds.get(sensor?.kind).color);
    const body = node('div', 'alert-body');
    const head = node('div', 'alert-item-head');
    head.append(node('strong', '', sensorName(sensor)), node('span', `alert-status ${status}`, statusText[status]));
    const line = node('p', 'alert-line', silenceRule(rule)
      ? `Alert when no reading arrives for ${minutesLabel(rule.silence_minutes)}`
      : `Alert when ${kinds.metricLabel(rule.metric)} is ${limitText(rule)}`);
    line.title = silenceRule(rule) ? 'No reading' : rule.metric;
    const meta = node('p', 'alert-meta');
    if (notifyNoun[rule.notify_channel]) meta.append(node('span', 'notify', `Calls ${formatPhone(rule.notify_phone)}`));
    if (silenceRule(rule) && rule.notify_recovery) meta.append(node('span', '', 'Notifies when readings resume'));
    const latest = sensor?.latest_reading;
    if (silenceRule(rule)) {
      const heard = sensor?.last_received_at;
      meta.append(node('span', '', heard ? `Last reading ${kinds.timeAgo(heard)}` : 'No reading yet. This alert calls only after a reading arrives and then stops.'));
    } else if (latest?.metric === rule.metric && typeof latest.numeric_value === 'number' && (latest.unit || '') === (rule.unit || '')) {
      const now = node('span', '', 'Now ');
      now.append(node('span', 'alert-value', kinds.formatValue(latest.numeric_value, latest.unit)));
      const gap = kinds.formatValue(Math.abs(latest.numeric_value - rule.threshold), rule.unit);
      const met = conditionMet(latest.numeric_value, rule.comparator, rule.threshold);
      const distance = latest.numeric_value === rule.threshold ? 'At the limit' : met ? `${gap} past the limit` : `${gap} from the limit`;
      meta.append(now, node('span', met ? 'over' : '', distance));
    } else if (sensor) {
      meta.append(node('span', '', 'Waiting for a matching reading'));
    }
    const fired = alertData.events.filter((event) => event.rule_id === rule.id);
    if (fired.length) {
      const last = node('span', '', 'Last fired ');
      last.append(timeElement(fired[0].observed_at || fired[0].created_at));
      meta.append(last, node('span', '', `${fired.length}× in recent history`));
    } else {
      meta.append(node('span', '', 'Has not fired yet'));
    }
    if (status === 'triggered') meta.append(node('span', 'over', silenceRule(rule) ? 'Resets when a reading arrives' : 'Resets when the reading returns inside the limit'));
    const actions = node('div', 'alert-actions');
    const paused = status === 'paused';
    // Rules on removed sensors cannot be resumed, so they only offer Delete.
    if (sensor) actions.append(alertButton(paused ? 'Resume' : 'Pause', 'secondary', 'toggle', rule.id, () => api('/api/alerts', 'PATCH', { id: rule.id, enabled: paused })));
    actions.append(alertButton('Delete', 'alert-delete', 'delete', rule.id, async () => {
      if (confirm(`Delete the alert for ${sensorName(sensor)}?`)) await api('/api/alerts', 'DELETE', { id: rule.id });
    }));
    body.append(head, line, meta, actions);
    item.append(kinds.badge(sensor?.kind), body);
    return item;
  }

  function renderAlerts() {
    const list = $('dashboard-alerts');
    const focused = document.activeElement?.closest?.('#dashboard-alerts [data-action]');
    const focusKey = focused ? [focused.dataset.action, focused.dataset.ruleId] : null;
    list.replaceChildren();
    const { rules, events } = alertData;
    const counts = { watching: 0, triggered: 0, paused: 0 };
    for (const rule of rules) counts[ruleStatus(rule)]++;
    const summary = $('alert-summary');
    summary.replaceChildren();
    for (const status of ['triggered', 'watching', 'paused']) {
      if (counts[status]) summary.append(node('span', `alert-chip ${status}`, `${counts[status]} ${status.toUpperCase()}`));
    }
    if (!rules.length && !events.length) {
      list.append(node('p', 'dashboard-empty', 'No alerts yet. Set a threshold or a silence alert below, or ask Fizz.'));
      return;
    }
    if (events.length) {
      const group = node('div', 'alert-group');
      group.append(node('h3', '', 'RECENT TRIGGERS'));
      const items = node('ol', 'alert-items');
      for (const event of showAllEvents ? events : events.slice(0, eventPreview)) items.append(eventItem(event));
      group.append(items);
      if (events.length > eventPreview) {
        const more = node('button', 'alert-more', showAllEvents ? 'Show fewer' : `Show all ${events.length} triggers`);
        more.type = 'button';
        more.dataset.action = 'more';
        more.dataset.ruleId = '';
        more.setAttribute('aria-expanded', String(showAllEvents));
        more.addEventListener('click', () => { showAllEvents = !showAllEvents; renderAlerts(); });
        group.append(more);
      }
      list.append(group);
    }
    if (rules.length) {
      const group = node('div', 'alert-group');
      group.append(node('h3', '', 'RULES'));
      const items = node('ul', 'alert-items');
      const rank = { triggered: 0, watching: 1, paused: 2 };
      for (const rule of [...rules].sort((a, b) => rank[ruleStatus(a)] - rank[ruleStatus(b)])) items.append(ruleItem(rule));
      group.append(items);
      list.append(group);
    }
    if (focusKey) list.querySelector(`[data-action="${focusKey[0]}"][data-rule-id="${focusKey[1]}"]`)?.focus();
  }

  function appendMessage(role, message) {
    const item = node('div', `chat-message ${role}`);
    item.append(node('span', '', role === 'agent' ? 'FIZZ' : 'YOU'), node('p', '', message));
    $('chat-messages').append(item);
    $('chat-messages').scrollTop = $('chat-messages').scrollHeight;
    return item;
  }

  function appendThinking() {
    const item = appendMessage('agent', 'Thinking');
    item.classList.add('thinking');
    const dots = node('span', 'thinking-dots');
    for (let i = 0; i < 3; i++) dots.append(node('span', '', '.'));
    item.querySelector('p').append(dots);
    return item;
  }

  function createdAlertSummary(rule) {
    const sensor = sensors.find((item) => item.id === rule.sensor_id);
    const what = silenceRule(rule) ? `no reading for ${minutesLabel(rule.silence_minutes)}` : `${kinds.metricLabel(rule.metric)} ${limitText(rule)}`;
    const summary = node('p', 'alert-meta', `Active alert · ${sensorName(sensor)} · ${what}`);
    summary.style.setProperty('--sensor-color', kinds.get(sensor?.kind).color);
    return summary;
  }

  function setupSummary(result) {
    const panel = node('div', 'chat-setup');
    const link = node('a', '', (result.pairing || result.pairing_setup) ? 'View device setup in Sensors' : 'Manage this sensor');
    link.href = (result.pairing || result.pairing_setup) ? '/sensors.html#pair-device' : '/sensors.html#your-sensors-title';
    if (result.pairing_setup) {
      panel.append(node('strong', '', 'Connect your Linux device'), node('p', '', 'Run these commands in a terminal on your Raspberry Pi or Linux device, then paste the displayed pairing code into this chat.'));
      const commands = node('pre');
      commands.append(node('code', '', `curl -fsSL ${location.origin}/install.sh | sh\nFIZZ_API=${location.origin} fizz pair`));
      panel.append(commands, node('p', '', 'After I claim the code, approve the request in that terminal and run fizz run --every 60.'));
    }
    if (result.sensor_setup) {
      panel.append(node('strong', '', 'Sensor API credentials'), node('p', '', 'Copy this key now. It is shown once and is not included in chat history sent to Fizz.'));
      const idLabel = node('p', '', 'Sensor ID');
      const keyLabel = node('p', '', 'API key');
      const id = node('code', '', result.sensor_setup.sensor_id);
      const key = node('code', '', result.sensor_setup.api_key);
      const copy = node('button', 'secondary', 'Copy API key');
      copy.type = 'button';
      const status = node('p', 'chat-setup-status');
      status.setAttribute('role', 'status');
      copy.addEventListener('click', async () => {
        try {
          await navigator.clipboard.writeText(result.sensor_setup.api_key);
          status.textContent = 'API key copied.';
        } catch { status.textContent = 'Select the API key above and copy it manually.'; }
      });
      panel.append(idLabel, id, keyLabel, key, copy, status);
    }
    panel.append(link);
    return panel;
  }

  function setThinking(active) {
    $('dashboard').classList.toggle('fizz-thinking', active);
  }

  function updateChatControls() {
    $('chat-form').querySelector('button[type=submit]').disabled = chatBusy || voiceLocked;
    $('chat-input').disabled = chatBusy || voiceLocked;
    window.fizzChatVoice?.setBusy(chatBusy);
    for (const prompt of document.querySelectorAll('[data-chat-prompt]')) prompt.disabled = chatBusy || voiceLocked;
  }

  async function sendMessage(message) {
    if (chatBusy || !message || $('dashboard').hidden) return null;
    $('chat-error').textContent = '';
    appendMessage('user', message);
    chatBusy = true;
    updateChatControls();
    const pending = appendThinking();
    setThinking(true);
    const version = sessionGeneration;
    const controller = new AbortController();
    chatController = controller;
    try {
      const result = await api('/api/chat', 'POST', { message, history: chatHistory.slice(-12) }, controller.signal);
      if (version !== sessionGeneration || $('dashboard').hidden) return null;
      pending.classList.remove('thinking');
      pending.querySelector('p').textContent = result.reply || 'I could not find an answer.';
      window.fizzVoiceClips.attach(pending, result.clips);
      chatHistory.push({ role: 'user', content: message }, { role: 'assistant', content: result.reply });
      chatHistory = chatHistory.slice(-12);
      if (result.rule) {
        pending.append(createdAlertSummary(result.rule));
      }
      if (result.sensor || result.pairing || result.pairing_setup) pending.append(setupSummary(result));
      if (result.rule || result.sensor) {
        try { await refresh(); }
        catch { $('chat-error').textContent = 'Your change was saved, but the dashboard could not refresh. Open Sensors or refresh the page to see it.'; }
      }
      $('chat-messages').scrollTop = $('chat-messages').scrollHeight;
      return result;
    } catch (error) {
      if (version === sessionGeneration && error.name !== 'AbortError') {
        pending.classList.remove('thinking');
        pending.querySelector('p').textContent = 'I could not answer right now.';
        $('chat-error').textContent = error.message;
      }
      return null;
    } finally {
      if (version === sessionGeneration) {
        chatBusy = false;
        chatController = null;
        setThinking(false);
        updateChatControls();
        if (!voiceLocked) $('chat-input').focus();
      }
    }
  }

  window.fizzChat = {
    send: sendMessage,
    lock(active) { voiceLocked = active; updateChatControls(); },
  };

  $('dashboard-refresh').addEventListener('click', () => void refresh());
  for (const button of document.querySelectorAll('[data-sensor-filter]')) {
    button.addEventListener('click', () => {
      sensorFilter = button.dataset.sensorFilter;
      for (const filter of document.querySelectorAll('[data-sensor-filter]')) filter.setAttribute('aria-pressed', String(filter === button));
      renderSensors();
    });
  }
  for (const button of document.querySelectorAll('[data-chat-prompt]')) {
    button.addEventListener('click', () => {
      if (chatBusy || voiceLocked) return;
      window.fizzChatVoice?.stopPlayback();
      void sendMessage(button.dataset.chatPrompt);
    });
  }

  function syncAlertKind() {
    const silence = $('alert-kind').value === 'silence';
    for (const id of ['alert-metric', 'alert-operator', 'alert-threshold', 'alert-unit']) {
      const field = $(id);
      field.hidden = silence;
      if (id === 'alert-metric' || id === 'alert-threshold') field.required = !silence;
    }
    $('alert-minutes').hidden = !silence;
    $('alert-minutes').required = silence;
    $('alert-recovery-wrap').hidden = !silence;
    $('alert-form-label').textContent = silence ? 'Create a silence alert' : 'Create a threshold alert';
  }
  $('alert-kind').addEventListener('change', syncAlertKind);
  $('alert-sensor').addEventListener('change', updateMetricHint);
  $('alert-metric').addEventListener('input', () => { $('alert-metric').dataset.autofill = 'false'; });
  $('alert-unit').addEventListener('input', () => { $('alert-unit').dataset.autofill = 'false'; });
  $('alert-notify').addEventListener('change', () => {
    const phone = $('alert-notify').value !== 'none';
    $('alert-phone').hidden = !phone;
    $('alert-phone').required = phone;
    if (phone) $('alert-phone').focus();
  });
  $('quick-alert').addEventListener('submit', async (event) => {
    event.preventDefault();
    $('alert-message').textContent = '';
    const button = $('quick-alert').querySelector('button[type=submit]');
    button.disabled = true;
    try {
      const notify = $('alert-notify').value;
      const silence = $('alert-kind').value === 'silence';
      const rule = silence
        ? { kind: 'silence', sensor_id: $('alert-sensor').value, silence_minutes: Number($('alert-minutes').value), notify_recovery: $('alert-recovery').checked }
        : { sensor_id: $('alert-sensor').value, metric: $('alert-metric').value.trim(), comparator: $('alert-operator').value, threshold: Number($('alert-threshold').value), unit: $('alert-unit').value.trim() };
      if (notify !== 'none') Object.assign(rule, { notify_channel: notify, notify_phone: $('alert-phone').value.trim() });
      await api('/api/alerts', 'POST', rule);
      const ready = silence ? 'Fizz will call you if it goes quiet.' : 'Fizz will call you when it triggers.';
      $('alert-message').textContent = notify === 'none' ? 'Alert is active.' : `Alert is active. ${ready}`;
      $('alert-threshold').value = '';
      await refresh();
    } catch (error) { $('alert-message').textContent = error.message; }
    finally { button.disabled = false; }
  });
  $('chat-form').addEventListener('submit', async (event) => {
    event.preventDefault();
    const input = $('chat-input');
    const message = input.value.trim();
    if (!message || chatBusy || voiceLocked) return;
    input.value = '';
    window.fizzChatVoice?.stopPlayback();
    await sendMessage(message);
  });

  // "Set alert" in the sensor detail view fills the alert form with that sensor and metric.
  detail.configure({
    onAlert(sensor, reading) {
      const builder = document.querySelector('.alert-builder');
      if (builder) builder.open = true;
      $('alert-kind').value = 'threshold';
      syncAlertKind();
      $('alert-sensor').value = sensor.id;
      $('alert-metric').value = reading.metric;
      $('alert-metric').dataset.autofill = 'false';
      $('alert-unit').value = reading.unit || '';
      $('alert-unit').dataset.autofill = 'false';
      $('alert-threshold').value = '';
      $('alert-threshold').placeholder = `Now ${kinds.formatValue(reading.numeric_value, reading.unit)}`;
      $('quick-alert').scrollIntoView({ behavior: matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth', block: 'center' });
      $('alert-threshold').focus({ preventScroll: true });
    },
  });

  // Browser agents change data through WebMCP tools (webmcp.js); redraw when they do.
  addEventListener('fizz:changed', () => { void refresh(); });
  window.fizzDashboard = {
    start(username, initialSensors) {
      sessionGeneration++;
      document.title = 'Overview · Fizzlayer';
      $('dashboard-username').textContent = username;
      $('dashboard-subtitle').textContent = initialSensors?.length ? 'Your sensors are ready.' : 'Ask Fizz to add your first sensor or pair a device.';
      sensors = initialSensors || [];
      renderSensors();
      if (timer) clearInterval(timer);
      refresh();
      timer = setInterval(refresh, 5000);
      window.fizzChatVoice?.start();
    },
    stop() {
      sessionGeneration++;
      detail.close();
      chatController?.abort();
      chatController = null;
      chatHistory = [];
      chatBusy = false;
      voiceLocked = false;
      window.fizzChatVoice?.reset();
      updateChatControls();
      if (timer) clearInterval(timer);
      timer = null;
      sensors = [];
      readingHistory.clear();
      sensorFilter = 'all';
      for (const filter of document.querySelectorAll('[data-sensor-filter]')) filter.setAttribute('aria-pressed', String(filter.dataset.sensorFilter === 'all'));
      alertData = { rules: [], events: [] };
      showAllEvents = false;
      setThinking(false);
      window.fizzVoiceClips.reset();
      $('chat-messages').replaceChildren();
      appendMessage('agent', 'Hi, I’m Fizz. I can add sensors, pair devices, and help you understand your readings. What would you like to know?');
      $('chat-input').value = '';
      $('chat-error').textContent = '';
      $('alert-notify').value = 'none';
      $('alert-phone').value = '';
      $('alert-phone').hidden = true;
      $('alert-phone').required = false;
    },
  };
})();
