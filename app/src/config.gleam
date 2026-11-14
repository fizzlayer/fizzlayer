//// Public Supabase settings for the browser. The anon key and the newer
//// publishable key are meant to ship in a frontend. The service-role key is not.

import gleam/bit_array
import gleam/dynamic/decode
import gleam/json
import gleam/result
import gleam/string

pub type KeyProblem {
  NotAKey
  ServiceRole
  WrongRole
}

pub fn check_config(url: String, key: String) -> Result(Nil, String) {
  case string.trim(url), string.trim(key) {
    "", _ | _, "" -> Error("Sign-in isn't configured yet.")
    url, key ->
      case accept_url(url), classify_key(key) {
        False, _ -> Error("The Supabase URL isn't usable from the browser.")
        _, Error(_) -> Error("The Supabase key isn't a publishable anon key.")
        True, Ok(_) -> Ok(Nil)
      }
  }
}

pub fn parse_config(text: String) -> Result(#(String, String), String) {
  let decoder = {
    use url <- decode.field("supabaseUrl", decode.string)
    use key <- decode.field("supabaseAnonKey", decode.string)
    decode.success(#(string.trim(url), string.trim(key)))
  }
  case json.parse(text, decoder) {
    Ok(#(url, key)) ->
      case check_config(url, key) {
        Ok(_) -> Ok(#(url, key))
        Error(message) -> Error(message)
      }
    Error(_) -> Error("Sign-in isn't configured yet.")
  }
}

pub fn accept_url(url: String) -> Bool {
  case url {
    "https://" <> rest ->
      rest != "" && !string.contains(url, "@") && !string.contains(rest, " ")
    "http://localhost:" <> rest -> rest != "" && !string.contains(rest, " ")
    "http://127.0.0.1:" <> rest -> rest != "" && !string.contains(rest, " ")
    _ -> False
  }
}

/// Anon JWTs and `sb_publishable_…` keys are accepted. Anything else is refused
/// so a service-role credential cannot be used to build a client.
pub fn classify_key(key: String) -> Result(Nil, KeyProblem) {
  case jwt_role(key) {
    Ok("anon") -> Ok(Nil)
    Ok("service_role") -> Error(ServiceRole)
    Ok(_) -> Error(WrongRole)
    Error(_) ->
      case
        string.starts_with(key, "sb_publishable_"),
        string.length(key) > 20,
        !string.contains(key, " "),
        !string.contains(key, "service_role")
      {
        True, True, True, True -> Ok(Nil)
        _, _, _, _ -> Error(NotAKey)
      }
  }
}

fn jwt_role(key: String) -> Result(String, Nil) {
  case string.split(key, on: ".") {
    [_, payload, _] -> {
      use bits <- result.try(bit_array.base64_url_decode(payload))
      use text <- result.try(bit_array.to_string(bits))
      case json.parse(text, role_decoder()) {
        Ok(role) -> Ok(role)
        Error(_) -> Error(Nil)
      }
    }
    _ -> Error(Nil)
  }
}

fn role_decoder() -> decode.Decoder(String) {
  use role <- decode.field("role", decode.string)
  decode.success(role)
}
