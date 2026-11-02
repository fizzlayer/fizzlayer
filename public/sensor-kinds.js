(() => {
  const SVG_NS = 'http://www.w3.org/2000/svg';
  // Font Awesome Free 6.7.2 icons (CC BY 4.0, /icons/fontawesome/LICENSE.txt): [viewBox width, path].
  const icons = {
    'droplet': [384, 'M192 512C86 512 0 426 0 320C0 228.8 130.2 57.7 166.6 11.7C172.6 4.2 181.5 0 191.1 0l1.8 0c9.6 0 18.5 4.2 24.5 11.7C253.8 57.7 384 228.8 384 320c0 106-86 192-192 192zM96 336c0-8.8-7.2-16-16-16s-16 7.2-16 16c0 61.9 50.1 112 112 112c8.8 0 16-7.2 16-16s-7.2-16-16-16c-44.2 0-80-35.8-80-80z'],
    'faucet-drip': [512, 'M224 0c17.7 0 32 14.3 32 32l0 12 96-12c17.7 0 32 14.3 32 32s-14.3 32-32 32L256 84l-31-3.9-1-.1-1 .1L192 84 96 96C78.3 96 64 81.7 64 64s14.3-32 32-32l96 12 0-12c0-17.7 14.3-32 32-32zM0 224c0-17.7 14.3-32 32-32l96 0 22.6-22.6c6-6 14.1-9.4 22.6-9.4l18.7 0 0-43.8 32-4 32 4 0 43.8 18.7 0c8.5 0 16.6 3.4 22.6 9.4L320 192l32 0c88.4 0 160 71.6 160 160c0 17.7-14.3 32-32 32l-64 0c-17.7 0-32-14.3-32-32s-14.3-32-32-32l-36.1 0c-20.2 29-53.9 48-91.9 48s-71.7-19-91.9-48L32 320c-17.7 0-32-14.3-32-32l0-64zM436.8 423.4c1.9-4.5 6.3-7.4 11.2-7.4s9.2 2.9 11.2 7.4l18.2 42.4c1.8 4.1 2.7 8.6 2.7 13.1l0 1.2c0 17.7-14.3 32-32 32s-32-14.3-32-32l0-1.2c0-4.5 .9-8.9 2.7-13.1l18.2-42.4z'],
    'gauge-high': [512, 'M0 256a256 256 0 1 1 512 0A256 256 0 1 1 0 256zM288 96a32 32 0 1 0 -64 0 32 32 0 1 0 64 0zM256 416c35.3 0 64-28.7 64-64c0-17.4-6.9-33.1-18.1-44.6L366 161.7c5.3-12.1-.2-26.3-12.3-31.6s-26.3 .2-31.6 12.3L257.9 288c-.6 0-1.3 0-1.9 0c-35.3 0-64 28.7-64 64s28.7 64 64 64zM176 144a32 32 0 1 0 -64 0 32 32 0 1 0 64 0zM96 288a32 32 0 1 0 0-64 32 32 0 1 0 0 64zm352-32a32 32 0 1 0 -64 0 32 32 0 1 0 64 0z'],
    'mobile-screen-button': [384, 'M16 64C16 28.7 44.7 0 80 0L304 0c35.3 0 64 28.7 64 64l0 384c0 35.3-28.7 64-64 64L80 512c-35.3 0-64-28.7-64-64L16 64zM224 448a32 32 0 1 0 -64 0 32 32 0 1 0 64 0zM304 64L80 64l0 320 224 0 0-320z'],
    'satellite-dish': [512, 'M192 32c0-17.7 14.3-32 32-32C383.1 0 512 128.9 512 288c0 17.7-14.3 32-32 32s-32-14.3-32-32C448 164.3 347.7 64 224 64c-17.7 0-32-14.3-32-32zM60.6 220.6L164.7 324.7l28.4-28.4c-.7-2.6-1.1-5.4-1.1-8.3c0-17.7 14.3-32 32-32s32 14.3 32 32s-14.3 32-32 32c-2.9 0-5.6-.4-8.3-1.1l-28.4 28.4L291.4 451.4c14.5 14.5 11.8 38.8-7.3 46.3C260.5 506.9 234.9 512 208 512C93.1 512 0 418.9 0 304c0-26.9 5.1-52.5 14.4-76.1c7.5-19 31.8-21.8 46.3-7.3zM224 96c106 0 192 86 192 192c0 17.7-14.3 32-32 32s-32-14.3-32-32c0-70.7-57.3-128-128-128c-17.7 0-32-14.3-32-32s14.3-32 32-32z'],
    'sliders': [512, 'M0 416c0 17.7 14.3 32 32 32l54.7 0c12.3 28.3 40.5 48 73.3 48s61-19.7 73.3-48L480 448c17.7 0 32-14.3 32-32s-14.3-32-32-32l-246.7 0c-12.3-28.3-40.5-48-73.3-48s-61 19.7-73.3 48L32 384c-17.7 0-32 14.3-32 32zm128 0a32 32 0 1 1 64 0 32 32 0 1 1 -64 0zM320 256a32 32 0 1 1 64 0 32 32 0 1 1 -64 0zm32-80c-32.8 0-61 19.7-73.3 48L32 224c-17.7 0-32 14.3-32 32s14.3 32 32 32l246.7 0c12.3 28.3 40.5 48 73.3 48s61-19.7 73.3-48l54.7 0c17.7 0 32-14.3 32-32s-14.3-32-32-32l-54.7 0c-12.3-28.3-40.5-48-73.3-48zM192 128a32 32 0 1 1 0-64 32 32 0 1 1 0 64zm73.3-64C253 35.7 224.8 16 192 16s-61 19.7-73.3 48L32 64C14.3 64 0 78.3 0 96s14.3 32 32 32l86.7 0c12.3 28.3 40.5 48 73.3 48s61-19.7 73.3-48L480 128c17.7 0 32-14.3 32-32s-14.3-32-32-32L265.3 64z'],
    'smog': [640, 'M32 144c0 79.5 64.5 144 144 144l123.3 0c22.6 19.9 52.2 32 84.7 32s62.1-12.1 84.7-32l27.3 0c61.9 0 112-50.1 112-112s-50.1-112-112-112c-10.7 0-21 1.5-30.8 4.3C443.8 27.7 401.1 0 352 0c-32.6 0-62.4 12.2-85.1 32.3C242.1 12.1 210.5 0 176 0C96.5 0 32 64.5 32 144zM616 368l-336 0c-13.3 0-24 10.7-24 24s10.7 24 24 24l336 0c13.3 0 24-10.7 24-24s-10.7-24-24-24zm-64 96l-112 0c-13.3 0-24 10.7-24 24s10.7 24 24 24l112 0c13.3 0 24-10.7 24-24s-10.7-24-24-24zm-192 0L24 464c-13.3 0-24 10.7-24 24s10.7 24 24 24l336 0c13.3 0 24-10.7 24-24s-10.7-24-24-24zM224 392c0-13.3-10.7-24-24-24L96 368c-13.3 0-24 10.7-24 24s10.7 24 24 24l104 0c13.3 0 24-10.7 24-24z'],
    'temperature-half': [320, 'M160 64c-26.5 0-48 21.5-48 48l0 164.5c0 17.3-7.1 31.9-15.3 42.5C86.2 332.6 80 349.5 80 368c0 44.2 35.8 80 80 80s80-35.8 80-80c0-18.5-6.2-35.4-16.7-48.9c-8.2-10.6-15.3-25.2-15.3-42.5L208 112c0-26.5-21.5-48-48-48zM48 112C48 50.2 98.1 0 160 0s112 50.1 112 112l0 164.4c0 .1 .1 .3 .2 .6c.2 .6 .8 1.6 1.7 2.8c18.9 24.4 30.1 55 30.1 88.1c0 79.5-64.5 144-144 144S16 447.5 16 368c0-33.2 11.2-63.8 30.1-88.1c.9-1.2 1.5-2.2 1.7-2.8c.1-.3 .2-.5 .2-.6L48 112zM208 368c0 26.5-21.5 48-48 48s-48-21.5-48-48c0-20.9 13.4-38.7 32-45.3L144 208c0-8.8 7.2-16 16-16s16 7.2 16 16l0 114.7c18.6 6.6 32 24.4 32 45.3z'],
    'volume-high': [640, 'M533.6 32.5C598.5 85.2 640 165.8 640 256s-41.5 170.7-106.4 223.5c-10.3 8.4-25.4 6.8-33.8-3.5s-6.8-25.4 3.5-33.8C557.5 398.2 592 331.2 592 256s-34.5-142.2-88.7-186.3c-10.3-8.4-11.8-23.5-3.5-33.8s23.5-11.8 33.8-3.5zM473.1 107c43.2 35.2 70.9 88.9 70.9 149s-27.7 113.8-70.9 149c-10.3 8.4-25.4 6.8-33.8-3.5s-6.8-25.4 3.5-33.8C475.3 341.3 496 301.1 496 256s-20.7-85.3-53.2-111.8c-10.3-8.4-11.8-23.5-3.5-33.8s23.5-11.8 33.8-3.5zm-60.5 74.5C434.1 199.1 448 225.9 448 256s-13.9 56.9-35.4 74.5c-10.3 8.4-25.4 6.8-33.8-3.5s-6.8-25.4 3.5-33.8C393.1 284.4 400 271 400 256s-6.9-28.4-17.7-37.3c-10.3-8.4-11.8-23.5-3.5-33.8s23.5-11.8 33.8-3.5zM301.1 34.8C312.6 40 320 51.4 320 64l0 384c0 12.6-7.4 24-18.9 29.2s-25 3.1-34.4-5.3L131.8 352 64 352c-35.3 0-64-28.7-64-64l0-64c0-35.3 28.7-64 64-64l67.8 0L266.7 40.1c9.4-8.4 22.9-10.4 34.4-5.3z'],
  };
  const kinds = {
    water: { label: 'Water', detail: 'Leaks & flow', metric: 'flow_l_min', unit: 'L/min', color: '#5cc8ff', example: 'Basement leak', icon: 'faucet-drip' },
    gas: { label: 'Gas', detail: 'Air safety', metric: 'concentration_ppm', unit: 'ppm', color: '#9be07a', example: 'Garage air', icon: 'smog' },
    radio: { label: 'Radio', detail: 'Signals & waves', metric: 'rssi_dbm', unit: 'dBm', color: '#ffe066', example: 'Rooftop antenna', icon: 'satellite-dish' },
    temperature: { label: 'Temperature', detail: 'Hot & cold', metric: 'temperature_c', unit: '°C', color: '#ff7b6b', example: 'Kitchen temperature', icon: 'temperature-half' },
    pressure: { label: 'Pressure', detail: 'Force & level', metric: 'pressure_kpa', unit: 'kPa', color: '#c79bff', example: 'Boiler pressure', icon: 'gauge-high' },
    humidity: { label: 'Humidity', detail: 'Moisture', metric: 'humidity_pct', unit: '%', color: '#5ee6c4', example: 'Greenhouse humidity', icon: 'droplet' },
    sound: { label: 'Sound', detail: 'Audio events', metric: 'sound_db', unit: 'dB', color: '#ffa94d', example: 'Nursery sound', icon: 'volume-high' },
    phone: { label: 'Phone', detail: 'Motion, voice & location', metric: 'acceleration_ms2', unit: 'm/s²', color: '#8c9dff', example: 'My phone', icon: 'mobile-screen-button' },
    custom: { label: 'Custom', detail: 'Your own metric', metric: 'value', unit: '', color: '#ff9ed2', example: 'Bike rack counter', icon: 'sliders' },
  };
  const order = ['water', 'gas', 'radio', 'temperature', 'pressure', 'humidity', 'sound', 'phone', 'custom'];
  const fallback = { label: 'Sensor', detail: '', metric: 'value', unit: '', color: '#a9eaf7', example: 'My sensor', icon: kinds.custom.icon };

  const metricNames = {
    temperature_c: 'Temperature', flow_l_min: 'Flow rate', concentration_ppm: 'Gas concentration',
    rssi_dbm: 'Signal strength', pressure_kpa: 'Pressure', humidity_pct: 'Humidity', sound_db: 'Sound level',
    acceleration_ms2: 'Acceleration', acceleration_x: 'Acceleration X', acceleration_y: 'Acceleration Y', acceleration_z: 'Acceleration Z',
    rotation_alpha: 'Compass heading', rotation_beta: 'Front/back tilt', rotation_gamma: 'Left/right tilt', orientation_deg: 'Orientation',
    latitude: 'Latitude', longitude: 'Longitude', location_accuracy: 'Location accuracy',
    voice_clip: 'Voice clip', voice_level: 'Voice level', voice_transcript: 'Transcript', value: 'Value',
  };
  const numbers = new Intl.NumberFormat(undefined, { maximumFractionDigits: 2 });
  const relative = new Intl.RelativeTimeFormat(undefined, { numeric: 'auto' });

  function get(kind) { return kinds[kind] || fallback; }

  function icon(kind) {
    const [width, d] = icons[get(kind).icon];
    const svg = document.createElementNS(SVG_NS, 'svg');
    svg.setAttribute('viewBox', `0 0 ${width} 512`);
    svg.setAttribute('aria-hidden', 'true');
    const path = document.createElementNS(SVG_NS, 'path');
    path.setAttribute('d', d);
    svg.append(path);
    return svg;
  }

  // A square pixel badge coloured for the sensor kind.
  function badge(kind, className = 'kind-badge') {
    const element = document.createElement('span');
    element.className = className;
    element.style.setProperty('--sensor-color', get(kind).color);
    element.append(icon(kind));
    return element;
  }

  function metricLabel(metric) {
    if (!metric) return '';
    return metricNames[metric] || metric.replaceAll('_', ' ').replace(/^./, (letter) => letter.toUpperCase());
  }

  function formatValue(value, unit) {
    const text = typeof value === 'number' ? numbers.format(value) : String(value);
    if (!unit) return text;
    return unit === '%' ? `${text}%` : `${text} ${unit}`;
  }

  function formatReading(reading) {
    if (!reading) return 'Waiting for data';
    if (reading.metric === 'voice_clip') return 'Clip received';
    return formatValue(reading.numeric_value ?? reading.boolean_value ?? reading.text_value, reading.unit);
  }

  function timeAgo(value) {
    const seconds = Math.round((new Date(value).getTime() - Date.now()) / 1000);
    if (!Number.isFinite(seconds)) return '';
    if (Math.abs(seconds) < 45) return 'just now';
    if (Math.abs(seconds) < 3600) return relative.format(Math.round(seconds / 60), 'minute');
    if (Math.abs(seconds) < 86400) return relative.format(Math.round(seconds / 3600), 'hour');
    return relative.format(Math.round(seconds / 86400), 'day');
  }

  window.fizzKinds = { order, get, icon, badge, metricLabel, formatValue, formatReading, timeAgo };
})();
