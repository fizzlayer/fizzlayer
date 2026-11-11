// Sensor detail: metric tiles on dashboard cards, and the larger view a card opens with gauges,
// history charts, and recent readings. Values come from the API; nothing here invents samples.
(() => {
  const kinds = window.fizzKinds;
  const SVG_NS = 'http://www.w3.org/2000/svg';
  const freshMs = 15 * 60 * 1000;
  const historyRefreshMs = 15 * 1000;
  const tileLimit = 4;
  const time = new Intl.DateTimeFormat(undefined, { hour: '2-digit', minute: '2-digit', second: '2-digit' });
  const shortTime = new Intl.DateTimeFormat(undefined, { hour: '2-digit', minute: '2-digit' });
  const numbers = new Intl.NumberFormat(undefined, { maximumFractionDigits: 2 });

  const dialog = document.getElementById('sensor-detail');
  let sensor = null;
  let options = {};
  let history = [];
  let historyAt = 0;
  let historyState = 'idle';
  let controller = null;
  let opener = null;
  let restoreFocus = true;
  const nowCards = new Map();

  function node(tag, className, text) {
    const element = document.createElement(tag);
    if (className) element.className = className;
    if (text !== undefined) element.textContent = text;
    return element;
  }
  function svg(tag, attributes = {}) {
    const element = document.createElementNS(SVG_NS, tag);
    for (const [name, value] of Object.entries(attributes)) element.setAttribute(name, value);
    return element;
  }
  function faIcon(name) {
    const element = node('span', `fa fa-${name}`);
    element.setAttribute('aria-hidden', 'true');
    return element;
  }
  const stamp = (reading) => new Date(reading.observed_at || reading.received_at).getTime();
  const clamp = (value, min, max) => Math.min(max, Math.max(min, value));

  // The newest value of each metric, from the sensor list, loaded history, and the single latest reading.
  function latestMetrics(item, readings = []) {
    const newest = new Map();
    const take = (reading) => {
      if (!reading?.metric) return;
      const prior = newest.get(reading.metric);
      if (!prior || stamp(reading) > stamp(prior)) newest.set(reading.metric, reading);
    };
    (item.latest_metrics || []).forEach(take);
    readings.forEach(take);
    take(item.latest_reading);
    return kinds.sortMetrics([...newest.values()], item.kind);
  }

  function valueText(reading) {
    if (reading.metric === 'voice_clip') return 'Clip received';
    if (typeof reading.boolean_value === 'boolean') return kinds.formatBoolean(reading);
    return kinds.formatValue(reading.numeric_value ?? reading.text_value ?? '', reading.unit);
  }

  function fraction(reading) {
    const scale = kinds.metricScale(reading.metric, reading.unit);
    if (!scale || !Number.isFinite(reading.numeric_value)) return null;
    return clamp((reading.numeric_value - scale.min) / (scale.max - scale.min), 0, 1);
  }

  // Compact tiles for a dashboard card: every metric the sensor reports, up to four, then a count.
  function tiles(item) {
    const metrics = latestMetrics(item);
    const grid = node('div', 'metric-tiles');
    for (const reading of metrics.slice(0, tileLimit)) {
      const tile = node('div', 'metric-tile');
      const level = kinds.metricLevel(reading);
      if (level) tile.dataset.level = level;
      tile.append(node('span', 'metric-tile-label', kinds.metricLabel(reading.metric)), node('strong', 'metric-tile-value', valueText(reading)));
      const share = fraction(reading);
      if (share !== null) {
        const meter = node('span', 'metric-meter');
        meter.setAttribute('aria-hidden', 'true');
        const fill = node('span');
        fill.style.width = `${(share * 100).toFixed(1)}%`;
        meter.append(fill);
        tile.append(meter);
      }
      grid.append(tile);
    }
    if (metrics.length > tileLimit) grid.append(node('p', 'metric-more', `+${metrics.length - tileLimit} more in details`));
    return grid;
  }

  // ---------- Detail view ----------

  function gaugeCard(reading) {
    const scale = kinds.metricScale(reading.metric, reading.unit);
    const card = node('figure', 'detail-card gauge-card');
    const r = 50;
    const circumference = 2 * Math.PI * r;
    const sweep = circumference * 0.75;
    const graphic = svg('svg', { viewBox: '0 0 140 126', class: 'gauge', 'aria-hidden': 'true' });
    const arc = (className) => svg('circle', { cx: 70, cy: 68, r, class: className, transform: 'rotate(135 70 68)', 'stroke-dasharray': `${sweep} ${circumference}` });
    const track = arc('gauge-track');
    const fill = arc('gauge-fill');
    fill.setAttribute('stroke-dasharray', `0 ${circumference}`);
    graphic.append(track, fill);
    for (const mark of [scale.warn, scale.danger]) {
      if (mark == null) continue;
      const angle = (135 + ((mark - scale.min) / (scale.max - scale.min)) * 270) * (Math.PI / 180);
      graphic.append(svg('line', { class: 'gauge-tick', x1: 70 + Math.cos(angle) * 42, y1: 68 + Math.sin(angle) * 42, x2: 70 + Math.cos(angle) * 58, y2: 68 + Math.sin(angle) * 58 }));
    }
    const value = svg('text', { x: 70, y: 70, class: 'gauge-value', 'text-anchor': 'middle' });
    const unit = svg('text', { x: 70, y: 90, class: 'gauge-unit', 'text-anchor': 'middle' });
    const low = svg('text', { x: 34, y: 120, class: 'gauge-end', 'text-anchor': 'middle' });
    const high = svg('text', { x: 106, y: 120, class: 'gauge-end', 'text-anchor': 'middle' });
    low.textContent = numbers.format(scale.min);
    high.textContent = numbers.format(scale.max);
    graphic.append(value, unit, low, high);
    const caption = node('figcaption');
    const label = node('span', 'detail-card-label', kinds.metricLabel(reading.metric));
    const status = node('span', 'detail-card-status');
    caption.append(label, status);
    card.append(graphic, caption);
    const update = (next) => {
      const share = fraction(next) ?? 0;
      value.textContent = numbers.format(next.numeric_value);
      unit.textContent = next.unit || '';
      const level = kinds.metricLevel(next);
      card.dataset.level = level;
      status.textContent = level === 'danger' ? 'Critical' : level === 'warn' ? 'High' : next.numeric_value > scale.max ? 'Above scale' : next.numeric_value < scale.min ? 'Below scale' : '';
      card.setAttribute('aria-label', `${kinds.metricLabel(next.metric)}: ${valueText(next)}, on a scale of ${kinds.formatValue(scale.min, next.unit)} to ${kinds.formatValue(scale.max, next.unit)}${status.textContent ? `, ${status.textContent.toLowerCase()}` : ''}.`);
      // Start empty and sweep to the value, so the gauge animates in and between readings.
      requestAnimationFrame(() => fill.setAttribute('stroke-dasharray', `${(sweep * share).toFixed(2)} ${circumference}`));
    };
    card.setAttribute('role', 'img');
    return { element: card, update, type: 'gauge' };
  }

  function statCard(reading) {
    const card = node('figure', 'detail-card detail-stat-card');
    const label = node('figcaption', 'detail-card-label', kinds.metricLabel(reading.metric));
    const value = node('strong', 'detail-stat-value');
    const range = node('p', 'detail-stat-range');
    card.append(label, value, range);
    const update = (next) => {
      value.textContent = valueText(next);
      const values = series(next.metric).map((point) => point.value);
      range.textContent = values.length > 1 ? `Low ${kinds.formatValue(Math.min(...values), next.unit)} · High ${kinds.formatValue(Math.max(...values), next.unit)}` : 'Range appears as readings arrive';
    };
    return { element: card, update, type: 'stat' };
  }

  function flagCard(reading) {
    const card = node('figure', 'detail-card flag-card');
    const badge = node('span', 'flag-icon');
    const label = node('figcaption', 'detail-card-label', kinds.metricLabel(reading.metric));
    const value = node('strong', 'detail-stat-value');
    card.append(badge, label, value);
    const update = (next) => {
      const level = kinds.metricLevel(next);
      card.dataset.level = level;
      badge.replaceChildren(faIcon(level === 'danger' ? 'triangle-exclamation' : 'check'));
      value.textContent = valueText(next);
    };
    return { element: card, update, type: 'flag' };
  }

  function textCard(reading) {
    const card = node('figure', 'detail-card text-card');
    const label = node('figcaption', 'detail-card-label', kinds.metricLabel(reading.metric));
    const value = node('p', 'text-value');
    const when = node('p', 'detail-stat-range');
    card.append(label, value, when);
    const update = (next) => {
      value.textContent = valueText(next);
      when.textContent = `Received ${kinds.timeAgo(next.observed_at || next.received_at)}`;
    };
    return { element: card, update, type: 'text' };
  }

  function cardFor(reading) {
    if (typeof reading.boolean_value === 'boolean') return flagCard(reading);
    if (Number.isFinite(reading.numeric_value)) return kinds.metricScale(reading.metric, reading.unit) ? gaugeCard(reading) : statCard(reading);
    return textCard(reading);
  }

  function withAlertAction(entry, reading) {
    if (!Number.isFinite(reading.numeric_value) || !options.onAlert) return entry;
    const button = node('button', 'detail-card-action', 'Set alert');
    button.type = 'button';
    button.setAttribute('aria-label', `Set an alert on ${kinds.metricLabel(reading.metric)}`);
    button.addEventListener('click', () => { const target = sensor; close(false); options.onAlert(target, entry.reading); });
    entry.element.append(button);
    return entry;
  }

  // Update the "right now" cards in place so gauges animate between readings instead of redrawing.
  function renderNow() {
    const grid = dialog.querySelector('.detail-now');
    const metrics = latestMetrics(sensor, history);
    const seen = new Set();
    for (const reading of metrics) {
      const type = typeof reading.boolean_value === 'boolean' ? 'flag' : Number.isFinite(reading.numeric_value) ? (kinds.metricScale(reading.metric, reading.unit) ? 'gauge' : 'stat') : 'text';
      let entry = nowCards.get(reading.metric);
      if (!entry || entry.type !== type) {
        entry?.element.remove();
        entry = withAlertAction(cardFor(reading), reading);
        nowCards.set(reading.metric, entry);
      }
      entry.reading = reading;
      entry.update(reading);
      grid.append(entry.element);
      seen.add(reading.metric);
    }
    for (const [metric, entry] of nowCards) if (!seen.has(metric)) { entry.element.remove(); nowCards.delete(metric); }
    dialog.querySelector('.detail-now-empty').hidden = metrics.length > 0;
    dialog.querySelector('.detail-alert').hidden = !metrics.some((reading) => Number.isFinite(reading.numeric_value)) || !options.onAlert;
  }

  function series(metric) {
    return history
      .filter((reading) => reading.metric === metric && Number.isFinite(reading.numeric_value))
      .map((reading) => ({ at: stamp(reading), value: reading.numeric_value, unit: reading.unit }))
      .filter((point) => Number.isFinite(point.at))
      .sort((a, b) => a.at - b.at);
  }

  function chart(metric) {
    const points = series(metric);
    const card = node('figure', 'history-card');
    const head = node('figcaption', 'history-head');
    const last = points.at(-1);
    head.append(node('span', 'detail-card-label', kinds.metricLabel(metric)), node('strong', '', last ? kinds.formatValue(last.value, last.unit) : ''));
    card.append(head);
    if (points.length < 2) {
      card.append(node('p', 'history-empty', 'Not enough readings yet to draw a trend.'));
      return card;
    }
    const values = points.map((point) => point.value);
    let min = Math.min(...values);
    let max = Math.max(...values);
    if (min === max) { min -= 1; max += 1; }
    const first = points[0].at;
    const span = Math.max(points.at(-1).at - first, 1);
    const x = (point) => ((point.at - first) / span) * 600;
    const y = (point) => 132 - ((point.value - min) / (max - min)) * 120;
    // Break the line across long gaps (no readings arrived), rather than drawing values that were never measured.
    const gaps = points.slice(1).map((point, index) => point.at - points[index].at).sort((a, b) => a - b);
    const breakAfter = Math.max(gaps[Math.floor(gaps.length / 2)] * 6, 5 * 60 * 1000);
    const segments = [[points[0]]];
    for (let index = 1; index < points.length; index += 1) {
      if (points[index].at - points[index - 1].at > breakAfter) segments.push([]);
      segments.at(-1).push(points[index]);
    }
    // A lone reading between gaps becomes a dot (a zero-length segment with round caps).
    const trace = (segment) => (segment.length === 1
      ? `M${x(segment[0]).toFixed(1)},${y(segment[0]).toFixed(1)} l0.01,0`
      : segment.map((point, index) => `${index ? 'L' : 'M'}${x(point).toFixed(1)},${y(point).toFixed(1)}`).join(' '));
    const line = segments.map(trace).join(' ');
    const area = segments.filter((segment) => segment.length > 1).map((segment) => `${trace(segment)} L${x(segment.at(-1)).toFixed(1)},140 L${x(segment[0]).toFixed(1)},140 Z`).join(' ');
    const plot = node('div', 'history-plot');
    const graphic = svg('svg', { viewBox: '0 0 600 140', preserveAspectRatio: 'none', class: 'history-chart', role: 'img' });
    graphic.setAttribute('aria-label', `${kinds.metricLabel(metric)}: ${points.length} readings from ${time.format(first)} to ${time.format(points.at(-1).at)}, between ${kinds.formatValue(Math.min(...values), last.unit)} and ${kinds.formatValue(Math.max(...values), last.unit)}.`);
    const id = `fade-${metric}`;
    const defs = svg('defs');
    const gradient = svg('linearGradient', { id, x1: 0, y1: 0, x2: 0, y2: 1 });
    gradient.append(svg('stop', { offset: '0%', 'stop-color': 'currentColor', 'stop-opacity': '.22' }), svg('stop', { offset: '100%', 'stop-color': 'currentColor', 'stop-opacity': '0' }));
    defs.append(gradient);
    for (const level of [12, 72, 132]) graphic.append(svg('line', { x1: 0, x2: 600, y1: level, y2: level, class: 'history-grid' }));
    graphic.append(defs, svg('path', { d: area, fill: `url(#${id})`, class: 'history-area' }), svg('path', { d: line, class: 'history-line' }));
    const axis = node('div', 'history-axis');
    axis.append(node('span', '', kinds.formatValue(Math.max(...values), last.unit)), node('span', '', kinds.formatValue(Math.min(...values), last.unit)));
    const cursor = node('div', 'history-cursor');
    const dot = node('span', 'history-dot');
    const tip = node('span', 'history-tip');
    cursor.hidden = true;
    cursor.append(dot, tip);
    plot.append(graphic, axis, cursor);
    // Show the reading nearest the pointer.
    plot.addEventListener('pointermove', (event) => {
      const box = plot.getBoundingClientRect();
      const at = first + ((event.clientX - box.left) / box.width) * span;
      const nearest = points.reduce((best, point) => (Math.abs(point.at - at) < Math.abs(best.at - at) ? point : best));
      cursor.hidden = false;
      cursor.style.left = `${(x(nearest) / 600) * 100}%`;
      dot.style.top = `${(y(nearest) / 140) * 100}%`;
      tip.textContent = `${kinds.formatValue(nearest.value, nearest.unit)} · ${time.format(nearest.at)}`;
      tip.classList.toggle('flip', x(nearest) > 420);
    });
    plot.addEventListener('pointerleave', () => { cursor.hidden = true; });
    const times = node('div', 'history-times');
    times.append(node('span', '', shortTime.format(first)), node('span', '', `${points.length} readings`), node('span', '', shortTime.format(points.at(-1).at)));
    card.append(plot, times);
    return card;
  }

  function renderHistory() {
    const section = dialog.querySelector('.detail-history');
    const status = dialog.querySelector('.detail-history-status');
    if (historyState === 'loading' && !history.length) { status.textContent = 'Loading recent readings…'; status.hidden = false; section.replaceChildren(); return; }
    if (historyState === 'error' && !history.length) { status.textContent = 'Recent readings could not be loaded. They will retry shortly.'; status.hidden = false; section.replaceChildren(); return; }
    const metrics = [...new Set(history.filter((reading) => Number.isFinite(reading.numeric_value)).map((reading) => reading.metric))];
    const ordered = kinds.sortMetrics(metrics.map((metric) => history.find((reading) => reading.metric === metric)), sensor.kind).map((reading) => reading.metric);
    status.hidden = ordered.length > 0;
    status.textContent = history.length ? 'This sensor has no numeric readings to chart.' : 'No readings yet.';
    section.replaceChildren(...ordered.map(chart));
    renderTable();
  }

  // One row per sample, with a column per metric, when a device sends a handful of metrics together;
  // otherwise one row per reading.
  function renderTable() {
    const table = dialog.querySelector('.detail-table');
    const recent = history.slice(0, 60);
    const metrics = kinds.sortMetrics([...new Map(recent.map((reading) => [reading.metric, reading])).values()], sensor.kind).map((reading) => reading.metric);
    const pivot = metrics.length > 1 && metrics.length <= 5;
    const headRow = node('tr');
    for (const heading of pivot ? ['Time', ...metrics.map(kinds.metricLabel)] : ['Time', 'Metric', 'Value']) {
      const cell = node('th', '', heading);
      cell.scope = 'col';
      headRow.append(cell);
    }
    const cell = (reading) => {
      const td = node('td', '', reading ? valueText(reading) : '–');
      const level = reading && kinds.metricLevel(reading);
      if (level) td.dataset.level = level;
      return td;
    };
    let rows;
    if (pivot) {
      const samples = new Map();
      for (const reading of recent) {
        const key = stamp(reading);
        if (!samples.has(key)) samples.set(key, new Map());
        if (!samples.get(key).has(reading.metric)) samples.get(key).set(reading.metric, reading);
      }
      rows = [...samples].slice(0, 10).map(([at, values]) => {
        const row = node('tr');
        row.append(node('td', '', time.format(at)), ...metrics.map((metric) => cell(values.get(metric))));
        return row;
      });
    } else {
      rows = history.slice(0, 12).map((reading) => {
        const row = node('tr');
        row.append(node('td', '', time.format(stamp(reading))), node('td', '', kinds.metricLabel(reading.metric)), cell(reading));
        return row;
      });
    }
    table.tHead.replaceChildren(headRow);
    table.tBodies[0].replaceChildren(...rows);
    table.classList.toggle('pivot', pivot);
    dialog.querySelector('.detail-table-wrap').hidden = rows.length === 0;
  }

  function renderHeader() {
    const info = kinds.get(sensor.kind);
    dialog.style.setProperty('--sensor-color', info.color);
    dialog.querySelector('.detail-badge').replaceChildren(kinds.badge(sensor.kind, 'kind-badge detail-kind-badge'));
    dialog.querySelector('#sensor-detail-title').textContent = sensor.name || info.label;
    const metrics = latestMetrics(sensor, history);
    const newest = metrics.reduce((best, reading) => (!best || stamp(reading) > stamp(best) ? reading : best), null);
    const source = sensor.mode === 'simulated' ? 'Sample data' : sensor.mode === 'phone' ? 'Paired phone' : 'API sensor';
    dialog.querySelector('.detail-meta').textContent = `${info.label} · ${source}${newest ? ` · Updated ${kinds.timeAgo(newest.observed_at || newest.received_at)}` : ''}`;
    const state = dialog.querySelector('.detail-state');
    const fresh = newest && Date.now() - stamp(newest) < freshMs;
    state.textContent = !newest ? 'Waiting' : fresh ? 'Live' : 'Quiet';
    state.dataset.state = !newest ? 'waiting' : fresh ? 'live' : 'quiet';
    state.title = !newest ? 'No readings yet' : fresh ? 'A reading arrived in the last 15 minutes' : 'No reading in the last 15 minutes';
  }

  async function loadHistory() {
    if (!sensor) return;
    controller?.abort();
    controller = new AbortController();
    const target = sensor.id;
    historyState = 'loading';
    if (!history.length) renderHistory();
    try {
      const response = await fetch(`/api/readings?sensor_id=${encodeURIComponent(target)}&limit=500`, { credentials: 'same-origin', signal: controller.signal });
      const data = await response.json();
      if (!response.ok) throw new Error(data.error?.message || 'Unavailable');
      if (!sensor || sensor.id !== target) return;
      history = data.readings || [];
      historyState = 'ready';
    } catch (error) {
      if (error.name === 'AbortError' || !sensor || sensor.id !== target) return;
      historyState = 'error';
    }
    historyAt = Date.now();
    renderHeader();
    renderNow();
    renderHistory();
  }

  function build() {
    dialog.replaceChildren();
    const head = node('header', 'detail-head');
    const badge = node('div', 'detail-badge');
    const titles = node('div', 'detail-titles');
    const title = node('h2');
    title.id = 'sensor-detail-title';
    titles.append(title, node('p', 'detail-meta'));
    const state = node('span', 'detail-state');
    const closeButton = node('button', 'detail-close');
    closeButton.type = 'button';
    closeButton.setAttribute('aria-label', 'Close sensor details');
    closeButton.append(faIcon('xmark'));
    closeButton.addEventListener('click', () => close());
    head.append(badge, titles, state, closeButton);

    const now = node('section', 'detail-section');
    now.setAttribute('aria-labelledby', 'detail-now-title');
    const nowTitle = node('h3', 'detail-section-title', 'Right now');
    nowTitle.id = 'detail-now-title';
    const nowEmpty = node('p', 'detail-now-empty', 'This sensor has not sent a reading yet.');
    now.append(nowTitle, node('div', 'detail-now'), nowEmpty);

    const trends = node('section', 'detail-section');
    trends.setAttribute('aria-labelledby', 'detail-history-title');
    const trendsTitle = node('h3', 'detail-section-title', 'Recent history');
    trendsTitle.id = 'detail-history-title';
    trends.append(trendsTitle, node('p', 'detail-history-status'), node('div', 'detail-history'));

    const table = node('section', 'detail-section detail-table-wrap');
    table.setAttribute('aria-labelledby', 'detail-table-title');
    const tableTitle = node('h3', 'detail-section-title', 'Latest readings');
    tableTitle.id = 'detail-table-title';
    const grid = node('table', 'detail-table');
    const headRow = node('tr');
    for (const heading of ['Time', 'Metric', 'Value']) { const cell = node('th', '', heading); cell.scope = 'col'; headRow.append(cell); }
    const thead = node('thead');
    thead.append(headRow);
    grid.append(thead, node('tbody'));
    const scroll = node('div', 'detail-table-scroll');
    scroll.append(grid);
    table.append(tableTitle, scroll);

    const foot = node('footer', 'detail-foot');
    const alert = node('button', 'primary detail-alert');
    alert.type = 'button';
    alert.append('Set an alert');
    alert.addEventListener('click', () => {
      const reading = latestMetrics(sensor, history).find((item) => Number.isFinite(item.numeric_value));
      const target = sensor;
      close(false);
      if (reading) options.onAlert?.(target, reading);
    });
    const manage = node('a', 'secondary detail-manage', 'Manage sensor');
    manage.href = '/sensors.html';
    foot.append(node('p', 'detail-note', 'History covers the most recent 500 readings.'), manage, alert);

    const panel = node('div', 'detail-panel');
    panel.append(head, now, trends, table, foot);
    dialog.append(panel);
  }

  function open(item, from) {
    if (!dialog || !item) return;
    controller?.abort();
    sensor = item;
    opener = from || document.activeElement;
    restoreFocus = true;
    history = [];
    historyAt = 0;
    historyState = 'idle';
    nowCards.clear();
    build();
    renderHeader();
    renderNow();
    renderHistory();
    if (!dialog.open) dialog.showModal();
    void loadHistory();
  }

  // restore: return focus to the card that opened the view (false when an action moves focus elsewhere).
  function close(restore = true) {
    if (!dialog?.open) return;
    restoreFocus = restore;
    dialog.close();
  }

  // Called after each dashboard refresh: keep the open view current, or close it if the sensor is gone.
  function noteReading(item, reading) {
    if (!dialog?.open || !sensor || !item || sensor.id !== item.id || !reading) return;
    sensor = item;
    const duplicate = history.some((row) => row.event_id && row.event_id === reading.event_id && row.metric === reading.metric);
    if (!duplicate) history = [reading, ...history].slice(0, 500);
    renderHeader();
    renderNow();
    renderHistory();
  }

  function update(list) {
    if (!dialog?.open || !sensor) return;
    const next = list.find((item) => item.id === sensor.id);
    if (!next) { close(); return; }
    sensor = next;
    renderHeader();
    renderNow();
    if (Date.now() - historyAt > historyRefreshMs && historyState !== 'loading') void loadHistory();
  }

  if (dialog) {
    dialog.addEventListener('close', () => {
      const closedId = sensor?.id;
      controller?.abort();
      sensor = null;
      history = [];
      nowCards.clear();
      // The dashboard redraws its cards while the view is open, so return focus to this sensor's current card.
      const card = closedId && document.querySelector(`[data-sensor-id="${CSS.escape(closedId)}"] .live-card-open`);
      if (restoreFocus) (opener?.isConnected ? opener : card)?.focus();
      opener = null;
      restoreFocus = true;
    });
    // Close when the backdrop (outside the panel) is clicked.
    dialog.addEventListener('click', (event) => { if (event.target === dialog) close(); });
  }

  window.fizzSensorDetail = { tiles, open, update, close, noteReading, metricCount: (item) => latestMetrics(item).length, configure: (next) => { options = next || {}; } };
})();
