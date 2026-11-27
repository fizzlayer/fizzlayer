//// The sign-in screen at `/app` and `/app/sign-in`: create an account, sign
//// in with a password, Google, GitHub or a passkey, reset a password, and
//// finish links from Supabase emails. Every request goes to `/api/auth`, which
//// sets the `fizz_session` cookie. This replaces the sign-in on `/app.html`.

import api
import browser
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element, text}
import lustre/element/html
import lustre/event
import route
import ui

pub type Mode {
  Create
  SignIn
  Forgot
  Reset(token: String)
  /// After an email goes out. `resend` is the `/api/auth` action that sends
  /// it again.
  CheckEmail(message: String, resend: String)
}

pub type Notice {
  Quiet
  Info(String)
  Problem(String)
}

pub type Model {
  Model(
    mode: Mode,
    email: String,
    password: String,
    busy: Bool,
    notice: Notice,
    providers: List(String),
    passkeys: Bool,
  )
}

pub type Msg {
  ModeChosen(Mode)
  EmailEdited(String)
  PasswordEdited(String)
  Submitted
  Replied(#(Int, String))
  ResendClicked
  Resent(#(Int, String))
  ProviderClicked(String)
  PasskeyClicked
  ProvidersLoaded(#(Int, String))
}

/// What the parent does after an update.
pub type Outcome {
  Stay
  SignedIn
}

/// `creating` picks the first tab. `fragment` is the URL hash, which carries
/// links from Supabase emails (`access_token`, `type`) and sign-in errors
/// (`auth_error`, `error_code`).
pub fn init(creating: Bool, fragment: Option(String)) -> #(Model, Effect(Msg)) {
  let hash = option.unwrap(fragment, "")
  let start = case creating, hash {
    _, "sign-in" | False, _ -> SignIn
    True, _ -> Create
  }
  let model =
    Model(
      mode: start,
      email: "",
      password: "",
      busy: False,
      notice: Quiet,
      providers: ["google", "github"],
      passkeys: passkeys_supported(),
    )
  let token = route.query_value(hash, "access_token")
  let kind = route.query_value(hash, "type")
  let auth_error = route.query_value(hash, "auth_error")
  let link_error =
    route.query_value(hash, "error") != ""
    || route.query_value(hash, "error_code") != ""
  let #(model, first) = case token, kind, auth_error, link_error {
    "", _, "", False -> #(model, effect.none())
    "", _, "", True -> #(
      Model(
        ..model,
        mode: SignIn,
        notice: Problem(
          "That link has expired or was already used. Request a new one.",
        ),
      ),
      clear_hash_effect(),
    )
    "", _, code, _ -> #(
      Model(..model, mode: SignIn, notice: Problem(auth_error_message(code))),
      clear_hash_effect(),
    )
    token, "recovery", _, _ -> #(
      Model(..model, mode: Reset(token)),
      clear_hash_effect(),
    )
    token, _, _, _ -> #(
      Model(..model, mode: SignIn, busy: True),
      effect.batch([clear_hash_effect(), post(link_body(token, None))]),
    )
  }
  #(model, effect.batch([first, load_providers()]))
}

/// Fills in the email the home page's sign-up form sent as `?email=`, then
/// takes it out of the address bar. A missing or malformed address leaves
/// the field empty.
pub fn prefill(model: Model, query: Option(String)) -> #(Model, Effect(Msg)) {
  let raw = route.query_value(option.unwrap(query, ""), "email")
  // Forms encode a space as `+`, and a literal `+` as `%2B`.
  let email =
    raw
    |> string.replace("+", " ")
    |> uri.percent_decode
    |> result.unwrap("")
    |> string.trim
  case raw, model.mode, api.valid_email(email) {
    "", _, _ -> #(model, effect.none())
    _, Create, True | _, SignIn, True -> #(
      Model(..model, email:),
      effect.from(fn(_) { clear_email() }),
    )
    _, _, _ -> #(model, effect.from(fn(_) { clear_email() }))
  }
}

/// Unlocks the form after the app could not finish a sign-in.
pub fn idle(model: Model) -> Model {
  Model(..model, busy: False, password: "")
}

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg), Outcome) {
  case msg {
    ModeChosen(mode) -> #(
      Model(..model, mode:, password: "", notice: Quiet),
      effect.none(),
      Stay,
    )
    EmailEdited(email) -> #(
      Model(..model, email:, notice: Quiet),
      effect.none(),
      Stay,
    )
    PasswordEdited(password) -> #(
      Model(..model, password:, notice: Quiet),
      effect.none(),
      Stay,
    )
    Submitted -> submit(model)
    Replied(#(status, body)) -> replied(model, status, body)
    ResendClicked ->
      case model.mode, model.busy {
        CheckEmail(_, action), False -> #(
          Model(..model, busy: True, notice: Quiet),
          request(action_body(action, model.email, ""), Resent),
          Stay,
        )
        _, _ -> #(model, effect.none(), Stay)
      }
    Resent(#(200, _)) -> #(
      Model(
        ..model,
        busy: False,
        notice: Info(
          "Sent again to "
          <> model.email
          <> ". Check your inbox and spam folder.",
        ),
      ),
      effect.none(),
      Stay,
    )
    Resent(#(_, body)) -> #(
      Model(..model, busy: False, notice: Problem(message_of(body))),
      effect.none(),
      Stay,
    )
    ProviderClicked(provider) -> #(
      Model(..model, busy: True, notice: Quiet),
      effect.from(fn(_) { browser.assign("/api/auth?provider=" <> provider) }),
      Stay,
    )
    PasskeyClicked -> #(
      Model(..model, busy: True, notice: Quiet),
      effect.from(fn(dispatch) {
        passkey_sign_in(fn(reply) { dispatch(Replied(reply)) })
      }),
      Stay,
    )
    ProvidersLoaded(#(200, body)) ->
      case json.parse(body, providers_decoder()) {
        Ok(providers) -> #(
          Model(
            ..model,
            providers: list.filter(["google", "github"], list.contains(
              providers,
              _,
            )),
          ),
          effect.none(),
          Stay,
        )
        Error(_) -> #(model, effect.none(), Stay)
      }
    // If the list cannot load, keep both buttons: /api/auth still refuses
    // a provider that is turned off.
    ProvidersLoaded(_) -> #(model, effect.none(), Stay)
  }
}

fn submit(model: Model) -> #(Model, Effect(Msg), Outcome) {
  let email = string.lowercase(string.trim(model.email))
  let model = Model(..model, email:)
  let check = case model.mode {
    Create | SignIn | Forgot ->
      case api.valid_email(email) {
        True -> Ok(Nil)
        False -> Error("Enter a valid email address.")
      }
    _ -> Ok(Nil)
  }
  let check = case check, model.mode {
    Ok(_), Create | Ok(_), Reset(_) ->
      case api.password_ok(model.password, True) {
        True -> Ok(Nil)
        False -> Error("Use at least 12 characters, up to 72 bytes.")
      }
    Ok(_), SignIn ->
      case model.password {
        "" -> Error("Enter your password.")
        _ -> Ok(Nil)
      }
    other, _ -> other
  }
  let body = case model.mode {
    Create -> Some(action_body("sign_up", email, model.password))
    SignIn -> Some(action_body("sign_in", email, model.password))
    Forgot -> Some(action_body("recover", email, ""))
    Reset(token) -> Some(link_body(token, Some(model.password)))
    CheckEmail(..) -> None
  }
  case model.busy, check, body {
    True, _, _ | _, _, None -> #(model, effect.none(), Stay)
    False, Error(message), _ -> #(
      Model(..model, notice: Problem(message)),
      effect.none(),
      Stay,
    )
    False, Ok(_), Some(body) -> #(
      Model(..model, busy: True, notice: Quiet),
      post(body),
      Stay,
    )
  }
}

fn replied(
  model: Model,
  status: Int,
  body: String,
) -> #(Model, Effect(Msg), Outcome) {
  let done = Model(..model, busy: False, password: "")
  case status, model.mode {
    // Cancelled passkey prompt.
    -1, _ -> #(done, effect.none(), Stay)
    200, Forgot -> #(
      Model(
        ..done,
        mode: CheckEmail(
          "If "
            <> model.email
            <> " has a Fizzlayer account, we sent it a link to choose a new password.",
          "recover",
        ),
      ),
      effect.none(),
      Stay,
    )
    200, _ ->
      case json.parse(body, confirm_decoder()) {
        Ok(True) -> #(
          Model(
            ..done,
            mode: CheckEmail(
              "We sent a confirmation link to "
                <> model.email
                <> ". Open it on any device to finish creating your account.",
              "resend",
            ),
          ),
          effect.none(),
          Stay,
        )
        _ -> #(Model(..done, busy: True), effect.none(), SignedIn)
      }
    _, mode ->
      case code_of(body), mode {
        "email_not_confirmed", _ -> #(
          Model(
            ..done,
            mode: CheckEmail(
              "Confirm your email first. Open the link we sent to "
                <> model.email
                <> ", or send it again.",
              "resend",
            ),
          ),
          effect.none(),
          Stay,
        )
        "link_expired", Reset(_) -> #(
          Model(..done, mode: Forgot, notice: Problem(message_of(body))),
          effect.none(),
          Stay,
        )
        _, _ -> #(
          Model(..done, notice: Problem(message_of(body))),
          effect.none(),
          Stay,
        )
      }
  }
}

// View -------------------------------------------------------------------------

/// `locked` disables the form while the app is still checking the session.
pub fn view(model: Model, locked: Bool) -> Element(Msg) {
  let disabled = locked || model.busy
  let title = case model.mode {
    Create -> "Create your account"
    SignIn -> "Sign in"
    Forgot -> "Reset your password"
    Reset(_) -> "Choose a new password"
    CheckEmail(..) -> "Check your email"
  }
  ui.card([attribute.id("sign-in")], [
    html.h1([], [text(title)]),
    case model.mode {
      Create | SignIn ->
        ui.segmented("Account", [
          #(
            "Create account",
            model.mode == Create,
            event.on_click(ModeChosen(Create)),
          ),
          #("Sign in", model.mode == SignIn, event.on_click(ModeChosen(SignIn))),
        ])
      _ -> element.none()
    },
    case model.mode {
      Create -> ui.lead("Start free on the Hobbyist plan.")
      Forgot -> ui.lead("We'll email you a link to choose a new password.")
      CheckEmail(message, _) -> ui.lead(message)
      SignIn | Reset(_) -> element.none()
    },
    notice(model.notice),
    case model.mode {
      CheckEmail(..) ->
        ui.actions([
          ui.button(
            ui.Secondary,
            [
              attribute.type_("button"),
              attribute.disabled(disabled),
              event.on_click(ResendClicked),
            ],
            [text("Resend email")],
          ),
          ui.text_button([event.on_click(ModeChosen(SignIn))], [
            text("Back to sign in"),
          ]),
        ])
      _ -> form(model, disabled)
    },
    case model.mode {
      Create | SignIn -> alternatives(model, disabled)
      Forgot ->
        ui.actions([
          ui.text_button([event.on_click(ModeChosen(SignIn))], [
            text("Back to sign in"),
          ]),
        ])
      _ -> element.none()
    },
  ])
}

fn form(model: Model, disabled: Bool) -> Element(Msg) {
  let wants_email = case model.mode {
    Reset(_) -> False
    _ -> True
  }
  let wants_password = case model.mode {
    Create | SignIn | Reset(_) -> True
    _ -> False
  }
  let new_password = case model.mode {
    SignIn -> False
    _ -> True
  }
  html.form([event.on_submit(fn(_) { Submitted }), attribute.novalidate(True)], [
    case wants_email {
      False -> element.none()
      True ->
        ui.field(
          "Email",
          "email",
          "",
          ui.input([
            attribute.id("email"),
            attribute.name("email"),
            attribute.type_("email"),
            attribute.autocomplete("email"),
            attribute.attribute("inputmode", "email"),
            attribute.attribute("autocapitalize", "none"),
            attribute.attribute("spellcheck", "false"),
            attribute.attribute("maxlength", "254"),
            attribute.required(True),
            attribute.placeholder("you@example.com"),
            attribute.value(model.email),
            attribute.disabled(disabled),
            event.on_input(EmailEdited),
          ]),
        )
    },
    case wants_password {
      False -> element.none()
      True ->
        ui.field(
          case model.mode {
            Reset(_) -> "New password"
            _ -> "Password"
          },
          "password",
          case new_password {
            True -> "At least 12 characters."
            False -> ""
          },
          ui.input([
            attribute.id("password"),
            attribute.name("password"),
            attribute.type_("password"),
            attribute.autocomplete(case new_password {
              True -> "new-password"
              False -> "current-password"
            }),
            attribute.attribute("maxlength", "72"),
            attribute.required(True),
            attribute.value(model.password),
            attribute.disabled(disabled),
            event.on_input(PasswordEdited),
          ]),
        )
    },
    case model.mode {
      SignIn ->
        ui.field_extra([
          ui.text_button([event.on_click(ModeChosen(Forgot))], [
            text("Forgot password?"),
          ]),
        ])
      _ -> element.none()
    },
    ui.submit(
      case model.busy, model.mode {
        True, _ -> "Please wait…"
        False, Create -> "Create account"
        False, SignIn -> "Sign in"
        False, Forgot -> "Send reset link"
        False, _ -> "Save password"
      },
      disabled,
    ),
  ])
}

fn alternatives(model: Model, disabled: Bool) -> Element(Msg) {
  let verb = case model.mode {
    Create -> "Sign up"
    _ -> "Sign in"
  }
  let providers =
    list.map(model.providers, fn(id) {
      let #(provider, name) = case id {
        "google" -> #(ui.Google, "Google")
        _ -> #(ui.GitHub, "GitHub")
      }
      ui.provider_button(provider, verb <> " with " <> name, [
        attribute.disabled(disabled),
        event.on_click(ProviderClicked(id)),
      ])
    })
  let passkey = case model.mode, model.passkeys {
    SignIn, True -> [
      ui.wide_button(
        ui.Secondary,
        [
          attribute.type_("button"),
          attribute.disabled(disabled),
          event.on_click(PasskeyClicked),
        ],
        [text("Sign in with a passkey")],
      ),
    ]
    _, _ -> []
  }
  html.div([], [
    case providers, passkey {
      [], [] -> element.none()
      _, _ -> ui.divider("or")
    },
    ui.stack(list.append(providers, passkey)),
    ui.fine_print([
      text("By continuing, you agree to the "),
      html.a([attribute.href("/terms.html")], [text("Terms of Service")]),
      text(" and "),
      html.a([attribute.href("/privacy.html")], [text("Privacy Policy")]),
      text("."),
    ]),
  ])
}

fn notice(notice: Notice) -> Element(Msg) {
  case notice {
    Quiet -> element.none()
    Info(message) -> ui.notice_text(ui.Good, message)
    Problem(message) -> ui.notice_text(ui.Bad, message)
  }
}

// Requests ---------------------------------------------------------------------

fn post(body: String) -> Effect(Msg) {
  request(body, Replied)
}

fn request(body: String, to: fn(#(Int, String)) -> Msg) -> Effect(Msg) {
  effect.from(fn(dispatch) {
    browser.send("POST", "/api/auth", body, fn(reply) { dispatch(to(reply)) })
  })
}

fn load_providers() -> Effect(Msg) {
  effect.from(fn(dispatch) {
    browser.send("GET", "/api/auth?providers", "", fn(reply) {
      dispatch(ProvidersLoaded(reply))
    })
  })
}

fn clear_hash_effect() -> Effect(Msg) {
  effect.from(fn(_) { clear_hash() })
}

fn action_body(action: String, email: String, password: String) -> String {
  let fields = [
    #("action", json.string(action)),
    #("email", json.string(email)),
  ]
  let fields = case password {
    "" -> fields
    _ -> list.append(fields, [#("password", json.string(password))])
  }
  json.object(fields) |> json.to_string
}

fn link_body(token: String, password: Option(String)) -> String {
  let fields = [
    #("action", json.string("link")),
    #("access_token", json.string(token)),
  ]
  let fields = case password {
    Some(password) ->
      list.append(fields, [#("password", json.string(password))])
    None -> fields
  }
  json.object(fields) |> json.to_string
}

pub fn auth_error_message(code: String) -> String {
  case code {
    "mfa_required" -> "Complete multi-factor authentication before signing in."
    "rate_limited" -> "Too many attempts. Try again in an hour."
    "sign_up_closed" -> "This instance isn't accepting new accounts."
    "cancelled" -> "Sign-in was cancelled."
    "expired" -> "Sign-in took too long or was interrupted. Try again."
    "unavailable" ->
      "That sign-in option isn't available here. Use another one."
    "no_email" ->
      "We couldn't get a verified email address from that account. Add and verify one with the provider (on GitHub: Settings → Emails), then try again."
    "verify_email" ->
      "We sent you an email to confirm your address. Open the link in it, then sign in again."
    _ -> "Sign-in is temporarily unavailable. Try again."
  }
}

fn message_of(body: String) -> String {
  case body {
    "" -> "Could not reach Fizzlayer. Check your connection and try again."
    _ -> api.error_message(body, body_or_default(body))
  }
}

// A plain-text body (from the passkey helper) is already a message.
fn body_or_default(body: String) -> String {
  case string.starts_with(body, "{") {
    True -> "Something went wrong. Try again."
    False -> body
  }
}

fn code_of(body: String) -> String {
  let decoder = {
    use code <- decode.subfield(["error", "code"], decode.string)
    decode.success(code)
  }
  case json.parse(body, decoder) {
    Ok(code) -> code
    Error(_) -> ""
  }
}

fn confirm_decoder() -> decode.Decoder(Bool) {
  decode.optional_field("confirm_email", False, decode.bool, decode.success)
}

fn providers_decoder() -> decode.Decoder(List(String)) {
  use providers <- decode.field("providers", decode.list(decode.string))
  decode.success(providers)
}

@external(javascript, "./auth_ffi.mjs", "clear_hash")
fn clear_hash() -> Nil

@external(javascript, "./auth_ffi.mjs", "clear_email")
fn clear_email() -> Nil

@external(javascript, "./auth_ffi.mjs", "passkeys_supported")
fn passkeys_supported() -> Bool

@external(javascript, "./auth_ffi.mjs", "passkey_sign_in")
fn passkey_sign_in(done: fn(#(Int, String)) -> Nil) -> Nil
