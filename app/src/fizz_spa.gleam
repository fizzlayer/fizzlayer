import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/uri.{type Uri}
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element, text}
import lustre/element/html
import lustre/event
import modem

import api
import browser
import config
import gateway
import route.{type Route}
import signin
import ui

pub type Notice {
  Quiet
  Info(String)
  Alert(String)
}

pub type Account {
  Booting
  SignedOut
  SignedIn(username: String, body: String)
}

pub type Model {
  Model(
    route: Route,
    signin: signin.Model,
    plan: String,
    notice: Notice,
    busy: Bool,
    linked: Bool,
    token: String,
    account: Account,
    gate: gateway.Model,
  )
}

pub type Msg {
  Navigated(Uri)
  LinkClicked(String)
  SignInMsg(signin.Msg)
  ConfigLoaded(#(Bool, String))
  SessionLoaded(#(Bool, String, String))
  MeLoaded(#(Int, String))
  LinkLoaded(#(Int, String))
  SignOutClicked
  SupabaseSignedOut(#(Bool, String))
  SessionDeleted(#(Int, String))
  Gate(gateway.Msg)
}

pub fn main() -> Nil {
  let app = lustre.application(init, update, view)
  case lustre.start(app, "#app", Nil) {
    Ok(_) -> Nil
    Error(_) -> Nil
  }
}

/// Route changes. modem only reports Back and Forward and `modem.push`;
/// `nav_ffi.mjs` decides which link clicks stay in the app.
fn routing() -> Effect(Msg) {
  effect.batch([
    modem.advanced(
      modem.Options(handle_internal_links: False, handle_external_links: False),
      Navigated,
    ),
    effect.from(fn(dispatch) {
      on_app_link(fn(href) { dispatch(LinkClicked(href)) })
    }),
  ])
}

@external(javascript, "./nav_ffi.mjs", "on_app_link")
fn on_app_link(dispatch: fn(String) -> Nil) -> Nil

/// The model the app starts with at `uri`, before any effect runs. The
/// pre-rendered HTML for a route is `view(first_model(uri))`, so the first
/// client render matches it.
pub fn first_model(uri: Uri) -> Model {
  boot_uri(blank(), uri).0
}

fn blank() -> Model {
  Model(
    route: route.SignIn,
    signin: signin.init(True, None).0,
    plan: "",
    notice: Quiet,
    busy: True,
    linked: False,
    token: "",
    account: Booting,
    gate: gateway.empty(),
  )
}

fn init(_flags: Nil) -> #(Model, Effect(Msg)) {
  case modem.initial_uri() {
    Ok(uri) -> boot_uri(blank(), uri)
    Error(_) -> #(blank(), effect.batch([routing(), load_config()]))
  }
}

fn boot_uri(model: Model, uri: Uri) -> #(Model, Effect(Msg)) {
  let parsed = route.parse(uri.path)
  case parsed {
    route.Leave(_) -> #(model, modem.load(uri))
    route.Preview(name) -> #(
      Model(
        ..model,
        route: parsed,
        busy: False,
        account: SignedOut,
        gate: gateway.preview(name),
      ),
      routing(),
    )
    _ -> {
      let #(form, form_effect) =
        signin.init(wants_create(uri.path, uri.query), uri.fragment)
      let form_effect = case parsed {
        route.SignIn -> effect.map(form_effect, SignInMsg)
        _ -> effect.none()
      }
      #(
        Model(
          ..model,
          route: parsed,
          signin: form,
          plan: wanted_plan(uri.query),
          notice: arrival_notice(uri.query),
        ),
        effect.batch([routing(), load_config(), form_effect]),
      )
    }
  }
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    LinkClicked(href) ->
      case uri.parse(href) {
        Ok(target) -> #(
          model,
          modem.push(target.path, target.query, target.fragment),
        )
        Error(_) -> #(model, effect.none())
      }
    Navigated(uri) ->
      case route.parse(uri.path) {
        route.Leave(_) -> #(model, modem.load(uri))
        route.Preview(name) -> #(
          Model(
            ..model,
            route: route.Preview(name),
            busy: False,
            gate: gateway.preview(name),
          ),
          effect.none(),
        )
        parsed -> {
          let model = Model(..model, route: parsed)
          case model.account {
            SignedIn(_, _) -> follow(model, parsed)
            _ -> #(model, effect.none())
          }
        }
      }
    // Sign-in runs on the server through /api/auth. The browser Supabase
    // client only picks up sessions from older email links, so without its
    // config the app asks the server who is signed in.
    ConfigLoaded(#(False, _)) -> #(model, get_me())
    ConfigLoaded(#(True, text)) ->
      case config.parse_config(text) {
        Error(_) -> #(model, get_me())
        Ok(#(url, key)) -> #(Model(..model, busy: True), boot(url, key))
      }
    SessionLoaded(#(True, token, _)) -> #(
      Model(..model, token: token),
      get_me(),
    )
    SessionLoaded(#(False, _, _)) -> #(Model(..model, token: ""), get_me())
    MeLoaded(#(0, message)) -> #(
      problem(model, text_or(message, "The workspace could not be loaded.")),
      effect.none(),
    )
    MeLoaded(#(status, body)) ->
      case api.me_outcome(status, body, model.token != "", model.linked) {
        api.Workspace(username:, body:) -> signed_in(model, username, body)
        api.NeedsLink -> #(
          Model(..model, linked: True, busy: True),
          post_link(model.token),
        )
        api.SignedOut -> #(
          Model(..model, busy: False, token: "", account: SignedOut),
          effect.none(),
        )
        api.Unavailable(message:) -> #(problem(model, message), effect.none())
      }
    LinkLoaded(#(0, message)) -> #(
      problem(model, text_or(message, "Sign-in could not be finished.")),
      effect.none(),
    )
    LinkLoaded(#(status, body)) ->
      case api.link_outcome(status, body) {
        Ok(_) -> #(Model(..model, busy: True, token: ""), get_me())
        Error(message) -> #(problem(model, message), effect.none())
      }
    SignInMsg(form_msg) -> {
      let #(form, form_effect, outcome) = signin.update(model.signin, form_msg)
      let model = Model(..model, signin: form, notice: Quiet)
      let form_effect = effect.map(form_effect, SignInMsg)
      case outcome {
        signin.Stay -> #(model, form_effect)
        signin.SignedIn -> #(
          Model(..model, busy: True),
          effect.batch([form_effect, get_me()]),
        )
      }
    }
    SignOutClicked ->
      case model.account {
        SignedIn(_, _) -> #(
          Model(..model, busy: True, notice: Quiet),
          sign_out(),
        )
        _ -> #(model, effect.none())
      }
    SupabaseSignedOut(#(True, _)) -> #(model, delete_session())
    SupabaseSignedOut(#(False, message)) -> #(
      Model(
        ..model,
        busy: False,
        notice: Alert(text_or(message, "Could not clear the browser session.")),
      ),
      effect.none(),
    )
    SessionDeleted(#(200, _)) -> #(
      Model(
        ..blank(),
        busy: False,
        account: SignedOut,
        route: route.SignIn,
        notice: Info("Signed out."),
      ),
      push(route.sign_in_path),
    )
    SessionDeleted(#(0, message)) -> #(
      Model(
        ..model,
        busy: False,
        notice: Alert(text_or(message, "Sign-out failed.")),
      ),
      get_me(),
    )
    SessionDeleted(#(_, body)) -> #(
      Model(
        ..model,
        busy: False,
        notice: Alert(api.error_message(body, "Sign-out failed.")),
      ),
      get_me(),
    )
    Gate(inner) -> {
      let #(gate, fx, path) = gateway.update(model.gate, inner)
      let nav = case path {
        "" -> effect.none()
        path -> push(path)
      }
      #(Model(..model, gate:), effect.batch([effect.map(fx, Gate), nav]))
    }
  }
}

fn signed_in(
  model: Model,
  username: String,
  body: String,
) -> #(Model, Effect(Msg)) {
  let model =
    Model(
      ..model,
      busy: False,
      token: "",
      account: SignedIn(username:, body:),
      notice: model.notice,
    )
  case model.plan {
    "tinkerer" | "pro" -> #(Model(..model, plan: ""), checkout(model.plan))
    _ ->
      case model.route {
        route.SignIn -> #(model, push(route.start_path))
        other -> follow(model, other)
      }
  }
}

fn follow(model: Model, parsed: Route) -> #(Model, Effect(Msg)) {
  let #(gate, fx) = gateway.on_route(model.gate, parsed)
  #(Model(..model, gate:), effect.map(fx, Gate))
}

fn problem(model: Model, message: String) -> Model {
  Model(
    ..model,
    busy: False,
    token: "",
    signin: signin.idle(model.signin),
    account: SignedOut,
    notice: Alert(message),
  )
}

fn text_or(message: String, fallback: String) -> String {
  case string.trim(message) {
    "" -> fallback
    message -> message
  }
}

fn wants_create(path: String, query: Option(String)) -> Bool {
  case path, query {
    "/app/sign-in", _ | "/app/sign-in/", _ -> False
    _, Some(text) -> !route.query_flag(text, "mode", "sign-in")
    _, None -> True
  }
}

fn wanted_plan(query: Option(String)) -> String {
  case query {
    Some(text) -> {
      let plan = route.query_value(text, "plan")
      case plan {
        "tinkerer" | "pro" -> plan
        _ -> ""
      }
    }
    None -> ""
  }
}

fn arrival_notice(query: Option(String)) -> Notice {
  case query {
    Some(text) ->
      case
        route.query_flag(text, "billing", "success"),
        route.query_flag(text, "billing", "cancelled")
      {
        True, _ ->
          Info("Payment received. The plan updates when Stripe confirms it.")
        _, True -> Info("Checkout cancelled. The plan has not changed.")
        _, _ -> Quiet
      }
    None -> Quiet
  }
}

fn load_config() -> Effect(Msg) {
  use dispatch <- effect.from
  browser.load_config_text(fn(pair) { dispatch(ConfigLoaded(pair)) })
}

fn boot(url: String, key: String) -> Effect(Msg) {
  use dispatch <- effect.from
  browser.create_client(url, key)
  browser.strip_auth_params()
  browser.get_session(fn(pair) { dispatch(SessionLoaded(pair)) })
}

fn get_me() -> Effect(Msg) {
  use dispatch <- effect.from
  browser.send("GET", "/api/me", "", fn(pair) { dispatch(MeLoaded(pair)) })
}

fn post_link(token: String) -> Effect(Msg) {
  use dispatch <- effect.from
  browser.send("POST", "/api/auth", api.link_body(token), fn(pair) {
    dispatch(LinkLoaded(pair))
  })
}

fn checkout(plan: String) -> Effect(Msg) {
  use _dispatch <- effect.from
  browser.continue_checkout(plan)
}

fn sign_out() -> Effect(Msg) {
  use dispatch <- effect.from
  browser.sign_out_local(fn(pair) { dispatch(SupabaseSignedOut(pair)) })
}

fn delete_session() -> Effect(Msg) {
  use dispatch <- effect.from
  browser.send("DELETE", "/api/session", "", fn(pair) {
    dispatch(SessionDeleted(pair))
  })
}

fn push(path: String) -> Effect(Msg) {
  modem.push(path, None, None)
}

pub fn view(model: Model) -> Element(Msg) {
  let wide = case model.route {
    route.SignIn -> False
    _ -> True
  }
  let on_gateway = case model.route {
    route.SignIn | route.NotFound(_) | route.Leave(_) -> False
    _ -> True
  }
  html.div([], [
    ui.app_header([
      ui.wordmark("/"),
      case model.account {
        SignedIn(_, _) ->
          ui.nav("Sections", [
            ui.nav_link(route.gateways_path, "Gateway", on_gateway),
            ui.nav_link("/sensors", "Sensors", False),
          ])
        _ -> element.none()
      },
      case model.route {
        route.Preview(_) -> ui.badge("Example")
        _ -> element.none()
      },
      case model.account {
        SignedIn(username, _) ->
          ui.account([ui.user(username), sign_out_button(model.busy)])
        _ -> element.none()
      },
    ]),
    ui.main(wide, [screen(model)]),
  ])
}

fn screen(model: Model) -> Element(Msg) {
  case model.route, model.account {
    route.Preview(_), _ ->
      html.div([], [
        ui.notice_text(
          ui.Neutral,
          "Example data for layout. This is not your account.",
        ),
        element.map(gateway.view(model.gate), Gate),
      ])
    route.Leave(_), _ -> card("Opening…", [ui.muted("Leaving this page.")])
    route.NotFound(path), _ ->
      card("Page not found", [
        ui.lead(path <> " is not part of this app."),
        ui.actions([
          ui.link_button(ui.Secondary, route.sign_in_form_path, [
            text("Back to sign-in"),
          ]),
        ]),
      ])
    route.SignIn, Booting -> sign_in(model)
    _, Booting -> card("Loading…", [ui.muted("Checking your session.")])
    _, SignedOut ->
      case model.route {
        route.SignIn -> sign_in(model)
        _ ->
          card("Sign in", [
            notice(model.notice),
            ui.lead("Sign in to set up a gateway."),
            ui.actions([
              ui.link_button(ui.Primary, route.sign_in_form_path, [
                text("Sign in"),
              ]),
            ]),
          ])
      }
    _, SignedIn(_, _) ->
      html.div([], [
        notice(model.notice),
        element.map(gateway.view(model.gate), Gate),
      ])
  }
}

fn sign_in(model: Model) -> Element(Msg) {
  html.div([], [
    notice(model.notice),
    element.map(signin.view(model.signin, model.busy), SignInMsg),
  ])
}

fn sign_out_button(busy: Bool) -> Element(Msg) {
  ui.button(
    ui.Secondary,
    [
      attribute.type_("button"),
      attribute.disabled(busy),
      event.on_click(SignOutClicked),
    ],
    [text("Sign out")],
  )
}

fn card(title: String, body: List(Element(Msg))) -> Element(Msg) {
  ui.card([], [html.h1([], [text(title)]), ..body])
}

fn notice(notice: Notice) -> Element(Msg) {
  case notice {
    Quiet -> element.none()
    Info(message) -> ui.notice_text(ui.Good, message)
    Alert(message) -> alert(message)
  }
}

fn alert(message: String) -> Element(Msg) {
  ui.notice_text(ui.Bad, message)
}
