import gleam/bit_array
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/string
import gleeunit
import gleeunit/should
import lustre/element
import simplifile

import api
import config
import fizz_spa
import rewrites
import route

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn routes_under_app_test() {
  route.parse("/app") |> should.equal(route.SignIn)
  route.parse("/app/") |> should.equal(route.SignIn)
  route.parse("/app/index.html") |> should.equal(route.SignIn)
  route.parse("/app/workspace") |> should.equal(route.Workspace)
  route.parse("/app/workspace/") |> should.equal(route.Workspace)
  route.parse("/") |> should.equal(route.SignIn)
  route.parse("/workspace") |> should.equal(route.Workspace)
}

pub fn routes_outside_the_spa_leave_test() {
  route.parse("/app.html") |> should.equal(route.Leave(path: "/app.html"))
  route.parse("/index.html") |> should.equal(route.Leave(path: "/index.html"))
  route.parse("/api/me") |> should.equal(route.Leave(path: "/api/me"))
  route.parse("/install.sh") |> should.equal(route.Leave(path: "/install.sh"))
  route.parse("/ha.html") |> should.equal(route.Leave(path: "/ha.html"))
  route.parse("/.well-known/mcp.json")
  |> should.equal(route.Leave(path: "/.well-known/mcp.json"))
  route.parse("/app/missing")
  |> should.equal(route.NotFound(path: "/app/missing"))
}

pub fn anon_and_publishable_keys_are_accepted_test() {
  config.classify_key(jwt("{\"role\":\"anon\"}")) |> should.equal(Ok(Nil))
  config.classify_key(jwt(
    "{\"role\": \"anon\", \"iss\":\"https://example.test\"}",
  ))
  |> should.equal(Ok(Nil))
  config.classify_key("sb_publishable_example_key_value")
  |> should.equal(Ok(Nil))
}

pub fn service_role_and_other_keys_are_refused_test() {
  config.classify_key(jwt("{\"role\":\"service_role\"}"))
  |> should.equal(Error(config.ServiceRole))
  config.classify_key(jwt("{\"role\":\"authenticated\"}"))
  |> should.equal(Error(config.WrongRole))
  config.classify_key("service_role_secret")
  |> should.equal(Error(config.NotAKey))
  config.classify_key("") |> should.equal(Error(config.NotAKey))
}

pub fn config_errors_do_not_echo_the_key_test() {
  let key = jwt("{\"role\":\"service_role\"}")
  let text =
    "{\"supabaseUrl\":\"https://example.supabase.co\",\"supabaseAnonKey\":\""
    <> key
    <> "\"}"
  let assert Error(message) = config.parse_config(text)
  string.contains(message, key) |> should.be_false
  string.contains(message, "service_role") |> should.be_false
}

pub fn urls_must_be_https_or_loopback_test() {
  config.accept_url("https://example.supabase.co") |> should.be_true
  config.accept_url("http://127.0.0.1:54321") |> should.be_true
  config.accept_url("http://localhost:54321") |> should.be_true
  config.accept_url("http://example.com") |> should.be_false
  config.accept_url("https://user:pass@example.supabase.co") |> should.be_false
  config.accept_url("javascript:alert(1)") |> should.be_false
}

pub fn me_uses_the_cookie_before_exchanging_a_token_test() {
  api.me_outcome(200, "{\"username\":\"ada\"}", True, False)
  |> should.equal(api.Workspace(username: "ada", body: "{\"username\":\"ada\"}"))
  api.me_outcome(401, "{\"error\":{\"code\":\"unauthorized\"}}", False, False)
  |> should.equal(api.SignedOut)
  api.me_outcome(401, "{}", True, False) |> should.equal(api.NeedsLink)
  api.me_outcome(401, "{}", True, True)
  |> should.equal(api.Unavailable("Sign-in did not start a Fizzlayer session."))
  api.me_outcome(
    503,
    "{\"error\":{\"message\":\"Session check is unavailable.\"}}",
    True,
    False,
  )
  |> should.equal(api.Unavailable("Session check is unavailable."))
  api.me_outcome(500, "<html>nope</html>", False, False)
  |> should.equal(api.Unavailable("The workspace could not be loaded."))
}

pub fn link_outcome_and_body_test() {
  api.link_outcome(200, "{\"ok\":true,\"username\":\"ada\"}")
  |> should.equal(Ok(Nil))
  api.link_outcome(401, "{\"error\":{\"message\":\"That link has expired.\"}}")
  |> should.equal(Error("That link has expired."))
  let body = api.link_body("abc\"def")
  let assert Ok(token) = json.parse(body, token_decoder())
  token |> should.equal("abc\"def")
}

pub fn github_provider_detection_test() {
  api.github_enabled(200, "{\"providers\":[\"google\",\"github\"]}")
  |> should.be_true
  api.github_enabled(200, "{\"providers\":[\"google\"]}") |> should.be_false
  api.github_enabled(503, "{}") |> should.be_false
}

pub fn email_shape_test() {
  api.valid_email("Ada@Example.com") |> should.be_true
  api.valid_email("  ada@example.com ") |> should.be_true
  api.valid_email("not-an-email") |> should.be_false
  api.valid_email("a@b") |> should.be_false
  api.valid_email("a @b.co") |> should.be_false
  api.valid_email("a@b.c@d.com") |> should.be_false
}

pub fn view_does_not_render_the_access_token_test() {
  let token = "eyJhbGciOiJub25lIn0.payload.signature"
  let model =
    fizz_spa.Model(
      route: route.Workspace,
      email: "ada@example.com",
      notice: fizz_spa.Quiet,
      busy: False,
      github: True,
      linked: True,
      token: token,
      account: fizz_spa.SignedIn(
        username: "ada",
        body: "{\"username\":\"ada\"}",
      ),
    )
  let html = element.to_string(fizz_spa.view(model))
  string.contains(html, token) |> should.be_false
  string.contains(html, "ada") |> should.be_true
  string.contains(html, "GET /api/me") |> should.be_true
}

pub fn spa_rewrites_leave_the_existing_site_alone_test() {
  let assert Ok(text) = simplifile.read("../vercel.json")
  let assert Ok(parsed) = json.parse(text, vercel_decoder())
  rewrites.check(parsed.rewrites) |> should.equal(Ok(Nil))
  list.contains(parsed.rewrites, #(
    "/.well-known/webmcp",
    "/.well-known/webmcp.json",
  ))
  |> should.be_true
  list.contains(parsed.rewrites, #("/api/waitlist", "/api/contact"))
  |> should.be_true
  list.contains(parsed.headers, #("/app/config.json", "no-store"))
  |> should.be_true
}

type Vercel {
  Vercel(rewrites: List(#(String, String)), headers: List(#(String, String)))
}

fn vercel_decoder() -> decode.Decoder(Vercel) {
  use rewrites <- decode.field("rewrites", decode.list(rewrite_decoder()))
  use headers <- decode.field("headers", decode.list(header_decoder()))
  decode.success(Vercel(rewrites:, headers:))
}

fn rewrite_decoder() -> decode.Decoder(#(String, String)) {
  use source <- decode.field("source", decode.string)
  use destination <- decode.field("destination", decode.string)
  decode.success(#(source, destination))
}

fn header_decoder() -> decode.Decoder(#(String, String)) {
  use source <- decode.field("source", decode.string)
  use pairs <- decode.field("headers", decode.list(pair_decoder()))
  let cache = case list.find(pairs, fn(pair) { pair.0 == "Cache-Control" }) {
    Ok(#(_, value)) -> value
    Error(_) -> ""
  }
  decode.success(#(source, cache))
}

fn pair_decoder() -> decode.Decoder(#(String, String)) {
  use key <- decode.field("key", decode.string)
  use value <- decode.field("value", decode.string)
  decode.success(#(key, value))
}

fn token_decoder() -> decode.Decoder(String) {
  use token <- decode.field("access_token", decode.string)
  decode.success(token)
}

fn jwt(payload: String) -> String {
  "eyJhbGciOiJub25lIn0."
  <> bit_array.base64_url_encode(<<payload:utf8>>, False)
  <> ".sig"
}
