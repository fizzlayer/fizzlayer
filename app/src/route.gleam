//// Client routes for the SPA served at `/app`.
////
//// The Lustre dev server is the whole origin, so `/` is also the sign-in
//// screen there. Production only serves this bundle under `/app`.
//// `/sensors` and the rest of the site are full page loads.
////
//// Each gateway has one page with tabs at `/app/gateways/<id>/<tab>`. The
//// older onboarding URLs (`/app/onboarding/<id>/server` and the rest) and
//// `/tokens` still open the matching tab, so old links keep working.

import gleam/list
import gleam/string

/// The sections of a gateway's page.
pub type Tab {
  Overview
  Servers
  Rules
  Approvals
  Changes
  Connect
  Settings
}

pub type Route {
  SignIn
  /// The gateway list. `/app/start` and `/app/gateways` both land here.
  Gateways
  NewGateway
  Gateway(id: String, tab: Tab)
  Preview(name: String)
  NotFound(path: String)
  Leave(path: String)
}

/// Where sign-in starts, and where OAuth and email links return to. Supabase
/// allows this URL, so keep it stable.
pub const sign_in_path = "/app"

/// The sign-in form, as opposed to account creation at `/app`.
pub const sign_in_form_path = "/app/sign-in"

/// Where a signed-in visit lands: the list of gateways.
pub const gateways_path = "/app/gateways"

pub const new_gateway_path = "/app/onboarding"

/// Every tab in menu order.
pub const tabs = [
  Overview,
  Servers,
  Rules,
  Approvals,
  Changes,
  Connect,
  Settings,
]

/// The URL of one tab of a gateway. Without an id there is no gateway page,
/// so it falls back to the list instead of building `/app/gateways//servers`.
pub fn tab_path(id: String, tab: Tab) -> String {
  case id, tab {
    "", _ -> gateways_path
    _, Overview -> "/app/gateways/" <> id
    _, _ -> "/app/gateways/" <> id <> "/" <> tab_slug(tab)
  }
}

pub fn tab_slug(tab: Tab) -> String {
  case tab {
    Overview -> "overview"
    Servers -> "servers"
    Rules -> "rules"
    Approvals -> "approvals"
    Changes -> "alerts"
    Connect -> "connect"
    Settings -> "settings"
  }
}

pub fn preview_path(name: String) -> String {
  "/app/preview/" <> name
}

/// Parse a URL path. Paths outside the SPA are `Leave` so the caller can
/// do a full page load and hit the static site.
pub fn parse(path: String) -> Route {
  case segments(path) {
    [] | [""] | ["app"] | ["app", "index.html"] | ["app", "sign-in"] -> SignIn
    ["start"]
    | ["app", "start"]
    | ["gateways"]
    | ["app", "gateways"]
    | ["workspace"]
    | ["app", "workspace"] -> Gateways
    ["onboarding"] | ["app", "onboarding"] -> NewGateway
    ["onboarding", id, step] | ["app", "onboarding", id, step] ->
      gateway(path, id, old_step(step))
    ["gateways", id] | ["app", "gateways", id] ->
      gateway(path, id, Ok(Overview))
    ["gateways", id, page] | ["app", "gateways", id, page] ->
      gateway(path, id, tab_of(page))
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

fn gateway(path: String, id: String, tab: Result(Tab, Nil)) -> Route {
  case uuid_ish(id), tab {
    True, Ok(tab) -> Gateway(id:, tab:)
    _, _ -> NotFound(path:)
  }
}

fn tab_of(page: String) -> Result(Tab, Nil) {
  case page {
    "overview" -> Ok(Overview)
    "servers" -> Ok(Servers)
    "rules" -> Ok(Rules)
    "approvals" -> Ok(Approvals)
    "alerts" | "changes" -> Ok(Changes)
    "connect" | "tokens" -> Ok(Connect)
    "settings" -> Ok(Settings)
    _ -> Error(Nil)
  }
}

/// The steps of the old setup wizard, mapped onto tabs.
fn old_step(step: String) -> Result(Tab, Nil) {
  case step {
    "server" -> Ok(Servers)
    "tools" -> Ok(Rules)
    "pin" -> Ok(Changes)
    "client" -> Ok(Connect)
    _ -> Error(Nil)
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
