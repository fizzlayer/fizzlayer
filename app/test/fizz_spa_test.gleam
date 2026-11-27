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
import catalog
import checkout
import clients
import config
import fizz_spa
import gateway
import gleam/dict
import gleam/uri
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
  route.parse("/app/start") |> should.equal(route.Gateways)
  route.parse("/app/gateways") |> should.equal(route.Gateways)
  route.parse("/app/onboarding") |> should.equal(route.NewGateway)
  route.parse("/app/gateways/" <> id)
  |> should.equal(route.Gateway(id:, tab: route.Overview))
  route.parse("/app/gateways/" <> id <> "/servers")
  |> should.equal(route.Gateway(id:, tab: route.Servers))
  route.parse("/app/gateways/" <> id <> "/rules")
  |> should.equal(route.Gateway(id:, tab: route.Rules))
  route.parse("/app/gateways/" <> id <> "/approvals")
  |> should.equal(route.Gateway(id:, tab: route.Approvals))
  route.parse("/app/gateways/" <> id <> "/alerts")
  |> should.equal(route.Gateway(id:, tab: route.Changes))
  route.parse("/app/gateways/" <> id <> "/connect")
  |> should.equal(route.Gateway(id:, tab: route.Connect))
  route.parse("/app/gateways/" <> id <> "/settings")
  |> should.equal(route.Gateway(id:, tab: route.Settings))
  // Links from before the tabs keep working.
  route.parse("/app/gateways/" <> id <> "/tokens")
  |> should.equal(route.Gateway(id:, tab: route.Connect))
  route.parse("/app/onboarding/" <> id <> "/server")
  |> should.equal(route.Gateway(id:, tab: route.Servers))
  route.parse("/app/onboarding/" <> id <> "/tools")
  |> should.equal(route.Gateway(id:, tab: route.Rules))
  route.parse("/app/onboarding/" <> id <> "/pin")
  |> should.equal(route.Gateway(id:, tab: route.Changes))
  route.parse("/app/onboarding/" <> id <> "/client")
  |> should.equal(route.Gateway(id:, tab: route.Connect))
  route.parse("/app/gateways/" <> id <> "/nope")
  |> should.equal(route.NotFound(path: "/app/gateways/" <> id <> "/nope"))
  route.parse("/sensors") |> should.equal(route.Leave(path: "/sensors"))
  route.parse("/app/preview/client")
  |> should.equal(route.Preview(name: "client"))
}

pub fn tab_paths_round_trip_and_need_an_id_test() {
  let id = "11111111-1111-4111-8111-111111111111"
  list.each(route.tabs, fn(tab) {
    route.parse(route.tab_path(id, tab))
    |> should.equal(route.Gateway(id:, tab:))
  })
  route.tab_path("", route.Servers) |> should.equal("/app/gateways")
}

pub fn gateway_page_has_every_tab_and_counts_test() {
  let html = element.to_string(gateway.view(gateway.preview("overview")))
  list.each(route.tabs, fn(tab) {
    string.contains(
      html,
      "href=\""
        <> route.tab_path("11111111-1111-4111-8111-111111111111", tab)
        <> "\"",
    )
    |> should.be_true
  })
  string.contains(html, "aria-current=\"page\"") |> should.be_true
  string.contains(html, "fa-solid fa-hand") |> should.be_true
  string.contains(html, "/app/gateways//") |> should.be_false
}

fn on_plan(screen: String, plan: api.Plan, billing: Bool) -> String {
  element.to_string(gateway.view(
    gateway.Model(..gateway.preview(screen), plan:, billing:),
  ))
}

fn tinkerer() -> api.Plan {
  api.Plan(
    ..api.hobbyist(),
    id: "tinkerer",
    name: "Tinkerer",
    server_limit: api.Limited(10),
    phone_calls: api.Limited(20),
  )
}

fn pro() -> api.Plan {
  api.Plan(
    ..api.hobbyist(),
    id: "pro",
    name: "Pro",
    server_limit: api.Limited(25),
    phone_calls: api.Limited(100),
    stdio: True,
    dedicated: True,
  )
}

const tinkerer_checkout = "/app/checkout?plan=tinkerer&amp;return=gateway"

const pro_checkout = "/app/checkout?plan=pro&amp;return=gateway"

pub fn hobbyist_pages_offer_tinkerer_and_pro_test() {
  list.each(["gateways", "create", "overview", "servers"], fn(screen) {
    let html = on_plan(screen, api.hobbyist(), True)
    string.contains(html, "class=\"upsell\"") |> should.be_true
    string.contains(html, tinkerer_checkout) |> should.be_true
    string.contains(html, pro_checkout) |> should.be_true
    string.contains(html, "10 MCP servers instead of 3") |> should.be_true
  })
}

pub fn hobbyist_buttons_go_to_checkout_test() {
  let html = on_plan("gateways", api.hobbyist(), True)
  string.contains(html, "Upgrade to Tinkerer") |> should.be_true
  string.contains(html, "Upgrade to Pro") |> should.be_true
  string.contains(html, "Switch to") |> should.be_false
}

pub fn tinkerer_switches_to_pro_in_the_billing_portal_test() {
  list.each(["gateways", "create", "overview"], fn(screen) {
    let html = on_plan(screen, tinkerer(), True)
    // Checkout refuses a second subscription, so no checkout link at all.
    string.contains(html, "/app/checkout") |> should.be_false
    string.contains(html, "Switch to Pro") |> should.be_true
    string.contains(html, "Upgrade to") |> should.be_false
    string.contains(html, "25 MCP servers instead of 10") |> should.be_true
  })
}

pub fn the_portal_answer_opens_stripe_or_says_why_not_test() {
  let model =
    gateway.Model(
      ..gateway.preview("gateways"),
      plan: tinkerer(),
      billing: True,
    )
  element.to_string(gateway.view(model))
  |> string.contains("disabled")
  |> should.be_false
  let #(asking, _, _) = gateway.update(model, gateway.OpenPortal)
  asking.busy |> should.be_true
  // The button is disabled while the request runs.
  element.to_string(gateway.view(asking))
  |> string.contains("disabled")
  |> should.be_true
  let #(opened, _, path) =
    gateway.update(
      asking,
      gateway.PortalOpened(#(
        200,
        "{\"url\":\"https://billing.stripe.com/p/x\"}",
      )),
    )
  opened.busy |> should.be_false
  opened.notice |> should.equal(gateway.Quiet)
  path |> should.equal("")
  let #(refused, _, _) =
    gateway.update(
      asking,
      gateway.PortalOpened(#(
        409,
        "{\"error\":{\"code\":\"no_billing_account\",\"message\":\"Choose a paid plan first.\"}}",
      )),
    )
  refused.busy |> should.be_false
  refused.notice |> should.equal(gateway.Bad("Choose a paid plan first."))
  let #(offline, _, _) =
    gateway.update(asking, gateway.PortalOpened(#(0, "Failed to fetch")))
  offline.notice
  |> should.equal(gateway.Bad("Billing could not be opened. Try again."))
}

pub fn pro_and_enterprise_pages_offer_nothing_test() {
  let enterprise = api.Plan(..pro(), id: "enterprise", name: "Enterprise")
  list.each([pro(), enterprise], fn(plan) {
    list.each(["gateways", "create", "overview"], fn(screen) {
      string.contains(on_plan(screen, plan, True), "/app/checkout")
      |> should.be_false
    })
  })
}

pub fn no_offer_without_billing_test() {
  list.each(["gateways", "create", "overview"], fn(screen) {
    let html = on_plan(screen, api.hobbyist(), False)
    string.contains(html, "upsell") |> should.be_false
    string.contains(html, "/app/checkout") |> should.be_false
  })
}

pub fn billing_answer_turns_offers_on_test() {
  let model = gateway.preview("gateways")
  model.billing |> should.be_false
  let #(on, _, _) =
    gateway.update(model, gateway.BillingLoaded(#(200, "{\"available\":true}")))
  on.billing |> should.be_true
  let #(off, _, _) =
    gateway.update(on, gateway.BillingLoaded(#(200, "{\"available\":false}")))
  off.billing |> should.be_false
  let #(down, _, _) = gateway.update(on, gateway.BillingLoaded(#(404, "")))
  down.billing |> should.be_false
}

pub fn plan_line_uses_the_body_colour_test() {
  let html = on_plan("gateways", api.hobbyist(), False)
  string.contains(html, "class=\"plan-summary\"") |> should.be_true
  string.contains(html, "Hobbyist plan: 1 of 1 gateways") |> should.be_true
}

pub fn servers_tab_lists_the_featured_registry_servers_test() {
  let html = element.to_string(gateway.view(gateway.preview("servers")))
  list.each(catalog.featured(), fn(entry) {
    string.contains(html, entry.id) |> should.be_true
  })
  string.contains(html, "registry-search") |> should.be_true
  // GitHub is already on the example gateway.
  string.contains(html, "Add GitHub") |> should.be_false
  string.contains(html, "Add Stripe") |> should.be_true
}

pub fn add_sheet_prefills_from_the_catalog_test() {
  let html = element.to_string(gateway.view(gateway.preview("add-server")))
  string.contains(html, "role=\"dialog\"") |> should.be_true
  string.contains(html, "https://api.githubcopilot.com/mcp/") |> should.be_true
  string.contains(html, "personal access token") |> should.be_true
  string.contains(html, "type=\"password\"") |> should.be_true
}

pub fn catalog_slugs_are_valid_server_names_test() {
  list.each(catalog.featured(), fn(entry) {
    api.server_name_ok(catalog.slug(entry.title)) |> should.be_true
    api.remote_url_ok(entry.url) |> should.be_true
    catalog.addable(entry) |> should.be_true
  })
  catalog.slug("monday.com") |> should.equal("monday-com")
  catalog.slug("123 Go!") |> should.equal("go")
  catalog.slug("!!!") |> should.equal("server")
}

pub fn registry_page_maps_auth_test() {
  let body =
    "{\"servers\":["
    <> "{\"name\":\"a/key\",\"title\":\"Key\",\"description\":\"\",\"website\":\"\",\"remotes\":[{\"type\":\"streamable-http\",\"url\":\"https://a.example.com/mcp\",\"headers\":[{\"name\":\"Authorization\",\"secret\":true,\"required\":true,\"description\":\"Bearer key\"}],\"variables\":[]}]},"
    <> "{\"name\":\"b/open\",\"title\":\"Open\",\"description\":\"\",\"website\":\"\",\"remotes\":[{\"type\":\"sse\",\"url\":\"https://b.example.com/sse\",\"headers\":[],\"variables\":[]}]},"
    <> "{\"name\":\"c/custom\",\"title\":\"Custom\",\"description\":\"\",\"website\":\"\",\"remotes\":[{\"type\":\"streamable-http\",\"url\":\"https://{tenant}.example.com/mcp\",\"headers\":[{\"name\":\"X-Api-Key\",\"secret\":true,\"required\":true,\"description\":\"\"}],\"variables\":[\"tenant\"]}]}"
    <> "],\"next\":\"c/custom:1\"}"
  let assert Ok(page) = catalog.page_of(body)
  page.next |> should.equal("c/custom:1")
  let assert [key, open, custom] = page.entries
  key.auth |> should.equal(catalog.KeyRequired)
  key.key_hint |> should.equal("Bearer key")
  open.auth |> should.equal(catalog.NoKey)
  open.transport |> should.equal("sse")
  custom.auth |> should.equal(catalog.OtherHeaders(["X-Api-Key"]))
  catalog.addable(custom) |> should.be_false
  catalog.needs_fill(custom.url) |> should.be_true
  let assert Ok(last) = catalog.page_of("{\"servers\":[],\"next\":null}")
  last.next |> should.equal("")
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
      route: route.Gateways,
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
      checkout: checkout.Unknown,
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
    api.server_body(
      "github",
      "https://example.com/mcp",
      "http",
      "key",
      "secret-value",
    )
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
  list.length(paths) |> should.equal(24)
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

pub fn landing_points_hosted_at_the_app_and_keeps_agent_hooks_test() {
  let html = element.to_document_string(landing.page())
  assert string.contains(html, "src=\"/webmcp.js\"")
  assert !string.contains(html, "waitlist")
  assert !string.contains(html, "gateway-beta.js")
  assert string.contains(html, "Set one up")
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

pub fn servers_show_their_tools_and_default_rule_test() {
  let html = element.to_string(gateway.view(gateway.preview("servers")))
  string.contains(html, "create_issue") |> should.be_true
  string.contains(html, "3 tools · Allow by default") |> should.be_true
  string.contains(html, "every one is allowed") |> should.be_true
}

pub fn tools_are_asked_for_when_servers_load_test() {
  let server = "22222222-2222-4222-8222-222222222222"
  let model = gateway.Model(..gateway.preview("servers"), tools: dict.new())
  let body =
    "{\"servers\":[{\"id\":\""
    <> server
    <> "\",\"name\":\"github\",\"url\":\"https://api.githubcopilot.com/mcp/\",\"transport\":\"http\",\"auth_kind\":\"key\",\"has_secret\":true}]}"
  let #(loading, _, _) =
    gateway.update(model, gateway.ServersLoaded(model.id, #(200, body)))
  dict.get(loading.tools, server) |> should.equal(Ok(gateway.ToolsLoading))

  let answer =
    "{\"tools\":[{\"name\":\"search\",\"description\":\"Finds things.\"}]}"
  let #(loaded, _, _) =
    gateway.update(
      loading,
      gateway.ToolsAnswered(model.id, server, #(200, answer)),
    )
  dict.get(loaded.tools, server)
  |> should.equal(
    Ok(gateway.ToolsLoaded([api.Tool("search", "Finds things.")])),
  )

  // An answer for a gateway that is no longer open changes nothing.
  let #(other, _, _) =
    gateway.update(
      loading,
      gateway.ToolsAnswered("33333333-3333-4333-8333-333333333333", server, #(
        200,
        answer,
      )),
    )
  dict.get(other.tools, server) |> should.equal(Ok(gateway.ToolsLoading))

  let refused =
    "{\"error\":{\"code\":\"upstream_auth\",\"message\":\"The MCP server refused the credential.\"}}"
  let #(failed, _, _) =
    gateway.update(
      loading,
      gateway.ToolsAnswered(model.id, server, #(502, refused)),
    )
  dict.get(failed.tools, server)
  |> should.equal(
    Ok(gateway.ToolsFailed("The MCP server refused the credential.")),
  )
  let html =
    element.to_string(gateway.view(
      gateway.Model(..failed, screen: gateway.Page(route.Servers)),
    ))
  string.contains(html, "refused the credential") |> should.be_true
  string.contains(html, "Try again") |> should.be_true
}

pub fn adding_a_server_asks_it_for_tools_test() {
  let model =
    gateway.Model(..gateway.preview("servers"), tools: dict.new(), busy: True)
  let body =
    "{\"server\":{\"id\":\"77777777-7777-4777-8777-777777777777\",\"name\":\"docs\",\"url\":\"https://docs.mcp.cloudflare.com/mcp\",\"transport\":\"http\",\"auth_kind\":\"none\",\"has_secret\":false,\"trust_new_tools\":true}}"
  let #(next, _, path) =
    gateway.update(model, gateway.Wrote("server", #(200, body)))
  path |> should.equal("")
  next.busy |> should.be_false
  dict.get(next.tools, "77777777-7777-4777-8777-777777777777")
  |> should.equal(Ok(gateway.ToolsLoading))
}

pub fn every_client_setup_carries_the_url_and_token_test() {
  let url =
    "https://gw.fizzlayer.com/w/11111111-1111-4111-8111-111111111111/mcp"
  let token = "eyJhbGciOiJub25lIn0.eyJzdWIiOiJleGFtcGxlIn0.e30"
  list.each(
    [
      clients.claude_code(url, token),
      clients.cursor(url, token),
      clients.vscode(url, token),
      clients.codex(url, token),
      clients.gemini(url, token),
      clients.hermes(url, token),
      clients.generic(url, token),
    ],
    fn(setup) {
      string.contains(setup, url) |> should.be_true
      string.contains(setup, token) |> should.be_true
    },
  )
  // Codex reads the token from the environment, not from config.toml.
  let assert Ok(#(export, add)) =
    string.split_once(clients.codex(url, token), "\n")
  string.contains(export, token) |> should.be_true
  string.contains(add, token) |> should.be_false
  string.contains(add, "--bearer-token-env-var FIZZLAYER_TOKEN")
  |> should.be_true
  clients.bearer(token) |> should.equal("Bearer " <> token)
}

pub fn cursor_link_holds_the_server_config_test() {
  let link = clients.cursor_link("https://gw.example.com/mcp", "tok")
  let assert Ok(#(_, encoded)) = string.split_once(link, "&config=")
  string.starts_with(
    link,
    "cursor://anysphere.cursor-deeplink/mcp/install?name=fizzlayer&config=",
  )
  |> should.be_true
  let assert Ok(base64) = uri.percent_decode(encoded)
  let assert Ok(bits) = bit_array.base64_decode(base64)
  bit_array.to_string(bits)
  |> should.equal(Ok(
    "{\"url\":\"https://gw.example.com/mcp\",\"headers\":{\"Authorization\":\"Bearer tok\"}}",
  ))
}

pub fn connect_tab_fills_the_picked_client_test() {
  let base = gateway.preview("client-hosted")
  // Each case shows setup filled with a token made for the picked app.
  let pick = fn(key) {
    let #(model, _, _) = gateway.update(base, gateway.ClientPicked(key))
    element.to_string(gateway.view(gateway.Model(..model, minted_for: key)))
  }
  string.contains(pick("cursor"), "cursor://anysphere.cursor-deeplink")
  |> should.be_true
  string.contains(pick("hermes"), "mcp_servers:") |> should.be_true
  string.contains(pick("claude"), "Request headers") |> should.be_true
  let chatgpt = pick("chatgpt")
  string.contains(chatgpt, "cannot connect to it yet") |> should.be_true
  string.contains(chatgpt, "eyJhbGciOiJub25lIn0") |> should.be_false
}

pub fn tokens_are_named_by_the_user_and_kept_with_their_app_test() {
  let base = gateway.preview("client-hosted")
  // Picking an app does not name the token.
  let #(picked, _, _) = gateway.update(base, gateway.ClientPicked("claude"))
  picked.token_name |> should.equal("")
  // The token was made for Claude Code, so Claude asks for a new, named one
  // instead of showing that token.
  let html = element.to_string(gateway.view(picked))
  string.contains(html, "Token name") |> should.be_true
  string.contains(html, "Claude on my laptop") |> should.be_true
  string.contains(html, "eyJhbGciOiJub25lIn0") |> should.be_false
  // Back on Claude Code, its token and name show again.
  let #(back, _, _) =
    gateway.update(picked, gateway.ClientPicked("claude-code"))
  let html = element.to_string(gateway.view(back))
  string.contains(html, "Claude Code on laptop") |> should.be_true
  string.contains(html, "eyJhbGciOiJub25lIn0") |> should.be_true
  // The name typed is the one sent, and the created token is kept with it.
  let #(named, _, _) =
    gateway.update(picked, gateway.TokenNameEdited("  Work Mac  "))
  let #(minted, _, _) =
    gateway.update(
      gateway.Model(..named, minted: "", busy: True),
      gateway.Wrote("mint", #(
        200,
        "{\"token\":{\"token\":\"eyJhbGciOiJub25lIn0.eyJzdWIiOiJ4In0.e30\",\"audience\":\"https://gw.fizzlayer.com/w/x/mcp\"}}",
      )),
    )
  minted.minted_for |> should.equal("claude")
  minted.minted_name |> should.equal("Work Mac")
  minted.token_name |> should.equal("")
}
