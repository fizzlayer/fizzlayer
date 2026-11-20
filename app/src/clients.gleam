//// Copy-paste MCP client config. The token is a client JWT, never a
//// registration token and never an upstream API key.

import gleam/bit_array
import gleam/string
import gleam/uri

/// URL to put in a client. A hosted data plane uses the gateway's public URL.
/// Until that host answers, local compose is `http://127.0.0.1:3000/mcp`.
/// A self-hosted row uses the URL stored on the gateway.
pub fn endpoint(hosted: Bool, mode: String, public_url: String) -> String {
  case hosted, mode {
    True, _ ->
      case public_url {
        "" -> "https://gw.fizzlayer.com/mcp"
        url -> url
      }
    False, "selfhost" ->
      case public_url {
        "" -> "http://127.0.0.1:3000/mcp"
        url -> url
      }
    False, _ -> "http://127.0.0.1:3000/mcp"
  }
}

pub fn claude_code(url: String, token: String) -> String {
  "claude mcp add --transport http fizzlayer "
  <> shell(url)
  <> " --header "
  <> shell("Authorization: Bearer " <> token)
}

/// The header value for clients with a separate name and value field, such as
/// a Claude custom connector.
pub fn bearer(token: String) -> String {
  "Bearer " <> token
}

pub fn cursor(url: String, token: String) -> String {
  "{\n  \"mcpServers\": {\n    \"fizzlayer\": {\n      \"url\": \""
  <> json_escape(url)
  <> "\",\n      \"headers\": {\n        \"Authorization\": \"Bearer "
  <> json_escape(token)
  <> "\"\n      }\n    }\n  }\n}"
}

/// One-click install for Cursor: its deeplink takes the server entry as
/// base64 JSON.
pub fn cursor_link(url: String, token: String) -> String {
  let config =
    "{\"url\":\""
    <> json_escape(url)
    <> "\",\"headers\":{\"Authorization\":\"Bearer "
    <> json_escape(token)
    <> "\"}}"
  "cursor://anysphere.cursor-deeplink/mcp/install?name=fizzlayer&config="
  <> uri.percent_encode(bit_array.base64_encode(
    bit_array.from_string(config),
    True,
  ))
}

/// `.vscode/mcp.json`, or the user-level MCP config in VS Code.
pub fn vscode(url: String, token: String) -> String {
  "{\n  \"servers\": {\n    \"fizzlayer\": {\n      \"type\": \"http\",\n      \"url\": \""
  <> json_escape(url)
  <> "\",\n      \"headers\": {\n        \"Authorization\": \"Bearer "
  <> json_escape(token)
  <> "\"\n      }\n    }\n  }\n}"
}

/// Codex reads the token from an environment variable, so it never lands in
/// `config.toml`.
pub fn codex(url: String, token: String) -> String {
  "export FIZZLAYER_TOKEN="
  <> shell(token)
  <> "\ncodex mcp add fizzlayer --url "
  <> shell(url)
  <> " --bearer-token-env-var FIZZLAYER_TOKEN"
}

pub fn gemini(url: String, token: String) -> String {
  "gemini mcp add --transport http fizzlayer "
  <> shell(url)
  <> " --header "
  <> shell("Authorization: Bearer " <> token)
}

/// The `mcp_servers` entry for `~/.hermes/config.yaml`.
pub fn hermes(url: String, token: String) -> String {
  "mcp_servers:\n  fizzlayer:\n    url: \""
  <> json_escape(url)
  <> "\"\n    headers:\n      Authorization: \"Bearer "
  <> json_escape(token)
  <> "\""
}

pub fn generic(url: String, token: String) -> String {
  "URL: "
  <> url
  <> "\nHeader: Authorization: Bearer "
  <> token
  <> "\nAccept: application/json, text/event-stream\n"
}

fn shell(value: String) -> String {
  "'" <> string.replace(value, "'", "'\"'\"'") <> "'"
}

fn json_escape(value: String) -> String {
  value
  |> string.replace("\\", "\\\\")
  |> string.replace("\"", "\\\"")
  |> string.replace("\n", "")
  |> string.replace("\r", "")
}
