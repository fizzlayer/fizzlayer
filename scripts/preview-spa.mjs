// Static preview of public/ with the same /app fallback the Vercel rewrites use.
// Real files win, then a folder's index.html. Other /app paths get the loading shell.
import fs from "node:fs";
import http from "node:http";
import path from "node:path";

const root = path.resolve(process.argv[2] ?? "public");
const port = Number(process.env.PORT ?? 4173);

const types = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".svg": "image/svg+xml",
  ".sh": "text/plain; charset=utf-8",
  ".txt": "text/plain; charset=utf-8",
  ".png": "image/png",
};

function resolve(urlPath) {
  const decoded = decodeURIComponent(urlPath.split("?")[0]);
  const rel = decoded === "/" ? "/index.html" : decoded;
  const full = path.join(root, rel);
  if (full !== root && !full.startsWith(root + path.sep)) return null;
  if (fs.existsSync(full) && fs.statSync(full).isFile()) return full;
  const index = path.join(full, "index.html");
  if (fs.existsSync(index) && fs.statSync(index).isFile()) return index;
  if (fs.existsSync(full + ".html")) return full + ".html";
  if (decoded.startsWith("/app/")) return path.join(root, "app", "shell.html");
  return null;
}

// No API runs here. Answer like a server with nobody signed in, so pages show
// their signed-out state instead of a connection error.
function api(request, response) {
  const signedOut = request.url.startsWith("/api/me");
  response.writeHead(signedOut ? 401 : 503, { "content-type": "application/json" });
  response.end(JSON.stringify({ error: signedOut
    ? { code: "unauthorized", message: "Sign in first." }
    : { code: "preview", message: "The API isn't running in this preview." } }));
}

const server = http.createServer((request, response) => {
  if ((request.url ?? "").startsWith("/api/")) return api(request, response);
  const file = resolve(request.url ?? "/");
  if (!file) {
    response.writeHead(404, { "content-type": "text/plain; charset=utf-8" });
    response.end("not found");
    return;
  }
  const type = types[path.extname(file)] ?? "application/octet-stream";
  response.writeHead(200, { "content-type": type, "cache-control": "no-store" });
  fs.createReadStream(file).pipe(response);
});

server.listen(port, "127.0.0.1", () => {
  process.stdout.write(`preview http://127.0.0.1:${port}\n`);
});
