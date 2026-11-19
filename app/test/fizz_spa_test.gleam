import gleam/bit_array
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import lustre/element
import simplifile

import api
import clients
import config
import fizz_spa
import gateway
import openapi_routes
import prerender
import rewrites
import route
import signin
import site/landing

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn routes_under_app_test() {
  route.parse("/app") |> should.equal(route.SignIn)
  route.parse("/app/") |> should.equal(route.SignIn)
  route.parse("/app/index.html") |> should.equal(route.SignIn)
  route.parse("/app/workspace") |> should.equal(route.Gateways)
  route.parse("/app/workspace/") |> should.equal(route.Gateways)
  route.parse("/") |> should.equal(route.SignIn)
  route.parse("/workspace") |> should.equal(route.Gateways)
  let id = "11111111-1111-4111-8111-111111111111"
  route.parse("/app/start") |> should.equal(route.Start)
  route.parse("/app/onboarding")
  |> should.equal(route.Onboarding(id: "", step: route.Create))
  route.parse("/app/onboarding/" <> id <> "/server")
  |> should.equal(route.Onboarding(id:, step: route.Server))
  route.parse("/app/onboarding/" <> id <> "/tools")
  |> should.equal(route.Onboarding(id:, step: route.Tools))
  route.parse("/app/onboarding/" <> id <> "/pin")
  |> should.equal(route.Onboarding(id:, step: route.Pin))
  route.parse("/app/onboarding/" <> id <> "/client")
  |> should.equal(route.Onboarding(id:, step: route.Client))
  route.parse("/app/gateways/" <> id <> "/approvals")
  |> should.equal(route.Approvals(id:))
  route.parse("/app/gateways/" <> id <> "/alerts")
  |> should.equal(route.PinAlerts(id:))
  route.parse("/app/gateways/" <> id <> "/tokens")
  |> should.equal(route.ClientTokens(id:))
  route.parse("/sensors") |> should.equal(route.Leave(path: "/sensors"))
  route.parse("/app/preview/client")
  |> should.equal(route.Preview(name: "client"))
}

pub fn onboarding_path_without_a_gateway_test() {
  let id = "11111111-1111-4111-8111-111111111111"
  route.onboarding_path("", route.Create) |> should.equal("/app/onboarding")
  route.onboarding_path("", route.Server) |> should.equal("/app/onboarding")
  route.onboarding_path("", route.Client) |> should.equal("/app/onboarding")
  route.onboarding_path(id, route.Server)
  |> should.equal("/app/onboarding/" <> id <> "/server")
}

pub fn create_step_does_not_link_ahead_test() {
  let create =
    gateway.Model(..gateway.preview("tools"), screen: gateway.Create, id: "")
  let html = element.to_string(gateway.view(create))
  string.contains(html, "/app/onboarding//") |> should.be_false
  string.contains(html, "href=\"/app/onboarding\"") |> should.be_true
  string.contains(html, "step-locked") |> should.be_true
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
      route: route.Start,
      signin: signin.Model(
        ..signin.init(False, None).0,
        email: "ada@example.com",
        password: "not-shown-after-sign-in",
      ),
      plan: "",
      notice: fizz_spa.Quiet,
      busy: False,
      linked: True,
      token: token,
      account: fizz_spa.SignedIn(
        username: "ada",
        body: "{\"username\":\"ada\"}",
      ),
      gate: gateway.preview("choose"),
    )
  let html = element.to_string(fizz_spa.view(model))
  string.contains(html, token) |> should.be_false
  string.contains(html, "not-shown-after-sign-in") |> should.be_false
  string.contains(html, "ada") |> should.be_true
  string.contains(html, "Gateway") |> should.be_true
  string.contains(html, "/sensors") |> should.be_true
}

pub fn gateway_screens_do_not_repeat_secrets_test() {
  let client = gateway.preview("client")
  let shown = element.to_string(gateway.view(client))
  string.contains(shown, "fizz_reg_") |> should.be_true
  string.contains(shown, "127.0.0.1:3000") |> should.be_true
  string.contains(shown, "Authorization: Bearer") |> should.be_true
  let hidden =
    gateway.Model(
      ..client,
      screen: gateway.List,
      api_key: "upstream-token-sample",
    )
  let html = element.to_string(gateway.view(hidden))
  string.contains(html, "fizz_reg_") |> should.be_false
  string.contains(html, "upstream-token-sample") |> should.be_false
  string.contains(html, "eyJhbGciOiJub25lIn0") |> should.be_false
}

pub fn hosted_client_uses_the_public_url_test() {
  let model = gateway.preview("client-hosted")
  let html = element.to_string(gateway.view(model))
  string.contains(
    html,
    "https://gw.fizzlayer.com/w/11111111-1111-4111-8111-111111111111/mcp",
  )
  |> should.be_true
  string.contains(html, "127.0.0.1:3000") |> should.be_false
}

pub fn hobbyist_tools_do_not_offer_phone_test() {
  let html = element.to_string(gateway.view(gateway.preview("tools")))
  string.contains(html, "value=\"phone\"") |> should.be_false
  string.contains(html, "Tinkerer") |> should.be_true
  let paid = element.to_string(gateway.view(gateway.preview("tools-pro")))
  string.contains(paid, "value=\"phone\"") |> should.be_true
}

pub fn upgrade_prompt_links_to_pricing_test() {
  let html = element.to_string(gateway.view(gateway.preview("limit")))
  string.contains(html, "gateway limit") |> should.be_true
  string.contains(html, "href=\"/pricing\"") |> should.be_true
}

pub fn client_snippets_keep_the_registration_token_out_test() {
  let url = "http://127.0.0.1:3000/mcp"
  let jwt = "eyJhbGciOiJub25lIn0.eyJzdWIiOiJleGFtcGxlIn0.e30"
  let cursor = clients.cursor(url, jwt)
  string.contains(cursor, jwt) |> should.be_true
  string.contains(cursor, "fizz_reg_") |> should.be_false
  string.contains(clients.claude_code(url, jwt), "claude mcp add")
  |> should.be_true
  clients.endpoint(True, "shared", "https://gw.fizzlayer.com/w/x/mcp")
  |> should.equal("https://gw.fizzlayer.com/w/x/mcp")
  clients.endpoint(False, "shared", "https://gw.fizzlayer.com/w/x/mcp")
  |> should.equal("http://127.0.0.1:3000/mcp")
}

pub fn gateway_parsers_and_names_test() {
  api.gateway_name_ok("home") |> should.be_true
  api.gateway_name_ok("Home") |> should.be_false
  api.server_name_ok("git_hub") |> should.be_true
  api.tool_name_ok("*") |> should.be_true
  api.tool_name_ok("create_issue") |> should.be_true
  api.remote_url_ok("https://user:pass@example.com/mcp") |> should.be_false
  api.remote_url_ok("https://example.com/mcp") |> should.be_true
  api.password_ok("too-short", True) |> should.be_false
  api.password_ok("long-enough-pw", True) |> should.be_true
  api.registration_ok("fizz_reg_" <> string.repeat("ab", 32)) |> should.be_true
  api.registration_ok("fizz_reg_short") |> should.be_false
  let body =
    "{\"role\":\"owner\",\"plan\":{\"id\":\"hobbyist\",\"name\":\"Hobbyist\",\"gateway_limit\":1,\"mcp_server_limit\":3,\"stdio\":false,\"dedicated\":false,\"seat_limit\":1,\"tool_calls_per_month\":10000,\"phone_calls_per_month\":0,\"audit_retention_days\":7},\"gateways\":[]}"
  let assert Ok(context) = api.context_of(body)
  context.role |> should.equal("owner")
  api.phone_ok(context.plan) |> should.be_false
  api.hosted_available(200, "{\"available\":true}") |> should.be_true
  api.hosted_available(200, "{\"available\":false}") |> should.be_false
  api.hosted_available(404, "") |> should.be_false
  let created =
    "{\"registration_token\":\""
    <> "fizz_reg_"
    <> string.repeat("cd", 32)
    <> "\",\"gateway\":{\"id\":\"11111111-1111-4111-8111-111111111111\",\"name\":\"home\",\"mode\":\"shared\",\"public_url\":\"https://gw.fizzlayer.com/w/11111111-1111-4111-8111-111111111111/mcp\",\"status\":\"active\"}}"
  let assert Ok(row) = api.created_of(created)
  row.name |> should.equal("home")
  api.registration_ok(row.registration) |> should.be_true
  let server =
    api.server_body("github", "https://example.com/mcp", "key", "secret-value")
  string.contains(server, "secret-value") |> should.be_true
  case
    api.failure(
      402,
      "{\"error\":{\"code\":\"gateway_limit\",\"message\":\"Upgrade.\"}}",
      "no",
    )
  {
    api.Upgrade(message) -> message |> should.equal("Upgrade.")
    api.Message(_) -> should.fail()
  }
}

pub fn every_gateway_route_is_in_openapi_test() {
  let assert Ok(rust) = simplifile.read("../src/gateway/mod.rs")
  let assert Ok(spec) = simplifile.read("../public/openapi.json")
  let paths = openapi_routes.paths_from_rust(rust)
  list.length(paths) |> should.equal(22)
  list.each(paths, fn(path) {
    string.contains(spec, "\"" <> path <> "\"") |> should.be_true
  })
  string.contains(spec, "registrationToken") |> should.be_true
  string.contains(spec, "supabaseCookie") |> should.be_true
  string.contains(spec, "gateway_limit") |> should.be_true
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

pub fn rules_use_plain_names_test() {
  gateway.rule_label("allow") |> should.equal("Allow")
  gateway.rule_label("deny") |> should.equal("Block")
  gateway.rule_label("approve") |> should.equal("Ask first")
  let html = element.to_string(gateway.view(gateway.preview("tools")))
  string.contains(html, ">Block<") |> should.be_true
  string.contains(html, ">Ask first<") |> should.be_true
  string.contains(html, ">Deny<") |> should.be_false
}

pub fn landing_keeps_waitlist_and_agent_hooks_test() {
  let html = element.to_document_string(landing.page())
  assert string.contains(html, "src=\"/webmcp.js\"")
  assert string.contains(html, "id=\"beta-form\"")
  assert string.contains(html, "id=\"beta-email\"")
  assert string.contains(html, "id=\"beta-company\"")
  assert string.contains(html, "id=\"beta-status\"")
  assert string.contains(html, "href=\"/fizz.css\"")
}

pub fn sign_in_form_has_its_own_url_test() {
  route.parse("/app/sign-in") |> should.equal(route.SignIn)
  route.parse("/pricing") |> should.equal(route.Leave("/pricing"))
}

pub fn app_pages_are_prerendered_test() {
  let create = prerender.app_page("/app", "Create your account")
  assert string.contains(create, "<div id=\"app\"><div>")
  assert string.contains(create, "Create your account")
  assert string.contains(create, "src=\"/app/fizz_spa.js\"")
  let sign_in = prerender.app_page("/app/sign-in", "Sign in")
  assert string.contains(sign_in, "<h2>Sign in</h2>")
    || string.contains(sign_in, ">Sign in</h")
  assert !string.contains(sign_in, "Create your account</h")
  let shell = prerender.app_page("/app/gateways", "Fizzlayer")
  assert string.contains(shell, "Checking your session.")
  let tools = prerender.app_page("/app/preview/tools", "Example")
  assert string.contains(tools, ">Ask first<")
}

pub fn sign_in_matches_the_old_app_page_test() {
  let #(create, _) = signin.init(True, None)
  let html = element.to_string(signin.view(create, False))
  assert string.contains(html, "Create your account")
  assert string.contains(html, "Sign up with Google")
  assert string.contains(html, "Sign up with GitHub")
  assert string.contains(html, "/terms.html")
  let #(form, _) = signin.init(False, None)
  let html = element.to_string(signin.view(form, False))
  assert string.contains(html, "Forgot password?")
  assert string.contains(html, "Sign in with Google")
}

pub fn email_links_open_the_right_form_test() {
  let #(reset, _) = signin.init(True, Some("access_token=a.b.c&type=recovery"))
  reset.mode |> should.equal(signin.Reset("a.b.c"))
  let #(confirm, _) = signin.init(True, Some("access_token=a.b.c&type=signup"))
  confirm.busy |> should.be_true
  let #(failed, _) = signin.init(True, Some("auth_error=cancelled"))
  failed.notice |> should.equal(signin.Problem("Sign-in was cancelled."))
  let #(expired, _) =
    signin.init(True, Some("error=access_denied&error_code=otp_expired"))
  expired.mode |> should.equal(signin.SignIn)
}

pub fn sign_in_replies_move_the_form_along_test() {
  let #(form, _) = signin.init(False, None)
  let form = signin.Model(..form, mode: signin.Forgot, email: "ada@example.com")
  let #(sent, _, outcome) =
    signin.update(form, signin.Replied(#(200, "{\"ok\":true}")))
  outcome |> should.equal(signin.Stay)
  let assert signin.CheckEmail(_, "recover") = sent.mode
  let form = signin.Model(..form, mode: signin.SignIn)
  let #(_, _, outcome) =
    signin.update(
      form,
      signin.Replied(#(200, "{\"ok\":true,\"username\":\"ada\"}")),
    )
  outcome |> should.equal(signin.SignedIn)
  let #(unconfirmed, _, _) =
    signin.update(
      form,
      signin.Replied(#(
        400,
        "{\"error\":{\"code\":\"email_not_confirmed\",\"message\":\"x\"}}",
      )),
    )
  let assert signin.CheckEmail(_, "resend") = unconfirmed.mode
}
