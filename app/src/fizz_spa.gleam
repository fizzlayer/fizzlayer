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
    notice: Notice,
    busy: Bool,
    github: Bool,
    linked: Bool,
    token: String,
    account: Account,
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
  SendMagicLink
  MagicLinkResult(#(Bool, String))
  StartGitHub
  GitHubResult(#(Bool, String))
  SignOutClicked
  SupabaseSignedOut(#(Bool, String))
  SessionDeleted(#(Int, String))
}

pub fn main() -> Nil {
  let app = lustre.application(init, update, view)
  case lustre.start(app, "#app", Nil) {
    Ok(_) -> Nil
    Error(_) -> Nil
  }
}

fn init(_flags: Nil) -> #(Model, Effect(Msg)) {
  let model =
    Model(
      route: route.SignIn,
      email: "",
      notice: Quiet,
      busy: True,
      github: False,
      linked: False,
      token: "",
      account: Booting,
    )
  case modem.initial_uri() {
    Ok(uri) ->
      case route.parse(uri.path) {
        route.Leave(_) -> #(model, modem.load(uri))
        parsed -> #(
          Model(..model, route: parsed),
          effect.batch([modem.init(Navigated), load_config()]),
        )
      }
    Error(_) -> #(model, effect.batch([modem.init(Navigated), load_config()]))
  }
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    Navigated(uri) ->
      case route.parse(uri.path) {
        route.Leave(_) -> #(model, modem.load(uri))
        parsed -> #(Model(..model, route: parsed), effect.none())
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
        api.Workspace(username:, body:) -> #(
          Model(
            ..model,
            busy: False,
            token: "",
            account: SignedIn(username:, body:),
            notice: Quiet,
          ),
          effect.none(),
        )
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
    SendMagicLink -> send_magic_link(model)
    MagicLinkResult(#(True, _)) -> #(
      Model(
        ..model,
        busy: False,
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
        ..model,
        busy: False,
        token: "",
        linked: False,
        account: SignedOut,
        route: route.SignIn,
        notice: Info("Signed out."),
      ),
      effect.none(),
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
  }
}

fn send_magic_link(model: Model) -> #(Model, Effect(Msg)) {
  case model.busy, model.account {
    True, _ | _, Booting | _, Unconfigured(_) | _, SignedIn(_, _) -> #(
      model,
      effect.none(),
    )
    False, SignedOut -> {
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
  Model(..model, busy: False, token: "", account: Unconfigured(message))
}

fn problem(model: Model, message: String) -> Model {
  Model(
    ..model,
    busy: False,
    token: "",
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

pub fn view(model: Model) -> Element(Msg) {
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
      html.span([attribute.class("preview")], [text("App preview")]),
      html.span([attribute.class("spacer")], []),
      html.a([attribute.href("/index.html")], [text("Home")]),
      html.a([attribute.href("/app.html")], [text("Current app")]),
    ]),
    html.main([attribute.id("main")], [screen(model)]),
  ])
}

fn screen(model: Model) -> Element(Msg) {
  case model.route, model.account {
    route.Leave(_), _ ->
      card("Opening…", [html.p([], [text("Leaving this preview.")])])
    route.NotFound(path), _ ->
      card("Page not found", [
        html.p([attribute.class("muted")], [
          text(path <> " is not part of this preview."),
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
    route.Workspace, SignedIn(username, body) ->
      workspace(model, username, body)
    route.Workspace, _ ->
      card("Workspace", [
        notice(model.notice),
        html.p([], [text("Sign in to load your workspace from GET /api/me.")]),
        html.a(
          [
            attribute.class("button primary"),
            attribute.href(route.sign_in_path),
          ],
          [
            text("Sign in"),
          ],
        ),
      ])
    _, SignedIn(username, _) ->
      card("Signed in", [
        notice(model.notice),
        html.p([], [text("Signed in as " <> username <> ".")]),
        html.div([attribute.class("row")], [
          html.a(
            [
              attribute.class("button primary"),
              attribute.href(route.workspace_path),
            ],
            [
              text("Open workspace"),
            ],
          ),
          sign_out_button(model.busy),
        ]),
      ])
    route.SignIn, SignedOut -> sign_in(model)
  }
}

fn workspace(model: Model, username: String, body: String) -> Element(Msg) {
  card("Workspace", [
    notice(model.notice),
    html.p([], [text("Signed in as " <> username <> ".")]),
    html.p([attribute.class("muted")], [
      text(
        "GET /api/me, using the same fizz_session cookie as the current site.",
      ),
    ]),
    html.pre([], [text(body)]),
    sign_out_button(model.busy),
  ])
}

fn sign_in(model: Model) -> Element(Msg) {
  card("Sign in", [
    notice(model.notice),
    html.p([attribute.class("muted")], [
      text(
        "Email a magic link, or continue with GitHub when this project has it turned on. Magic links sign in an existing account. New accounts are still created in the current app.",
      ),
    ]),
    html.form([event.on_submit(fn(_) { SendMagicLink })], [
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
      html.div([attribute.class("row")], [
        html.button(
          [
            attribute.class("primary"),
            attribute.type_("submit"),
            attribute.disabled(model.busy),
          ],
          [
            text(case model.busy {
              True -> "Please wait…"
              False -> "Email me a sign-in link"
            }),
          ],
        ),
      ]),
    ]),
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
          [text("Continue with GitHub")],
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
