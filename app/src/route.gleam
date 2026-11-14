//// Client routes for the SPA served at `/app`.
////
//// The Lustre dev server is the whole origin, so `/` is also the sign-in
//// screen there. Production only serves this bundle under `/app`.

import gleam/list
import gleam/string

pub type Route {
  SignIn
  Workspace
  NotFound(path: String)
  Leave(path: String)
}

pub const sign_in_path = "/app"

pub const workspace_path = "/app/workspace"

/// Parse a URL path. Paths outside the SPA are `Leave` so the caller can
/// do a full page load and hit the static site.
pub fn parse(path: String) -> Route {
  case segments(path) {
    [] | [""] | ["app"] | ["app", "index.html"] -> SignIn
    ["workspace"] | ["app", "workspace"] -> Workspace
    ["app", ..] -> NotFound(path: path)
    _ -> Leave(path: path)
  }
}

fn segments(path: String) -> List(String) {
  path
  |> string.split(on: "/")
  |> list.filter(fn(segment) { segment != "" })
}
