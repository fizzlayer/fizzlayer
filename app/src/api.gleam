//// Parsing for the Rust API the SPA calls. Requests use the `fizz_session`
//// cookie (`credentials: same-origin`), the same way `public/app.js` does.

import gleam/dynamic/decode
import gleam/json
import gleam/list
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
