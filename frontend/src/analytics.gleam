/// Cookieless page-view rules. The browser still parses the URL; this module
/// decides which part may leave the page, and which hosts skip the script.
/// Local development never loads Vercel Web Analytics.
pub fn track_on_this_host(hostname: String) -> Bool {
  case hostname {
    "localhost" | "127.0.0.1" | "[::1]" -> False
    _ -> True
  }
}

/// Keep the origin and path. Query strings and fragments can carry sign-in
/// links, pairing codes, or billing results, so they are not part of this URL.
pub fn page_url(origin: String, pathname: String) -> String {
  origin <> pathname
}

pub fn install() -> Nil {
  do_install()
}

@external(javascript, "./analytics_ffi.mjs", "install")
fn do_install() -> Nil
