//// Copy-paste MCP client config. The token is a client JWT, never a
//// registration token and never an upstream API key.

import gleam/string

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

pub fn claude_desktop(url: String, token: String) -> String {
  "{\n  \"mcpServers\": {\n    \"fizzlayer\": {\n      \"type\": \"http\",\n      \"url\": \""
  <> json_escape(url)
  <> "\",\n      \"headers\": {\n        \"Authorization\": \"Bearer "
  <> json_escape(token)
  <> "\"\n      }\n    }\n  }\n}"
}

pub fn cursor(url: String, token: String) -> String {
  "{\n  \"mcpServers\": {\n    \"fizzlayer\": {\n      \"url\": \""
  <> json_escape(url)
  <> "\",\n      \"headers\": {\n        \"Authorization\": \"Bearer "
  <> json_escape(token)
  <> "\"\n      }\n    }\n  }\n}"
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
