//// Paid checkout at `/app/checkout?plan=pro&return=settings`. Stripe's
//// embedded form is mounted on this page, so the payment happens inside
//// Fizzlayer. `checkout_ffi.mjs` loads Stripe.js; the rest is this state
//// machine:
////
//// ```text
//// Waiting ─start─▶ Creating ─session─▶ Mounting ─mounted─▶ Open ─paid─▶ Paid
////                     │ error             │ load error
////                     ▼                   │
////                   Failed ◀──────────────┘
////                     │ retry, when trying again can help
////                     ▼
////                   Creating
////
//// Any state but Paid ─cancel─▶ Leaving
//// ```
////
//// `update` is pure: it returns the next model and a `Command`, and `run`
//// turns the command into an effect. Paid and Leaving are final, so a reply
//// that arrives after the person has moved on changes nothing.

import gleam/dynamic/decode
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element, text}
import lustre/event

import api
import browser
import route
import ui

pub type Plan {
  Tinkerer
  Pro
}

/// The page checkout returns to, with `?billing=success` or `?billing=cancelled`.
pub type Return {
  Settings
  App
  Gateways
}

pub type State {
  /// Waiting for the app to confirm who is signed in.
  Waiting
  /// `POST /api/billing` is creating the Checkout Session.
  Creating
  /// Stripe.js is loading and mounting the form.
  Mounting
  /// The form is on the page.
  Open
  /// Stripe reported a finished payment; leaving for the return page.
  Paid
  /// The person cancelled; leaving for the return page.
  Leaving
  /// Checkout could not start. `retry` is False when trying again cannot help,
  /// such as an account that already has a subscription.
  Failed(message: String, retry: Bool)
}

pub type Model {
  /// The URL named no plan that can be bought here.
  Unknown
  Checkout(plan: Plan, back: Return, state: State)
}

pub type Msg {
  SessionCreated(#(Int, String))
  Mounted(Bool)
  StripePaid
  CancelClicked
  RetryClicked
}

/// What `update` asks for. `run` performs it.
pub type Command {
  Nothing
  CreateSession(body: String)
  Mount(publishable_key: String, client_secret: String)
  Go(url: String)
}

/// The id of the element Stripe mounts its form into.
pub const frame_id = "stripe-checkout"

const load_failed =
  "The payment form could not load. Check your connection and try again."

const start_failed = "Checkout could not start. Try again in a moment."

// Starting -------------------------------------------------------------------

/// The checkout the URL's query asks for. `return` defaults to Settings, the
/// same default as `POST /api/billing`.
pub fn init(query: Option(String)) -> Model {
  let value = fn(key) {
    case query {
      Some(text) -> route.query_value(text, key)
      None -> ""
    }
  }
  case plan_named(value("plan")), return_named(value("return")) {
    Ok(plan), Ok(back) -> Checkout(plan:, back:, state: Waiting)
    _, _ -> Unknown
  }
}

/// Begin once the app knows the person is signed in. Only a waiting checkout
/// starts, so a second sign-in check never opens a second session.
pub fn start(model: Model) -> #(Model, Command) {
  case model {
    Checkout(plan, back, Waiting) -> #(
      Checkout(plan, back, Creating),
      CreateSession(session_body(plan, back)),
    )
    _ -> #(model, Nothing)
  }
}

/// `/app/checkout?plan=…&return=…`, the one way into checkout.
pub fn path(plan: Plan, back: Return) -> String {
  route.checkout_path <> "?" <> query(plan, back)
}

/// The query part of `path`, for `modem.push`, which takes it separately.
pub fn query(plan: Plan, back: Return) -> String {
  "plan=" <> plan_id(plan) <> "&return=" <> return_id(back)
}

pub fn plan_named(name: String) -> Result(Plan, Nil) {
  case name {
    "tinkerer" -> Ok(Tinkerer)
    "pro" -> Ok(Pro)
    _ -> Error(Nil)
  }
}

fn return_named(name: String) -> Result(Return, Nil) {
  case name {
    "" | "settings" -> Ok(Settings)
    "app" -> Ok(App)
    "gateway" -> Ok(Gateways)
    _ -> Error(Nil)
  }
}

// Transitions ----------------------------------------------------------------

pub fn update(model: Model, msg: Msg) -> #(Model, Command) {
  case model {
    Unknown ->
      case msg {
        CancelClicked -> #(model, Go(leave_url(Settings, False)))
        _ -> #(model, Nothing)
      }
    Checkout(plan, back, state) -> {
      let to = fn(state, command) { #(Checkout(plan, back, state), command) }
      case state, msg {
        Paid, _ | Leaving, _ -> #(model, Nothing)
        _, CancelClicked -> to(Leaving, Go(leave_url(back, False)))
        Creating, SessionCreated(#(status, body)) ->
          case session(status, body) {
            Ok(#(key, secret)) -> to(Mounting, Mount(key, secret))
            Error(failed) -> to(failed, Nothing)
          }
        Mounting, Mounted(True) -> to(Open, Nothing)
        Mounting, Mounted(False) -> to(Failed(load_failed, True), Nothing)
        Mounting, StripePaid | Open, StripePaid ->
          to(Paid, Go(leave_url(back, True)))
        Failed(_, True), RetryClicked ->
          to(Creating, CreateSession(session_body(plan, back)))
        _, _ -> #(model, Nothing)
      }
    }
  }
}

/// Read `POST /api/billing`. Server errors and a lost connection can be
/// retried; any other refusal states why and stays refused.
pub fn session(status: Int, body: String) -> Result(#(String, String), State) {
  case status {
    200 ->
      case json.parse(body, session_decoder()) {
        Ok(#(key, secret)) ->
          case
            string.starts_with(key, "pk_")
            && string.starts_with(secret, "cs_")
            && string.contains(secret, "_secret_")
          {
            True -> Ok(#(key, secret))
            False -> Error(Failed(start_failed, True))
          }
        Error(_) -> Error(Failed(start_failed, True))
      }
    0 -> Error(Failed(load_failed, True))
    _ -> Error(Failed(api.error_message(body, start_failed), status >= 500))
  }
}

fn session_decoder() -> decode.Decoder(#(String, String)) {
  use key <- decode.field("publishable_key", decode.string)
  use secret <- decode.field("client_secret", decode.string)
  decode.success(#(key, secret))
}

pub fn session_body(plan: Plan, back: Return) -> String {
  json.object([
    #("action", json.string("checkout")),
    #("plan", json.string(plan_id(plan))),
    #("return_to", json.string(return_id(back))),
  ])
  |> json.to_string
}

/// The return page with the outcome that page reports.
pub fn leave_url(back: Return, paid: Bool) -> String {
  let page = case back {
    Settings -> "/settings.html"
    App -> "/app.html"
    Gateways -> route.gateways_path
  }
  case paid {
    True -> page <> "?billing=success"
    False -> page <> "?billing=cancelled"
  }
}

fn plan_id(plan: Plan) -> String {
  case plan {
    Tinkerer -> "tinkerer"
    Pro -> "pro"
  }
}

fn return_id(back: Return) -> String {
  case back {
    Settings -> "settings"
    App -> "app"
    Gateways -> "gateway"
  }
}

// Effects --------------------------------------------------------------------

pub fn run(command: Command) -> Effect(Msg) {
  case command {
    Nothing -> effect.none()
    CreateSession(body) -> {
      use dispatch <- effect.from
      browser.send("POST", "/api/billing", body, fn(reply) {
        dispatch(SessionCreated(reply))
      })
    }
    // After paint, so the frame element is on the page when Stripe looks.
    Mount(key, secret) -> {
      use dispatch, _root <- effect.after_paint
      mount(frame_id, key, secret, fn(ok) { dispatch(Mounted(ok)) }, fn() {
        dispatch(StripePaid)
      })
    }
    // Replace, so Back from the return page does not open a new session.
    Go(url) -> {
      use _dispatch <- effect.from
      unmount()
      browser.replace(url)
    }
  }
}

/// Remove the form when the app leaves `/app/checkout` without a page load.
pub fn leave() -> Effect(msg) {
  use _dispatch <- effect.from
  unmount()
}

@external(javascript, "./checkout_ffi.mjs", "mount")
fn mount(
  frame: String,
  publishable_key: String,
  client_secret: String,
  mounted: fn(Bool) -> Nil,
  paid: fn() -> Nil,
) -> Nil

@external(javascript, "./checkout_ffi.mjs", "unmount")
fn unmount() -> Nil

// View -----------------------------------------------------------------------

pub fn view(model: Model) -> Element(Msg) {
  case model {
    Unknown ->
      ui.checkout_page(
        "Checkout",
        "Paid plans are Tinkerer and Pro.",
        ui.notice_text(ui.Bad, "This checkout link does not name a plan."),
        frame_id,
        [back_button("Back")],
      )
    Checkout(plan, _, state) ->
      ui.checkout_page(
        "Upgrade to " <> plan_name(plan),
        plan_price(plan)
          <> ". Stripe handles the payment; Fizzlayer never sees your card number.",
        status(state),
        frame_id,
        buttons(state),
      )
  }
}

fn status(state: State) -> Element(Msg) {
  case state {
    Waiting | Creating | Mounting -> ui.spinner("Loading secure checkout…")
    Open -> element.none()
    Paid -> ui.notice_text(ui.Good, "Payment received. Returning…")
    Leaving -> ui.muted("Returning…")
    Failed(message, _) -> ui.notice_text(ui.Bad, message)
  }
}

fn buttons(state: State) -> List(Element(Msg)) {
  case state {
    Paid | Leaving -> []
    Failed(_, True) -> [
      ui.button(
        ui.Primary,
        [attribute.type_("button"), event.on_click(RetryClicked)],
        [text("Try again")],
      ),
      back_button("Back"),
    ]
    Failed(_, False) -> [back_button("Back")]
    Waiting | Creating | Mounting | Open -> [back_button("Cancel")]
  }
}

fn back_button(label: String) -> Element(Msg) {
  ui.button(
    ui.Secondary,
    [attribute.type_("button"), event.on_click(CancelClicked)],
    [text(label)],
  )
}

pub fn plan_name(plan: Plan) -> String {
  case plan {
    Tinkerer -> "Tinkerer"
    Pro -> "Pro"
  }
}

/// The same prices as the pricing page.
pub fn plan_price(plan: Plan) -> String {
  case plan {
    Tinkerer -> "$10 a month"
    Pro -> "$25 a month"
  }
}

// Upgrades -------------------------------------------------------------------

/// The paid plans worth offering to someone on `current`, a plan id from the
/// API. Enterprise is arranged with us, so Pro and Enterprise get no offer,
/// and neither does a plan id this app does not know.
pub fn upgrades(current: String) -> List(Plan) {
  case current {
    "hobbyist" -> [Tinkerer, Pro]
    "tinkerer" -> [Pro]
    _ -> []
  }
}

/// MCP servers per gateway, as on the pricing page and in
/// `src/gateway/limits.rs`.
pub fn server_limit(plan: Plan) -> Int {
  case plan {
    Tinkerer -> 10
    Pro -> 25
  }
}

/// Phone calls a month, shared by alert calls and phone approvals.
pub fn phone_calls(plan: Plan) -> Int {
  case plan {
    Tinkerer -> 20
    Pro -> 100
  }
}
