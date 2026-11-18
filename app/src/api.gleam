//// Parsing for the Rust API the SPA calls. Requests use the `fizz_session`
//// cookie (`credentials: same-origin`), the same way `public/app.js` does.

import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string

pub type MeNext {
  Workspace(username: String, body: String)
  NeedsLink
  SignedOut
  Unavailable(message: String)
}

/// Decide what to do with `GET /api/me`.
///
/// A 401 with a Supabase access token means we still need to exchange it for
/// a Fizzlayer session via `POST /api/auth` `{"action":"link"}`. After that
/// exchange, another 401 is a failure rather than a retry.
pub fn me_outcome(
  status: Int,
  body: String,
  has_token: Bool,
  already_linked: Bool,
) -> MeNext {
  case status {
    200 ->
      case json.parse(body, username_decoder()) {
        Ok(username) -> Workspace(username: username, body: body)
        Error(_) -> Unavailable("The workspace response was not readable.")
      }
    401 ->
      case has_token, already_linked {
        True, False -> NeedsLink
        True, True -> Unavailable("Sign-in did not start a Fizzlayer session.")
        False, _ -> SignedOut
      }
    _ -> Unavailable(message_or(body, "The workspace could not be loaded."))
  }
}

pub fn link_outcome(status: Int, body: String) -> Result(Nil, String) {
  case status {
    200 ->
      case json.parse(body, ok_decoder()) {
        Ok(True) -> Ok(Nil)
        _ -> Error(message_or(body, "Sign-in could not be finished."))
      }
    _ -> Error(message_or(body, "Sign-in could not be finished."))
  }
}

pub fn github_enabled(status: Int, body: String) -> Bool {
  case status {
    200 ->
      case json.parse(body, providers_decoder()) {
        Ok(providers) -> list.contains(providers, "github")
        Error(_) -> False
      }
    _ -> False
  }
}

pub fn error_message(body: String, fallback: String) -> String {
  message_or(body, fallback)
}

pub fn link_body(token: String) -> String {
  json.object([
    #("action", json.string("link")),
    #("access_token", json.string(token)),
  ])
  |> json.to_string
}

pub fn valid_email(value: String) -> Bool {
  let email = string.lowercase(string.trim(value))
  case string.split_once(email, on: "@") {
    Ok(#(local, domain)) ->
      string.length(email) <= 254
      && string.length(local) > 0
      && string.length(local) <= 64
      && string.contains(domain, ".")
      && !string.starts_with(domain, ".")
      && !string.ends_with(domain, ".")
      && !string.contains(domain, "@")
      && plain(email)
    Error(_) -> False
  }
}

fn username_decoder() -> decode.Decoder(String) {
  use username <- decode.field("username", decode.string)
  decode.success(username)
}

fn ok_decoder() -> decode.Decoder(Bool) {
  use ok <- decode.field("ok", decode.bool)
  decode.success(ok)
}

fn providers_decoder() -> decode.Decoder(List(String)) {
  use providers <- decode.field("providers", decode.list(decode.string))
  decode.success(providers)
}

fn message_or(body: String, fallback: String) -> String {
  case json.parse(body, message_decoder()) {
    Ok(message) ->
      case string.trim(message) {
        "" -> fallback
        message -> message
      }
    Error(_) -> fallback
  }
}

fn message_decoder() -> decode.Decoder(String) {
  use message <- decode.field("error", error_message_decoder())
  decode.success(message)
}

fn error_message_decoder() -> decode.Decoder(String) {
  use message <- decode.field("message", decode.string)
  decode.success(message)
}

fn plain(value: String) -> Bool {
  list.all(string.to_utf_codepoints(value), fn(codepoint) {
    let code = string.utf_codepoint_to_int(codepoint)
    code > 32 && code != 127
  })
}

pub type Failure {
  Upgrade(String)
  Message(String)
}

pub type Cap {
  Limited(Int)
  Unlimited
}

pub type Plan {
  Plan(
    id: String,
    name: String,
    gateway_limit: Cap,
    server_limit: Cap,
    tool_calls: Cap,
    phone_calls: Cap,
    audit_days: Cap,
    stdio: Bool,
    dedicated: Bool,
  )
}

pub type GatewayRow {
  GatewayRow(
    id: String,
    name: String,
    mode: String,
    public_url: String,
    status: String,
    role: String,
  )
}

pub type ServerRow {
  ServerRow(
    id: String,
    name: String,
    url: String,
    transport: String,
    auth_kind: String,
    has_secret: Bool,
    enabled: Bool,
  )
}

pub type PolicyRow {
  PolicyRow(
    id: String,
    server_id: String,
    tool_name: String,
    effect: String,
    notify_channel: String,
  )
}

pub type PinRow {
  PinRow(server_name: String, tool_name: String, status: String)
}

pub type AlertRow {
  AlertRow(
    id: String,
    server_name: String,
    tool_name: String,
    preview: String,
    acknowledged: Bool,
  )
}

pub type ApprovalRow {
  ApprovalRow(
    id: String,
    server_name: String,
    tool_name: String,
    args_preview: String,
    status: String,
    notify_channel: String,
  )
}

pub type TokenRow {
  TokenRow(id: String, name: String, revoked: Bool)
}

pub type Context {
  Context(role: String, plan: Plan, gateways: List(GatewayRow))
}

pub type Created {
  Created(
    id: String,
    name: String,
    mode: String,
    public_url: String,
    registration: String,
  )
}

pub fn hobbyist() -> Plan {
  Plan(
    id: "hobbyist",
    name: "Hobbyist",
    gateway_limit: Limited(1),
    server_limit: Limited(3),
    tool_calls: Limited(10_000),
    phone_calls: Limited(0),
    audit_days: Limited(7),
    stdio: False,
    dedicated: False,
  )
}

pub fn phone_ok(plan: Plan) -> Bool {
  case plan.phone_calls {
    Unlimited -> True
    Limited(count) -> count > 0
  }
}

pub fn cap_label(cap: Cap) -> String {
  case cap {
    Unlimited -> "Custom"
    Limited(count) -> int.to_string(count)
  }
}

pub fn failure(status: Int, body: String, fallback: String) -> Failure {
  let message = error_message(body, fallback)
  case status {
    402 -> Upgrade(message)
    _ -> Message(message)
  }
}

pub fn hosted_available(status: Int, body: String) -> Bool {
  case status {
    200 ->
      case json.parse(body, hosted_decoder()) {
        Ok(True) -> True
        _ -> False
      }
    _ -> False
  }
}

pub fn gateway_body(name: String, mode: String, public_url: String) -> String {
  let fields = [
    #("name", json.string(name)),
    #("mode", json.string(mode)),
  ]
  let fields = case mode == "selfhost" && public_url != "" {
    True -> [#("public_url", json.string(public_url)), ..fields]
    False -> fields
  }
  json.object(fields) |> json.to_string
}

pub fn server_body(
  name: String,
  url: String,
  auth_kind: String,
  api_key: String,
) -> String {
  let kind = case api_key {
    "" -> auth_kind
    _ -> "key"
  }
  let fields = [
    #("name", json.string(name)),
    #("url", json.string(url)),
    #("transport", json.string("http")),
    #("auth_kind", json.string(kind)),
  ]
  let fields = case api_key {
    "" -> fields
    key -> [#("api_key", json.string(key)), ..fields]
  }
  json.object(fields) |> json.to_string
}

pub fn policy_body(
  server_id: String,
  tool: String,
  effect: String,
  channel: String,
) -> String {
  let fields = [
    #("tool_name", json.string(tool)),
    #("effect", json.string(effect)),
    #("notify_channel", json.string(channel)),
  ]
  let fields = case server_id {
    "" -> fields
    id -> [#("server_id", json.string(id)), ..fields]
  }
  json.object(fields) |> json.to_string
}

pub fn pin_body(server: String, tool: String) -> String {
  json.object([
    #("server", json.string(server)),
    #("tool", json.string(tool)),
  ])
  |> json.to_string
}

pub fn decision_body(status: String) -> String {
  json.object([#("status", json.string(status))]) |> json.to_string
}

pub fn token_body(name: String) -> String {
  json.object([
    #("name", json.string(name)),
    #("ttl_seconds", json.int(2_592_000)),
  ])
  |> json.to_string
}

pub fn context_of(body: String) -> Result(Context, Nil) {
  ok_or_nil(json.parse(body, context_decoder()))
}

pub fn created_of(body: String) -> Result(Created, Nil) {
  ok_or_nil(json.parse(body, created_decoder()))
}

pub fn registration_of(body: String) -> Result(String, Nil) {
  ok_or_nil(json.parse(body, registration_decoder()))
}

pub fn minted_of(body: String) -> Result(#(String, String), Nil) {
  ok_or_nil(json.parse(body, minted_decoder()))
}

pub fn servers_of(body: String) -> Result(List(ServerRow), Nil) {
  ok_or_nil(json.parse(body, field_list("servers", server_decoder())))
}

pub fn policies_of(body: String) -> Result(List(PolicyRow), Nil) {
  ok_or_nil(json.parse(body, field_list("policies", policy_decoder())))
}

pub fn pins_of(body: String) -> Result(List(PinRow), Nil) {
  ok_or_nil(json.parse(body, field_list("pins", pin_decoder())))
}

pub fn alerts_of(body: String) -> Result(List(AlertRow), Nil) {
  ok_or_nil(json.parse(body, field_list("alerts", alert_decoder())))
}

pub fn approvals_of(body: String) -> Result(List(ApprovalRow), Nil) {
  ok_or_nil(json.parse(body, field_list("approvals", approval_decoder())))
}

pub fn tokens_of(body: String) -> Result(List(TokenRow), Nil) {
  ok_or_nil(json.parse(body, field_list("tokens", token_decoder())))
}

pub fn tool_names(body: String) -> Result(List(String), Nil) {
  ok_or_nil(json.parse(body, decode.list(decode.string)))
}

fn ok_or_nil(value: Result(a, b)) -> Result(a, Nil) {
  result.replace_error(value, Nil)
}

pub fn gateway_name_ok(name: String) -> Bool {
  case codes(name) {
    [] -> False
    [first, ..rest] ->
      lowercase_letter(first)
      && list.length(rest) + 1 <= 41
      && list.all([first, ..rest], gateway_char)
      && list.last([first, ..rest]) != Ok(45)
  }
}

pub fn server_name_ok(name: String) -> Bool {
  case codes(name) {
    [] -> False
    [first, ..rest] ->
      lowercase_letter(first)
      && list.length(rest) + 1 <= 41
      && list.all([first, ..rest], server_char)
  }
}

pub fn tool_name_ok(name: String) -> Bool {
  name == "*"
  || {
    let size = string.byte_size(name)
    size >= 1 && size <= 128 && list.all(codes(name), tool_char)
  }
}

pub fn remote_url_ok(value: String) -> Bool {
  let size = string.byte_size(value)
  case
    size >= 8 && size <= 500 && !string.contains(value, "@") && plain(value)
  {
    False -> False
    True ->
      case
        string.starts_with(value, "https://"),
        string.starts_with(value, "http://")
      {
        True, _ -> host_ok(string.drop_start(value, 8))
        _, True -> host_ok(string.drop_start(value, 7))
        _, _ -> False
      }
  }
}

pub fn password_ok(password: String, creating: Bool) -> Bool {
  let size = string.byte_size(password)
  case creating {
    True -> string.length(password) >= 12 && size <= 72 && size >= 12
    False -> size >= 8 && size <= 72
  }
}

pub fn registration_ok(token: String) -> Bool {
  case string.split_once(token, "fizz_reg_") {
    Ok(#("", rest)) -> string.byte_size(rest) == 64 && hex(rest)
    _ -> False
  }
}

pub fn client_token_ok(token: String) -> Bool {
  let parts = string.split(token, ".")
  list.length(parts) == 3
  && string.byte_size(token) < 8000
  && !string.contains(token, " ")
  && !string.contains(token, "\"")
  && !string.contains(token, "\n")
  && list.all(parts, fn(part) { part != "" })
}

fn hosted_decoder() -> decode.Decoder(Bool) {
  decode.one_of(
    {
      use value <- decode.field("available", decode.bool)
      decode.success(value)
    },
    [
      {
        use value <- decode.field("hosted", decode.bool)
        decode.success(value)
      },
    ],
  )
}

fn context_decoder() -> decode.Decoder(Context) {
  use role <- decode.field("role", decode.string)
  use plan <- decode.field("plan", plan_decoder())
  use gateways <- decode.field("gateways", decode.list(gateway_decoder()))
  decode.success(Context(role:, plan:, gateways:))
}

fn plan_decoder() -> decode.Decoder(Plan) {
  use id <- decode.field("id", decode.string)
  use name <- decode.field("name", decode.string)
  use gateway_limit <- decode.field("gateway_limit", cap_decoder())
  use server_limit <- decode.field("mcp_server_limit", cap_decoder())
  use tool_calls <- decode.field("tool_calls_per_month", cap_decoder())
  use phone_calls <- decode.field("phone_calls_per_month", cap_decoder())
  use audit_days <- decode.field("audit_retention_days", cap_decoder())
  use stdio <- decode.field("stdio", decode.bool)
  use dedicated <- decode.field("dedicated", decode.bool)
  decode.success(Plan(
    id:,
    name:,
    gateway_limit:,
    server_limit:,
    tool_calls:,
    phone_calls:,
    audit_days:,
    stdio:,
    dedicated:,
  ))
}

fn cap_decoder() -> decode.Decoder(Cap) {
  decode.one_of(decode.map(decode.int, Limited), [decode.success(Unlimited)])
}

fn gateway_decoder() -> decode.Decoder(GatewayRow) {
  use id <- decode.field("id", decode.string)
  use name <- decode.field("name", decode.string)
  use mode <- decode.field("mode", decode.string)
  use public_url <- decode.field("public_url", decode.string)
  use status <- decode.field("status", decode.string)
  use role <- decode.optional_field("role", "", decode.string)
  decode.success(GatewayRow(id:, name:, mode:, public_url:, status:, role:))
}

fn created_decoder() -> decode.Decoder(Created) {
  use registration <- decode.field("registration_token", decode.string)
  use id <- decode.subfield(["gateway", "id"], decode.string)
  use name <- decode.subfield(["gateway", "name"], decode.string)
  use mode <- decode.subfield(["gateway", "mode"], decode.string)
  use public_url <- decode.subfield(["gateway", "public_url"], decode.string)
  decode.success(Created(id:, name:, mode:, public_url:, registration:))
}

fn registration_decoder() -> decode.Decoder(String) {
  use token <- decode.field("registration_token", decode.string)
  decode.success(token)
}

fn minted_decoder() -> decode.Decoder(#(String, String)) {
  use token <- decode.subfield(["token", "token"], decode.string)
  use audience <- decode.subfield(["token", "audience"], decode.string)
  decode.success(#(token, audience))
}

fn server_decoder() -> decode.Decoder(ServerRow) {
  use id <- decode.field("id", decode.string)
  use name <- decode.field("name", decode.string)
  use url <- decode.field("url", decode.string)
  use transport <- decode.field("transport", decode.string)
  use auth_kind <- decode.field("auth_kind", decode.string)
  use has_secret <- decode.field("has_secret", decode.bool)
  use enabled <- decode.optional_field("enabled", True, decode.bool)
  decode.success(ServerRow(
    id:,
    name:,
    url:,
    transport:,
    auth_kind:,
    has_secret:,
    enabled:,
  ))
}

fn policy_decoder() -> decode.Decoder(PolicyRow) {
  use id <- decode.field("id", decode.string)
  use server_id <- decode.optional_field("server_id", "", textish())
  use tool_name <- decode.field("tool_name", decode.string)
  use effect <- decode.field("effect", decode.string)
  use notify_channel <- decode.optional_field(
    "notify_channel",
    "log",
    decode.string,
  )
  decode.success(PolicyRow(
    id:,
    server_id:,
    tool_name:,
    effect:,
    notify_channel:,
  ))
}

fn pin_decoder() -> decode.Decoder(PinRow) {
  use server_name <- decode.field("server_name", decode.string)
  use tool_name <- decode.field("tool_name", decode.string)
  use status <- decode.field("status", decode.string)
  decode.success(PinRow(server_name:, tool_name:, status:))
}

fn alert_decoder() -> decode.Decoder(AlertRow) {
  use id <- decode.field("id", decode.string)
  use server_name <- decode.field("server_name", decode.string)
  use tool_name <- decode.field("tool_name", decode.string)
  use preview <- decode.optional_field("description_preview", "", decode.string)
  use acknowledged <- decode.optional_field("acknowledged_at", "", textish())
  decode.success(AlertRow(
    id:,
    server_name:,
    tool_name:,
    preview:,
    acknowledged: acknowledged != "",
  ))
}

fn approval_decoder() -> decode.Decoder(ApprovalRow) {
  use id <- decode.field("id", decode.string)
  use server_name <- decode.field("server_name", decode.string)
  use tool_name <- decode.field("tool_name", decode.string)
  use args_preview <- decode.optional_field("args_preview", "", decode.string)
  use status <- decode.field("status", decode.string)
  use notify_channel <- decode.optional_field(
    "notify_channel",
    "log",
    decode.string,
  )
  decode.success(ApprovalRow(
    id:,
    server_name:,
    tool_name:,
    args_preview:,
    status:,
    notify_channel:,
  ))
}

fn token_decoder() -> decode.Decoder(TokenRow) {
  use id <- decode.field("id", decode.string)
  use name <- decode.field("name", decode.string)
  use revoked <- decode.optional_field("revoked_at", "", textish())
  decode.success(TokenRow(id:, name:, revoked: revoked != ""))
}

fn field_list(key: String, item: decode.Decoder(a)) -> decode.Decoder(List(a)) {
  use rows <- decode.field(key, decode.list(item))
  decode.success(rows)
}

fn textish() -> decode.Decoder(String) {
  decode.one_of(decode.string, [
    decode.map(decode.int, int.to_string),
    decode.success(""),
  ])
}

fn codes(value: String) -> List(Int) {
  list.map(string.to_utf_codepoints(value), string.utf_codepoint_to_int)
}

fn lowercase_letter(code: Int) -> Bool {
  code >= 97 && code <= 122
}

fn gateway_char(code: Int) -> Bool {
  lowercase_letter(code) || digit(code) || code == 45
}

fn server_char(code: Int) -> Bool {
  gateway_char(code) || code == 95
}

fn tool_char(code: Int) -> Bool {
  lowercase_letter(code)
  || { code >= 65 && code <= 90 }
  || digit(code)
  || code == 95
  || code == 46
  || code == 58
  || code == 45
}

fn digit(code: Int) -> Bool {
  code >= 48 && code <= 57
}

fn host_ok(rest: String) -> Bool {
  let host =
    rest
    |> string.split("/")
    |> list.first
    |> result.unwrap("")
    |> string.split("?")
    |> list.first
    |> result.unwrap("")
    |> string.split("#")
    |> list.first
    |> result.unwrap("")
  host != "" && !string.starts_with(host, ":")
}

fn hex(value: String) -> Bool {
  list.all(codes(value), fn(code) {
    digit(code) || { code >= 97 && code <= 102 }
  })
}
