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
    Error(_) -> #(blank(), effect.batch([modem.init(Navigated), load_config()]))
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
      modem.init(Navigated),
    )
    _ -> #(
      Model(
        ..model,
        route: parsed,
        creating: wants_create(uri.query),
        plan: wanted_plan(uri.query),
        notice: arrival_notice(uri.query),
      ),
      effect.batch([modem.init(Navigated), load_config()]),
    )
  }
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
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

fn wants_create(query: Option(String)) -> Bool {
  case query {
    Some(text) -> !route.query_flag(text, "mode", "sign-in")
    None -> True
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
    route.SignIn -> ""
    _ -> " wide"
  }
  html.div([attribute.class("page")], [
    html.header([attribute.class("top")], [
      html.a([attribute.class("brand"), attribute.href(route.sign_in_path)], [
        html.img([
          attribute.src("/fizz-logo.svg"),
          attribute.alt("Fizzlayer"),
          attribute.width(28),
          attribute.height(28),
        ]),
        text("Fizzlayer"),
      ]),
      case model.route {
        route.Preview(_) ->
          html.span([attribute.class("preview")], [text("Example")])
        _ -> element.none()
      },
      html.span([attribute.class("spacer")], []),
      case model.account {
        SignedIn(username, _) ->
          html.span([attribute.class("who")], [text(username)])
        _ -> element.none()
      },
      html.a([attribute.href(route.gateways_path)], [text("Gateways")]),
      html.a([attribute.href("/sensors")], [text("Sensors")]),
      html.a([attribute.href("/")], [text("Home")]),
      case model.account {
        SignedIn(_, _) -> sign_out_button(model.busy)
        _ -> element.none()
      },
    ]),
    html.main([attribute.id("main"), attribute.class("main" <> wide)], [
      screen(model),
    ]),
  ])
}

fn screen(model: Model) -> Element(Msg) {
  case model.route, model.account {
    route.Preview(_), _ ->
      html.div([], [
        html.p([attribute.class("info")], [
          text("Example data for layout. This is not your account."),
        ]),
        element.map(gateway.view(model.gate), Gate),
      ])
    route.Leave(_), _ ->
      card("Opening…", [html.p([], [text("Leaving this page.")])])
    route.NotFound(path), _ ->
      card("Page not found", [
        html.p([attribute.class("muted")], [
          text(path <> " is not part of this app."),
        ]),
        html.a([attribute.class("button"), attribute.href(route.sign_in_path)], [
          text("Back to sign-in"),
        ]),
      ])
    _, Booting ->
      card("Loading…", [
        html.p([attribute.class("muted")], [text("Checking your session.")]),
      ])
    _, Unconfigured(message) ->
      card("Sign-in isn't configured", [
        alert(message),
        html.p([attribute.class("muted")], [
          text(
            "Set SUPABASE_URL and SUPABASE_ANON_KEY for the build. Use the anon or publishable key, never the service-role key.",
          ),
        ]),
      ])
    _, SignedOut ->
      case model.route {
        route.SignIn -> sign_in(model)
        _ ->
          card("Sign in", [
            notice(model.notice),
            html.p([], [text("Sign in to set up a gateway.")]),
            html.a(
              [
                attribute.class("button primary"),
                attribute.href(route.sign_in_path),
              ],
              [text("Sign in")],
            ),
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
    html.p([attribute.class("muted")], [
      text(case model.creating {
        True ->
          "After the account exists you choose a gateway or Sensors. Gateway is the default. A new account starts on Hobbyist."
        False ->
          "Sign in with your email and password. A magic link works for an account that already exists."
      }),
    ]),
    html.div([attribute.class("row")], [
      html.button(
        [
          attribute.type_("button"),
          attribute.class(case model.creating {
            True -> "primary"
            False -> "ghost"
          }),
          event.on_click(ShowCreate),
        ],
        [text("Create account")],
      ),
      html.button(
        [
          attribute.type_("button"),
          attribute.class(case model.creating {
            False -> "primary"
            True -> "ghost"
          }),
          event.on_click(ShowSignIn),
        ],
        [text("Sign in")],
      ),
    ]),
    html.form([event.on_submit(fn(_) { SubmitPassword })], [
      html.label([attribute.for("email")], [text("Email")]),
      html.input([
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
      html.label([attribute.for("password")], [text("Password")]),
      html.input([
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
      case model.creating {
        True ->
          html.p([attribute.class("muted")], [
            text("At least 12 characters, up to 72 bytes."),
          ])
        False -> element.none()
      },
      html.div([attribute.class("row")], [
        html.button(
          [
            attribute.class("primary"),
            attribute.type_("submit"),
            attribute.disabled(model.busy),
          ],
          [
            text(case model.busy, model.creating {
              True, _ -> "Please wait…"
              False, True -> "Create account"
              False, False -> "Sign in"
            }),
          ],
        ),
      ]),
    ]),
    case model.creating {
      False ->
        html.button(
          [
            attribute.class("ghost"),
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
        html.button(
          [
            attribute.class("ghost"),
            attribute.type_("button"),
            attribute.disabled(model.busy),
            event.on_click(StartGitHub),
          ],
          [
            text(case model.creating {
              True -> "Sign up with GitHub"
              False -> "Continue with GitHub"
            }),
          ],
        )
    },
  ])
}

fn sign_out_button(busy: Bool) -> Element(Msg) {
  html.button(
    [
      attribute.class("ghost"),
      attribute.type_("button"),
      attribute.disabled(busy),
      event.on_click(SignOutClicked),
    ],
    [text("Sign out")],
  )
}

fn card(title: String, body: List(Element(Msg))) -> Element(Msg) {
  html.section([attribute.class("card")], [html.h1([], [text(title)]), ..body])
}

fn notice(notice: Notice) -> Element(Msg) {
  case notice {
    Quiet -> element.none()
    Info(message) ->
      html.p([attribute.role("status"), attribute.class("info")], [
        text(message),
      ])
    Alert(message) -> alert(message)
  }
}

fn alert(message: String) -> Element(Msg) {
  html.p([attribute.role("alert"), attribute.class("alert")], [text(message)])
}
