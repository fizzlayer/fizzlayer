// Browser check for the phone pairing section in Settings (public/settings-phones.js).
// Serves public/ locally and answers /api/* with stubs, so it needs no server or database.
//   node scripts/settings-phones-check.mjs
// Env: PLAYWRIGHT_CORE (path to playwright-core), CHROMIUM (browser binary, default /usr/bin/chromium).
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { existsSync, statSync } from 'node:fs';
import { createRequire } from 'node:module';
import assert from 'node:assert/strict';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const site = path.join(path.dirname(fileURLToPath(import.meta.url)), '../public');
const { chromium } = createRequire(import.meta.url)(process.env.PLAYWRIGHT_CORE || 'playwright-core');

const types = { '.html': 'text/html', '.css': 'text/css', '.js': 'text/javascript', '.svg': 'image/svg+xml', '.png': 'image/png', '.woff2': 'font/woff2' };
const server = createServer(async (req, res) => {
  const file = path.join(site, decodeURIComponent(new URL(req.url, 'http://x').pathname));
  if (!file.startsWith(site) || !existsSync(file) || !statSync(file).isFile()) { res.writeHead(404).end(); return; }
  res.writeHead(200, { 'content-type': types[path.extname(file)] || 'application/octet-stream' }).end(await readFile(file));
}).listen(0);
const origin = `http://127.0.0.1:${server.address().port}`;

function account(callsIncluded) {
  return {
    username: 'ada', email: 'ada@example.com', providers: ['email'], passkeys: [], created_at: '2026-11-01T00:00:00Z',
    can_add_passkey: false, billing_available: false,
    plan: {
      id: callsIncluded ? 'tinkerer' : 'hobbyist', name: callsIncluded ? 'Tinkerer' : 'Hobbyist', monthly_price_cents: callsIncluded ? 1000 : 0,
      device_limit: 3, devices_used: 0, monthly_credits: 10, credits_used: 0, credits_reset_at: '2026-12-01T00:00:00Z',
      calls_included: callsIncluded, subscription: {},
    },
  };
}

// One page with a stubbed API. `phones` is the server's list; POSTs are recorded and change it.
async function open(browser, { callsIncluded, phones = [], confirmError }) {
  const state = { phones: [...phones], pending: null, posts: [] };
  const page = await browser.newPage();
  const errors = [];
  page.on('pageerror', (error) => errors.push(error.message));
  await page.route('**/*', async (route) => {
    const url = new URL(route.request().url());
    if (url.origin !== origin) return route.abort();
    const reply = (status, body) => route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(body) });
    if (url.pathname === '/api/account') return reply(200, account(callsIncluded));
    if (url.pathname === '/api/me') return reply(200, { username: 'ada' });
    if (url.pathname === '/api/phones' && route.request().method() === 'GET') {
      return reply(200, { calls_included: callsIncluded, phones: state.phones.map((phone) => ({ phone })), pending: state.pending });
    }
    if (url.pathname === '/api/phones') {
      const body = route.request().postDataJSON();
      state.posts.push(body);
      if (body.action === 'start') { state.pending = { phone: '+14155550123', attempts_remaining: 5 }; return reply(200, { phone: '+14155550123' }); }
      if (body.action === 'confirm' && confirmError) return reply(400, { error: { code: 'invalid_code', message: confirmError } });
      if (body.action === 'confirm') { state.pending = null; state.phones.push(body.phone); return reply(200, { phone: body.phone }); }
      if (body.action === 'remove') { state.phones = state.phones.filter((phone) => phone !== body.phone); return reply(200, { ok: true }); }
    }
    if (url.pathname.startsWith('/api/')) return reply(404, { error: { code: 'not_found', message: 'No route.' } });
    return route.continue();
  });
  await page.goto(`${origin}/settings.html`);
  await page.waitForFunction(() => document.getElementById('phones-empty').hidden === false || document.querySelector('#phone-list li'));
  return { page, state, errors };
}
const visible = (page, selector) => page.locator(selector).isVisible();
const text = (page, selector) => page.locator(selector).innerText();

const browser = await chromium.launch({ executablePath: process.env.CHROMIUM || '/usr/bin/chromium' });
try {
  // Hobbyist: no pairing, an upgrade pointer, and a number kept from a paid plan stays removable.
  {
    const { page, state, errors } = await open(browser, { callsIncluded: false, phones: ['+14155550100'] });
    assert.equal(await text(page, '#phones-title'), 'Phone for approval calls');
    assert.ok(await visible(page, '#phones-upgrade'));
    assert.match(await text(page, '#phones-upgrade'), /not included on Hobbyist/);
    assert.equal(await page.locator('#phones-upgrade a').getAttribute('href'), '#plan-title');
    assert.ok(!(await visible(page, '#phone-pair-form')));
    assert.ok(!(await visible(page, '#phone-confirm-form')));
    assert.equal(await text(page, '#phone-list li strong'), '(415) 555-0100');
    await page.getByRole('button', { name: 'Remove (415) 555-0100' }).click();
    await page.waitForFunction(() => !document.querySelector('#phone-list li'));
    assert.deepEqual(state.posts, [{ action: 'remove', phone: '+14155550100' }]);
    assert.match(await text(page, '#phone-message'), /was removed/);
    assert.deepEqual(errors, []);
    await page.close();
  }
  // Tinkerer: pair a number with the code from the call, then remove it.
  {
    const { page, state, errors } = await open(browser, { callsIncluded: true });
    assert.ok(await visible(page, '#phones-empty'));
    assert.ok(!(await visible(page, '#phones-upgrade')));
    assert.ok(await visible(page, '#phone-pair-form'));
    await page.fill('#phone-number', '(415) 555-0123');
    await page.click('#phone-start');
    await page.locator('#phone-confirm-form').waitFor({ state: 'visible' });
    assert.match(await text(page, '#phone-message'), /Calling \(415\) 555-0123/);
    await page.fill('#phone-code', '123456');
    await page.getByRole('button', { name: 'Confirm' }).click();
    await page.locator('#phone-list li').waitFor();
    assert.equal(await text(page, '#phone-list li strong'), '(415) 555-0123');
    assert.match(await text(page, '#phone-message'), /is paired/);
    assert.ok(!(await visible(page, '#phone-confirm-form')));
    assert.ok(!(await visible(page, '#phones-empty')));
    assert.deepEqual(state.posts.slice(0, 2), [
      { action: 'start', phone: '(415) 555-0123' },
      { action: 'confirm', phone: '+14155550123', code: '123456' },
    ]);
    assert.deepEqual(errors, []);
    await page.close();
  }
  // A wrong code shows the server's message and keeps the code form open.
  {
    const { page, errors } = await open(browser, { callsIncluded: true, confirmError: 'That code is not right. 4 tries left.' });
    await page.fill('#phone-number', '4155550123');
    await page.click('#phone-start');
    await page.locator('#phone-confirm-form').waitFor({ state: 'visible' });
    await page.fill('#phone-code', '000000');
    await page.getByRole('button', { name: 'Confirm' }).click();
    await page.waitForFunction(() => /not right/.test(document.getElementById('phone-message').textContent));
    assert.ok(await visible(page, '#phone-confirm-form'));
    assert.equal(await page.locator('#phone-list li').count(), 0);
    assert.deepEqual(errors, []);
    await page.close();
  }
  console.log('settings phone pairing: ok');
} finally {
  await browser.close();
  server.close();
}
