//// Writes the public site pages as static HTML, so they load without
//// JavaScript and search engines, link previews and agents can read them.
//// Run from `app/` with `gleam run -m prerender`; `scripts/build-spa.sh` does.
//// The output is committed, and CI fails if it is out of date.

import lustre/element
import site/landing

@external(javascript, "./prerender_ffi.mjs", "write_file")
fn write_file(path: String, contents: String) -> Nil

@external(javascript, "./prerender_ffi.mjs", "read_file")
fn read_file(path: String) -> String

pub fn main() -> Nil {
  write_file("../public/fizz.css", read_file("assets/fizz.css"))
  write_file(
    "../public/index.html",
    element.to_document_string(landing.page()) <> "\n",
  )
}
