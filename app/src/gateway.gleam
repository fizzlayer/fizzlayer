//// Gateway onboarding and the signed-in gateway pages.
////
//// Secrets stay in this model only as long as the page has to show them:
//// the registration token and the client JWT on the connect step, and the
//// upstream key in the server field until submit. Other screens do not read
//// those fields.

import gleam/list
import gleam/string
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element, text}
import lustre/element/html
import lustre/event

import api
import browser
import clients
import route.{type Route}
import ui

pub type Screen {
  Choose
  Create
  Server
  Tools
  Pin
  Client
  List
  Home
  Inbox
  Alerts
  Tokens
}

pub type Hosted {
  Unknown
  Up
  Down
}

pub type Note {
  Quiet
  Good(String)
  Bad(String)
}

pub type Model {
  Model(
    screen: Screen,
    id: String,
    loaded: Bool,
    busy: Bool,
    hosted: Hosted,
    role: String,
    plan: api.Plan,
    gateways: List(api.GatewayRow),
    servers: List(api.ServerRow),
    policies: List(api.PolicyRow),
    pins: List(api.PinRow),
    alerts: List(api.AlertRow),
    approvals: List(api.ApprovalRow),
    tokens: List(api.TokenRow),
    server_pick: String,
    name: String,
    mode: String,
    public_url: String,
    server_name: String,
    server_url: String,
    auth_kind: String,
    api_key: String,
    tool_name: String,
    effect: String,
    channel: String,
    token_name: String,
    minted: String,
    audience: String,
    registration: String,
    discovered: List(String),
    probe_note: String,
    notice: Note,
    upgrade: String,
    confirm_delete: Bool,
  )
}

pub type Msg {
  NameEdited(String)
  ModeEdited(String)
  PublicUrlEdited(String)
  ServerNameEdited(String)
  ServerUrlEdited(String)
  AuthKindEdited(String)
  ApiKeyEdited(String)
  ToolEdited(String)
  EffectEdited(String)
  ChannelEdited(String)
  TokenNameEdited(String)
  ServerPicked(String)
  SubmitGateway
  SubmitServer
  SavePolicy(server_id: String, tool: String, effect: String)
  SaveNamedTool
  ApprovePin(server: String, tool: String)
  AckAlert(String)
  Decide(id: String, status: String)
  MintToken
  RevokeToken(String)
  RotateRegistration
  AskDelete
  DeleteGateway
  RemoveServer(String)
  Continue(route.Step)
  Copy(String)
  ContextLoaded(#(Int, String))
  ServersLoaded(String, #(Int, String))
  PoliciesLoaded(String, #(Int, String))
  PinsLoaded(String, #(Int, String))
  AlertsLoaded(String, #(Int, String))
  ApprovalsLoaded(String, #(Int, String))
  TokensLoaded(String, #(Int, String))
  Wrote(String, #(Int, String))
  ProbeLoaded(#(Bool, String))
  HostedLoaded(#(Int, String))
  Copied(#(Bool, String))
}

pub fn empty() -> Model {
  Model(
    screen: Choose,
    id: "",
    loaded: False,
    busy: False,
    hosted: Unknown,
    role: "owner",
    plan: api.hobbyist(),
    gateways: [],
    servers: [],
    policies: [],
    pins: [],
    alerts: [],
    approvals: [],
    tokens: [],
    server_pick: "",
    name: "",
    mode: "shared",
    public_url: "",
    server_name: "",
    server_url: "",
    auth_kind: "key",
    api_key: "",
    tool_name: "",
    effect: "approve",
    channel: "log",
    token_name: "Cursor",
    minted: "",
    audience: "",
    registration: "",
    discovered: [],
    probe_note: "",
    notice: Quiet,
    upgrade: "",
    confirm_delete: False,
  )
}

pub fn on_route(model: Model, route: Route) -> #(Model, Effect(Msg)) {
  case route {
    route.Start -> #(Model(..model, screen: Choose), load_context())
    route.Gateways -> #(Model(..model, screen: List), load_context())
    route.Onboarding("", route.Create) -> #(
      Model(..model, screen: Create, id: ""),
      load_context(),
    )
    route.Onboarding(id, step) -> #(
      Model(..model, screen: screen_of(step), id: id),
      effect.batch([load_context(), load_details(id)]),
    )
    route.GatewayHome(id) -> #(
      Model(..model, screen: Home, id: id),
      effect.batch([load_context(), load_details(id)]),
    )
    route.Approvals(id) -> #(
      Model(..model, screen: Inbox, id: id),
      effect.batch([load_context(), load_details(id)]),
    )
    route.PinAlerts(id) -> #(
      Model(..model, screen: Alerts, id: id),
      effect.batch([load_context(), load_details(id)]),
    )
    route.ClientTokens(id) -> #(
      Model(..model, screen: Tokens, id: id),
      effect.batch([load_context(), load_details(id)]),
    )
    _ -> #(model, effect.none())
  }
}

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg), String) {
  case msg {
    NameEdited(name) -> #(
      Model(..model, name: name, notice: Quiet),
      effect.none(),
      "",
    )
    ModeEdited(mode) -> #(
      Model(..model, mode: mode, notice: Quiet),
      effect.none(),
      "",
    )
    PublicUrlEdited(url) -> #(
      Model(..model, public_url: url, notice: Quiet),
      effect.none(),
      "",
    )
    ServerNameEdited(name) -> #(
      Model(..model, server_name: name, notice: Quiet),
      effect.none(),
      "",
    )
    ServerUrlEdited(url) -> #(
      Model(..model, server_url: url, notice: Quiet),
      effect.none(),
      "",
    )
    AuthKindEdited(kind) -> #(
      Model(..model, auth_kind: kind, notice: Quiet),
      effect.none(),
      "",
    )
    ApiKeyEdited(key) -> #(
      Model(..model, api_key: key, notice: Quiet),
      effect.none(),
      "",
    )
    ToolEdited(name) -> #(
      Model(..model, tool_name: name, notice: Quiet),
      effect.none(),
      "",
    )
    EffectEdited(effect_name) -> #(
      Model(..model, effect: effect_name, notice: Quiet),
      effect.none(),
      "",
    )
    ChannelEdited(channel) -> #(
      Model(..model, channel: channel, notice: Quiet),
      effect.none(),
      "",
    )
    TokenNameEdited(name) -> #(
      Model(..model, token_name: name, notice: Quiet),
      effect.none(),
      "",
    )
    ServerPicked(id) -> #(Model(..model, server_pick: id), effect.none(), "")
    SubmitGateway -> submit_gateway(model)
    SubmitServer -> submit_server(model)
    SavePolicy(server_id, tool, effect_name) ->
      save_policy(model, server_id, tool, effect_name)
    SaveNamedTool ->
      save_policy(
        model,
        model.server_pick,
        string_trim(model.tool_name),
        model.effect,
      )
    ApprovePin(server, tool) ->
      post_json(model, pin_url(model.id), api.pin_body(server, tool), "pin")
    AckAlert(id) -> post_json(model, ack_url(model.id, id), "{}", "ack")
    Decide(id, status) ->
      post_json(
        model,
        decision_url(model.id, id),
        api.decision_body(status),
        "decision",
      )
    MintToken -> mint(model)
    RevokeToken(id) ->
      send_empty(model, "DELETE", token_url(model.id, id), "revoke")
    RotateRegistration ->
      post_json(model, registration_url(model.id), "{}", "rotate")
    AskDelete -> #(Model(..model, confirm_delete: True), effect.none(), "")
    DeleteGateway ->
      send_empty(model, "DELETE", gateway_url(model.id), "delete")
    RemoveServer(id) ->
      send_empty(model, "DELETE", server_url(model.id, id), "remove")
    Continue(step) -> #(
      model,
      effect.none(),
      route.onboarding_path(model.id, step),
    )
    Copy(value) -> #(model, copy(value), "")
    ContextLoaded(#(status, body)) -> context_loaded(model, status, body)
    ServersLoaded(id, #(status, body)) ->
      rows_loaded(model, id, status, body, api.servers_of, remember_servers)
    PoliciesLoaded(id, #(status, body)) ->
      rows_loaded(model, id, status, body, api.policies_of, fn(next, rows) {
        Model(..next, policies: rows)
      })
    PinsLoaded(id, #(status, body)) ->
      rows_loaded(model, id, status, body, api.pins_of, fn(next, rows) {
        Model(..next, pins: rows)
      })
    AlertsLoaded(id, #(status, body)) ->
      rows_loaded(model, id, status, body, api.alerts_of, fn(next, rows) {
        Model(..next, alerts: rows)
      })
    ApprovalsLoaded(id, #(status, body)) ->
      rows_loaded(model, id, status, body, api.approvals_of, fn(next, rows) {
        Model(..next, approvals: rows)
      })
    TokensLoaded(id, #(status, body)) ->
      rows_loaded(model, id, status, body, api.tokens_of, fn(next, rows) {
        Model(..next, tokens: rows)
      })
    Wrote(kind, #(status, body)) -> wrote(model, kind, status, body)
    ProbeLoaded(#(True, body)) -> #(probe_ok(model, body), effect.none(), "")
    ProbeLoaded(#(False, message)) -> #(
      Model(..model, probe_note: message, discovered: []),
      effect.none(),
      "",
    )
    HostedLoaded(#(status, body)) -> #(
      Model(..model, hosted: case api.hosted_available(status, body) {
        True -> Up
        False -> Down
      }),
      effect.none(),
      "",
    )
    Copied(#(True, _)) -> #(
      Model(..model, notice: Good("Copied.")),
      effect.none(),
      "",
    )
    Copied(#(False, _)) -> #(
      Model(..model, notice: Bad("Select the text and copy it.")),
      effect.none(),
      "",
    )
  }
}

fn submit_gateway(model: Model) -> #(Model, Effect(Msg), String) {
  case writable(model), api.gateway_name_ok(model.name) {
    Error(message), _ -> #(bad(model, message), effect.none(), "")
    _, False -> #(
      bad(
        model,
        "Use a short name: a lowercase letter, then letters, digits, or hyphens.",
      ),
      effect.none(),
      "",
    )
    Ok(_), True ->
      case model.mode == "selfhost" && !api.remote_url_ok(model.public_url) {
        True -> #(
          bad(
            model,
            "Self-host needs a public http or https URL, with no username or password in it.",
          ),
          effect.none(),
          "",
        )
        False ->
          case model.mode == "dedicated" && !model.plan.dedicated {
            True -> #(
              Model(
                ..model,
                upgrade: "A dedicated gateway is included on Pro. Upgrade to Pro, or create a shared gateway.",
              ),
              effect.none(),
              "",
            )
            False -> #(
              Model(..model, busy: True, notice: Quiet, upgrade: ""),
              post(
                "/api/gateway/gateways",
                api.gateway_body(model.name, model.mode, model.public_url),
                "gateway",
              ),
              "",
            )
          }
      }
  }
}

fn submit_server(model: Model) -> #(Model, Effect(Msg), String) {
  case writable(model) {
    Error(message) -> #(bad(model, message), effect.none(), "")
    Ok(_) ->
      case api.server_name_ok(model.server_name) {
        False -> #(
          bad(
            model,
            "Server name must start with a letter and use lowercase letters, digits, hyphens, or underscores.",
          ),
          effect.none(),
          "",
        )
        True ->
          case api.remote_url_ok(model.server_url) {
            False -> #(
              bad(
                model,
                "Server URL must be http or https, with no username or password in it.",
              ),
              effect.none(),
              "",
            )
            True ->
              case
                model.auth_kind == "key" && string_trim(model.api_key) == ""
              {
                True -> #(
                  bad(model, "Paste the server's API key or token."),
                  effect.none(),
                  "",
                )
                False -> {
                  let key = model.api_key
                  let url = model.server_url
                  let kind = model.auth_kind
                  #(
                    Model(
                      ..model,
                      busy: True,
                      api_key: "",
                      notice: Quiet,
                      upgrade: "",
                    ),
                    post_then_probe(
                      servers_url(model.id),
                      api.server_body(model.server_name, url, kind, key),
                      url,
                      kind,
                      key,
                    ),
                    "",
                  )
                }
              }
          }
      }
  }
}

fn save_policy(
  model: Model,
  server_id: String,
  tool: String,
  effect_name: String,
) -> #(Model, Effect(Msg), String) {
  let channel = case
    effect_name == "approve"
    && model.channel == "phone"
    && !api.phone_ok(model.plan)
  {
    True -> "blocked"
    False ->
      case model.channel {
        "webhook" | "phone" -> model.channel
        _ -> "log"
      }
  }
  case writable(model) {
    Error(message) -> #(bad(model, message), effect.none(), "")
    Ok(_) ->
      case api.tool_name_ok(tool), effect_name, channel {
        False, _, _ -> #(
          bad(model, "Tool name is * or letters, digits, and . _ : -."),
          effect.none(),
          "",
        )
        _, "allow", _ | _, "deny", _ | _, "approve", _ ->
          case channel {
            "blocked" -> #(
              Model(
                ..model,
                upgrade: "Phone calls are on Tinkerer and Pro. Hobbyist can log the approval or send a webhook.",
              ),
              effect.none(),
              "",
            )
            _ ->
              send_json(
                model,
                "PUT",
                policies_url(model.id),
                api.policy_body(server_id, tool, effect_name, channel),
                "policy",
              )
          }
        _, _, _ -> #(
          bad(model, "Choose Allow, Block, or Ask first."),
          effect.none(),
          "",
        )
      }
  }
}

fn mint(model: Model) -> #(Model, Effect(Msg), String) {
  let name = string_trim(model.token_name)
  case writable(model) {
    Error(message) -> #(bad(model, message), effect.none(), "")
    Ok(_) ->
      case name == "" || string.length(name) > 80 {
        True -> #(
          bad(model, "Name the token, up to 80 characters."),
          effect.none(),
          "",
        )
        False ->
          post_json(model, tokens_url(model.id), api.token_body(name), "mint")
      }
  }
}

fn context_loaded(
  model: Model,
  status: Int,
  body: String,
) -> #(Model, Effect(Msg), String) {
  case status {
    200 ->
      case api.context_of(body) {
        Error(_) -> #(
          bad(model, "The gateway list was not readable."),
          effect.none(),
          "",
        )
        Ok(context) -> {
          let channel = case api.phone_ok(context.plan), model.channel {
            False, "phone" -> "log"
            _, channel -> channel
          }
          let next =
            Model(
              ..model,
              loaded: True,
              role: context.role,
              plan: context.plan,
              gateways: context.gateways,
              channel: channel,
            )
          case model.hosted {
            Unknown -> #(next, hosted(), "")
            _ -> #(next, effect.none(), "")
          }
        }
      }
    _ -> #(
      problem(model, status, body, "The gateway list could not be loaded."),
      effect.none(),
      "",
    )
  }
}

fn rows_loaded(
  model: Model,
  id: String,
  status: Int,
  body: String,
  parse: fn(String) -> Result(List(a), Nil),
  store: fn(Model, List(a)) -> Model,
) -> #(Model, Effect(Msg), String) {
  case id == model.id {
    False -> #(model, effect.none(), "")
    True ->
      case status {
        200 ->
          case parse(body) {
            Ok(rows) -> #(store(model, rows), effect.none(), "")
            Error(_) -> #(model, effect.none(), "")
          }
        _ -> #(
          problem(model, status, body, "That gateway could not be loaded."),
          effect.none(),
          "",
        )
      }
  }
}

fn remember_servers(model: Model, rows: List(api.ServerRow)) -> Model {
  let pick = case model.server_pick, rows {
    "", [first, ..] -> first.id
    pick, _ -> pick
  }
  Model(..model, servers: rows, server_pick: pick)
}

fn wrote(
  model: Model,
  kind: String,
  status: Int,
  body: String,
) -> #(Model, Effect(Msg), String) {
  case status {
    200 -> wrote_ok(model, kind, body)
    _ -> #(
      problem(model, status, body, "That gateway change was not saved."),
      effect.none(),
      "",
    )
  }
}

fn wrote_ok(
  model: Model,
  kind: String,
  body: String,
) -> #(Model, Effect(Msg), String) {
  case kind {
    "gateway" ->
      case api.created_of(body) {
        Error(_) -> #(
          bad(model, "The gateway was not created."),
          effect.none(),
          "",
        )
        Ok(created) -> {
          let registration = case api.registration_ok(created.registration) {
            True -> created.registration
            False -> ""
          }
          let note = case registration {
            "" ->
              Bad(
                "The gateway was created, but the registration token was not usable. Rotate it on the connect step.",
              )
            _ -> Quiet
          }
          #(
            Model(
              ..model,
              busy: False,
              id: created.id,
              name: created.name,
              mode: created.mode,
              public_url: created.public_url,
              registration: registration,
              notice: note,
              upgrade: "",
            ),
            effect.none(),
            route.onboarding_path(created.id, route.Server),
          )
        }
      }
    "server" -> #(
      Model(
        ..model,
        busy: False,
        api_key: "",
        probe_note: "Checking that server for tools…",
        upgrade: "",
        notice: Quiet,
      ),
      effect.none(),
      route.onboarding_path(model.id, route.Tools),
    )
    "policy" -> #(
      Model(
        ..model,
        busy: False,
        tool_name: "",
        upgrade: "",
        notice: Good("Rule saved."),
      ),
      load_policies(model.id),
      "",
    )
    "pin" -> #(
      Model(..model, busy: False, upgrade: "", notice: Good("Pin approved.")),
      effect.batch([load_pins(model.id), load_alerts(model.id)]),
      "",
    )
    "ack" -> #(
      Model(..model, busy: False, notice: Good("Alert dismissed.")),
      load_alerts(model.id),
      "",
    )
    "decision" -> #(
      Model(..model, busy: False, notice: Good("Decision saved.")),
      load_approvals(model.id),
      "",
    )
    "mint" ->
      case api.minted_of(body) {
        Error(_) -> #(
          bad(model, "The token was not minted."),
          effect.none(),
          "",
        )
        Ok(#(token, audience)) ->
          case api.client_token_ok(token) {
            False -> #(
              bad(model, "The token did not look usable. Mint another."),
              effect.none(),
              "",
            )
            True -> #(
              Model(
                ..model,
                busy: False,
                minted: token,
                audience: audience,
                notice: Good("Copy this token now. It is not shown again."),
                upgrade: "",
              ),
              load_tokens(model.id),
              "",
            )
          }
      }
    "revoke" -> #(
      Model(..model, busy: False, notice: Good("Token revoked.")),
      load_tokens(model.id),
      "",
    )
    "rotate" ->
      case api.registration_of(body) {
        Ok(token) ->
          case api.registration_ok(token) {
            True -> #(
              Model(
                ..model,
                busy: False,
                registration: token,
                notice: Good(
                  "Copy the new registration token. The previous one no longer works.",
                ),
              ),
              effect.none(),
              "",
            )
            False -> #(
              bad(model, "The registration token was not rotated."),
              effect.none(),
              "",
            )
          }
        Error(_) -> #(
          bad(model, "The registration token was not rotated."),
          effect.none(),
          "",
        )
      }
    "delete" -> #(
      Model(
        ..empty(),
        notice: Good("Gateway deleted."),
        loaded: model.loaded,
        plan: model.plan,
        role: model.role,
        hosted: model.hosted,
      ),
      effect.none(),
      route.gateways_path,
    )
    "remove" -> #(
      Model(..model, busy: False, notice: Good("Server removed.")),
      load_servers(model.id),
      "",
    )
    _ -> #(model, effect.none(), "")
  }
}

fn probe_ok(model: Model, body: String) -> Model {
  let names = case api.tool_names(body) {
    Ok(found) -> list.filter(found, api.tool_name_ok)
    Error(_) -> []
  }
  let note = case names {
    [] ->
      "That server returned no tools. Name the ones you want to rule, or come back after the gateway has listed them."
    _ ->
      "These names came from the server just now. Tools without a rule are blocked."
  }
  Model(..model, discovered: names, probe_note: note)
}

fn post_json(
  model: Model,
  path: String,
  body: String,
  kind: String,
) -> #(Model, Effect(Msg), String) {
  send_json(model, "POST", path, body, kind)
}

fn send_json(
  model: Model,
  method: String,
  path: String,
  body: String,
  kind: String,
) -> #(Model, Effect(Msg), String) {
  case writable(model) {
    Error(message) -> #(bad(model, message), effect.none(), "")
    Ok(_) -> #(
      Model(..model, busy: True, notice: Quiet, upgrade: ""),
      method_send(method, path, body, kind),
      "",
    )
  }
}

fn send_empty(
  model: Model,
  method: String,
  path: String,
  kind: String,
) -> #(Model, Effect(Msg), String) {
  case writable(model) {
    Error(message) -> #(bad(model, message), effect.none(), "")
    Ok(_) -> #(
      Model(..model, busy: True, notice: Quiet, confirm_delete: False),
      method_send(method, path, "", kind),
      "",
    )
  }
}

fn writable(model: Model) -> Result(Nil, String) {
  case model.busy {
    True -> Error("busy")
    False ->
      case model.role {
        "owner" | "admin" -> Ok(Nil)
        _ -> Error("Only an owner or admin can change this gateway.")
      }
  }
}

fn bad(model: Model, message: String) -> Model {
  case message {
    "" | "busy" -> model
    message -> Model(..model, busy: False, notice: Bad(message))
  }
}

fn problem(model: Model, status: Int, body: String, fallback: String) -> Model {
  case api.failure(status, body, fallback) {
    api.Upgrade(message) ->
      Model(..model, busy: False, upgrade: message, notice: Quiet)
    api.Message(message) -> Model(..model, busy: False, notice: Bad(message))
  }
}

fn screen_of(step: route.Step) -> Screen {
  case step {
    route.Create -> Create
    route.Server -> Server
    route.Tools -> Tools
    route.Pin -> Pin
    route.Client -> Client
  }
}

fn load_context() -> Effect(Msg) {
  use dispatch <- effect.from
  browser.send("GET", "/api/gateway/gateways", "", fn(pair) {
    dispatch(ContextLoaded(pair))
  })
}

fn hosted() -> Effect(Msg) {
  use dispatch <- effect.from
  browser.hosted_probe(fn(pair) { dispatch(HostedLoaded(pair)) })
}

fn load_details(id: String) -> Effect(Msg) {
  effect.batch([
    load_servers(id),
    load_policies(id),
    load_pins(id),
    load_alerts(id),
    load_approvals(id),
    load_tokens(id),
  ])
}

fn load_servers(id: String) -> Effect(Msg) {
  get(servers_url(id), fn(pair) { ServersLoaded(id, pair) })
}

fn load_policies(id: String) -> Effect(Msg) {
  get(policies_url(id), fn(pair) { PoliciesLoaded(id, pair) })
}

fn load_pins(id: String) -> Effect(Msg) {
  get(pins_url(id), fn(pair) { PinsLoaded(id, pair) })
}

fn load_alerts(id: String) -> Effect(Msg) {
  get(alerts_url(id), fn(pair) { AlertsLoaded(id, pair) })
}

fn load_approvals(id: String) -> Effect(Msg) {
  get(approvals_url(id), fn(pair) { ApprovalsLoaded(id, pair) })
}

fn load_tokens(id: String) -> Effect(Msg) {
  get(tokens_url(id), fn(pair) { TokensLoaded(id, pair) })
}

fn get(path: String, tag: fn(#(Int, String)) -> Msg) -> Effect(Msg) {
  use dispatch <- effect.from
  browser.send("GET", path, "", fn(pair) { dispatch(tag(pair)) })
}

fn post(path: String, body: String, kind: String) -> Effect(Msg) {
  method_send("POST", path, body, kind)
}

fn method_send(
  method: String,
  path: String,
  body: String,
  kind: String,
) -> Effect(Msg) {
  use dispatch <- effect.from
  browser.send(method, path, body, fn(pair) { dispatch(Wrote(kind, pair)) })
}

fn post_then_probe(
  path: String,
  body: String,
  url: String,
  kind: String,
  key: String,
) -> Effect(Msg) {
  use dispatch <- effect.from
  browser.send("POST", path, body, fn(pair) {
    dispatch(Wrote("server", pair))
    case pair {
      #(200, _) ->
        browser.probe_tools(url, kind, key, fn(result) {
          dispatch(ProbeLoaded(result))
        })
      _ -> Nil
    }
  })
}

fn copy(value: String) -> Effect(Msg) {
  use dispatch <- effect.from
  browser.copy_text(value, fn(pair) { dispatch(Copied(pair)) })
}

fn gateway_url(id: String) -> String {
  "/api/gateway/gateways/" <> id
}

fn servers_url(id: String) -> String {
  gateway_url(id) <> "/servers"
}

fn server_url(id: String, server: String) -> String {
  servers_url(id) <> "/" <> server
}

fn policies_url(id: String) -> String {
  gateway_url(id) <> "/policies"
}

fn pins_url(id: String) -> String {
  gateway_url(id) <> "/pins"
}

fn pin_url(id: String) -> String {
  pins_url(id) <> "/approve"
}

fn alerts_url(id: String) -> String {
  gateway_url(id) <> "/pin-alerts"
}

fn ack_url(id: String, alert: String) -> String {
  alerts_url(id) <> "/" <> alert <> "/ack"
}

fn approvals_url(id: String) -> String {
  gateway_url(id) <> "/approvals"
}

fn decision_url(id: String, approval: String) -> String {
  approvals_url(id) <> "/" <> approval <> "/decision"
}

fn tokens_url(id: String) -> String {
  gateway_url(id) <> "/tokens"
}

fn token_url(id: String, token: String) -> String {
  tokens_url(id) <> "/" <> token
}

fn registration_url(id: String) -> String {
  gateway_url(id) <> "/registration-token"
}

fn string_trim(value: String) -> String {
  string.trim(value)
}

pub fn view(model: Model) -> Element(Msg) {
  html.div([], [
    upgrade_box(model.upgrade),
    note(model.notice),
    case model.screen {
      Choose -> choose(model)
      Create -> create_form(model)
      Server -> server_form(model)
      Tools -> tools(model)
      Pin -> pins(model)
      Client -> client(model)
      List -> list_page(model)
      Home -> home(model)
      Inbox -> inbox(model)
      Alerts -> alerts(model)
      Tokens -> token_page(model)
    },
  ])
}

fn choose(model: Model) -> Element(Msg) {
  ui.card([attribute.id("step-choose")], [
    html.h1([], [text("What do you want to set up?")]),
    ui.lead("You can add the other one later."),
    ui.choices([
      ui.choice(True, [
        html.h2([], [text("Gateway")]),
        html.p([], [
          text(
            "Choose which tools your AI agents can use, and approve risky calls before they run.",
          ),
        ]),
        ui.link_button(ui.Primary, route.onboarding_path("", route.Create), [
          text("Set up a gateway"),
        ]),
      ]),
      ui.choice(False, [
        html.h2([], [text("Sensors")]),
        html.p([], [
          text("Connect devices, watch their readings, and get alerts."),
        ]),
        ui.link_button(ui.Secondary, "/sensors", [
          text("Open Sensors"),
        ]),
      ]),
    ]),
    case model.gateways {
      [] -> element.none()
      _ ->
        html.p([], [
          html.a([attribute.href(route.gateways_path)], [
            text("Open your gateways"),
          ]),
        ])
    },
  ])
}

fn create_form(model: Model) -> Element(Msg) {
  ui.card([attribute.id("step-create")], [
    steps(model),
    html.h1([], [text("Create a gateway")]),
    hosted_note(model),
    plan_card(model.plan),
    html.form([event.on_submit(fn(_) { SubmitGateway })], [
      field(
        "Gateway name",
        "gateway-name",
        model.name,
        "home",
        False,
        NameEdited,
      ),
      ui.field(
        "Where it runs",
        "gateway-mode",
        "",
        ui.select(
          [
            attribute.id("gateway-mode"),
            attribute.disabled(model.busy),
            event.on_change(ModeEdited),
          ],
          [
            option("shared", "Shared", model.mode == "shared"),
            option("selfhost", "Self-host", model.mode == "selfhost"),
            case model.plan.dedicated {
              True ->
                option("dedicated", "Dedicated", model.mode == "dedicated")
              False ->
                html.option(
                  [attribute.value("dedicated"), attribute.disabled(True)],
                  "Dedicated (Pro)",
                )
            },
          ],
        ),
      ),
      case model.mode == "selfhost" {
        True ->
          field(
            "Public URL",
            "public-url",
            model.public_url,
            "https://gateway.example.com/mcp",
            False,
            PublicUrlEdited,
          )
        False -> element.none()
      },
      ui.actions([
        ui.button(
          ui.Primary,
          [
            attribute.type_("submit"),
            attribute.disabled(model.busy),
          ],
          [text("Create gateway")],
        ),
      ]),
    ]),
  ])
}

fn server_form(model: Model) -> Element(Msg) {
  ui.card([attribute.id("step-server")], [
    steps(model),
    html.h1([], [text("Add an MCP server")]),
    ui.muted(
      "Paste the server URL. If it needs a key, it is stored encrypted and is not shown again. This page does not keep the key after you submit.",
    ),
    html.form([event.on_submit(fn(_) { SubmitServer })], [
      field(
        "Server name",
        "server-name",
        model.server_name,
        "github",
        False,
        ServerNameEdited,
      ),
      field(
        "Server URL",
        "server-url",
        model.server_url,
        "https://example.com/mcp",
        False,
        ServerUrlEdited,
      ),
      ui.field(
        "Auth",
        "auth-kind",
        "",
        ui.select(
          [
            attribute.id("auth-kind"),
            attribute.disabled(model.busy),
            event.on_change(AuthKindEdited),
          ],
          [
            option("none", "No extra credential", model.auth_kind == "none"),
            option("key", "API key or token", model.auth_kind == "key"),
            option(
              "passthrough",
              "Pass the client token through",
              model.auth_kind == "passthrough",
            ),
          ],
        ),
      ),
      case model.auth_kind == "key" {
        True ->
          field(
            "API key or token",
            "api-key",
            model.api_key,
            "",
            True,
            ApiKeyEdited,
          )
        False -> element.none()
      },
      ui.actions([
        ui.button(
          ui.Primary,
          [
            attribute.type_("submit"),
            attribute.disabled(model.busy),
          ],
          [text("Add server")],
        ),
      ]),
    ]),
    server_list(model),
  ])
}

fn tools(model: Model) -> Element(Msg) {
  ui.card([attribute.id("step-tools")], [
    steps(model),
    html.h1([], [text("Rules for each tool")]),
    ui.lead(
      "Allow runs the tool. Block stops it. Ask first holds each call until you approve it, then the agent tries again. Tools without a rule are blocked.",
    ),
    channel_field(model),
    case model.probe_note {
      "" -> element.none()
      note -> ui.muted(note)
    },
    server_picker(model),
    ui.list([
      tool_row(model, "*"),
      ..list.map(tool_names(model), fn(name) { tool_row(model, name) })
    ]),
    case tool_names(model) {
      [] ->
        ui.muted(
          "No tool names yet. Type one, or wait until the gateway lists them.",
        )
      _ -> element.none()
    },
    html.form([event.on_submit(fn(_) { SaveNamedTool })], [
      field(
        "Tool name",
        "tool-name",
        model.tool_name,
        "create_issue",
        False,
        ToolEdited,
      ),
      ui.actions([
        ui.button(
          ui.Secondary,
          [
            attribute.type_("submit"),
            attribute.disabled(model.busy),
          ],
          [text("Save rule for this name")],
        ),
      ]),
    ]),
    ui.actions([
      ui.button(
        ui.Primary,
        [
          attribute.type_("button"),
          attribute.disabled(model.busy),
          event.on_click(Continue(route.Pin)),
        ],
        [text("Continue to pins")],
      ),
    ]),
  ])
}

fn pins(model: Model) -> Element(Msg) {
  ui.card([attribute.id("step-pin")], [
    steps(model),
    html.h1([], [text("Pin tool descriptions")]),
    ui.muted(
      "A pin is the description the gateway has seen. If that text changes later, the tool is hidden until you approve the new one. Calls stay denied until the pin is approved.",
    ),
    case model.pins {
      [] ->
        ui.muted(
          "Nothing is pinned yet. Pins show up after the gateway lists the server's tools. You can connect a client and come back.",
        )
      rows -> ui.list(list.map(rows, pin_row))
    },
    open_alerts(model),
    ui.actions([
      ui.button(
        ui.Primary,
        [
          attribute.type_("button"),
          attribute.disabled(model.busy),
          event.on_click(Continue(route.Client)),
        ],
        [text("Continue to a client")],
      ),
    ]),
  ])
}

fn client(model: Model) -> Element(Msg) {
  let hosted = model.hosted == Up
  let url =
    clients.endpoint(hosted, current_mode(model), current_public_url(model))
  ui.card([attribute.id("step-client")], [
    steps(model),
    html.h1([], [text("Connect a client")]),
    case hosted {
      True ->
        html.div([], [
          html.p([], [text("Clients use this URL.")]),
          ui.code_block(current_public_url(model)),
          html.h2([], [text("Run it yourself")]),
          ui.muted(
            "Linked mode still uses a registration token. That token is not the client token.",
          ),
          registration_box(model),
        ])
      False -> self_host(model)
    },
    html.form([event.on_submit(fn(_) { MintToken })], [
      field(
        "Token name",
        "token-name",
        model.token_name,
        "Cursor",
        False,
        TokenNameEdited,
      ),
      ui.actions([
        ui.button(
          ui.Primary,
          [
            attribute.type_("submit"),
            attribute.disabled(model.busy),
          ],
          [text("Mint a client token")],
        ),
      ]),
    ]),
    case api.client_token_ok(model.minted) {
      False -> ui.muted("Mint a token to fill the snippets. It is shown once.")
      True -> snippets(url, model.minted)
    },
    html.p([], [
      html.a([attribute.href(route.gateway_path(model.id))], [
        text("Open this gateway"),
      ]),
    ]),
  ])
}

fn self_host(model: Model) -> Element(Msg) {
  html.div([attribute.id("self-host")], [
    html.p([], [
      text(
        "The shared host is not answering yet, so this gateway has no public MCP URL to hand a client. Run it yourself and link it with the registration token.",
      ),
    ]),
    html.ol([], [
      html.li([], [
        text(
          "Set FIZZ_API_URL to this site's origin, with no path and no password.",
        ),
      ]),
      html.li([], [
        text(
          "Put the registration token in a file (mode 0600) and point FIZZ_REGISTRATION_TOKEN_FILE at it.",
        ),
      ]),
      html.li([], [
        text(
          "Run fizz-agent pull next to agentgateway. Do not also run fizz-config watch on the same file.",
        ),
      ]),
    ]),
    html.p([], [
      text("The linked setup is described in the gateway README and on "),
      html.a([attribute.href("/self-host")], [text("the self-host page")]),
      text("."),
    ]),
    registration_box(model),
    ui.muted(
      "The snippets below use http://127.0.0.1:3000/mcp, which is the local compose port. Replace it with the URL you publish. The client token is not the registration token.",
    ),
  ])
}

fn registration_box(model: Model) -> Element(Msg) {
  case api.registration_ok(model.registration) {
    False ->
      html.div([], [
        ui.muted(
          "The registration token is shown once. If you left this page, rotate it. The new value replaces the old one.",
        ),
        ui.actions([
          ui.button(
            ui.Secondary,
            [
              attribute.type_("button"),
              attribute.disabled(model.busy),
              event.on_click(RotateRegistration),
            ],
            [text("Rotate registration token")],
          ),
        ]),
      ])
    True ->
      html.div([], [
        ui.snippet(
          "Registration token, for fizz-agent only",
          model.registration,
          [
            ui.button(
              ui.Secondary,
              [
                attribute.type_("button"),
                event.on_click(Copy(model.registration)),
              ],
              [text("Copy")],
            ),
          ],
        ),
      ])
  }
}

fn snippets(url: String, token: String) -> Element(Msg) {
  html.div([], [
    snippet("Claude Code", clients.claude_code(url, token)),
    snippet("Claude Desktop", clients.claude_desktop(url, token)),
    snippet("Cursor", clients.cursor(url, token)),
    snippet("Any HTTP MCP client", clients.generic(url, token)),
  ])
}

fn snippet(title: String, body: String) -> Element(Msg) {
  ui.snippet(title, body, [
    ui.button(
      ui.Secondary,
      [attribute.type_("button"), event.on_click(Copy(body))],
      [text("Copy")],
    ),
  ])
}

fn list_page(model: Model) -> Element(Msg) {
  ui.card([attribute.id("step-gateways")], [
    html.h1([], [text("Gateways")]),
    plan_card(model.plan),
    case model.loaded, model.gateways {
      False, _ -> ui.muted("Loading gateways…")
      True, [] ->
        html.p([], [
          text("No gateway yet. "),
          html.a([attribute.href(route.onboarding_path("", route.Create))], [
            text("Create one"),
          ]),
          text("."),
        ])
      True, rows -> ui.list(list.map(rows, gateway_row))
    },
    html.p([], [
      ui.link_button(ui.Primary, route.onboarding_path("", route.Create), [
        text("New gateway"),
      ]),
    ]),
  ])
}

fn home(model: Model) -> Element(Msg) {
  let row = current_gateway(model)
  ui.card([attribute.id("step-home")], [
    html.h1([], [
      text(case row {
        Ok(gateway) -> gateway.name
        Error(_) -> "Gateway"
      }),
    ]),
    case row {
      Ok(gateway) ->
        html.div([], [
          html.p([], [
            ui.badge(mode_label(gateway.mode)),
            text(" "),
            ui.badge(gateway.status),
          ]),
          case gateway.status {
            "disabled" ->
              ui.notice_text(
                ui.Bad,
                "This gateway is paused because your plan's gateway limit is reached. Remove a gateway or upgrade to run it again.",
              )
            _ -> element.none()
          },
          ui.code_block(gateway.public_url),
        ])
      Error(_) -> ui.muted("Loading…")
    },
    nav_links(model.id),
    server_list(model),
    registration_box(model),
    case model.confirm_delete {
      False ->
        ui.button(
          ui.Secondary,
          [
            attribute.type_("button"),
            event.on_click(AskDelete),
          ],
          [text("Delete gateway")],
        )
      True ->
        html.div([], [
          html.p([], [text("Delete this gateway, its servers, and its tokens?")]),
          ui.button(
            ui.Primary,
            [
              attribute.type_("button"),
              attribute.disabled(model.busy),
              event.on_click(DeleteGateway),
            ],
            [text("Confirm delete")],
          ),
        ])
    },
  ])
}

fn inbox(model: Model) -> Element(Msg) {
  let pending =
    list.filter(model.approvals, fn(row) { row.status == "pending" })
  ui.card([attribute.id("step-approvals")], [
    html.h1([], [text("Approvals")]),
    ui.muted(
      "Approve or deny a pending call. Approving allows that same call once. The agent has to retry it.",
    ),
    nav_links(model.id),
    case pending {
      [] -> html.p([], [text("No pending approvals.")])
      rows -> ui.list(list.map(rows, approval_row))
    },
  ])
}

fn alerts(model: Model) -> Element(Msg) {
  ui.card([attribute.id("step-alerts")], [
    html.h1([], [text("Changed tools")]),
    ui.muted(
      "The description below is text from the MCP server. Treat it as untrusted. Approving the pin stores the new hash. Dismiss only hides the alert.",
    ),
    nav_links(model.id),
    open_alerts(model),
  ])
}

fn token_page(model: Model) -> Element(Msg) {
  ui.card([attribute.id("step-tokens")], [
    html.h1([], [text("Client tokens")]),
    ui.muted(
      "Revoking a token blocks it on the next call. The JWT itself is only shown when you mint it.",
    ),
    nav_links(model.id),
    case api.client_token_ok(model.minted) {
      True ->
        html.div([], [
          html.p([], [text("New token")]),
          secret_block(model.minted),
        ])
      False -> element.none()
    },
    html.form([event.on_submit(fn(_) { MintToken })], [
      field(
        "Token name",
        "token-name",
        model.token_name,
        "Cursor",
        False,
        TokenNameEdited,
      ),
      ui.button(
        ui.Primary,
        [
          attribute.type_("submit"),
          attribute.disabled(model.busy),
        ],
        [text("Mint a client token")],
      ),
    ]),
    case model.tokens {
      [] -> ui.muted("No client tokens yet.")
      rows -> ui.list(list.map(rows, token_row))
    },
  ])
}

fn approval_row(row: api.ApprovalRow) -> Element(Msg) {
  ui.list_row(
    row.tool_name,
    [text(row.server_name <> " · " <> row.args_preview)],
    [
      ui.button(
        ui.Primary,
        [attribute.type_("button"), event.on_click(Decide(row.id, "approved"))],
        [text("Approve")],
      ),
      ui.button(
        ui.Secondary,
        [attribute.type_("button"), event.on_click(Decide(row.id, "denied"))],
        [text("Reject")],
      ),
    ],
  )
}

fn token_row(row: api.TokenRow) -> Element(Msg) {
  ui.list_row(
    row.name,
    [
      ui.badge(case row.revoked {
        True -> "Revoked"
        False -> "Active"
      }),
    ],
    [
      case row.revoked {
        True -> element.none()
        False ->
          ui.button(
            ui.Danger,
            [attribute.type_("button"), event.on_click(RevokeToken(row.id))],
            [text("Revoke")],
          )
      },
    ],
  )
}

fn pin_row(row: api.PinRow) -> Element(Msg) {
  ui.list_row(
    row.server_name <> " / " <> row.tool_name,
    [ui.badge(row.status)],
    [
      case row.status == "approved" {
        True -> element.none()
        False ->
          ui.button(
            ui.Secondary,
            [
              attribute.type_("button"),
              event.on_click(ApprovePin(row.server_name, row.tool_name)),
            ],
            [text("Approve pin")],
          )
      },
    ],
  )
}

fn open_alerts(model: Model) -> Element(Msg) {
  let open = list.filter(model.alerts, fn(row) { !row.acknowledged })
  case open {
    [] -> ui.muted("No changed tools.")
    rows ->
      ui.list(
        list.map(rows, fn(row) {
          ui.list_row(
            row.server_name <> " / " <> row.tool_name,
            [html.p([], [text(row.preview)])],
            [
              ui.button(
                ui.Primary,
                [
                  attribute.type_("button"),
                  event.on_click(ApprovePin(row.server_name, row.tool_name)),
                ],
                [text("Approve the new description")],
              ),
              ui.button(
                ui.Secondary,
                [attribute.type_("button"), event.on_click(AckAlert(row.id))],
                [text("Dismiss")],
              ),
            ],
          )
        }),
      )
  }
}

fn tool_row(model: Model, name: String) -> Element(Msg) {
  let title = case name {
    "*" -> "Every tool (default)"
    _ -> name
  }
  ui.list_row(title, [text(policy_label(model, name))], [
    rule_button(model, name, "allow"),
    rule_button(model, name, "deny"),
    rule_button(model, name, "approve"),
  ])
}

fn rule_button(
  model: Model,
  tool: String,
  effect_name: String,
) -> Element(Msg) {
  let current = current_effect(model, tool) == Ok(effect_name)
  ui.button(
    case current {
      True -> ui.Primary
      False -> ui.Secondary
    },
    [
      attribute.type_("button"),
      attribute.aria_pressed(case current {
        True -> "true"
        False -> "false"
      }),
      attribute.disabled(model.busy),
      event.on_click(SavePolicy(model.server_pick, tool, effect_name)),
    ],
    [text(rule_label(effect_name))],
  )
}

/// The UI names for rule effects. The API keeps allow, deny, and approve.
pub fn rule_label(effect_name: String) -> String {
  case effect_name {
    "allow" -> "Allow"
    "deny" -> "Block"
    "approve" -> "Ask first"
    other -> other
  }
}

fn current_policy(model: Model, tool: String) -> Result(api.PolicyRow, Nil) {
  list.find(model.policies, fn(row) {
    row.tool_name == tool
    && { row.server_id == model.server_pick || row.server_id == "" }
  })
}

fn current_effect(model: Model, tool: String) -> Result(String, Nil) {
  case current_policy(model, tool) {
    Ok(row) -> Ok(row.effect)
    Error(_) -> Error(Nil)
  }
}

fn policy_label(model: Model, tool: String) -> String {
  case current_policy(model, tool) {
    Ok(row) ->
      case row.effect {
        "approve" ->
          rule_label(row.effect) <> " · notify by " <> row.notify_channel
        _ -> rule_label(row.effect)
      }
    Error(_) -> "No rule yet"
  }
}

fn tool_names(model: Model) -> List(String) {
  unique(
    list.flatten([
      model.discovered,
      list.map(model.pins, fn(row) { row.tool_name }),
      list.filter_map(model.policies, fn(row) {
        case row.tool_name {
          "*" | "" -> Error(Nil)
          name -> Ok(name)
        }
      }),
    ]),
  )
}

fn unique(items: List(String)) -> List(String) {
  list.fold(items, [], fn(acc, item) {
    case list.contains(acc, item) {
      True -> acc
      False -> list.append(acc, [item])
    }
  })
}

fn server_picker(model: Model) -> Element(Msg) {
  case model.servers {
    [] -> element.none()
    rows ->
      html.div([], [
        ui.field(
          "Server",
          "server-pick",
          "",
          ui.select(
            [attribute.id("server-pick"), event.on_change(ServerPicked)],
            list.map(rows, fn(row) {
              option(row.id, row.name, row.id == model.server_pick)
            }),
          ),
        ),
      ])
  }
}

fn server_list(model: Model) -> Element(Msg) {
  case model.servers {
    [] -> element.none()
    rows ->
      ui.list(
        list.map(rows, fn(row) {
          ui.list_row(
            row.name,
            [
              text(
                row.url
                <> case row.has_secret {
                  True -> " · credential stored"
                  False -> ""
                },
              ),
            ],
            [
              ui.button(
                ui.Secondary,
                [
                  attribute.type_("button"),
                  event.on_click(RemoveServer(row.id)),
                ],
                [text("Remove")],
              ),
            ],
          )
        }),
      )
  }
}

fn gateway_row(row: api.GatewayRow) -> Element(Msg) {
  ui.list_row(row.name, [text(mode_label(row.mode) <> " · " <> row.status)], [
    ui.link_button(ui.Secondary, route.gateway_path(row.id), [text("Open")]),
    ui.link_button(ui.Quiet, route.approvals_path(row.id), [text("Approvals")]),
    ui.link_button(ui.Quiet, route.alerts_path(row.id), [text("Changed tools")]),
    ui.link_button(ui.Quiet, route.tokens_path(row.id), [text("Tokens")]),
  ])
}

fn mode_label(mode: String) -> String {
  case mode {
    "shared" -> "Shared"
    "selfhost" -> "Self-hosted"
    "dedicated" -> "Dedicated"
    other -> other
  }
}

fn nav_links(id: String) -> Element(Msg) {
  ui.nav("Gateway pages", [
    ui.nav_link(route.gateways_path, "All gateways", False),
    ui.nav_link(route.approvals_path(id), "Approvals", False),
    ui.nav_link(route.alerts_path(id), "Changed tools", False),
    ui.nav_link(route.tokens_path(id), "Tokens", False),
    ui.nav_link(route.onboarding_path(id, route.Tools), "Rules", False),
  ])
}

fn channel_field(model: Model) -> Element(Msg) {
  html.div([], [
    ui.field(
      "When a tool asks",
      "notify",
      "",
      ui.select([attribute.id("notify"), event.on_change(ChannelEdited)], [
        option("log", "Log", model.channel == "log"),
        option("webhook", "Webhook", model.channel == "webhook"),
        case api.phone_ok(model.plan) {
          True -> option("phone", "Phone", model.channel == "phone")
          False -> element.none()
        },
      ]),
    ),
    case api.phone_ok(model.plan) {
      True -> ui.muted("Phone calls share the monthly cap with sensor alerts.")
      False ->
        ui.muted_content([
          text(
            "Phone calls are on Tinkerer and Pro. This plan can log the request or send a webhook. ",
          ),
          html.a([attribute.href("/pricing")], [text("See plans")]),
          text("."),
        ])
    },
  ])
}

fn hosted_note(model: Model) -> Element(Msg) {
  case model.hosted {
    Unknown -> ui.muted("Checking whether the shared gateway is up…")
    Up ->
      html.p([], [
        text(
          "The shared gateway is up. A new shared gateway gets a hosted MCP URL.",
        ),
      ])
    Down ->
      html.p([], [
        text(
          "The shared host is not answering yet. You can still save the gateway, servers, and rules. The connect step shows how to run it yourself.",
        ),
      ])
  }
}

fn plan_card(plan: api.Plan) -> Element(Msg) {
  ui.plan([attribute.id("plan-limits")], [
    html.h2([], [text(plan.name)]),
    html.ul([], [
      html.li([], [text("Gateways: " <> api.cap_label(plan.gateway_limit))]),
      html.li([], [text("MCP servers: " <> api.cap_label(plan.server_limit))]),
      html.li([], [
        text("Tool calls this month: " <> api.cap_label(plan.tool_calls)),
      ]),
      html.li([], [
        text(
          "Phone calls this month, shared with sensor alerts: "
          <> api.cap_label(plan.phone_calls),
        ),
      ]),
      html.li([], [text("Audit kept, days: " <> api.cap_label(plan.audit_days))]),
      html.li([], [
        text(case plan.stdio {
          True -> "stdio servers: included"
          False -> "stdio servers: not on this plan"
        }),
      ]),
      html.li([], [
        text(case plan.dedicated {
          True -> "Dedicated gateway: included"
          False -> "Dedicated gateway: Pro"
        }),
      ]),
    ]),
    html.a([attribute.href("/pricing")], [text("Plans and upgrades")]),
  ])
}

fn steps(model: Model) -> Element(Msg) {
  let current = step_of_screen(model.screen)
  ui.steps(
    list.map(
      [
        #(route.Create, "Gateway"),
        #(route.Server, "Server"),
        #(route.Tools, "Rules"),
        #(route.Pin, "Pin"),
        #(route.Client, "Connect"),
      ],
      fn(item) {
        let #(step, label) = item
        // Before the gateway exists, later steps have nowhere to go.
        let href = case model.id, step {
          "", route.Create -> route.onboarding_path("", step)
          "", _ -> ""
          id, _ -> route.onboarding_path(id, step)
        }
        #(href, label, current == Ok(step))
      },
    ),
  )
}

fn step_of_screen(screen: Screen) -> Result(route.Step, Nil) {
  case screen {
    Create -> Ok(route.Create)
    Server -> Ok(route.Server)
    Tools -> Ok(route.Tools)
    Pin -> Ok(route.Pin)
    Client -> Ok(route.Client)
    _ -> Error(Nil)
  }
}

fn field(
  label: String,
  id: String,
  value: String,
  placeholder: String,
  secret: Bool,
  msg: fn(String) -> Msg,
) -> Element(Msg) {
  ui.field(
    label,
    id,
    "",
    ui.input([
      attribute.id(id),
      attribute.type_(case secret {
        True -> "password"
        False -> "text"
      }),
      attribute.autocomplete("off"),
      attribute.placeholder(placeholder),
      attribute.value(value),
      event.on_input(msg),
    ]),
  )
}

fn option(value: String, label: String, selected: Bool) -> Element(Msg) {
  html.option([attribute.value(value), attribute.selected(selected)], label)
}

fn secret_block(value: String) -> Element(Msg) {
  ui.code_block(value)
}

fn upgrade_box(message: String) -> Element(Msg) {
  case message {
    "" -> element.none()
    message ->
      ui.notice(ui.Caution, [attribute.id("upgrade")], [
        html.p([], [text(message)]),
        ui.link_button(ui.Secondary, "/pricing", [text("See plans")]),
      ])
  }
}

fn note(notice: Note) -> Element(Msg) {
  case notice {
    Quiet -> element.none()
    Good(message) -> ui.notice_text(ui.Good, message)
    Bad(message) -> ui.notice_text(ui.Bad, message)
  }
}

fn current_gateway(model: Model) -> Result(api.GatewayRow, Nil) {
  list.find(model.gateways, fn(row) { row.id == model.id })
}

fn current_mode(model: Model) -> String {
  case current_gateway(model) {
    Ok(row) -> row.mode
    Error(_) -> model.mode
  }
}

fn current_public_url(model: Model) -> String {
  case current_gateway(model) {
    Ok(row) -> row.public_url
    Error(_) -> model.public_url
  }
}

pub fn preview(name: String) -> Model {
  let id = "11111111-1111-4111-8111-111111111111"
  let base =
    Model(
      ..empty(),
      loaded: True,
      hosted: Down,
      id: id,
      name: "home",
      mode: "shared",
      public_url: "https://gw.fizzlayer.com/w/" <> id <> "/mcp",
      registration: "fizz_reg_" <> string.repeat("ab", 32),
      minted: "eyJhbGciOiJub25lIn0.eyJzdWIiOiJleGFtcGxlIn0.e30",
      audience: "https://gw.fizzlayer.com/w/" <> id <> "/mcp",
      gateways: [
        api.GatewayRow(
          id: id,
          name: "home",
          mode: "shared",
          public_url: "https://gw.fizzlayer.com/w/" <> id <> "/mcp",
          status: "active",
          role: "owner",
        ),
      ],
      servers: [
        api.ServerRow(
          id: "22222222-2222-4222-8222-222222222222",
          name: "github",
          url: "https://example.com/mcp",
          transport: "http",
          auth_kind: "key",
          has_secret: True,
          enabled: True,
        ),
      ],
      server_pick: "22222222-2222-4222-8222-222222222222",
      discovered: ["ping", "create_issue", "move_funds"],
      policies: [
        api.PolicyRow(
          id: "33333333-3333-4333-8333-333333333333",
          server_id: "22222222-2222-4222-8222-222222222222",
          tool_name: "ping",
          effect: "allow",
          notify_channel: "log",
        ),
      ],
      pins: [
        api.PinRow(
          server_name: "github",
          tool_name: "ping",
          status: "unreviewed",
        ),
        api.PinRow(
          server_name: "github",
          tool_name: "create_issue",
          status: "changed",
        ),
      ],
      alerts: [
        api.AlertRow(
          id: "44444444-4444-4444-8444-444444444444",
          server_name: "github",
          tool_name: "create_issue",
          preview: "Creates an issue. Description text from the server.",
          acknowledged: False,
        ),
      ],
      approvals: [
        api.ApprovalRow(
          id: "55555555-5555-4555-8555-555555555555",
          server_name: "github",
          tool_name: "move_funds",
          args_preview: "amount, destination",
          status: "pending",
          notify_channel: "log",
        ),
      ],
      tokens: [
        api.TokenRow(
          id: "66666666-6666-4666-8666-666666666666",
          name: "Cursor on laptop",
          revoked: False,
        ),
      ],
      server_name: "github",
      server_url: "https://example.com/mcp",
      probe_note: "These names came from the server just now. Tools without a rule are blocked.",
    )
  case name {
    "choose" ->
      Model(..base, screen: Choose, registration: "", minted: "", api_key: "")
    "create" -> Model(..base, screen: Create, registration: "", minted: "")
    "server" ->
      Model(..base, screen: Server, registration: "", minted: "", api_key: "")
    "tools" -> Model(..base, screen: Tools, registration: "", minted: "")
    "tools-pro" ->
      Model(
        ..base,
        screen: Tools,
        registration: "",
        minted: "",
        plan: api.Plan(
          ..api.hobbyist(),
          id: "pro",
          name: "Pro",
          phone_calls: api.Limited(100),
          dedicated: True,
          stdio: True,
        ),
      )
    "pin" -> Model(..base, screen: Pin, registration: "", minted: "")
    "client" -> Model(..base, screen: Client)
    "client-hosted" -> Model(..base, screen: Client, hosted: Up)
    "gateways" ->
      Model(..base, screen: List, registration: "", minted: "", api_key: "")
    "approvals" -> Model(..base, screen: Inbox, registration: "", minted: "")
    "alerts" -> Model(..base, screen: Alerts, registration: "", minted: "")
    "tokens" -> Model(..base, screen: Tokens, minted: "")
    "limit" ->
      Model(
        ..base,
        screen: Create,
        registration: "",
        minted: "",
        upgrade: "Your plan's gateway limit is reached. Hobbyist and Tinkerer include 1 shared gateway, and Pro includes 1 dedicated gateway. Remove a gateway or upgrade.",
      )
    _ -> Model(..base, screen: Choose, registration: "", minted: "")
  }
}
