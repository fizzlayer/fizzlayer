// Render the 1200x630 social preview card to public/og.png in headless Chromium.
//   node tools/og/render.mjs [out.png]
// Env: PLAYWRIGHT_CORE (path to playwright-core), CHROMIUM (default /usr/bin/chromium).
// The card is served alongside public/ so it uses the site's real styles, fonts, and icons.
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const site = path.join(here, '../../public');
const out = path.resolve(process.argv[2] || path.join(site, 'og.png'));
const { chromium } = createRequire(import.meta.url)(process.env.PLAYWRIGHT_CORE || 'playwright-core');

const types = { '.html': 'text/html', '.css': 'text/css', '.js': 'text/javascript', '.svg': 'image/svg+xml', '.png': 'image/png' };
const server = createServer(async (req, res) => {
  const pathname = decodeURIComponent(new URL(req.url, 'http://x').pathname);
  const file = pathname === '/card.html' ? path.join(here, 'card.html') : path.join(site, pathname);
  if (!(file.startsWith(site) || file === path.join(here, 'card.html')) || !existsSync(file)) { res.writeHead(404).end(); return; }
  res.writeHead(200, { 'content-type': types[path.extname(file)] || 'application/octet-stream' }).end(await readFile(file));
}).listen(0);

const browser = await chromium.launch({ executablePath: process.env.CHROMIUM || '/usr/bin/chromium' });
const page = await browser.newPage({ viewport: { width: 1200, height: 630 }, deviceScaleFactor: 1 });
page.on('pageerror', e => console.error('page error:', e.message));
await page.goto(`http://127.0.0.1:${server.address().port}/card.html`, { waitUntil: 'networkidle' });
await page.evaluate(() => document.fonts.ready);
await page.screenshot({ path: out, type: 'png' });
await browser.close();
server.close();
console.log('wrote', out);
