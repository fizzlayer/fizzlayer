#!/usr/bin/env node
// Generate the agent discovery cards from their sources so they never drift:
//   public/.well-known/webmcp.json              WebMCP card (served at /.well-known/webmcp), from public/webmcp.js
//   public/.well-known/mcp/server-card.json     MCP Server Card (SEP-1649 draft), from src/mcp.rs
// Usage: node scripts/agent-cards.mjs           write both files
//        node scripts/agent-cards.mjs --check   fail if either file is out of date (CI)
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const read = (path) => readFileSync(join(root, path), 'utf8');
const ORIGIN = 'https://fizzlayer.com';
const version = read('Cargo.toml').match(/^version = "([^"]+)"/m)[1];

// Run webmcp.js against a stub WebMCP implementation and collect what it registers.
function webmcpTools() {
  const tools = [];
  const modelContext = { registerTool: (tool) => { tools.push(tool); } };
  const sandbox = {
    document: { modelContext },
    navigator: {},
    location: { origin: ORIGIN, pathname: '/' },
    window: { dispatchEvent() {} },
    URL, URLSearchParams, JSON, CustomEvent: class {}, setTimeout() {},
  };
  vm.runInNewContext(read('public/webmcp.js'), sandbox, { filename: 'webmcp.js' });
  return tools.map(({ name, description, inputSchema, annotations }) => ({ name, description, inputSchema, ...(annotations ? { annotations } : {}) }));
}

// The pages that load webmcp.js, read from the HTML so new pages are picked up.
function webmcpPages() {
  const pages = ['index.html', 'app.html', 'sensors.html', 'agents.html', 'settings.html', 'privacy.html', 'terms.html', 'demo.html', 'phone.html'];
  return pages.filter((page) => read(`public/${page}`).includes('src="/webmcp.js"')).map((page) => (page === 'index.html' ? '/' : `/${page}`));
}

function rustString(source, name) {
  const match = source.match(new RegExp(`const ${name}: &str = "((?:[^"\\\\]|\\\\.)*)";`, 's'));
  if (!match) throw new Error(`could not find ${name} in src/mcp.rs`);
  return match[1].replace(/\\\n\s*/g, '').replace(/\\"/g, '"').replace(/\\\\/g, '\\');
}

function webmcpCard() {
  return {
    name: 'fizzlayer',
    title: 'Fizzlayer',
    version,
    description: 'The physical layer for AI agents. Connect sensors, phones, and Linux devices, read their data, set alerts, and manage a Fizzlayer account and plan.',
    url: `${ORIGIN}/`,
    api: 'document.modelContext',
    pages: webmcpPages(),
    instructions: 'Open any listed page in a browser with WebMCP and call get_started. Tools act with the signed-in browser session. Accounts need an invite code and email confirmation; payments are entered by the person on Stripe Checkout. Failures return {"ok": false, "error": "..."}.',
    documentation: `${ORIGIN}/llms.txt`,
    mcp_server_card: `${ORIGIN}/.well-known/mcp/server-card.json`,
    tools: webmcpTools(),
  };
}

function serverCard() {
  const mcp = read('src/mcp.rs');
  return {
    $schema: 'https://static.modelcontextprotocol.io/schemas/mcp-server-card/v1.json',
    version: '1.0',
    protocolVersion: rustString(mcp, 'MODERN_VERSION'),
    serverInfo: { name: 'fizz', title: 'Fizz', version },
    description: 'Read a Fizzlayer customer\'s sensors, readings, and alerts, create alerts, and claim device pairing codes.',
    iconUrl: `${ORIGIN}/fizz-logo-480.png`,
    documentationUrl: 'https://github.com/fizzlayer/fizzlayer/blob/main/docs/REFERENCE.md#agent-connections-mcp',
    transport: { type: 'streamable-http', endpoint: `${ORIGIN}/api/mcp` },
    capabilities: { tools: { listChanged: false } },
    authentication: { required: true, schemes: ['bearer'] },
    instructions: `${rustString(mcp, 'INSTRUCTIONS')} Get a bearer token (fizz_agent_...) from ${ORIGIN}/agents.html or the create_agent_connection WebMCP tool.`,
    tools: ['dynamic'],
  };
}

const outputs = {
  'public/.well-known/webmcp.json': webmcpCard(),
  'public/.well-known/mcp/server-card.json': serverCard(),
};
const check = process.argv.includes('--check');
let stale = false;
for (const [path, card] of Object.entries(outputs)) {
  const text = `${JSON.stringify(card, null, 2)}\n`;
  if (check) {
    let current = '';
    try { current = read(path); } catch {}
    if (current !== text) { stale = true; console.error(`${path} is out of date; run node scripts/agent-cards.mjs`); }
  } else {
    mkdirSync(dirname(join(root, path)), { recursive: true });
    writeFileSync(join(root, path), text);
    console.log(`wrote ${path}`);
  }
}
if (stale) process.exit(1);
