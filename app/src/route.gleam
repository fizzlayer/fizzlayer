//// Client routes for the SPA served at `/app`.
////
//// The Lustre dev server is the whole origin, so `/` is also the sign-in
//// screen there. Production only serves this bundle under `/app`.
//// `/sensors` and the rest of the site are full page loads.

import gleam/list
import gleam/string

pub type Step {
  Create
  Server
  Tools
  Pin
  Client
}

pub type Route {
  SignIn
  Start
  Onboarding(id: String, step: Step)
  Gateways
  GatewayHome(id: String)
  Approvals(id: String)
  PinAlerts(id: String)
  ClientTokens(id: String)
  Preview(name: String)
  NotFound(path: String)
  Leave(path: String)
}

pub const sign_in_path = "/app"

pub const start_path = "/app/start"

pub const gateways_path = "/app/gateways"

pub fn onboarding_path(id: String, step: Step) -> String {
  case id, step {
    "", Create -> "/app/onboarding"
    _, Create -> "/app/onboarding"
    _, Server -> "/app/onboarding/" <> id <> "/server"
    _, Tools -> "/app/onboarding/" <> id <> "/tools"
    _, Pin -> "/app/onboarding/" <> id <> "/pin"
    _, Client -> "/app/onboarding/" <> id <> "/client"
  }
}

pub fn gateway_path(id: String) -> String {
  "/app/gateways/" <> id
}

pub fn approvals_path(id: String) -> String {
  "/app/gateways/" <> id <> "/approvals"
}

pub fn alerts_path(id: String) -> String {
  "/app/gateways/" <> id <> "/alerts"
}

pub fn tokens_path(id: String) -> String {
  "/app/gateways/" <> id <> "/tokens"
}

pub fn preview_path(name: String) -> String {
  "/app/preview/" <> name
}

/// Parse a URL path. Paths outside the SPA are `Leave` so the caller can
/// do a full page load and hit the static site.
pub fn parse(path: String) -> Route {
  case segments(path) {
    [] | [""] | ["app"] | ["app", "index.html"] -> SignIn
    ["start"] | ["app", "start"] -> Start
    ["onboarding"] | ["app", "onboarding"] -> Onboarding(id: "", step: Create)
    ["onboarding", id, step] | ["app", "onboarding", id, step] ->
      onboarding(path, id, step)
    ["gateways"] | ["app", "gateways"] | ["workspace"] | ["app", "workspace"] ->
      Gateways
    ["gateways", id] | ["app", "gateways", id] -> gateway_home(path, id)
    ["gateways", id, page] | ["app", "gateways", id, page] ->
      gateway_page(path, id, page)
    ["preview", name] | ["app", "preview", name] -> Preview(name:)
    ["app", ..] -> NotFound(path:)
    _ -> Leave(path:)
  }
}

pub fn query_flag(query: String, key: String, value: String) -> Bool {
  query
  |> string.split("&")
  |> list.any(fn(pair) { pair == key <> "=" <> value })
}

pub fn query_value(query: String, key: String) -> String {
  query
  |> string.split("&")
  |> list.find_map(fn(pair) {
    case string.split_once(pair, "=") {
      Ok(#(name, value)) if name == key -> Ok(value)
      _ -> Error(Nil)
    }
  })
  |> result_or("")
}

fn onboarding(path: String, id: String, step: String) -> Route {
  case uuid_ish(id) {
    False -> NotFound(path:)
    True ->
      case step {
        "server" -> Onboarding(id:, step: Server)
        "tools" -> Onboarding(id:, step: Tools)
        "pin" -> Onboarding(id:, step: Pin)
        "client" -> Onboarding(id:, step: Client)
        _ -> NotFound(path:)
      }
  }
}

fn gateway_home(path: String, id: String) -> Route {
  case uuid_ish(id) {
    True -> GatewayHome(id:)
    False -> NotFound(path:)
  }
}

fn gateway_page(path: String, id: String, page: String) -> Route {
  case uuid_ish(id) {
    False -> NotFound(path:)
    True ->
      case page {
        "approvals" -> Approvals(id:)
        "alerts" -> PinAlerts(id:)
        "tokens" -> ClientTokens(id:)
        _ -> NotFound(path:)
      }
  }
}

fn result_or(value: Result(String, Nil), fallback: String) -> String {
  case value {
    Ok(found) -> found
    Error(_) -> fallback
  }
}

fn uuid_ish(value: String) -> Bool {
  string.byte_size(value) == 36
  && string.contains(value, "-")
  && list.all(string.to_utf_codepoints(value), fn(codepoint) {
    let code = string.utf_codepoint_to_int(codepoint)
    code == 45
    || { code >= 48 && code <= 57 }
    || { code >= 97 && code <= 102 }
    || { code >= 65 && code <= 70 }
  })
}

fn segments(path: String) -> List(String) {
  path
  |> string.split(on: "/")
  |> list.filter(fn(segment) { segment != "" })
}
