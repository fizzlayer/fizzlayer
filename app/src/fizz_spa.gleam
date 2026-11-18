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
import ui

pub type Notice {
  Quiet
  Info(String)
  Alert(String)
}

pub type Account {
  Booting
  Unconfigured(String)
  SignedOut
  SignedIn(username: String, body: String)
}

pub type Model {
  Model(
    route: Route,
    email: String,
    password: String,
    creating: Bool,
    plan: String,
    notice: Notice,
    busy: Bool,
    github: Bool,
    linked: Bool,
    token: String,
    account: Account,
    gate: gateway.Model,
  )
}

pub type Msg {
  Navigated(Uri)
  LinkClicked(String)
  ConfigLoaded(#(Bool, String))
  ProvidersLoaded(#(Int, String))
  SessionLoaded(#(Bool, String, String))
  MeLoaded(#(Int, String))
  LinkLoaded(#(Int, String))
  EmailEdited(String)
  PasswordEdited(String)
  ShowCreate
  ShowSignIn
  SubmitPassword
  PasswordResult(#(Int, String))
  SendMagicLink
  MagicLinkResult(#(Bool, String))
  StartGitHub
  GitHubResult(#(Bool, String))
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
    email: "",
    password: "",
    creating: True,
    plan: "",
    notice: Quiet,
    busy: True,
    github: False,
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
        creating: False,
        account: SignedOut,
        gate: gateway.preview(name),
      ),
      routing(),
    )
    _ -> #(
      Model(
        ..model,
        route: parsed,
        creating: wants_create(uri.path, uri.query),
        plan: wanted_plan(uri.query),
        notice: arrival_notice(uri.query),
      ),
      effect.batch([routing(), load_config()]),
    )
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
    ConfigLoaded(#(False, _)) -> #(
      unconfigured(model, "Sign-in isn't configured yet."),
      effect.none(),
    )
    ConfigLoaded(#(True, text)) ->
      case config.parse_config(text) {
        Error(message) -> #(unconfigured(model, message), effect.none())
        Ok(#(url, key)) -> #(Model(..model, busy: True), boot(url, key))
      }
    ProvidersLoaded(#(status, body)) -> #(
      Model(..model, github: api.github_enabled(status, body)),
      effect.none(),
    )
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
    EmailEdited(email) -> #(
      Model(..model, email: email, notice: Quiet),
      effect.none(),
    )
    PasswordEdited(password) -> #(
      Model(..model, password: password, notice: Quiet),
      effect.none(),
    )
    ShowCreate -> #(
      Model(..model, creating: True, notice: Quiet),
      effect.none(),
    )
    ShowSignIn -> #(
      Model(..model, creating: False, notice: Quiet),
      effect.none(),
    )
    SubmitPassword -> submit_password(model)
    PasswordResult(#(status, body)) ->
      case api.auth_outcome(status, body) {
        api.SignedIn -> #(
          Model(..model, busy: True, password: "", notice: Quiet),
          get_me(),
        )
        api.ConfirmEmail -> #(
          Model(
            ..model,
            busy: False,
            password: "",
            notice: Info(
              "Check your email and open the confirmation link in this browser.",
            ),
          ),
          effect.none(),
        )
        api.AuthFailed(message) -> #(
          Model(..model, busy: False, password: "", notice: Alert(message)),
          effect.none(),
        )
      }
    SendMagicLink -> send_magic_link(model)
    MagicLinkResult(#(True, _)) -> #(
      Model(
        ..model,
        busy: False,
        password: "",
        notice: Info(
          "Check your email for a sign-in link. Open it in this browser.",
        ),
      ),
      effect.none(),
    )
    MagicLinkResult(#(False, message)) -> #(
      problem(model, text_or(message, "Could not send the sign-in email.")),
      effect.none(),
    )
    StartGitHub -> start_github(model)
    GitHubResult(#(True, _)) -> #(
      Model(..model, busy: True, notice: Info("Redirecting to GitHub…")),
      effect.none(),
    )
    GitHubResult(#(False, message)) -> #(
      problem(model, text_or(message, "GitHub sign-in could not start.")),
      effect.none(),
    )
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
        creating: True,
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
      password: "",
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

fn submit_password(model: Model) -> #(Model, Effect(Msg)) {
  case model.busy, model.account {
    True, _ | _, Booting | _, Unconfigured(_) | _, SignedIn(_, _) -> #(
      model,
      effect.none(),
    )
    False, SignedOut -> {
      let email = string.lowercase(string.trim(model.email))
      case
        api.valid_email(email),
        api.password_ok(model.password, model.creating)
      {
        False, _ -> #(
          Model(..model, notice: Alert("Enter a valid email address.")),
          effect.none(),
        )
        _, False -> #(
          Model(
            ..model,
            notice: Alert(case model.creating {
              True -> "Use at least 12 characters, up to 72 bytes."
              False -> "Email or password is incorrect."
            }),
          ),
          effect.none(),
        )
        True, True -> {
          let action = case model.creating {
            True -> "sign_up"
            False -> "sign_in"
          }
          #(
            Model(..model, email: email, busy: True, notice: Quiet),
            password_request(action, email, model.password),
          )
        }
      }
    }
  }
}

fn send_magic_link(model: Model) -> #(Model, Effect(Msg)) {
  case model.busy, model.account, model.creating {
    True, _, _
    | _, Booting, _
    | _, Unconfigured(_), _
    | _, SignedIn(_, _), _
    | _, _, True
    -> #(model, effect.none())
    False, SignedOut, False -> {
      let email = string.lowercase(string.trim(model.email))
      case api.valid_email(email) {
        False -> #(
          Model(..model, notice: Alert("Enter a valid email address.")),
          effect.none(),
        )
        True -> {
          let redirect = browser.page_origin() <> route.sign_in_path
          case redirect == route.sign_in_path {
            True -> #(
              problem(model, "This page has no origin to return to."),
              effect.none(),
            )
            False -> #(
              Model(..model, email: email, busy: True, notice: Quiet),
              magic_link(email, redirect),
            )
          }
        }
      }
    }
  }
}

fn start_github(model: Model) -> #(Model, Effect(Msg)) {
  case model.busy, model.github, model.account {
    True, _, _
    | _, False, _
    | _, _, SignedIn(_, _)
    | _, _, Booting
    | _, _, Unconfigured(_)
    -> #(model, effect.none())
    False, True, SignedOut -> {
      let redirect = browser.page_origin() <> route.sign_in_path
      case redirect == route.sign_in_path {
        True -> #(
          problem(model, "This page has no origin to return to."),
          effect.none(),
        )
        False -> #(Model(..model, busy: True, notice: Quiet), github(redirect))
      }
    }
  }
}

fn unconfigured(model: Model, message: String) -> Model {
  Model(
    ..model,
    busy: False,
    token: "",
    password: "",
    account: Unconfigured(message),
  )
}

fn problem(model: Model, message: String) -> Model {
  Model(
    ..model,
    busy: False,
    token: "",
    password: "",
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
  browser.send("GET", "/api/auth?providers", "", fn(pair) {
    dispatch(ProvidersLoaded(pair))
  })
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

fn password_request(
  action: String,
  email: String,
  password: String,
) -> Effect(Msg) {
  use dispatch <- effect.from
  browser.send(
    "POST",
    "/api/auth",
    api.auth_body(action, email, password),
    fn(pair) { dispatch(PasswordResult(pair)) },
  )
}

fn checkout(plan: String) -> Effect(Msg) {
  use _dispatch <- effect.from
  browser.continue_checkout(plan)
}

fn magic_link(email: String, redirect: String) -> Effect(Msg) {
  use dispatch <- effect.from
  browser.sign_in_with_otp(email, redirect, fn(pair) {
    dispatch(MagicLinkResult(pair))
  })
}

fn github(redirect: String) -> Effect(Msg) {
  use dispatch <- effect.from
  browser.sign_in_with_github(redirect, fn(pair) {
    dispatch(GitHubResult(pair))
  })
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
    _, Unconfigured(message) ->
      card("Sign-in isn't configured", [
        alert(message),
        ui.muted(
          "Set SUPABASE_URL and SUPABASE_ANON_KEY for the build. Use the anon or publishable key, never the service-role key.",
        ),
      ])
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
  let title = case model.creating {
    True -> "Create your account"
    False -> "Sign in"
  }
  card(title, [
    notice(model.notice),
    ui.lead(case model.creating {
      True ->
        "Your account starts on the free Hobbyist plan. Next, you choose what to set up."
      False -> "Use your email and password, or get a sign-in link by email."
    }),
    html.form([event.on_submit(fn(_) { SubmitPassword })], [
      ui.field(
        "Email",
        "email",
        "",
        ui.input([
          attribute.id("email"),
          attribute.name("email"),
          attribute.type_("email"),
          attribute.autocomplete("email"),
          attribute.required(True),
          attribute.placeholder("you@example.com"),
          attribute.value(model.email),
          attribute.disabled(model.busy),
          event.on_input(EmailEdited),
        ]),
      ),
      ui.field(
        "Password",
        "password",
        case model.creating {
          True -> "At least 12 characters."
          False -> ""
        },
        ui.input([
          attribute.id("password"),
          attribute.name("password"),
          attribute.type_("password"),
          attribute.autocomplete(case model.creating {
            True -> "new-password"
            False -> "current-password"
          }),
          attribute.required(True),
          attribute.value(model.password),
          attribute.disabled(model.busy),
          event.on_input(PasswordEdited),
        ]),
      ),
      ui.actions([
        ui.button(
          ui.Primary,
          [attribute.type_("submit"), attribute.disabled(model.busy)],
          [
            text(case model.busy, model.creating {
              True, _ -> "Please wait…"
              False, True -> "Create account"
              False, False -> "Sign in"
            }),
          ],
        ),
        case model.creating {
          False ->
            ui.button(
              ui.Secondary,
              [
                attribute.type_("button"),
                attribute.disabled(model.busy),
                event.on_click(SendMagicLink),
              ],
              [text("Email me a sign-in link")],
            )
          True -> element.none()
        },
        case model.github {
          False -> element.none()
          True ->
            ui.button(
              ui.Secondary,
              [
                attribute.type_("button"),
                attribute.disabled(model.busy),
                event.on_click(StartGitHub),
              ],
              [text("Continue with GitHub")],
            )
        },
      ]),
    ]),
    html.p([], [
      text(case model.creating {
        True -> "Already have an account? "
        False -> "New to Fizzlayer? "
      }),
      ui.text_button(
        [
          event.on_click(case model.creating {
            True -> ShowSignIn
            False -> ShowCreate
          }),
        ],
        [
          text(case model.creating {
            True -> "Sign in"
            False -> "Create an account"
          }),
        ],
      ),
    ]),
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
