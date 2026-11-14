//// Checks the SPA fallback in vercel.json. Filesystem routes win on Vercel, so
//// `/app/fizz_spa.js` is still served as a file. These patterns are only the
//// fallback for paths that are not real files.

import gleam/list
import gleam/string

pub fn spa_fallback(source: String) -> Bool {
  case source {
    "/app" | "/app/" | "/app/:path*" -> True
    _ -> False
  }
}

pub fn matches_spa(source: String, path: String) -> Bool {
  case source {
    "/app" -> path == "/app"
    "/app/" -> path == "/app/"
    "/app/:path*" -> string.starts_with(path, "/app/")
    _ -> False
  }
}

pub fn is_catch_all(source: String) -> Bool {
  case source {
    "/(.*)" | "/:path*" | "/:path(.*)" | "/:splat*" | "/:path+" -> True
    _ -> False
  }
}

const protected = [
  "/api/ingest", "/api/me", "/api/status", "/api/auth", "/api/session",
  "/api/sensors", "/install.sh", "/.well-known/mcp.json",
  "/.well-known/mcp/server-card.json", "/.well-known/webmcp",
  "/.well-known/ai-plugin.json", "/llms.txt", "/openapi.json", "/ha.html",
  "/index.html", "/app.html", "/app.js", "/sensors.html", "/docs.html",
  "/pricing", "/self-host", "/integrations/slack/events",
]

const required = ["/app", "/app/", "/app/:path*"]

pub fn check(rewrites: List(#(String, String))) -> Result(Nil, String) {
  let catch_all = list.find(rewrites, fn(rewrite) { is_catch_all(rewrite.0) })
  let spa =
    list.filter(rewrites, fn(rewrite) { rewrite.1 == "/app/index.html" })
  let unknown = list.find(spa, fn(rewrite) { !spa_fallback(rewrite.0) })
  let missing =
    list.find(required, fn(source) {
      !list.any(spa, fn(rewrite) { rewrite.0 == source })
    })
  let swallowed =
    list.find(protected, fn(path) {
      list.any(spa, fn(rewrite) { matches_spa(rewrite.0, path) })
    })
  case catch_all, unknown, missing, swallowed {
    Ok(#(source, _)), _, _, _ ->
      Error("Catch-all rewrite is not allowed: " <> source)
    _, Ok(#(source, _)), _, _ ->
      Error("Unexpected SPA fallback source: " <> source)
    _, _, Ok(source), _ -> Error("Missing SPA fallback for " <> source)
    _, _, _, Ok(path) -> Error("SPA fallback would swallow " <> path)
    Error(_), Error(_), Error(_), Error(_) -> Ok(Nil)
  }
}
