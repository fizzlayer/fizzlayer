/* A self-contained sample workspace. No auth, API requests, or real notifications. */
(() => {
  'use strict';
  const $ = (id) => document.getElementById(id);
  const kinds = window.fizzKinds;
  const seeds = [
    { id: 'cold-room', name: 'Cold Room', kind: 'temperature', zone: 'storage', base: 4.8, amplitude: .3, description: 'A temperature probe in cold storage. The sample watch list alerts when this room rises above 8 °C.' },
    { id: 'greenhouse', name: 'Greenhouse', kind: 'humidity', zone: 'greenhouse', base: 48.2, amplitude: .8, description: 'Humidity around the plants. A sample alert watches for readings below 45%.' },
    { id: 'warehouse', name: 'Warehouse', kind: 'temperature', zone: 'storage', base: 21.6, amplitude: .5, description: 'Ambient temperature on the warehouse floor, shown alongside the cold room in the Storage filter.' },
    { id: 'basement', name: 'Basement', kind: 'water', zone: 'storage', base: 0, amplitude: 0, description: 'A water flow sensor below the storage area. Zero flow means no water is moving in this sample.' },
    { id: 'office-air', name: 'Office Air', kind: 'gas', zone: 'office', base: 418, amplitude: 9, description: 'Sample carbon dioxide concentration from the office, in parts per million. Compare it with storage and greenhouse readings in one workspace.' },
    { id: 'grow-room', name: 'Grow Room', kind: 'temperature', zone: 'greenhouse', base: 22.4, amplitude: .3, description: 'A second greenhouse reading to show temperature and humidity together.' },
  ];
  let sensors, rules, events, tick, incident, paused, filter, busy, generation = 0, eventSeq = 0;
  let responseTimer;
  const valueText = (sensor) => kinds.formatValue(sensor.value, kinds.get(sensor.kind).unit);
  const sensorFor = (id) => sensors.find((sensor) => sensor.id === id);
  const breached = (rule) => rule.enabled && (rule.comparator === 'gt' ? sensorFor(rule.sensorId).value > rule.threshold : sensorFor(rule.sensorId).value < rule.threshold);

  function el(tag, className, text) {
    const element = document.createElement(tag);
    if (className) element.className = className;
    if (text !== undefined) element.textContent = text;
    return element;
  }

  function setText(node, text) {
    if (node.textContent !== text) node.textContent = text;
  }

  function arrowLabel(element, text) {
    if (text !== undefined) element.textContent = text;
    element.append(' ', el('span', 'fa-arrow fa-arrow-diagonal'));
    element.lastElementChild.setAttribute('aria-hidden', 'true');
    return element;
  }

  function trendGeometry(sensor) {
    const values = sensor.history;
    const min = Math.min(...values) - .2;
    const range = Math.max(...values) - min + .2;
    return values.map((value, index) => `${index ? 'L' : 'M'}${(3 + index * 314 / (values.length - 1)).toFixed(1)},${(64 - (value - min) / range * 58).toFixed(1)}`).join(' ');
  }

  function paintTrend(svg, sensor) {
    svg.setAttribute('aria-label', `${sensor.name}: ${sensor.history.length} simulated readings, now ${valueText(sensor)}.`);
    svg.querySelector('path').setAttribute('d', trendGeometry(sensor));
  }

  function trend(sensor, detail = false) {
    const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    svg.setAttribute('viewBox', '0 0 320 70');
    svg.setAttribute('preserveAspectRatio', 'none');
    svg.setAttribute('class', 'sensor-trend');
    svg.style.setProperty('--sensor-color', kinds.get(sensor.kind).color);
    svg.setAttribute('role', 'img');
    // The line is redrawn every tick. Let the stable card button receive the click.
    svg.style.pointerEvents = 'none';
    const path = document.createElementNS(svg.namespaceURI, 'path');
    for (const [key, value] of Object.entries({ fill: 'none', stroke: 'currentColor', 'stroke-width': detail ? '2.5' : '1.8', 'stroke-linecap': 'round', 'stroke-linejoin': 'round', 'vector-effect': 'non-scaling-stroke' })) path.setAttribute(key, value);
    svg.append(path);
    paintTrend(svg, sensor);
    return svg;
  }

  function renderSensors() {
    // Keep card nodes stable while readings update, preserving keyboard focus.
    for (const sensor of sensors) {
      const card = $(`sensor-${sensor.id}`);
      card.hidden = filter !== 'all' && sensor.zone !== filter;
      card.classList.toggle('incident', rules.some((rule) => rule.sensorId === sensor.id && breached(rule)));
      card.querySelector('.live-value').textContent = valueText(sensor);
      // Update the chart in place. Replacing the SVG drops a click that starts on it.
      paintTrend(card.querySelector('.sensor-trend'), sensor);
    }
    $('demo-updated').textContent = paused ? 'SAMPLE STREAM PAUSED' : `SAMPLE STREAM · UPDATED ${new Date().toLocaleTimeString()}`;
  }

  function buildSensors() {
    $('demo-sensors').replaceChildren();
    $('rule-sensor').replaceChildren();
    for (const sensor of sensors) {
      const info = kinds.get(sensor.kind);
      const card = el('button', 'live-card');
      card.type = 'button';
      card.id = `sensor-${sensor.id}`;
      card.setAttribute('aria-label', `Explore ${sensor.name} sample readings`);
      card.style.setProperty('--sensor-color', info.color);
      const top = el('div', 'live-card-top');
      const title = el('div', 'live-card-title');
      title.append(el('h3', '', sensor.name), el('span', '', info.label.toUpperCase()));
      top.append(kinds.badge(sensor.kind), title, el('span', 'mode-pill simulated', 'SAMPLE'));
      const foot = el('div', 'live-foot');
      foot.append(el('span', '', sensor.zone === 'office' ? 'Office' : sensor.zone === 'storage' ? 'Storage' : 'Greenhouse'), arrowLabel(el('span', '', 'Explore')));
      card.append(top, el('p', 'live-metric', sensor.kind === 'gas' ? 'CO₂ concentration' : kinds.metricLabel(info.metric)), el('p', 'live-value', valueText(sensor)), trend(sensor), foot);
      card.addEventListener('click', () => {
        $('detail-title').textContent = sensor.name;
        $('detail-value').textContent = valueText(sensor);
        $('detail-chart').replaceChildren(trend(sensor, true));
        $('detail-description').textContent = sensor.description;
        $('sensor-dialog').showModal();
      });
      $('demo-sensors').append(card);
      const option = el('option', '', `${sensor.name} (${info.unit})`);
      option.value = sensor.id;
      $('rule-sensor').append(option);
    }
  }

  function ruleDescription(rule) {
    const sensor = sensorFor(rule.sensorId);
    return `${sensor.name} ${rule.comparator === 'gt' ? 'above' : 'below'} ${kinds.formatValue(rule.threshold, kinds.get(sensor.kind).unit)}`;
  }

  function showCall(eyebrow, title, transcript, footnote) {
    $('call-eyebrow').textContent = eyebrow;
    $('call-title').textContent = title;
    $('call-transcript').textContent = transcript;
    $('call-footnote').textContent = footnote;
    $('call-dialog').showModal();
  }

  function callPreview(event) {
    showCall(
      'SIMULATED PHONE ALERT',
      'Fizz is calling the shift lead.',
      `“Hi, this is Fizz from your Harbor & Pine demo workspace. ${event.name} is reading ${event.value}. Your alert is set for ${event.description}. Please check the sensor and the space.”`,
      'This is a call preview. No phone number is used and no real call is placed.',
    );
  }

  const digitWords = ['zero', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine'];
  let pairedPhones = [];
  let pendingPair = null;
  function demoPhone(input) {
    const digits = String(input || '').replace(/\D/g, '');
    const national = digits.length === 11 && digits.startsWith('1') ? digits.slice(1) : digits;
    if (national.length !== 10 || national[0] < '2' || national[3] < '2') return null;
    return `+1${national}`;
  }
  function spokenCode(code) {
    return [...code].map((digit) => digitWords[Number(digit)]).join('. ');
  }
  function formatDemoPhone(phone) {
    const match = /^\+1(\d{3})(\d{3})(\d{4})$/.exec(phone || '');
    return match ? `(${match[1]}) ${match[2]}-${match[3]}` : phone;
  }
  function renderPhones() {
    const list = $('demo-phones');
    list.replaceChildren();
    $('demo-phones-empty').hidden = pairedPhones.length > 0;
    for (const phone of pairedPhones) {
      const item = el('li', 'phone-row');
      item.append(el('strong', '', formatDemoPhone(phone)));
      const remove = el('button', 'secondary', 'Remove');
      remove.type = 'button';
      remove.addEventListener('click', () => {
        pairedPhones = pairedPhones.filter((item) => item !== phone);
        $('demo-phone-message').textContent = `${formatDemoPhone(phone)} was removed. New call previews need a paired number.`;
        renderPhones();
      });
      item.append(remove);
      list.append(item);
    }
  }
  function startDemoPair(raw) {
    const phone = demoPhone(raw);
    if (!phone) {
      $('demo-phone-message').textContent = 'Enter a valid US phone number. This demo will not call it.';
      return;
    }
    if (pairedPhones.includes(phone)) {
      $('demo-phone-message').textContent = `${formatDemoPhone(phone)} is already paired in this demo.`;
      return;
    }
    if (pendingPair && pendingPair.phone === phone && Date.now() < pendingPair.resendAt) {
      $('demo-phone-message').textContent = 'Wait a few seconds before calling this number again. In the app, the wait is one minute.';
      return;
    }
    const code = String(Math.floor(Math.random() * 1000000)).padStart(6, '0');
    const spoken = spokenCode(code);
    pendingPair = { phone, code, attempts: 0, expires: Date.now() + 10 * 60 * 1000, resendAt: Date.now() + 8000 };
    $('demo-confirm-form').hidden = false;
    $('demo-code').value = '';
    $('demo-phone-message').textContent = `Simulated call to ${formatDemoPhone(phone)}. Listen for the code, then enter it. It expires in 10 minutes.`;
    showCall(
      'SIMULATED PAIRING CALL',
      `Fizzlayer is calling ${formatDemoPhone(phone)}.`,
      `“This is Fizzlayer, calling to pair your phone. Your pairing code is: ${spoken}. I will repeat the code. Your pairing code is: ${spoken}. Enter this code in the dashboard. Goodbye.”`,
      'Simulated pairing call. The real app places this call and does not show the code on screen.',
    );
    $('demo-code').focus();
  }

  function ruleStatus(rule) {
    return !rule.enabled ? 'paused' : breached(rule) ? 'triggered' : 'watching';
  }

  function paintRuleItem(item, rule) {
    const status = ruleStatus(rule);
    const description = ruleDescription(rule);
    item.className = `alert-item demo-rule ${status}`;
    setText(item.querySelector('strong'), sensorFor(rule.sensorId).name);
    const badge = item.querySelector('.alert-status');
    badge.className = `alert-status ${status}`;
    setText(badge, status.toUpperCase());
    setText(item.querySelector('.alert-line'), `Alert when ${description}.`);
    setText(item.querySelector('.alert-actions > span'), rule.notification === 'call' ? 'Phone call preview · shift lead' : 'Dashboard notification');
    const toggle = item.querySelector('[data-rule-action="toggle"]');
    setText(toggle, rule.enabled ? 'Pause' : 'Resume');
    toggle.setAttribute('aria-label', `${rule.enabled ? 'Pause' : 'Resume'} alert: ${description}`);
    item.querySelector('[data-rule-action="delete"]').setAttribute('aria-label', `Delete alert: ${description}`);
  }

  function buildRuleItem(rule) {
    const item = el('li', 'alert-item demo-rule');
    item.dataset.ruleId = rule.id;
    const head = el('div', 'alert-item-head');
    head.append(el('strong'), el('span', 'alert-status'));
    const actions = el('div', 'alert-actions');
    const buttons = el('div');
    for (const action of ['toggle', 'delete']) {
      const button = el('button', action === 'delete' ? 'alert-delete' : 'secondary', action === 'delete' ? 'Delete' : '');
      button.type = 'button';
      button.dataset.ruleAction = action;
      button.addEventListener('click', () => {
        const current = rules.find((entry) => entry.id === rule.id);
        if (!current) return;
        if (action === 'delete') rules = rules.filter((entry) => entry.id !== current.id);
        else current.enabled = !current.enabled;
        evaluateRules();
        renderAlerts();
        renderSensors();
        if (action === 'delete') $('alert-builder').querySelector('summary').focus();
      });
      buttons.append(button);
    }
    actions.append(el('span'), buttons);
    item.append(head, el('p', 'alert-line'), actions);
    paintRuleItem(item, rule);
    return item;
  }

  function buildEventItem(event) {
    const item = el('div', 'demo-event');
    item.dataset.eventId = event.id;
    item.append(el('strong', '', `${event.name} crossed its threshold`), el('p', '', `${event.value} · ${event.description} · ${event.notification === 'call' ? 'Simulated phone alert ready' : 'Demo dashboard alert'}`));
    if (event.notification === 'call') {
      const button = arrowLabel(el('button', 'secondary', 'Preview the call'));
      button.type = 'button';
      button.addEventListener('click', () => callPreview(event));
      item.append(button);
    }
    return item;
  }

  // Keep rule and event nodes stable across the sample-stream tick. Replacing them
  // drops a click whose press and release land on different nodes.
  function placeItems(parent, items, key, build) {
    const keys = items.map(key);
    for (const child of [...parent.children]) {
      if (!keys.includes(child.dataset.key)) child.remove();
    }
    items.forEach((item, index) => {
      let node = [...parent.children].find((child) => child.dataset.key === keys[index]);
      if (!node) {
        node = build(item);
        node.dataset.key = keys[index];
      }
      if (parent.children[index] !== node) parent.insertBefore(node, parent.children[index] || null);
    });
  }

  function renderAlerts() {
    const active = rules.filter((rule) => rule.enabled);
    const triggered = rules.filter(breached);
    $('enabled-count').textContent = active.length;
    $('workspace-health').textContent = triggered.length ? 'Needs a look' : 'All clear';
    $('workspace-health').classList.toggle('incident', triggered.length > 0);
    $('health-detail').textContent = triggered.length ? `${triggered.length} threshold alert${triggered.length === 1 ? '' : 's'} triggered` : 'Readings within their limits';
    $('alert-summary').textContent = triggered.length ? `${triggered.length} triggered` : `${active.length} watching`;
    $('alert-summary').className = `alert-chip ${triggered.length ? 'triggered' : 'watching'}`;
    const list = $('demo-rules');
    if (!rules.length) {
      list.replaceChildren(el('li', 'dashboard-empty', 'No demo alerts. Create one below.'));
    } else {
      placeItems(list, rules, (rule) => rule.id, buildRuleItem);
      for (const rule of rules) paintRuleItem(list.querySelector(`[data-key="${CSS.escape(rule.id)}"]`), rule);
    }
    placeItems($('demo-events'), events.slice(0, 3), (event) => event.id, buildEventItem);
  }

  function evaluateRules() {
    for (const rule of rules) {
      const met = breached(rule);
      if (met && !rule.triggered) {
        const sensor = sensorFor(rule.sensorId);
        events.unshift({ id: `event-${generation}-${++eventSeq}`, name: sensor.name, value: valueText(sensor), description: ruleDescription(rule), notification: rule.notification });
        events = events.slice(0, 12);
      }
      rule.triggered = met;
    }
  }

  function addRule(sensorId, comparator, threshold, notification) {
    const duplicate = rules.some((rule) => rule.sensorId === sensorId && rule.comparator === comparator && rule.threshold === threshold && rule.enabled && rule.notification === notification);
    if (duplicate) return false;
    rules.push({ id: `rule-${generation}-${++tick}`, sensorId, comparator, threshold, notification, enabled: true, triggered: false });
    evaluateRules();
    renderAlerts();
    renderSensors();
    return true;
  }

  function message(role, text) {
    const item = el('div', `chat-message ${role}`);
    item.append(el('span', '', role === 'user' ? 'YOU' : 'FIZZ · DEMO'), el('p', '', text));
    $('demo-chat').append(item);
    while ($('demo-chat').children.length > 16) $('demo-chat').firstElementChild.remove();
    $('demo-chat').scrollTop = $('demo-chat').scrollHeight;
    return item;
  }

  const sensorAliases = [
    [/grow/, 'grow-room'],
    [/cold/, 'cold-room'],
    [/greenhouse|humid|plant/, 'greenhouse'],
    [/warehouse/, 'warehouse'],
    [/basement|water|leak/, 'basement'],
    [/office|\bair\b|co2|co₂/, 'office-air'],
  ];

  function namedSensor(phrase) {
    const text = phrase.toLowerCase();
    for (const [pattern, id] of sensorAliases) if (pattern.test(text)) return sensorFor(id);
    return null;
  }

  function alertSubject(question) {
    const text = question.toLowerCase();
    const patterns = [
      /\b(?:if|when|watch)\s+(?:the\s+)?([a-z0-9][a-z0-9'’ \-]{0,48}?)\s+(?:goes|is|gets|rises|drops|exceeds|falls|hits|reads|climbs|reaches|passes)\b/,
      /\b(?:for|on|about|watch)\s+(?:the\s+)?([a-z0-9][a-z0-9'’ \-]{0,48}?)\s+(?:above|below|over|under)\b/,
    ];
    for (const pattern of patterns) {
      const match = text.match(pattern);
      if (!match) continue;
      const start = match.index + match[0].indexOf(match[1]);
      return question.slice(start, start + match[1].length).replace(/^(?:my|the|a|an|our)\s+/i, '').replace(/\s+(?:temperature|temp|humidity|water|reading|sensor)$/i, '').trim();
    }
    return '';
  }

  function sensorNames() {
    return sensors.map((sensor) => sensor.name).join(', ');
  }

  function missingSensorReply(name) {
    const lead = name ? `“${name}” isn’t in this workspace.` : 'Which sensor should I watch?';
    return `${lead} This sample workspace has ${sensorNames()}. I can set that alert on one of them — say which — or you can add a sensor in the app from the Sensors page: sample data, an API device, a phone, or a paired Linux device.`;
  }

  function mentionsAgentConnection(text) {
    return /\bmcp\b|webmcp|agent token|llms\.txt|\bclaude\b|\bcursor\b|connect(?:ing)?(?:\s+\w+){0,4}\s+agent/.test(text);
  }

  function mcpAnswer(text) {
    const intro = /\bclaude\b/.test(text) ? 'Yes. Claude can read your sensors once it is connected over MCP. ' : '';
    return `${intro}Fizzlayer exposes an MCP server at /api/mcp (Streamable HTTP; https://fizzlayer.com/api/mcp on the hosted site). Create an agent token on the Agents page — tokens start with fizz_agent_ — and send Authorization: Bearer. The tools are list_sensors, get_readings, list_alerts, create_alert (when the token is allowed to create alerts), and pair_device. Setup is in /docs.html#mcp, with a shorter guide at /llms.txt. This demo does not connect a live agent.`;
  }

  function answer(question) {
    const text = question.toLowerCase();
    const cold = sensorFor('cold-room');
    if (mentionsAgentConnection(text)) return mcpAnswer(text);
    if (/(set|create|add|alert me|watch.*above)/.test(text) && /(alert|watch)/.test(text)) {
      const match = text.match(/(above|below|over|under)\s*(-?\d+(?:\.\d+)?)/);
      if (!match) return 'Try “Alert me if the cold room goes above 7 °C”, or use the threshold form below. Any phone notification here is a preview.';
      const subject = alertSubject(question);
      const vague = /^(it|this|that|something|reading|value|sensor|temperature|temp)$/i.test(subject);
      const sensor = subject && !vague ? namedSensor(subject) : namedSensor(text);
      if (!sensor) return missingSensorReply(subject && !vague ? subject : '');
      const comparator = /below|under/.test(match[1]) ? 'lt' : 'gt';
      const threshold = Number(match[2]);
      const wantsCall = /call|phone/.test(text);
      if (wantsCall && !pairedPhones.length) {
        return `I can watch ${sensor.name}, but a call needs a paired number. Use Phones above: the demo shows the code the real app would read aloud. Or ask for a dashboard alert, which does not call.`;
      }
      const notification = wantsCall ? 'call' : 'dashboard';
      const created = addRule(sensor.id, comparator, threshold, notification);
      return `${created ? 'Demo alert created' : 'That demo alert is already watching'}: ${sensor.name} ${comparator === 'gt' ? 'above' : 'below'} ${kinds.formatValue(threshold, kinds.get(sensor.kind).unit)}. ${notification === 'call' ? `It will preview a call to ${formatDemoPhone(pairedPhones[0])}.` : 'It will appear in Alerts & activity.'}`;
    }
    if (/alert|watch list|watching|threshold/.test(text)) return rules.length ? `Your sample watch list: ${rules.map((rule) => `${ruleDescription(rule)} (${rule.enabled ? breached(rule) ? 'triggered' : 'watching' : 'paused'})`).join('; ')}. Use “Simulate temperature spike” to try the cold room alert.` : 'Your sample watch list is empty. Create a threshold alert below to try it.';
    if (/cold|spike|warm/.test(text)) return `Cold Room is ${valueText(cold)} in the sample workspace. ${incident ? 'The temperature spike is active. Check Alerts & activity for any thresholds crossed; you can also preview the sample phone call.' : 'It is below the default 8 °C alert threshold. Its recent sample readings are steady. Try simulating a spike to see what happens.'}`;
    if (/greenhouse|plant|humid|grow/.test(text)) {
      const temperature = valueText(sensorFor('grow-room'));
      const humidity = valueText(sensorFor('greenhouse'));
      return `Grow Room is ${temperature} and Greenhouse humidity is ${humidity}. Here's what your sensors are seeing. The sample humidity alert watches for a drop below 45%.`;
    }
    if (/water|basement|leak/.test(text)) return `Basement flow is ${valueText(sensorFor('basement'))} in this sample. The simulated history shows no water flow. You can create an alert above 0 L/min to watch for a change.`;
    if (/air|co2|co₂|office/.test(text)) return `Office Air shows a sample CO₂ concentration of ${valueText(sensorFor('office-air'))}. Open its sensor card to explore the recent simulated history.`;
    if (/warehouse/.test(text)) return `Warehouse temperature is ${valueText(sensorFor('warehouse'))}. Use the Storage filter to compare it with the Cold Room and Basement readings.`;
    if (/summary|summari[sz]e|sensor|happening|status|overview/.test(text)) return `Here is your sample workspace: Cold Room ${valueText(cold)}, Warehouse ${valueText(sensorFor('warehouse'))}, Greenhouse ${valueText(sensorFor('greenhouse'))}, Grow Room ${valueText(sensorFor('grow-room'))}, Basement ${valueText(sensorFor('basement'))}, and Office Air ${valueText(sensorFor('office-air'))}. ${rules.filter(breached).length ? 'A threshold needs attention. See Alerts & activity.' : 'No enabled threshold is currently crossed.'}`;
    return 'I can walk you through this sample workspace. Ask about the cold room, greenhouse, water flow, or watch list. Try “Alert me if the cold room goes above 7 °C.” Demo replies use these sample readings.';
  }

  function setBusy(value) {
    busy = value;
    $('demo-chat-input').disabled = value;
    $('demo-chat-form').querySelector('button').disabled = value;
    for (const button of document.querySelectorAll('[data-prompt]')) button.disabled = value;
  }

  function ask(question) {
    if (busy || !question) return;
    const version = generation;
    message('user', question);
    const pending = message('agent', 'Checking the sample readings…');
    pending.classList.add('thinking');
    setBusy(true);
    responseTimer = setTimeout(() => {
      if (generation !== version) return;
      pending.querySelector('p').textContent = answer(question);
      pending.classList.remove('thinking');
      setBusy(false);
      $('demo-chat').scrollTop = $('demo-chat').scrollHeight;
    }, 650);
  }

  function update() {
    tick++;
    for (const [index, sensor] of sensors.entries()) {
      sensor.value = sensor.id === 'cold-room' && incident ? 9.2 : Math.max(0, Math.round((sensor.base + Math.sin(tick * .7 + index) * sensor.amplitude) * 10) / 10);
      sensor.history.push(sensor.value);
      sensor.history = sensor.history.slice(-24);
    }
    evaluateRules();
    renderSensors();
    renderAlerts();
  }

  function reset() {
    generation++;
    clearTimeout(responseTimer);
    tick = 0; incident = false; paused = false; filter = 'all'; events = [];
    sensors = seeds.map((seed, index) => ({ ...seed, value: seed.base, history: Array.from({ length: 24 }, (_, i) => Math.max(0, Math.round((seed.base + Math.sin(i * .55 + index) * seed.amplitude) * 10) / 10)) }));
    rules = [
      { id: 'cold-default', sensorId: 'cold-room', comparator: 'gt', threshold: 8, notification: 'call', enabled: true, triggered: false },
      { id: 'humidity-default', sensorId: 'greenhouse', comparator: 'lt', threshold: 45, notification: 'dashboard', enabled: true, triggered: false },
    ];
    for (const dialog of document.querySelectorAll('dialog[open]')) dialog.close();
    for (const button of document.querySelectorAll('[data-filter]')) button.setAttribute('aria-pressed', String(button.dataset.filter === 'all'));
    $('pause-demo').textContent = 'Pause readings';
    $('pause-demo').setAttribute('aria-pressed', 'false');
    $('stream-status').textContent = 'Sample stream running';
    arrowLabel($('simulate-spike'), 'Simulate temperature spike');
    $('scenario-result').hidden = true;
    document.querySelector('.demo-scenario').classList.remove('incident');
    pairedPhones = [];
    pendingPair = null;
    $('demo-phone-message').textContent = '';
    $('demo-phone').value = '';
    $('demo-code').value = '';
    $('demo-confirm-form').hidden = true;
    renderPhones();
    $('rule-message').textContent = '';
    $('demo-alert-form').reset();
    $('alert-builder').open = false;
    $('demo-chat-input').value = '';
    $('demo-chat').replaceChildren();
    setBusy(false);
    message('agent', 'Hi, I’m Fizz. This sample workspace has a cold room, a greenhouse, and an office. Ask me what the sensors are seeing, or try a temperature spike.');
    buildSensors();
    renderSensors();
    renderAlerts();
  }

  for (const button of document.querySelectorAll('[data-filter]')) button.addEventListener('click', () => {
    filter = button.dataset.filter;
    for (const filterButton of document.querySelectorAll('[data-filter]')) filterButton.setAttribute('aria-pressed', String(filterButton === button));
    renderSensors();
  });
  for (const button of document.querySelectorAll('[data-prompt]')) button.addEventListener('click', () => ask(button.dataset.prompt));
  $('demo-chat-form').addEventListener('submit', (event) => {
    event.preventDefault();
    const text = $('demo-chat-input').value.trim();
    if (!text || busy) return;
    $('demo-chat-input').value = '';
    ask(text);
  });
  $('simulate-spike').addEventListener('click', () => {
    incident = !incident;
    arrowLabel($('simulate-spike'), incident ? 'Resolve temperature spike' : 'Simulate temperature spike');
    $('scenario-result').hidden = !incident;
    document.querySelector('.demo-scenario').classList.toggle('incident', incident);
    update();
  });
  $('pause-demo').addEventListener('click', () => {
    paused = !paused;
    $('pause-demo').textContent = paused ? 'Resume readings' : 'Pause readings';
    $('pause-demo').setAttribute('aria-pressed', String(paused));
    $('stream-status').textContent = paused ? 'Sample stream paused' : 'Sample stream running';
    renderSensors();
  });
  $('reset-demo').addEventListener('click', reset);
  $('demo-alert-form').addEventListener('submit', (event) => {
    event.preventDefault();
    const threshold = Number($('rule-threshold').value);
    if (!Number.isFinite(threshold)) return;
    const notification = $('rule-notification').value;
    if (notification === 'call' && !pairedPhones.length) {
      $('rule-message').textContent = 'Pair a number above before a call preview can use one. Dashboard-only alerts do not need a phone.';
      return;
    }
    const created = addRule($('rule-sensor').value, $('rule-comparator').value, threshold, notification);
    $('rule-message').textContent = created
      ? (notification === 'call' ? `Demo alert created. A trigger will preview a call to ${formatDemoPhone(pairedPhones[0])}.` : 'Demo alert created. Try a temperature spike to see it trigger.')
      : 'That demo alert already exists in your watch list.';
  });
  $('demo-pair-form').addEventListener('submit', (event) => {
    event.preventDefault();
    startDemoPair($('demo-phone').value);
  });
  $('demo-resend').addEventListener('click', () => startDemoPair($('demo-phone').value || pendingPair?.phone));
  $('demo-confirm-form').addEventListener('submit', (event) => {
    event.preventDefault();
    if (!pendingPair) {
      $('demo-phone-message').textContent = 'Call the number first to hear a simulated code.';
      return;
    }
    if (Date.now() > pendingPair.expires) {
      pendingPair = null;
      $('demo-phone-message').textContent = 'That code expired. Call the number again for a new one.';
      return;
    }
    const entered = $('demo-code').value.replace(/\D/g, '');
    if (entered !== pendingPair.code) {
      pendingPair.attempts += 1;
      if (pendingPair.attempts >= 5) {
        pendingPair = null;
        $('demo-confirm-form').hidden = true;
        $('demo-phone-message').textContent = 'Too many tries for this code. Call the number again.';
        return;
      }
      $('demo-phone-message').textContent = `That code doesn't match. ${5 - pendingPair.attempts} tries left.`;
      return;
    }
    pairedPhones.push(pendingPair.phone);
    $('demo-phone-message').textContent = `${formatDemoPhone(pendingPair.phone)} is paired in this demo. A real workspace would now allow alerts to call it.`;
    pendingPair = null;
    $('demo-code').value = '';
    $('demo-confirm-form').hidden = true;
    renderPhones();
  });
  for (const button of document.querySelectorAll('[data-close-dialog]')) button.addEventListener('click', () => button.closest('dialog').close());
  for (const link of document.querySelectorAll('.dashboard-bar nav a')) link.addEventListener('click', () => {
    for (const other of document.querySelectorAll('.dashboard-bar nav a')) other.classList.toggle('active', other === link);
  });
  reset();
  setInterval(() => { if (!paused && !document.hidden) update(); }, 3000);
})();
