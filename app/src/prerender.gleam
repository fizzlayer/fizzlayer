//// Writes pages as static HTML, so they show at once, without waiting for
//// JavaScript, and search engines, link previews and agents can read them.
//// Run from `app/` with `gleam run -m prerender`, after the SPA bundle is in
//// `public/app`; `scripts/build-spa.sh` does both.
////
//// Site pages (`public/index.html`, `public/fizz.css`) are committed, and CI
//// fails if they are out of date. App pages under `public/app` are build
//// output. Each is the app's first render for that URL, so the bundle takes
//// over the same markup instead of replacing a blank page.

import fizz_spa
import gleam/list
import gleam/uri
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import site/landing

@external(javascript, "./prerender_ffi.mjs", "write_file")
fn write_file(path: String, contents: String) -> Nil

@external(javascript, "./prerender_ffi.mjs", "read_file")
fn read_file(path: String) -> String

/// The example screens at `/app/preview/<name>`. Keep in step with
/// `gateway.preview`.
pub const previews = [
  "choose", "create", "server", "tools", "tools-pro", "pin", "client",
  "client-hosted", "gateways", "approvals", "alerts", "tokens", "limit",
]

pub fn main() -> Nil {
  write_file("../public/fizz.css", read_file("assets/fizz.css"))
  write_file("../public/index.html", render(landing.page()))

  write_file(
    "../public/app/index.html",
    app_page("/app", "Create your account"),
  )
  write_file(
    "../public/app/sign-in/index.html",
    app_page("/app/sign-in", "Sign in"),
  )
  // Every other /app URL gets the loading screen until the session is known.
  write_file("../public/app/shell.html", app_page("/app/gateways", "Fizzlayer"))
  list.each(previews, fn(name) {
    write_file(
      "../public/app/preview/" <> name <> "/index.html",
      app_page("/app/preview/" <> name, "Example"),
    )
  })
}

fn render(page: Element(msg)) -> String {
  element.to_document_string(page) <> "\n"
}

/// One app URL as a full document, with the app's first render inside `#app`.
pub fn app_page(path: String, title: String) -> String {
  let assert Ok(target) = uri.parse(path)
  let content = fizz_spa.view(fizz_spa.first_model(target))
  render(
    html.html([attribute.lang("en")], [
      html.head([], [
        html.meta([attribute.charset("utf-8")]),
        html.meta([
          attribute.name("viewport"),
          attribute.content("width=device-width, initial-scale=1"),
        ]),
        html.meta([attribute.name("robots"), attribute.content("noindex")]),
        html.title([], case title {
          "Fizzlayer" -> title
          _ -> title <> " | Fizzlayer"
        }),
        html.link([
          attribute.rel("icon"),
          attribute.href("/fizz-agent.svg"),
          attribute.type_("image/svg+xml"),
        ]),
        html.link([
          attribute.rel("preload"),
          attribute.href("/fonts/Geist-Variable.woff2"),
          attribute.attribute("as", "font"),
          attribute.type_("font/woff2"),
          attribute.attribute("crossorigin", ""),
        ]),
        html.link([attribute.rel("stylesheet"), attribute.href("/app/fizz.css")]),
        // Passkey sign-in uses window.fizzPasskey; it must run before the app.
        html.script(
          [attribute.src("/passkey.js"), attribute.attribute("defer", "")],
          "",
        ),
        html.script(
          [attribute.type_("module"), attribute.src("/app/fizz_spa.js")],
          "",
        ),
      ]),
      html.body([], [html.div([attribute.id("app")], [content])]),
    ]),
  )
}
