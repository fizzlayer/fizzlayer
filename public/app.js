const $ = (id) => document.getElementById(id);
const form = $('account-form');
const sensorNames = {
  water: 'Water', gas: 'Gas', radio: 'Radio', temperature: 'Temperature',
  pressure: 'Pressure', humidity: 'Humidity', sound: 'Sound', phone: 'Phone', custom: 'Custom',
};
let chosenKinds = [];
let signedInUsername = '';

// Sign-in goes through Supabase Auth via /api/auth: email and password, Google, GitHub, or a passkey.
// Anyone can create an account. Passkeys are added on the Settings page once signed in.
const passkeysSupported = window.fizzPasskey.supported;
// OAuth buttons in #oauth, by Supabase provider id. /api/auth?providers narrows the list to the
// ones turned on in Supabase, so a self-hosted instance never shows a button that can't work.
const oauthProviders = { google: 'Google', github: 'GitHub' };
let oauthEnabled = Object.keys(oauthProviders);
// Same names, prices, and limits as the pricing page. Paid rows stay hidden when Stripe is unset.
const signupPlans = [
  { id: 'hobbyist', name: 'Hobbyist', tag: 'For your first sensors', price: '$0', detail: '3 connected devices · 10 Fizz credits / month · Phone calls: Dashboard only' },
  { id: 'tinkerer', name: 'Tinkerer', tag: 'For the home lab', price: '$10', period: '/ month', detail: '10 connected devices · 100 Fizz credits / month · Phone calls: Included', paid: true },
  { id: 'pro', name: 'Pro', tag: 'For serious setups', price: '$25', period: '/ month', detail: '50 connected devices · 1,000 Fizz credits / month · Phone calls: Included', paid: true },
  { id: 'enterprise', name: 'Enterprise', tag: 'For teams and sites', price: 'Custom', detail: 'Custom connected devices · Custom Fizz credits · Phone calls: Included', href: '/enterprise' },
];
const PLAN_KEY = 'fizz.signupPlan';
const requestedPlan = new URLSearchParams(location.search).get('plan');
let billingAvailable = false;
let chosenPlan = ['hobbyist', 'tinkerer', 'pro'].includes(requestedPlan) ? requestedPlan : 'hobbyist';
const billingNotice = ['success', 'cancelled'].includes(new URLSearchParams(location.search).get('billing'))
  ? new URLSearchParams(location.search).get('billing') : '';
let billingKnown = Promise.resolve();
const modes = {
  create: {
    label: 'NEW ACCOUNT', title: 'Create your account', intro: 'Enter your email and choose a password.',
    submit: 'Create account', fields: ['email', 'password'], oauthVerb: 'Sign up',
  },
  'sign-in': {
    label: 'SIGN IN', title: 'Welcome back', intro: 'Sign in to your Fizzlayer account.',
    submit: 'Sign in', fields: ['email', 'password'], oauthVerb: 'Sign in', passkey: true,
  },
  forgot: {
    label: 'RESET', title: 'Reset your password', intro: 'Enter your email and we will send you a link to choose a new password.',
    submit: 'Send reset link', fields: ['email'],
  },
  reset: {
    label: 'NEW PASSWORD', title: 'Choose a new password', intro: 'Enter a new password for your Fizzlayer account.',
    submit: 'Save password', fields: ['password'],
  },
  'check-email': { label: 'CHECK EMAIL', title: 'Check your email', intro: '', fields: [] },
};
let mode = 'create';
let resetToken = ''; // From a password reset link; used once to set the new password.
let pending = null; // What "Resend email" sends: { action, email }.

function showError(message) {
  $('form-error').textContent = message;
  $('form-error').hidden = !message;
}

// Shows the OAuth and passkey buttons that work here, and the divider only if any do.
function renderAlternatives() {
  const current = modes[mode];
  const choosing = mode === 'create' || mode === 'sign-in';
  for (const [provider, name] of Object.entries(oauthProviders)) {
    $(provider).hidden = !oauthEnabled.includes(provider);
    $(`${provider}-label`).textContent = `${current.oauthVerb || 'Continue'} with ${name}`;
  }
  const passkey = Boolean(current.passkey && passkeysSupported);
  $('passkey').hidden = !passkey;
  $('oauth').hidden = !choosing || (!oauthEnabled.length && !passkey);
}

function render(intro) {
  const current = modes[mode];
  const choosing = mode === 'create' || mode === 'sign-in';
  $('mode-switch').hidden = !choosing;
  for (const [id, on] of [['create-mode', mode === 'create'], ['sign-in-mode', mode === 'sign-in']]) {
    $(id).classList.toggle('selected', on);
    $(id).setAttribute('aria-pressed', String(on));
  }
  for (const field of ['email', 'password']) $(`${field}-wrap`).hidden = !current.fields.includes(field);
  // The form stays visible in every mode so its error message can show; only its parts hide.
  $('form-actions').hidden = !current.submit;
  $('email-sent').hidden = mode !== 'check-email';
  renderAlternatives();
  $('forgot').hidden = mode !== 'sign-in' && mode !== 'forgot';
  $('forgot').textContent = mode === 'forgot' ? 'Back to sign in' : 'Forgot password?';
  $('step-label').textContent = current.label;
  $('auth-title').textContent = current.title;
  document.title = `${current.title} · Fizzlayer`;
  $('auth-intro').textContent = intro ?? current.intro;
  $('continue').textContent = current.submit || '';
  $('password').minLength = mode === 'sign-in' ? 8 : 12;
  $('password').autocomplete = mode === 'sign-in' ? 'current-password' : 'new-password';
  $('email').autocomplete = mode === 'sign-in' ? 'username' : 'email';
  $('password-help').hidden = mode === 'sign-in';
  renderPlans();
  showError('');
}

function paidPlan(id) {
  return id === 'tinkerer' || id === 'pro';
}

function planBody(plan) {
  const body = document.createDocumentFragment();
  for (const [className, text] of [
    ['plan-option-name', plan.name],
    ['plan-option-price', plan.period ? `${plan.price} ${plan.period}` : plan.price],
    ['plan-option-tag', plan.tag],
    ['plan-option-detail', plan.detail],
  ]) {
    const span = document.createElement('span');
    span.className = className;
    span.textContent = text;
    body.append(span);
  }
  return body;
}

function renderPlans() {
  const picker = $('plan-picker');
  const show = mode === 'create' && billingAvailable;
  picker.hidden = !show;
  if (!show) return;
  const box = $('plan-options');
  box.className = 'plan-options';
  box.replaceChildren();
  for (const plan of signupPlans) {
    if (plan.href) {
      const link = document.createElement('a');
      link.className = 'plan-option plan-option-link';
      link.href = plan.href;
      link.setAttribute('aria-label', 'Enterprise, contact us');
      if (requestedPlan === 'enterprise') link.classList.add('plan-option-current');
      link.append(planBody(plan));
      box.append(link);
      continue;
    }
    const label = document.createElement('label');
    label.className = 'plan-option';
    const input = document.createElement('input');
    input.type = 'radio';
    input.name = 'plan';
    input.value = plan.id;
    input.checked = plan.id === chosenPlan;
    input.addEventListener('change', () => { chosenPlan = plan.id; });
    const check = document.createElement('span');
    check.className = 'plan-option-check';
    check.setAttribute('aria-hidden', 'true');
    label.append(input, check, planBody(plan));
    box.append(label);
  }
}

function rememberSignupPlan() {
  if (mode !== 'create' || !billingAvailable || !paidPlan(chosenPlan)) {
    localStorage.removeItem(PLAN_KEY);
    return;
  }
  localStorage.setItem(PLAN_KEY, JSON.stringify({ plan: chosenPlan, at: Date.now() }));
}

function takeSignupPlan() {
  let stored = null;
  try { stored = JSON.parse(localStorage.getItem(PLAN_KEY) || 'null'); } catch { stored = null; }
  localStorage.removeItem(PLAN_KEY);
  if (!stored || !paidPlan(stored.plan)) return null;
  if (typeof stored.at !== 'number' || Date.now() - stored.at > 24 * 60 * 60 * 1000) return null;
  return stored.plan;
}

async function showWorkspace(username) {
  signedInUsername = username;
  let sensors = [];
  try { sensors = (await send('/api/sensors', 'GET')).sensors || []; } catch { sensors = []; }
  $('upgrade-prompt').hidden = true;
  showDashboard(sensors);
}

async function showBillingReturn(username) {
  await billingKnown;
  if (!billingAvailable) {
    await showWorkspace(username);
    return;
  }
  signedInUsername = username;
  let sensors = [];
  try { sensors = (await send('/api/sensors', 'GET')).sensors || []; } catch { sensors = []; }
  showDashboard(sensors);
  const note = $('upgrade-prompt');
  note.replaceChildren();
  if (billingNotice === 'cancelled') {
    note.append('Checkout cancelled. Your plan has not changed. ');
    const link = document.createElement('a');
    link.href = '/settings.html';
    link.textContent = 'Finish upgrading';
    note.append(link, ' whenever you’re ready.');
  } else {
    note.textContent = 'Payment received. Your plan will update shortly; refresh this page in a minute.';
  }
  note.hidden = false;
}

async function continueAfterSignup(username) {
  await billingKnown;
  const plan = takeSignupPlan();
  // No Stripe keys: no plan picker, no checkout, and no upgrade prompt. The new account opens the dashboard.
  if (!billingAvailable) {
    await showWorkspace(username);
    return;
  }
  if (plan) {
    try {
      const result = await send('/api/billing', 'POST', { action: 'checkout', plan, return_to: 'app' });
      location.assign(result.url);
      return;
    } catch { /* Checkout did not start. The account stays on Hobbyist. */ }
  }
  showSetup(username);
}

function setMode(next, intro) {
  const email = $('email').value;
  mode = next;
  form.reset();
  $('email').value = email; // Keep a typed address when moving between sign-in and reset.
  render(intro);
  const first = modes[next].fields.find((field) => !(field === 'email' && email));
  if (first) $(first).focus();
}

function validEmail() {
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test($('email').value.trim())) {
    showError('Enter a valid email address.');
    $('email').focus();
    return false;
  }
  return true;
}

function validPassword() {
  const length = new TextEncoder().encode($('password').value).length;
  const tooShort = mode === 'sign-in' ? length < 8 : [...$('password').value].length < 12;
  if (tooShort || length > 72) {
    showError(mode === 'sign-in' ? 'Enter your password.' : 'Use at least 12 characters, up to 72 bytes.');
    $('password').focus();
    return false;
  }
  return true;
}


function setupError(message) {
  $('setup-error').textContent = message;
  $('setup-error').hidden = !message;
}

function renderSetup() {
  $('setup-loading').hidden = true;
  $('sensor-question').hidden = false;
  $('setup-retry').hidden = true;
  document.querySelectorAll('.sensor-card').forEach((card) => {
    card.setAttribute('aria-pressed', String(chosenKinds.includes(card.dataset.kind)));
  });
  const count = chosenKinds.length;
  $('setup-start').disabled = count === 0;
  $('selection-status').textContent = count === 0
    ? 'No sensors selected yet'
    : `${count} sensor ${count === 1 ? 'type' : 'types'} selected: ${chosenKinds.map((kind) => sensorNames[kind]).join(', ')}`;
}

async function loadSetup() {
  $('sensor-question').hidden = true;
  $('setup-loading').hidden = false;
  $('setup-retry').hidden = true;
  setupError('');
  try {
    const [state, inventory] = await Promise.all([send('/api/setup', 'GET'), send('/api/sensors', 'GET')]);
    if (inventory.sensors?.length) {
      showDashboard(inventory.sensors);
      return;
    }
    chosenKinds = state.choices.filter((kind) => sensorNames[kind]);
    renderSetup();
  } catch (error) {
    $('setup-loading').hidden = true;
    setupError(error.message);
    $('setup-retry').hidden = false;
  }
}

function showSetup(username) {
  signedInUsername = username;
  $('account-panel').hidden = true;
  $('dashboard').hidden = true;
  $('setup').hidden = false;
  document.querySelector('.shell').classList.add('setup-active');
  document.querySelector('.shell').classList.remove('dashboard-active');
  $('setup-username').textContent = username;
  loadSetup();
}

function showDashboard(sensors) {
  $('account-panel').hidden = true;
  $('setup').hidden = true;
  $('dashboard').hidden = false;
  document.querySelector('.shell').classList.remove('setup-active');
  document.querySelector('.shell').classList.add('dashboard-active');
  window.fizzDashboard.start(signedInUsername, sensors);
}

async function send(url, method, data) {
  const response = await fetch(url, {
    method,
    credentials: 'same-origin',
    headers: { 'content-type': 'application/json' },
    body: data ? JSON.stringify(data) : undefined,
  });
  const result = await response.json();
  if (!response.ok) throw Object.assign(new Error(result.error?.message || 'Something went wrong. Try again.'), { code: result.error?.code });
  return result;
}

form.addEventListener('submit', async (event) => {
  event.preventDefault();
  const { fields } = modes[mode];
  if (fields.includes('email') && !validEmail()) return;
  if (fields.includes('password') && !validPassword()) return;
  const email = $('email').value.trim();
  const password = $('password').value;
  if (mode === 'create') rememberSignupPlan();
  else localStorage.removeItem(PLAN_KEY);
  const body = {
    create: { action: 'sign_up', email, password },
    'sign-in': { action: 'sign_in', email, password },
    forgot: { action: 'recover', email },
    reset: { action: 'link', access_token: resetToken, password },
  }[mode];
  const button = $('continue');
  button.disabled = true;
  showError('');
  try {
    const result = await send('/api/auth', 'POST', body);
    if (result.username) {
      resetToken = '';
      const created = mode === 'create';
      form.reset();
      if (created) await continueAfterSignup(result.username);
      else showSetup(result.username);
    } else if (mode === 'forgot') {
      pending = { action: 'recover', email };
      setMode('check-email', `If ${email} has a Fizzlayer account, we sent it a link to choose a new password.`);
    } else {
      pending = { action: 'resend', email };
      setMode('check-email', `We sent a confirmation link to ${email}. Open it on any device to finish creating your account.`);
    }
  } catch (error) {
    if (error.code === 'email_not_confirmed') {
      pending = { action: 'resend', email };
      setMode('check-email', `Confirm your email first. Open the link we sent to ${email}, or send it again.`);
      return;
    }
    if (error.code === 'link_expired' && mode === 'reset') {
      setMode('forgot');
      showError(error.message);
      return;
    }
    showError(error.message);
    const field = { invalid_email: 'email', weak_password: 'password', same_password: 'password' }[error.code];
    if (field && modes[mode].fields.includes(field)) $(field).focus();
  } finally {
    button.disabled = false;
  }
});

$('resend').addEventListener('click', async () => {
  if (!pending) return;
  const button = $('resend');
  button.disabled = true;
  showError('');
  try {
    await send('/api/auth', 'POST', pending);
    $('auth-intro').textContent = `Sent again to ${pending.email}. Check your inbox and spam folder.`;
  } catch (error) {
    showError(error.message);
  } finally {
    button.disabled = false;
  }
});

$('passkey').addEventListener('click', async () => {
  const button = $('passkey');
  button.disabled = true;
  showError('');
  try {
    const start = await send('/api/auth', 'POST', { action: 'passkey_options' });
    const credential = await window.fizzPasskey.credential(start.options, false);
    const result = await send('/api/auth', 'POST', { action: 'passkey_sign_in', challenge_id: start.challenge_id, credential });
    localStorage.removeItem(PLAN_KEY);
    showSetup(result.username);
  } catch (error) {
    if (!window.fizzPasskey.cancelled(error)) showError(error instanceof DOMException ? 'That passkey didn’t work. Try again.' : error.message);
  } finally {
    button.disabled = false;
  }
});

$('create-mode').addEventListener('click', () => setMode('create'));
$('sign-in-mode').addEventListener('click', () => setMode('sign-in'));
$('forgot').addEventListener('click', () => setMode(mode === 'forgot' ? 'sign-in' : 'forgot'));
$('back-to-sign-in').addEventListener('click', () => setMode('sign-in'));
// Google and GitHub sign-in leave the page. A new account gets a Fizzlayer account on return.
for (const provider of Object.keys(oauthProviders)) {
  $(provider).addEventListener('click', () => {
    if (mode === 'create') rememberSignupPlan();
    else localStorage.removeItem(PLAN_KEY);
    location.assign(`/api/auth?provider=${provider}`);
  });
}
// If this fails, every button stays: /api/auth?provider= still refuses a disabled provider.
fetch('/api/auth?providers', { credentials: 'same-origin' })
  .then((response) => (response.ok ? response.json() : null))
  .then((data) => {
    if (!Array.isArray(data?.providers)) return;
    oauthEnabled = Object.keys(oauthProviders).filter((provider) => data.providers.includes(provider));
    renderAlternatives();
  })
  .catch(() => {});

document.querySelectorAll('.sensor-card').forEach((card) => {
  const info = window.fizzKinds.get(card.dataset.kind);
  const name = document.createElement('span');
  name.className = 'sensor-name';
  name.textContent = info.label;
  const detail = document.createElement('span');
  detail.className = 'sensor-detail';
  detail.textContent = info.detail;
  card.style.setProperty('--sensor-color', info.color);
  const selected = document.createElement('span');
  selected.className = 'sensor-selected';
  selected.setAttribute('aria-hidden', 'true');
  const check = document.createElement('span');
  check.className = 'fa fa-check';
  selected.append(check, 'Selected');
  card.replaceChildren(window.fizzKinds.badge(card.dataset.kind, 'sensor-icon'), name, detail, selected);
});
document.querySelectorAll('.sensor-card').forEach((card) => card.addEventListener('click', async () => {
  const cards = document.querySelectorAll('.sensor-card');
  const removing = chosenKinds.includes(card.dataset.kind);
  cards.forEach((item) => { item.disabled = true; });
  setupError('');
  try {
    const state = await send('/api/setup', removing ? 'DELETE' : 'POST', { kind: card.dataset.kind });
    chosenKinds = state.choices.filter((kind) => sensorNames[kind]);
    renderSetup();
  } catch (error) {
    setupError(error.message);
  } finally {
    cards.forEach((item) => { item.disabled = false; });
  }
}));
$('setup-start').addEventListener('click', async () => {
  const button = $('setup-start');
  button.disabled = true;
  setupError('');
  try {
    const current = await send('/api/sensors', 'GET');
    for (const kind of chosenKinds) {
      if (!current.sensors.some((sensor) => sensor.kind === kind)) {
        await send('/api/sensors', 'POST', { kind, mode: 'simulated' });
      }
    }
    const inventory = await send('/api/sensors', 'GET');
    showDashboard(inventory.sensors);
  } catch (error) {
    setupError(error.message);
    button.disabled = chosenKinds.length === 0;
  }
});
$('setup-retry').addEventListener('click', loadSetup);
$('setup-chat').addEventListener('click', () => {
  showDashboard([]);
  $('chat-title').scrollIntoView({ behavior: 'smooth', block: 'start' });
  $('chat-input').focus({ preventScroll: true });
});
async function signOut() {
  try {
    await send('/api/session', 'DELETE');
    window.fizzDashboard.stop();
    $('setup').hidden = true;
    $('dashboard').hidden = true;
    $('account-panel').hidden = false;
    document.querySelector('.shell').classList.remove('setup-active');
    document.querySelector('.shell').classList.remove('dashboard-active');
    chosenKinds = [];
    setMode('sign-in');
  } catch { /* Keep the signed-in view if the server could not revoke the session. */ }
}
$('sign-out').addEventListener('click', signOut);
$('dashboard-sign-out').addEventListener('click', signOut);

// Arriving here can carry state in the URL fragment:
// - #sign-in from the landing page's Sign in link.
// - #auth_error=<code> when Google or GitHub sign-in fails in /api/auth.
// - #access_token=...&type=signup|recovery from a Supabase email link, or #error=... if it expired.
const hash = new URLSearchParams(location.hash.slice(1));
const authErrors = {
  mfa_required: 'Complete multi-factor authentication before signing in.',
  rate_limited: 'Too many attempts. Try again in an hour.',
  sign_up_closed: "This instance isn't accepting new accounts.",
  cancelled: 'Sign-in was cancelled.',
  expired: 'Sign-in took too long or was interrupted. Try again.',
  failed: 'Sign-in is temporarily unavailable. Try again.',
  unavailable: "That sign-in option isn't available here. Use another one.",
  no_email: "We couldn't get a verified email address from that account. Add and verify one with the provider (on GitHub: Settings → Emails), then try again.",
  verify_email: 'We sent you an email to confirm your address. Open the link in it, then sign in again.',
};
const linkToken = hash.get('access_token');
const authError = hash.get('auth_error');
if (location.hash === '#sign-in') mode = 'sign-in';
// Tokens must not linger in the address bar or history.
if (location.hash) history.replaceState(null, '', location.pathname);

if (linkToken && hash.get('type') === 'recovery') {
  resetToken = linkToken;
  mode = 'reset';
  render();
  $('password').focus();
} else if (linkToken) {
  mode = 'sign-in';
  render('Confirming your email…');
  send('/api/auth', 'POST', { action: 'link', access_token: linkToken })
    .then((result) => continueAfterSignup(result.username))
    .catch((error) => {
      render();
      showError(error.message);
    });
} else if (hash.get('error') || hash.get('error_code')) {
  mode = 'sign-in';
  render();
  showError('That link has expired or was already used. Request a new one.');
} else {
  render();
  if (authError) showError(authErrors[authError] || authErrors.failed);
  fetch('/api/me', { credentials: 'same-origin', cache: 'no-store' })
    .then((response) => response.ok ? response.json() : null)
    .then((data) => {
      if (!data?.username) return;
      if (billingNotice) return showBillingReturn(data.username);
      if (localStorage.getItem(PLAN_KEY)) return continueAfterSignup(data.username);
      showSetup(data.username);
    })
    .catch(() => {});
}

billingKnown = fetch('/api/billing', { credentials: 'same-origin', cache: 'no-store' })
  .then((response) => (response.ok ? response.json() : { available: false }))
  .then((data) => {
    billingAvailable = data.available === true;
    if (!billingAvailable) chosenPlan = 'hobbyist';
    renderPlans();
  })
  .catch(() => { billingAvailable = false; chosenPlan = 'hobbyist'; });
