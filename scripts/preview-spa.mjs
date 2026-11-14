// Static preview of public/ with the same /app fallback the Vercel rewrites use.
// Real files win. Only missing /app paths serve the SPA shell.
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
  if (decoded === "/app" || decoded === "/app/" || decoded.startsWith("/app/")) {
    return path.join(root, "app", "index.html");
  }
  return null;
}

const server = http.createServer((request, response) => {
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
