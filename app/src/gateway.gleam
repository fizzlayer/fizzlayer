//// The signed-in gateway screens: the gateway list, a form to create one, and
//// one page per gateway with tabs for its servers, rules, approvals, tool
//// changes, clients and settings.
////
//// Secrets stay in this model only as long as the page has to show them:
//// the registration token and the client JWT on the Connect tab, and the
//// upstream key in the add-server sheet until submit. Other tabs do not read
//// those fields.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/string
import gleam/uri
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element, text}
import lustre/element/html
import lustre/event

import api
import browser
import catalog
import clients
import route.{type Route, type Tab}
import ui

pub type Screen {
  List
  Create
  Page(Tab)
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

/// The add-server panel.
pub type Sheet {
  Closed
  Custom
  FromCatalog(catalog.Entry)
}

/// A server's tools, asked of the server through the API.
pub type Tools {
  ToolsLoading
  ToolsLoaded(List(api.Tool))
  ToolsFailed(String)
}

/// Registry search, separate from the featured list.
pub type Search {
  Idle
  Searching
  Searched(query: String)
  SearchFailed(String)
}

pub type Model {
  Model(
    screen: Screen,
    id: String,
    /// The gateway whose servers, rules and the rest are loaded, so switching
    /// tabs does not fetch them again.
    details_id: String,
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
    server_transport: String,
    auth_kind: String,
    api_key: String,
    tool_name: String,
    effect: String,
    channel: String,
    token_name: String,
    minted: String,
    /// The client and name the shown token was created for. Its setup only
    /// shows while that client is picked.
    minted_for: String,
    minted_name: String,
    audience: String,
    registration: String,
    /// Tools per server id, filled as soon as servers load or one is added.
    tools: Dict(String, Tools),
    /// The MCP client picked on Connect.
    client: String,
    notice: Note,
    upgrade: String,
    confirm_delete: Bool,
    sheet: Sheet,
    category: String,
    query: String,
    search: Search,
    results: List(catalog.Entry),
    next: String,
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
  ClientPicked(String)
  ServerPicked(String)
  RulesFor(String)
  SubmitGateway
  SubmitServer
  SavePolicy(server_id: String, tool: String, effect: String)
  SaveNamedTool
  ApprovePin(server: String, tool: String)
  AckAlert(String)
  Decide(id: String, status: String)
  RefreshApprovals
  MintToken
  TokenNameEdited(String)
  RevokeToken(String)
  RotateRegistration
  AskDelete
  CancelDelete
  DeleteGateway
  RemoveServer(String)
  Copy(String)
  CategoryPicked(String)
  QueryEdited(String)
  SearchRegistry
  MoreResults
  ClearSearch
  OpenEntry(catalog.Entry)
  OpenCustom
  CloseSheet
  ContextLoaded(#(Int, String))
  ServersLoaded(String, #(Int, String))
  PoliciesLoaded(String, #(Int, String))
  PinsLoaded(String, #(Int, String))
  AlertsLoaded(String, #(Int, String))
  ApprovalsLoaded(String, #(Int, String))
  TokensLoaded(String, #(Int, String))
  RegistryLoaded(Bool, #(Int, String))
  Wrote(String, #(Int, String))
  LoadTools(String)
  ToolsAnswered(String, String, #(Int, String))
  HostedLoaded(#(Int, String))
  Copied(#(Bool, String))
}

pub fn empty() -> Model {
  Model(
    screen: List,
    id: "",
    details_id: "",
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
    server_transport: "http",
    auth_kind: "key",
    api_key: "",
    tool_name: "",
    effect: "approve",
    channel: "log",
    token_name: "",
    minted: "",
    minted_for: "",
    minted_name: "",
    audience: "",
    registration: "",
    tools: dict.new(),
    client: "claude-code",
    notice: Quiet,
    upgrade: "",
    confirm_delete: False,
    sheet: Closed,
    category: "all",
    query: "",
    search: Idle,
    results: [],
    next: "",
  )
}

pub fn on_route(model: Model, route: Route) -> #(Model, Effect(Msg)) {
  let model = Model(..model, sheet: Closed, confirm_delete: False, api_key: "")
  case route {
    route.Gateways -> #(Model(..model, screen: List), load_context())
    route.NewGateway -> #(
      Model(..model, screen: Create, id: "", notice: Quiet),
      load_context(),
    )
    route.Gateway(id, tab) ->
      case id == model.details_id {
        // Same gateway, another tab: keep what is loaded. Approvals change
        // while the page is open, so those tabs ask again.
        True -> #(
          Model(..model, screen: Page(tab), notice: Quiet, upgrade: ""),
          case tab {
            route.Overview | route.Approvals -> load_approvals(id)
            _ -> effect.none()
          },
        )
        False -> {
          // The create form sets `id` and the one-time registration token
          // before it opens the new gateway. Keep them for that gateway only.
          let same = id == model.id
          #(
            Model(
              ..model,
              screen: Page(tab),
              id: id,
              details_id: id,
              servers: [],
              policies: [],
              pins: [],
              alerts: [],
              approvals: [],
              tokens: [],
              server_pick: "",
              tools: dict.new(),
              registration: case same {
                True -> model.registration
                False -> ""
              },
              minted: "",
              minted_for: "",
              minted_name: "",
              token_name: "",
            ),
            effect.batch([load_context(), load_details(id)]),
          )
        }
      }
    _ -> #(model, effect.none())
  }
}

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg), String) {
  case msg {
    NameEdited(name) -> edited(Model(..model, name: name))
    ModeEdited(mode) -> edited(Model(..model, mode: mode))
    PublicUrlEdited(url) -> edited(Model(..model, public_url: url))
    ServerNameEdited(name) -> edited(Model(..model, server_name: name))
    ServerUrlEdited(url) -> edited(Model(..model, server_url: url))
    AuthKindEdited(kind) -> edited(Model(..model, auth_kind: kind))
    ApiKeyEdited(key) -> edited(Model(..model, api_key: key))
    ToolEdited(name) -> edited(Model(..model, tool_name: name))
    EffectEdited(effect_name) -> edited(Model(..model, effect: effect_name))
    ChannelEdited(channel) -> edited(Model(..model, channel: channel))
    ClientPicked(key) -> #(Model(..model, client: key), effect.none(), "")
    LoadTools(server) -> #(
      Model(..model, tools: dict.insert(model.tools, server, ToolsLoading)),
      load_tools(model.id, server),
      "",
    )
    QueryEdited(query) -> #(Model(..model, query: query), effect.none(), "")
    ServerPicked(id) -> #(Model(..model, server_pick: id), effect.none(), "")
    RulesFor(id) -> #(
      Model(..model, server_pick: id),
      effect.none(),
      route.tab_path(model.id, route.Rules),
    )
    CategoryPicked(category) -> #(
      Model(..model, category: category),
      effect.none(),
      "",
    )
    SearchRegistry -> search_registry(model)
    MoreResults ->
      case model.search, model.next {
        Searched(query), next if next != "" -> #(
          Model(..model, search: Searching),
          registry(query, next, True),
          "",
        )
        _, _ -> #(model, effect.none(), "")
      }
    ClearSearch -> #(
      Model(..model, query: "", search: Idle, results: [], next: ""),
      effect.none(),
      "",
    )
    OpenEntry(entry) ->
      case catalog.addable(entry) {
        False -> #(model, effect.none(), "")
        True -> #(
          Model(
            ..model,
            sheet: FromCatalog(entry),
            server_name: free_name(model, catalog.slug(entry.title)),
            server_url: entry.url,
            server_transport: entry.transport,
            auth_kind: catalog.auth_kind(entry),
            api_key: "",
            notice: Quiet,
            upgrade: "",
          ),
          effect.none(),
          "",
        )
      }
    OpenCustom -> #(
      Model(
        ..model,
        sheet: Custom,
        server_name: "",
        server_url: "",
        server_transport: "http",
        auth_kind: "key",
        api_key: "",
        notice: Quiet,
        upgrade: "",
      ),
      effect.none(),
      "",
    )
    CloseSheet -> #(
      Model(..model, sheet: Closed, api_key: ""),
      effect.none(),
      "",
    )
    SubmitGateway -> submit_gateway(model)
    SubmitServer -> submit_server(model)
    SavePolicy(server_id, tool, effect_name) ->
      save_policy(model, server_id, tool, effect_name)
    SaveNamedTool ->
      save_policy(
        model,
        model.server_pick,
        string.trim(model.tool_name),
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
    RefreshApprovals -> #(
      Model(..model, notice: Quiet),
      load_approvals(model.id),
      "",
    )
    MintToken -> mint(model)
    TokenNameEdited(name) -> #(
      Model(..model, token_name: name),
      effect.none(),
      "",
    )
    RevokeToken(id) ->
      send_empty(model, "DELETE", token_url(model.id, id), "revoke")
    RotateRegistration ->
      post_json(model, registration_url(model.id), "{}", "rotate")
    AskDelete -> #(Model(..model, confirm_delete: True), effect.none(), "")
    CancelDelete -> #(Model(..model, confirm_delete: False), effect.none(), "")
    DeleteGateway ->
      send_empty(model, "DELETE", gateway_url(model.id), "delete")
    RemoveServer(id) ->
      send_empty(model, "DELETE", server_url(model.id, id), "remove")
    Copy(value) -> #(model, copy(value), "")
    ContextLoaded(#(status, body)) -> context_loaded(model, status, body)
    ServersLoaded(id, #(status, body)) -> {
      let #(next, effects, path) =
        rows_loaded(model, id, status, body, api.servers_of, remember_servers)
      let #(next, more) = ask_for_tools(next)
      #(next, effect.batch([effects, more]), path)
    }
    ToolsAnswered(gateway, server, #(status, body)) ->
      case gateway == model.id {
        False -> #(model, effect.none(), "")
        True -> #(
          Model(
            ..model,
            tools: dict.insert(model.tools, server, tools_state(status, body)),
          ),
          effect.none(),
          "",
        )
      }
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
    RegistryLoaded(append, #(status, body)) ->
      registry_loaded(model, append, status, body)
    Wrote(kind, #(status, body)) -> wrote(model, kind, status, body)
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

fn edited(model: Model) -> #(Model, Effect(Msg), String) {
  #(Model(..model, notice: Quiet), effect.none(), "")
}

/// A server name not already used on this gateway: `github`, then
/// `github-2` and so on.
fn free_name(model: Model, base: String) -> String {
  let taken = list.map(model.servers, fn(row) { row.name })
  free_name_from(taken, base, 1)
}

fn free_name_from(taken: List(String), base: String, n: Int) -> String {
  let candidate = case n {
    1 -> base
    _ -> string.slice(base, 0, 38) <> "-" <> int.to_string(n)
  }
  case list.contains(taken, candidate) && n < 50 {
    True -> free_name_from(taken, base, n + 1)
    False -> candidate
  }
}

fn search_registry(model: Model) -> #(Model, Effect(Msg), String) {
  let query = string.trim(model.query)
  case query {
    "" -> #(
      Model(..model, search: Idle, results: [], next: ""),
      effect.none(),
      "",
    )
    _ ->
      case string.length(query) > 100 {
        True -> #(
          Model(
            ..model,
            search: SearchFailed("Search for up to 100 characters."),
          ),
          effect.none(),
          "",
        )
        False -> #(
          Model(..model, search: Searching, results: [], next: ""),
          registry(query, "", False),
          "",
        )
      }
  }
}

fn registry(query: String, cursor: String, append: Bool) -> Effect(Msg) {
  let path =
    "/api/gateway/registry?search="
    <> uri.percent_encode(query)
    <> case cursor {
      "" -> ""
      _ -> "&cursor=" <> uri.percent_encode(cursor)
    }
  get(path, fn(pair) { RegistryLoaded(append, pair) })
}

fn registry_loaded(
  model: Model,
  append: Bool,
  status: Int,
  body: String,
) -> #(Model, Effect(Msg), String) {
  let query = string.trim(model.query)
  case status {
    200 ->
      case catalog.page_of(body) {
        Ok(page) -> #(
          Model(
            ..model,
            search: Searched(query),
            results: case append {
              True -> list.append(model.results, page.entries)
              False -> page.entries
            },
            next: page.next,
          ),
          effect.none(),
          "",
        )
        Error(_) -> #(
          Model(
            ..model,
            search: SearchFailed("The registry answer was not readable."),
          ),
          effect.none(),
          "",
        )
      }
    0 -> #(
      Model(
        ..model,
        search: SearchFailed(
          "Could not reach Fizzlayer. Check your connection.",
        ),
      ),
      effect.none(),
      "",
    )
    _ -> #(
      Model(
        ..model,
        search: SearchFailed(api.error_message(
          body,
          "The MCP Registry did not answer. Try again, or add the server by URL.",
        )),
      ),
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
  let url = string.trim(model.server_url)
  case writable(model) {
    Error(message) -> #(bad(model, message), effect.none(), "")
    Ok(_) ->
      case
        api.server_name_ok(model.server_name),
        catalog.needs_fill(url),
        api.remote_url_ok(url)
      {
        False, _, _ -> #(
          bad(
            model,
            "Server name must start with a letter and use lowercase letters, digits, hyphens, or underscores.",
          ),
          effect.none(),
          "",
        )
        _, True, _ -> #(
          bad(
            model,
            "Fill in the {…} parts of the URL. The server's docs say what goes there.",
          ),
          effect.none(),
          "",
        )
        _, _, False -> #(
          bad(
            model,
            "Server URL must be http or https, with no username or password in it.",
          ),
          effect.none(),
          "",
        )
        True, False, True ->
          case model.auth_kind == "key" && string.trim(model.api_key) == "" {
            True -> #(
              bad(model, "Paste the server's API key or token."),
              effect.none(),
              "",
            )
            False -> {
              let key = case model.auth_kind {
                "key" -> model.api_key
                _ -> ""
              }
              let kind = model.auth_kind
              #(
                Model(
                  ..model,
                  busy: True,
                  api_key: "",
                  notice: Quiet,
                  upgrade: "",
                ),
                post(
                  servers_url(model.id),
                  api.server_body(
                    model.server_name,
                    url,
                    model.server_transport,
                    kind,
                    key,
                  ),
                  "server",
                ),
                "",
              )
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
  let name = string.trim(model.token_name)
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
  let known = list.any(rows, fn(row) { row.id == model.server_pick })
  let pick = case known, rows {
    True, _ -> model.server_pick
    False, [first, ..] -> first.id
    False, [] -> ""
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
                "The gateway was created, but the registration token was not usable. Rotate it in Settings.",
              )
            _ ->
              Good("Gateway created. Add the first MCP server it should reach.")
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
            route.tab_path(created.id, route.Servers),
          )
        }
      }
    "server" -> {
      // Ask the new server for its tools right away, so they show before any
      // agent connects. New servers allow every tool, so policies reload too.
      let #(tools, ask) = case api.added_server_of(body) {
        Ok(server) -> #(
          dict.insert(model.tools, server.id, ToolsLoading),
          load_tools(model.id, server.id),
        )
        Error(_) -> #(model.tools, effect.none())
      }
      #(
        Model(
          ..model,
          busy: False,
          api_key: "",
          sheet: Closed,
          tools: tools,
          upgrade: "",
          notice: Good(
            "Server added. Every tool on it is allowed. Narrow that in Rules.",
          ),
        ),
        effect.batch([
          load_servers(model.id),
          load_policies(model.id),
          load_pins(model.id),
          ask,
        ]),
        "",
      )
    }
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
                minted_for: model.client,
                minted_name: string.trim(model.token_name),
                token_name: "",
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

/// Ask for the tools of every server whose tools are not known yet.
fn ask_for_tools(model: Model) -> #(Model, Effect(Msg)) {
  let missing =
    list.filter(model.servers, fn(row) { !dict.has_key(model.tools, row.id) })
  #(
    Model(
      ..model,
      tools: list.fold(missing, model.tools, fn(acc, row) {
        dict.insert(acc, row.id, ToolsLoading)
      }),
    ),
    effect.batch(list.map(missing, fn(row) { load_tools(model.id, row.id) })),
  )
}

fn tools_state(status: Int, body: String) -> Tools {
  case status {
    200 ->
      case api.tools_of(body) {
        Ok(tools) -> ToolsLoaded(tools)
        Error(_) -> ToolsFailed("The tool list was not readable.")
      }
    0 -> ToolsFailed("Could not reach Fizzlayer. Check your connection.")
    _ ->
      ToolsFailed(api.error_message(
        body,
        "The server's tools could not be listed.",
      ))
  }
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

fn load_tools(gateway: String, server: String) -> Effect(Msg) {
  get(server_url(gateway, server) <> "/tools", fn(pair) {
    ToolsAnswered(gateway, server, pair)
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

// Views --------------------------------------------------------------------------

pub fn view(model: Model) -> Element(Msg) {
  case model.screen {
    List -> html.div([], [notices(model), list_page(model)])
    Create -> html.div([], [notices(model), create_page(model)])
    Page(tab) -> gateway_page(model, tab)
  }
}

fn notices(model: Model) -> Element(Msg) {
  html.div([], [upgrade_box(model.upgrade), note(model.notice)])
}

// The gateway list ----------------------------------------------------------------

fn list_page(model: Model) -> Element(Msg) {
  let under_limit = case model.plan.gateway_limit {
    api.Unlimited -> True
    api.Limited(cap) -> list.length(model.gateways) < cap
  }
  let new_button =
    ui.link_button(
      ui.Primary,
      route.new_gateway_path,
      ui.with_icon("plus", "New gateway"),
    )
  html.div([attribute.id("step-gateways")], [
    ui.page_head(
      "Gateways",
      "Each gateway is one MCP endpoint for your agents, with its own servers, rules and approvals.",
      case model.gateways, under_limit {
        [], _ | _, False -> []
        _, True -> [new_button]
      },
    ),
    case model.loaded, model.gateways {
      False, _ -> ui.muted("Loading gateways…")
      True, [] ->
        ui.empty_state(
          "shield-halved",
          "Create your first gateway",
          "Point your agent at one gateway URL. Add the MCP servers it may use, choose what each tool can do, and approve risky calls before they run.",
          [new_button],
        )
      True, rows ->
        ui.gateway_grid(
          list.append(list.map(ordered(rows), gateway_card), case under_limit {
            True -> [
              ui.new_card(
                route.new_gateway_path,
                "New gateway",
                "Another endpoint with its own servers and rules.",
              ),
            ]
            False -> []
          }),
        )
    },
    case model.loaded {
      True ->
        ui.muted_content([
          text(
            model.plan.name
            <> " plan: "
            <> int.to_string(list.length(model.gateways))
            <> " of "
            <> api.cap_label(model.plan.gateway_limit)
            <> " gateways, up to "
            <> api.cap_label(model.plan.server_limit)
            <> " MCP servers. ",
          ),
          html.a([attribute.href("/pricing")], [text("Plans and upgrades")]),
        ])
      False -> element.none()
    },
  ])
}

/// Active gateways first, then paused ones, each in the order the API sent.
fn ordered(rows: List(api.GatewayRow)) -> List(api.GatewayRow) {
  let #(active, rest) = list.partition(rows, fn(row) { row.status == "active" })
  list.append(active, rest)
}

fn gateway_card(row: api.GatewayRow) -> Element(Msg) {
  ui.gateway_card(
    route.tab_path(row.id, route.Overview),
    row.name,
    mode_label(row.mode),
    row.status == "active",
    status_label(row.status),
    row.public_url,
  )
}

fn status_label(status: String) -> String {
  case status {
    "active" -> "Active"
    "disabled" -> "Paused"
    other -> string.capitalise(other)
  }
}

fn mode_label(mode: String) -> String {
  case mode {
    "shared" -> "Hosted, shared"
    "selfhost" -> "Self-hosted"
    "dedicated" -> "Hosted, dedicated"
    other -> other
  }
}

// Create ----------------------------------------------------------------------------

fn create_page(model: Model) -> Element(Msg) {
  ui.card([attribute.id("step-create")], [
    html.p([], [
      html.a([attribute.href(route.gateways_path)], [
        ui.icon("arrow-left"),
        text(" All gateways"),
      ]),
    ]),
    ui.panel_head(
      "shield-halved",
      "Create a gateway",
      "A gateway is the one MCP URL your agents use. Next you add the servers behind it.",
      [],
    ),
    hosted_note(model),
    html.form([event.on_submit(fn(_) { SubmitGateway })], [
      ui.field(
        "Gateway name",
        "gateway-name",
        "A lowercase letter, then letters, digits or hyphens. For example home or work.",
        name_input(model),
      ),
      ui.field("Where it runs", "gateway-mode", "", mode_select(model)),
      ui.muted(case model.mode {
        "selfhost" ->
          "You run the gateway with Docker and link it to this account. Your agents use the URL you publish."
        "dedicated" ->
          "A hosted gateway on its own machine. Dedicated gateways on Pro aren't ready yet."
        _ -> "Fizzlayer hosts it. You get a URL at gw.fizzlayer.com right away."
      }),
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
          [attribute.type_("submit"), attribute.disabled(model.busy)],
          ui.with_icon("arrow-right", "Create gateway"),
        ),
        ui.link_button(ui.Quiet, route.gateways_path, [text("Cancel")]),
      ]),
    ]),
    plan_card(model.plan),
  ])
}

fn name_input(model: Model) -> Element(Msg) {
  ui.input([
    attribute.id("gateway-name"),
    attribute.type_("text"),
    attribute.autocomplete("off"),
    attribute.placeholder("home"),
    attribute.value(model.name),
    event.on_input(NameEdited),
  ])
}

fn mode_select(model: Model) -> Element(Msg) {
  ui.select(
    [
      attribute.id("gateway-mode"),
      attribute.disabled(model.busy),
      event.on_change(ModeEdited),
    ],
    [
      option("shared", "Hosted by Fizzlayer (shared)", model.mode == "shared"),
      option("selfhost", "Self-host with Docker", model.mode == "selfhost"),
      case model.plan.dedicated {
        True ->
          option(
            "dedicated",
            "Hosted, dedicated (Pro)",
            model.mode == "dedicated",
          )
        False ->
          html.option(
            [attribute.value("dedicated"), attribute.disabled(True)],
            "Hosted, dedicated (Pro)",
          )
      },
    ],
  )
}

// One gateway -----------------------------------------------------------------------

fn gateway_page(model: Model, tab: Tab) -> Element(Msg) {
  let row = current_gateway(model)
  let name = case row {
    Ok(gateway) -> gateway.name
    Error(_) ->
      case model.name {
        "" -> "Gateway"
        name -> name
      }
  }
  let side =
    ui.side([
      ui.side_head(route.gateways_path, name, case row {
        Ok(gateway) ->
          ui.status_pill(
            gateway.status == "active",
            status_label(gateway.status),
          )
        Error(_) -> element.none()
      }),
      ui.tab_menu(
        "Gateway sections",
        list.map(route.tabs, fn(item) { menu_item(model, item, tab) }),
      ),
    ])
  html.div([attribute.id("gateway-" <> route.tab_slug(tab))], [
    ui.gateway_layout(
      side,
      ui.panel(route.tab_slug(tab), [
        notices(model),
        case row {
          Ok(gateway) if gateway.status == "disabled" ->
            ui.notice_text(
              ui.Bad,
              "This gateway is paused because your plan's gateway limit is reached. Remove a gateway or upgrade to run it again.",
            )
          _ -> element.none()
        },
        case tab {
          route.Overview -> overview_tab(model)
          route.Servers -> servers_tab(model)
          route.Rules -> rules_tab(model)
          route.Approvals -> approvals_tab(model)
          route.Changes -> changes_tab(model)
          route.Connect -> connect_tab(model)
          route.Settings -> settings_tab(model)
        },
      ]),
    ),
    sheet_view(model),
  ])
}

fn menu_item(model: Model, tab: Tab, current: Tab) -> ui.MenuItem {
  let #(icon, label, count, alert) = case tab {
    route.Overview -> #("gauge-high", "Overview", 0, False)
    route.Servers -> #("server", "Servers", list.length(model.servers), False)
    route.Rules -> #("list-check", "Rules", 0, False)
    route.Approvals -> #("hand", "Approvals", list.length(pending(model)), True)
    route.Changes -> #(
      "triangle-exclamation",
      "Tool changes",
      list.length(open_alert_rows(model)),
      True,
    )
    route.Connect -> #("plug", "Connect", 0, False)
    route.Settings -> #("gear", "Settings", 0, False)
  }
  ui.MenuItem(
    href: route.tab_path(model.id, tab),
    icon: icon,
    label: label,
    count: count,
    current: tab == current,
    alert: alert,
  )
}

fn pending(model: Model) -> List(api.ApprovalRow) {
  list.filter(model.approvals, fn(row) { row.status == "pending" })
}

fn open_alert_rows(model: Model) -> List(api.AlertRow) {
  list.filter(model.alerts, fn(row) { !row.acknowledged })
}

fn active_tokens(model: Model) -> List(api.TokenRow) {
  list.filter(model.tokens, fn(row) { !row.revoked })
}

// Overview ------------------------------------------------------------------------

fn overview_tab(model: Model) -> Element(Msg) {
  let url = endpoint_url(model)
  let waiting = pending(model)
  html.div([], [
    ui.panel_head(
      "gauge-high",
      "Overview",
      "Agents call this one URL. Every tool call is checked against your rules before it reaches a server.",
      [],
    ),
    ui.block("Endpoint", [], [
      ui.copy_line(url, [copy_button(url)]),
      ui.muted(case model.hosted, current_mode(model) {
        Up, "shared" ->
          "Hosted by Fizzlayer. Agents need a client token from Connect."
        _, "selfhost" ->
          "Self-hosted. This is the URL you published. Link your gateway with the registration token in Connect."
        _, _ -> "Agents need a client token from Connect to call this URL."
      }),
    ]),
    ui.stat_grid([
      ui.stat(
        route.tab_path(model.id, route.Servers),
        "server",
        list.length(model.servers),
        "Servers",
        False,
      ),
      ui.stat(
        route.tab_path(model.id, route.Rules),
        "list-check",
        list.length(model.policies),
        "Rules",
        False,
      ),
      ui.stat(
        route.tab_path(model.id, route.Approvals),
        "hand",
        list.length(waiting),
        "Waiting for you",
        True,
      ),
      ui.stat(
        route.tab_path(model.id, route.Changes),
        "triangle-exclamation",
        list.length(open_alert_rows(model)),
        "Changed tools",
        True,
      ),
      ui.stat(
        route.tab_path(model.id, route.Connect),
        "key",
        list.length(active_tokens(model)),
        "Client tokens",
        False,
      ),
    ]),
    ui.block("Get started", [], [
      ui.checklist([
        #(
          model.servers != [],
          "Add an MCP server",
          route.tab_path(model.id, route.Servers),
          "Add a server",
        ),
        #(
          model.policies != [],
          "Choose what its tools can do",
          route.tab_path(model.id, route.Rules),
          "Set rules",
        ),
        #(
          active_tokens(model) != [],
          "Connect an agent with a client token",
          route.tab_path(model.id, route.Connect),
          "Connect",
        ),
      ]),
    ]),
    case waiting {
      [] -> element.none()
      rows ->
        ui.block(
          "Waiting for you",
          [
            ui.link_button(
              ui.Quiet,
              route.tab_path(model.id, route.Approvals),
              ui.with_icon("arrow-right", "All approvals"),
            ),
          ],
          [ui.item_list(list.map(list.take(rows, 3), approval_row))],
        )
    },
  ])
}

// Servers --------------------------------------------------------------------------

fn servers_tab(model: Model) -> Element(Msg) {
  html.div([], [
    ui.panel_head(
      "server",
      "Servers",
      "The MCP servers this gateway forwards to. A key you add is stored encrypted and never shown again.",
      [
        ui.button(
          ui.Secondary,
          [attribute.type_("button"), event.on_click(OpenCustom)],
          ui.with_icon("link", "Add by URL"),
        ),
      ],
    ),
    case model.servers {
      [] -> element.none()
      rows ->
        ui.block("Connected", [], [
          ui.item_list(list.map(rows, fn(row) { server_row(model, row) })),
        ])
    },
    ui.block(
      case model.servers {
        [] -> "Add your first server"
        _ -> "Add another server"
      },
      [],
      [
        ui.muted(
          "Pick one from the official MCP Registry, or search all of it. Its tools show up as soon as it is added, and every one is allowed until you narrow it in Rules.",
        ),
        ui.search_bar(
          [event.on_submit(fn(_) { SearchRegistry })],
          [
            attribute.id("registry-search"),
            attribute.placeholder("Search the MCP Registry, for example linear"),
            attribute.value(model.query),
            attribute.autocomplete("off"),
            event.on_input(QueryEdited),
          ],
          "Search",
          model.search == Searching,
        ),
        case model.search {
          Idle -> featured_view(model)
          Searching ->
            case model.results {
              [] -> ui.muted("Searching the MCP Registry…")
              _ -> results_view(model, string.trim(model.query))
            }
          Searched(query) -> results_view(model, query)
          SearchFailed(message) ->
            html.div([], [
              ui.notice_text(ui.Bad, message),
              ui.actions([
                ui.button(
                  ui.Quiet,
                  [attribute.type_("button"), event.on_click(ClearSearch)],
                  ui.with_icon("arrow-left", "Back to featured servers"),
                ),
              ]),
            ])
        },
        ui.muted(
          "Featured servers come from the official MCP Registry and are published by the vendor. They take one API key or none. Servers that need an OAuth sign-in or other headers can't be added yet.",
        ),
      ],
    ),
  ])
}

fn server_row(model: Model, row: api.ServerRow) -> Element(Msg) {
  html.div([], [server_summary(model, row), server_tools(model, row)])
}

/// What the server listed: its tools, a spinner while asking, or the reason it
/// could not be asked, with a retry.
fn server_tools(model: Model, row: api.ServerRow) -> Element(Msg) {
  case dict.get(model.tools, row.id) {
    Error(_) -> element.none()
    Ok(ToolsLoading) ->
      ui.server_tools(
        [
          ui.icon_classes("fa-solid fa-spinner fa-spin"),
          text(" Asking " <> row.name <> " for its tools…"),
        ],
        [],
      )
    Ok(ToolsFailed(message)) ->
      ui.server_tools([ui.icon("triangle-exclamation"), text(" " <> message)], [
        ui.button(
          ui.Quiet,
          [attribute.type_("button"), event.on_click(LoadTools(row.id))],
          ui.with_icon("rotate", "Try again"),
        ),
      ])
    Ok(ToolsLoaded([])) ->
      ui.server_tools([text("The server listed no tools.")], [])
    Ok(ToolsLoaded(tools)) -> {
      let count = list.length(tools)
      let summary =
        int.to_string(count)
        <> case count {
          1 -> " tool"
          _ -> " tools"
        }
        <> " · "
        <> default_rule_label(model, row.id)
      let chips =
        ui.tool_chips(
          list.map(tools, fn(tool) { #(tool.name, tool.description) }),
        )
      ui.server_tools([], [ui.disclosure(summary, count <= 12, [chips])])
    }
  }
}

/// What the server's `*` rule does, in the words of the rule switch.
fn default_rule_label(model: Model, server_id: String) -> String {
  case
    list.find(model.policies, fn(row) {
      row.tool_name == "*" && row.server_id == server_id
    })
  {
    Ok(row) -> rule_label(row.effect) <> " by default"
    Error(_) -> "no default rule, so unlisted tools are blocked"
  }
}

fn server_summary(model: Model, row: api.ServerRow) -> Element(Msg) {
  ui.item_row(
    server_icon(row.url),
    row.name,
    [
      html.code([], [text(row.url)]),
      text(" "),
      case row.has_secret {
        True -> ui.pill(ui.Good, "key", "Key stored")
        False -> ui.pill(ui.Neutral, "lock-open", "No key")
      },
    ],
    [
      ui.button(
        ui.Secondary,
        [
          attribute.type_("button"),
          attribute.disabled(model.busy),
          event.on_click(RulesFor(row.id)),
        ],
        ui.with_icon("list-check", "Rules"),
      ),
      ui.button(
        ui.Danger,
        [
          attribute.type_("button"),
          attribute.disabled(model.busy),
          event.on_click(RemoveServer(row.id)),
        ],
        ui.with_icon("trash", "Remove"),
      ),
    ],
  )
}

/// A featured server's icon when its URL matches, otherwise a server.
fn server_icon(url: String) -> String {
  case list.find(catalog.featured(), fn(entry) { entry.url == url }) {
    Ok(entry) -> entry.icon
    Error(_) -> "fa-solid fa-server"
  }
}

fn featured_view(model: Model) -> Element(Msg) {
  let entries = catalog.in_category(catalog.featured(), model.category)
  html.div([], [
    ui.chips(
      "Categories",
      list.map(catalog.categories, fn(item) {
        let #(key, label) = item
        #(label, model.category == key, event.on_click(CategoryPicked(key)))
      }),
    ),
    ui.catalog_grid([
      #("custom", ui.custom_card([event.on_click(OpenCustom)])),
      ..list.index_map(entries, fn(entry, index) {
        #(entry.id, catalog_card(model, entry, index + 1))
      })
    ]),
  ])
}

fn results_view(model: Model, query: String) -> Element(Msg) {
  html.div([], [
    ui.block(
      "Registry results for “" <> query <> "”",
      [
        ui.button(
          ui.Quiet,
          [attribute.type_("button"), event.on_click(ClearSearch)],
          ui.with_icon("xmark", "Clear"),
        ),
      ],
      [
        case model.results, model.search {
          [], Searched(_) ->
            ui.empty_state(
              "magnifying-glass",
              "No remote servers found",
              "Only servers with a remote URL are listed. Try another word, or add the server by URL.",
              [
                ui.button(
                  ui.Secondary,
                  [attribute.type_("button"), event.on_click(OpenCustom)],
                  ui.with_icon("link", "Add by URL"),
                ),
              ],
            )
          rows, _ ->
            ui.catalog_grid(
              list.index_map(rows, fn(entry, index) {
                #(
                  entry.id <> " " <> entry.url,
                  catalog_card(model, entry, index),
                )
              }),
            )
        },
        case model.next, model.search {
          "", _ -> element.none()
          _, Searching ->
            ui.actions([
              ui.button(
                ui.Secondary,
                [attribute.type_("button"), attribute.disabled(True)],
                [
                  ui.icon_classes("fa-solid fa-spinner fa-spin"),
                  text("Loading"),
                ],
              ),
            ])
          _, _ ->
            ui.actions([
              ui.button(
                ui.Secondary,
                [attribute.type_("button"), event.on_click(MoreResults)],
                ui.with_icon("angles-down", "Load more"),
              ),
            ])
        },
      ],
    ),
  ])
}

fn catalog_card(
  model: Model,
  entry: catalog.Entry,
  index: Int,
) -> Element(Msg) {
  let added = list.any(model.servers, fn(row) { row.url == entry.url })
  let source = case entry.category {
    "registry" -> entry.id
    _ -> "MCP Registry · " <> entry.id
  }
  ui.catalog_card(
    index,
    entry.icon,
    entry.title,
    source,
    case entry.description {
      "" -> "No description in the registry."
      description -> description
    },
    [
      auth_pill(entry.auth),
      case added, catalog.addable(entry) {
        True, _ -> ui.pill(ui.Good, "check", "Added")
        _, False ->
          ui.button(
            ui.Secondary,
            [attribute.type_("button"), attribute.disabled(True)],
            [text("Not supported yet")],
          )
        _, True ->
          ui.button(
            ui.Primary,
            [
              attribute.type_("button"),
              attribute.disabled(model.busy),
              attribute.aria_label("Add " <> entry.title),
              event.on_click(OpenEntry(entry)),
            ],
            ui.with_icon("plus", "Add"),
          )
      },
    ],
  )
}

fn auth_pill(auth: catalog.Auth) -> Element(Msg) {
  case auth {
    catalog.KeyRequired -> ui.pill(ui.Neutral, "key", catalog.auth_label(auth))
    catalog.KeyOptional -> ui.pill(ui.Neutral, "key", catalog.auth_label(auth))
    catalog.NoKey -> ui.pill(ui.Good, "lock-open", catalog.auth_label(auth))
    catalog.OtherHeaders(names) ->
      ui.pill(ui.Caution, "ban", "Needs " <> string.join(names, ", "))
  }
}

fn sheet_view(model: Model) -> Element(Msg) {
  case model.sheet {
    Closed -> element.none()
    Custom ->
      ui.sheet("Add a server by URL", "fa-solid fa-link", close_sheet(), [
        ui.muted(
          "Any remote MCP server that speaks streamable HTTP or SSE. Servers that need an OAuth sign-in can't be added yet.",
        ),
        server_form(model, ""),
      ])
    FromCatalog(entry) ->
      ui.sheet("Add " <> entry.title, entry.icon, close_sheet(), [
        html.p([], [text(entry.description)]),
        ui.muted_content([
          text("From the official MCP Registry: "),
          html.code([], [text(entry.id)]),
          case entry.website {
            "" -> element.none()
            site ->
              html.span([], [
                text(" · "),
                html.a(
                  [
                    attribute.href(site),
                    attribute.target("_blank"),
                    attribute.rel("noopener noreferrer"),
                  ],
                  [text("Docs "), ui.icon("arrow-up-right-from-square")],
                ),
              ])
          },
        ]),
        server_form(model, entry.key_hint),
      ])
  }
}

fn close_sheet() -> List(attribute.Attribute(Msg)) {
  [event.on_click(CloseSheet)]
}

fn server_form(model: Model, key_hint: String) -> Element(Msg) {
  html.form([event.on_submit(fn(_) { SubmitServer })], [
    ui.field(
      "Name",
      "server-name",
      "Agents see it before each tool name. Lowercase letters, digits, hyphens or underscores.",
      text_input("server-name", model.server_name, "github", ServerNameEdited),
    ),
    ui.field(
      "Server URL",
      "server-url",
      case catalog.needs_fill(model.server_url) {
        True -> "Replace each {…} part. The server's docs say what goes there."
        False -> ""
      },
      text_input(
        "server-url",
        model.server_url,
        "https://example.com/mcp",
        ServerUrlEdited,
      ),
    ),
    ui.field(
      "Credential",
      "auth-kind",
      "",
      ui.select(
        [
          attribute.id("auth-kind"),
          attribute.disabled(model.busy),
          event.on_change(AuthKindEdited),
        ],
        [
          option("none", "No credential", model.auth_kind == "none"),
          option("key", "API key or token", model.auth_kind == "key"),
          option(
            "passthrough",
            "Pass the agent's own token through",
            model.auth_kind == "passthrough",
          ),
        ],
      ),
    ),
    case model.auth_kind == "key" {
      True ->
        ui.field(
          "API key or token",
          "api-key",
          case key_hint {
            "" ->
              "Stored encrypted and sent as Authorization: Bearer. It is not shown again."
            hint -> hint <> " Stored encrypted and not shown again."
          },
          ui.input([
            attribute.id("api-key"),
            attribute.type_("password"),
            attribute.autocomplete("off"),
            attribute.value(model.api_key),
            event.on_input(ApiKeyEdited),
          ]),
        )
      False -> element.none()
    },
    ui.actions([
      ui.button(
        ui.Primary,
        [attribute.type_("submit"), attribute.disabled(model.busy)],
        case model.busy {
          True -> [
            ui.icon_classes("fa-solid fa-spinner fa-spin"),
            text("Adding"),
          ]
          False -> ui.with_icon("plus", "Add server")
        },
      ),
      ui.button(
        ui.Quiet,
        [attribute.type_("button"), event.on_click(CloseSheet)],
        [text("Cancel")],
      ),
    ]),
    // Last in the form, beside the button that caused it. A conditional
    // first child would also shift the prerendered fields on hydration.
    case model.notice {
      Bad(message) -> ui.notice_text(ui.Bad, message)
      _ -> element.none()
    },
  ])
}

// Rules ----------------------------------------------------------------------------

fn rules_tab(model: Model) -> Element(Msg) {
  html.div([attribute.id("step-tools")], [
    ui.panel_head(
      "list-check",
      "Rules for each tool",
      "Allow runs the tool. Block stops it. Ask first holds each call until you approve it, then the agent tries again. A new server starts with every tool allowed.",
      [],
    ),
    case model.servers {
      [] ->
        ui.empty_state(
          "server",
          "Add a server first",
          "Rules apply to the tools of a server on this gateway.",
          [
            ui.link_button(
              ui.Primary,
              route.tab_path(model.id, route.Servers),
              ui.with_icon("plus", "Add a server"),
            ),
          ],
        )
      rows ->
        html.div([], [
          ui.chips(
            "Server",
            list.map(rows, fn(row) {
              #(
                row.name,
                row.id == model.server_pick,
                event.on_click(ServerPicked(row.id)),
              )
            }),
          ),
          channel_field(model),
          case dict.get(model.tools, model.server_pick) {
            Ok(ToolsLoading) -> ui.muted("Asking the server for its tools…")
            Ok(ToolsFailed(message)) ->
              html.div([], [
                ui.notice_text(ui.Caution, message),
                ui.actions([
                  ui.button(
                    ui.Quiet,
                    [
                      attribute.type_("button"),
                      event.on_click(LoadTools(model.server_pick)),
                    ],
                    ui.with_icon("rotate", "Try again"),
                  ),
                ]),
              ])
            _ -> element.none()
          },
          ui.item_list([
            tool_row(model, "*"),
            ..list.map(tool_names(model), fn(name) { tool_row(model, name) })
          ]),
          case tool_names(model) {
            [] ->
              ui.muted(
                "The server has not listed any tools. You can still type a tool name below.",
              )
            _ -> element.none()
          },
          html.form([event.on_submit(fn(_) { SaveNamedTool })], [
            field(
              "Rule for a tool by name",
              "tool-name",
              model.tool_name,
              "create_issue",
              False,
              ToolEdited,
            ),
            ui.field(
              "Rule",
              "tool-effect",
              "",
              ui.select(
                [attribute.id("tool-effect"), event.on_change(EffectEdited)],
                [
                  option("allow", rule_label("allow"), model.effect == "allow"),
                  option("deny", rule_label("deny"), model.effect == "deny"),
                  option(
                    "approve",
                    rule_label("approve"),
                    model.effect == "approve",
                  ),
                ],
              ),
            ),
            ui.actions([
              ui.button(
                ui.Secondary,
                [attribute.type_("submit"), attribute.disabled(model.busy)],
                ui.with_icon("floppy-disk", "Save rule"),
              ),
            ]),
          ]),
        ])
    },
  ])
}

fn tool_row(model: Model, name: String) -> Element(Msg) {
  let title = case name {
    "*" -> "Every tool (default)"
    _ -> name
  }
  ui.item_row(
    case name {
      "*" -> "fa-solid fa-layer-group"
      _ -> "fa-solid fa-wrench"
    },
    title,
    [
      text(policy_label(model, name)),
      case tool_description(model, name) {
        "" -> element.none()
        description -> html.p([], [text(description)])
      },
    ],
    [
      ui.rule_switch("Rule for " <> title, [
        rule_option(model, name, "allow", "check"),
        rule_option(model, name, "deny", "ban"),
        rule_option(model, name, "approve", "hand"),
      ]),
    ],
  )
}

fn rule_option(
  model: Model,
  tool: String,
  effect_name: String,
  icon: String,
) -> #(String, String, String, Bool, List(attribute.Attribute(Msg))) {
  #(
    effect_name,
    icon,
    rule_label(effect_name),
    current_effect(model, tool) == Ok(effect_name),
    [
      attribute.disabled(model.busy),
      event.on_click(SavePolicy(model.server_pick, tool, effect_name)),
    ],
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
    Error(_) ->
      case tool, current_policy(model, "*") {
        "*", _ -> "No default yet, so tools without a rule are blocked"
        _, Ok(default) -> rule_label(default.effect) <> ", from Every tool"
        _, Error(_) -> "No rule yet, so it is blocked"
      }
  }
}

/// The tools the picked server listed, if it has answered.
fn listed_tools(model: Model) -> List(api.Tool) {
  case dict.get(model.tools, model.server_pick) {
    Ok(ToolsLoaded(tools)) -> tools
    _ -> []
  }
}

fn tool_description(model: Model, name: String) -> String {
  case list.find(listed_tools(model), fn(tool) { tool.name == name }) {
    Ok(tool) -> tool.description
    Error(_) -> ""
  }
}

fn tool_names(model: Model) -> List(String) {
  let server = case
    list.find(model.servers, fn(row) { row.id == model.server_pick })
  {
    Ok(row) -> row.name
    Error(_) -> ""
  }
  unique(
    list.flatten([
      list.map(listed_tools(model), fn(tool) { tool.name }),
      list.filter_map(model.pins, fn(row) {
        case server == "" || row.server_name == server {
          True -> Ok(row.tool_name)
          False -> Error(Nil)
        }
      }),
      list.filter_map(model.policies, fn(row) {
        case row.tool_name, row.server_id == model.server_pick {
          "*", _ | "", _ -> Error(Nil)
          name, True -> Ok(name)
          _, False -> Error(Nil)
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

fn channel_field(model: Model) -> Element(Msg) {
  html.div([], [
    ui.field(
      "When a tool asks first, notify by",
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

// Approvals ------------------------------------------------------------------------

fn approvals_tab(model: Model) -> Element(Msg) {
  let decided =
    list.filter(model.approvals, fn(row) { row.status != "pending" })
  html.div([attribute.id("step-approvals")], [
    ui.panel_head(
      "hand",
      "Approvals",
      "Calls held by an Ask first rule. Approving lets that same call through once. The agent has to retry it.",
      [
        ui.button(
          ui.Secondary,
          [attribute.type_("button"), event.on_click(RefreshApprovals)],
          ui.with_icon("rotate", "Refresh"),
        ),
      ],
    ),
    case pending(model) {
      [] ->
        ui.empty_state(
          "circle-check",
          "No pending approvals",
          "When an agent calls a tool set to Ask first, the call waits here until you decide.",
          [],
        )
      rows -> ui.item_list(list.map(rows, approval_row))
    },
    case decided {
      [] -> element.none()
      rows ->
        ui.block("Decided", [], [
          ui.item_list(
            list.map(list.take(rows, 10), fn(row) {
              ui.item_row(
                "fa-solid fa-clock-rotate-left",
                row.tool_name,
                [
                  text(row.server_name <> " · "),
                  case row.status {
                    "approved" -> ui.pill(ui.Good, "check", "Approved")
                    "denied" -> ui.pill(ui.Bad, "xmark", "Rejected")
                    other -> ui.pill(ui.Neutral, "clock", other)
                  },
                ],
                [],
              )
            }),
          ),
        ])
    },
  ])
}

fn approval_row(row: api.ApprovalRow) -> Element(Msg) {
  ui.item_row(
    "fa-solid fa-hand",
    row.tool_name,
    [
      text(row.server_name),
      case row.args_preview {
        "" -> element.none()
        args -> html.span([], [text(" · arguments: " <> args)])
      },
    ],
    [
      ui.button(
        ui.Primary,
        [attribute.type_("button"), event.on_click(Decide(row.id, "approved"))],
        ui.with_icon("check", "Approve"),
      ),
      ui.button(
        ui.Secondary,
        [attribute.type_("button"), event.on_click(Decide(row.id, "denied"))],
        ui.with_icon("xmark", "Reject"),
      ),
    ],
  )
}

// Tool changes ------------------------------------------------------------------------

fn changes_tab(model: Model) -> Element(Msg) {
  html.div([attribute.id("step-alerts")], [
    ui.panel_head(
      "triangle-exclamation",
      "Tool changes",
      "The gateway pins each tool's description. If a server changes it, the tool is hidden until you approve the new text.",
      [],
    ),
    ui.block("Changed tools", [], [
      ui.muted(
        "The description is text from the MCP server. Treat it as untrusted. Approving stores the new text. Dismiss only hides the alert.",
      ),
      open_alerts(model),
    ]),
    ui.block("Pinned tools", [], [
      case model.pins {
        [] ->
          ui.muted(
            "Nothing is pinned yet. Pins show up after the gateway lists a server's tools.",
          )
        rows -> ui.item_list(list.map(rows, pin_row))
      },
    ]),
  ])
}

fn pin_row(row: api.PinRow) -> Element(Msg) {
  ui.item_row(
    "fa-solid fa-thumbtack",
    row.server_name <> " / " <> row.tool_name,
    [
      case row.status {
        "approved" -> ui.pill(ui.Good, "check", "Approved")
        "changed" -> ui.pill(ui.Caution, "triangle-exclamation", "Changed")
        other ->
          ui.pill(ui.Neutral, "circle-question", string.capitalise(other))
      },
    ],
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
            ui.with_icon("check", "Approve pin"),
          )
      },
    ],
  )
}

fn open_alerts(model: Model) -> Element(Msg) {
  case open_alert_rows(model) {
    [] -> ui.pill(ui.Good, "circle-check", "No changed tools")
    rows ->
      ui.item_list(
        list.map(rows, fn(row) {
          ui.item_row(
            "fa-solid fa-triangle-exclamation",
            row.server_name <> " / " <> row.tool_name,
            [html.p([], [text(row.preview)])],
            [
              ui.button(
                ui.Primary,
                [
                  attribute.type_("button"),
                  event.on_click(ApprovePin(row.server_name, row.tool_name)),
                ],
                ui.with_icon("check", "Approve the new description"),
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

// Connect ------------------------------------------------------------------------

fn connect_tab(model: Model) -> Element(Msg) {
  let hosted = model.hosted == Up && current_mode(model) != "selfhost"
  let url =
    clients.endpoint(
      model.hosted == Up,
      current_mode(model),
      current_public_url(model),
    )
  let label = client_label(model.client)
  html.div([attribute.id("step-client")], [
    ui.panel_head(
      "plug",
      "Connect an agent",
      "Pick the app your agent runs in. Fizzlayer makes a token for it and fills in the setup.",
      [],
    ),
    case hosted {
      True ->
        ui.block("Gateway URL", [], [
          ui.copy_line(current_public_url(model), [
            copy_button(current_public_url(model)),
          ]),
        ])
      False -> ui.block("Run it yourself", [], [self_host(model)])
    },
    ui.block("Pick your app", [], [
      ui.client_picker(
        "MCP clients",
        list.map(client_keys, fn(key) {
          let #(icon, detail) = client_meta(key)
          ui.ClientChoice(
            icon: icon,
            label: client_label(key),
            detail: detail,
            current: key == model.client,
            on_pick: event.on_click(ClientPicked(key)),
          )
        }),
      ),
    ]),
    ui.block(
      case model.client {
        "other" -> "Add Fizzlayer to any MCP client"
        _ -> "Add Fizzlayer to " <> label
      },
      [],
      [
        case
          model.client,
          api.client_token_ok(model.minted) && model.minted_for == model.client
        {
          "chatgpt", _ -> chatgpt_note()
          _, False -> token_form(model, label)
          key, True ->
            html.div([], [
              ui.muted("Using the token named " <> model.minted_name <> "."),
              ui.setup_steps(client_steps(key, url, model.minted, hosted)),
              ui.muted(
                "This token is shown once. Copy the setup now, or create another token later.",
              ),
            ])
        },
      ],
    ),
    ui.block("Tokens", [], [
      case model.tokens {
        [] -> ui.muted("No client tokens yet.")
        rows -> ui.item_list(list.map(rows, token_row))
      },
    ]),
  ])
}

/// Name a new client token, then create it.
fn token_form(model: Model, label: String) -> Element(Msg) {
  html.form([event.on_submit(fn(_) { MintToken })], [
    ui.muted(
      "Each app gets its own client token. It is shown once, and you can revoke it below without touching the others.",
    ),
    field(
      "Token name",
      "token-name",
      model.token_name,
      case model.client {
        "other" -> "My MCP client"
        _ -> label <> " on my laptop"
      },
      False,
      TokenNameEdited,
    ),
    ui.actions([
      ui.button(
        ui.Primary,
        [
          attribute.type_("submit"),
          attribute.disabled(model.busy || string.trim(model.token_name) == ""),
        ],
        ui.with_icon("key", "Create token"),
      ),
    ]),
  ])
}

const client_keys = [
  "claude-code", "claude", "chatgpt", "cursor", "vscode", "codex", "gemini",
  "hermes", "other",
]

fn client_label(key: String) -> String {
  case key {
    "claude-code" -> "Claude Code"
    "claude" -> "Claude"
    "chatgpt" -> "ChatGPT"
    "cursor" -> "Cursor"
    "vscode" -> "VS Code"
    "codex" -> "Codex"
    "gemini" -> "Gemini CLI"
    "hermes" -> "Hermes Agent"
    _ -> "Any MCP client"
  }
}

/// Icon classes and the one-line hint under each client.
fn client_meta(key: String) -> #(String, String) {
  case key {
    "claude-code" -> #("fa-solid fa-terminal", "One command")
    "claude" -> #("fa-solid fa-comments", "Web, desktop and mobile")
    "chatgpt" -> #("fa-solid fa-message", "Not yet")
    "cursor" -> #("fa-solid fa-i-cursor", "One-click install")
    "vscode" -> #("fa-solid fa-code", "mcp.json")
    "codex" -> #("fa-solid fa-laptop-code", "One command")
    "gemini" -> #("fa-brands fa-google", "One command")
    "hermes" -> #("fa-solid fa-feather-pointed", "config.yaml")
    _ -> #("fa-solid fa-plug", "URL and header")
  }
}

/// The steps for one client, filled with the gateway URL and a fresh token.
fn client_steps(
  key: String,
  url: String,
  token: String,
  hosted: Bool,
) -> List(#(String, List(Element(Msg)))) {
  case key {
    "claude-code" -> [
      #("Run this in a terminal.", [
        snippet("Terminal", clients.claude_code(url, token)),
      ]),
      #(
        "In Claude Code, run /mcp. The fizzlayer server lists your gateway's tools.",
        [],
      ),
    ]
    "claude" -> [
      #(
        "In Claude, open Settings, then Connectors, then Add custom connector.",
        [
          case hosted {
            True -> element.none()
            False ->
              ui.muted(
                "Claude connects from Anthropic's servers, so it needs a public gateway URL, not 127.0.0.1.",
              )
          },
        ],
      ),
      #("Name it Fizzlayer and paste this URL.", [
        ui.copy_line(url, [copy_button(url)]),
      ]),
      #("Under Request headers, add Authorization with this value.", [
        ui.copy_line(clients.bearer(token), [copy_button(clients.bearer(token))]),
      ]),
      #(
        "Save, then turn the connector on in a chat. It works in Claude on the web, desktop and mobile.",
        [],
      ),
    ]
    "cursor" -> [
      #("Install it in one click. Cursor asks before it adds the server.", [
        ui.actions([
          ui.link_button(
            ui.Primary,
            clients.cursor_link(url, token),
            ui.with_icon("arrow-up-right-from-square", "Add to Cursor"),
          ),
        ]),
      ]),
      #("Or add it to ~/.cursor/mcp.json by hand.", [
        snippet("mcp.json", clients.cursor(url, token)),
      ]),
    ]
    "vscode" -> [
      #(
        "Add this to .vscode/mcp.json in a project, or to the file MCP: Open User Configuration opens.",
        [snippet("mcp.json", clients.vscode(url, token))],
      ),
      #("Start fizzlayer from the MCP servers list in VS Code.", []),
    ]
    "codex" -> [
      #(
        "Run this in a terminal. Codex reads the token from FIZZLAYER_TOKEN, so add the export line to your shell profile too.",
        [snippet("Terminal", clients.codex(url, token))],
      ),
    ]
    "gemini" -> [
      #("Run this in a terminal.", [
        snippet("Terminal", clients.gemini(url, token)),
      ]),
      #("In Gemini CLI, run /mcp to check that fizzlayer is connected.", []),
    ]
    "hermes" -> [
      #("Add this to ~/.hermes/config.yaml.", [
        snippet("config.yaml", clients.hermes(url, token)),
      ]),
      #("In a Hermes chat, run /reload-mcp.", []),
    ]
    _ -> [
      #(
        "Use streamable HTTP with this URL and header. Any MCP client that can send a header works.",
        [snippet("Connection", clients.generic(url, token))],
      ),
    ]
  }
}

fn chatgpt_note() -> Element(Msg) {
  html.div([], [
    html.p([], [
      text(
        "ChatGPT's connector form signs in with OAuth or with nothing. It has no place for the token a Fizzlayer gateway checks, so ChatGPT cannot connect to it yet.",
      ),
    ]),
    ui.muted(
      "Codex, OpenAI's coding agent, can connect today. Pick Codex above.",
    ),
  ])
}

fn self_host(model: Model) -> Element(Msg) {
  html.div([attribute.id("self-host")], [
    html.p([], [
      text(case current_mode(model) {
        "selfhost" ->
          "This gateway runs on your machine. Link it to this account with the registration token."
        _ ->
          "The shared host is not answering yet, so this gateway has no public MCP URL to hand a client. Run it yourself and link it with the registration token."
      }),
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
            ui.with_icon("rotate", "Rotate registration token"),
          ),
        ]),
      ])
    True ->
      ui.snippet("Registration token, for fizz-agent only", model.registration, [
        copy_button(model.registration),
      ])
  }
}

fn snippet(title: String, body: String) -> Element(Msg) {
  ui.snippet(title, body, [copy_button(body)])
}

fn copy_button(value: String) -> Element(Msg) {
  ui.button(
    ui.Secondary,
    [attribute.type_("button"), event.on_click(Copy(value))],
    ui.with_icon("copy", "Copy"),
  )
}

fn token_row(row: api.TokenRow) -> Element(Msg) {
  ui.item_row(
    "fa-solid fa-key",
    row.name,
    [
      case row.revoked {
        True -> ui.pill(ui.Neutral, "ban", "Revoked")
        False -> ui.pill(ui.Good, "check", "Active")
      },
    ],
    [
      case row.revoked {
        True -> element.none()
        False ->
          ui.button(
            ui.Danger,
            [attribute.type_("button"), event.on_click(RevokeToken(row.id))],
            ui.with_icon("ban", "Revoke"),
          )
      },
    ],
  )
}

// Settings ------------------------------------------------------------------------

fn settings_tab(model: Model) -> Element(Msg) {
  let row = current_gateway(model)
  html.div([attribute.id("step-settings")], [
    ui.panel_head("gear", "Settings", "", []),
    ui.block("This gateway", [], [
      ui.facts([
        #(
          "Name",
          text(case row {
            Ok(gateway) -> gateway.name
            Error(_) -> model.name
          }),
        ),
        #("Where it runs", text(mode_label(current_mode(model)))),
        #("Status", case row {
          Ok(gateway) ->
            ui.status_pill(
              gateway.status == "active",
              status_label(gateway.status),
            )
          Error(_) -> text("…")
        }),
        #("URL", html.code([], [text(current_public_url(model))])),
      ]),
    ]),
    plan_card(model.plan),
    ui.danger_zone([
      html.h2([], [ui.icon("triangle-exclamation"), text(" Delete gateway")]),
      html.p([], [
        text(
          "Deletes the gateway, its servers, rules and tokens. Agents using its URL stop working.",
        ),
      ]),
      case model.confirm_delete {
        False ->
          ui.button(
            ui.Danger,
            [attribute.type_("button"), event.on_click(AskDelete)],
            ui.with_icon("trash", "Delete gateway"),
          )
        True ->
          ui.actions([
            ui.button(
              ui.Danger,
              [
                attribute.type_("button"),
                attribute.disabled(model.busy),
                event.on_click(DeleteGateway),
              ],
              ui.with_icon("trash", "Yes, delete it"),
            ),
            ui.button(
              ui.Quiet,
              [attribute.type_("button"), event.on_click(CancelDelete)],
              [text("Keep it")],
            ),
          ])
      },
    ]),
  ])
}

// Shared pieces ------------------------------------------------------------------

fn hosted_note(model: Model) -> Element(Msg) {
  case model.hosted {
    Unknown -> ui.muted("Checking whether the shared gateway is up…")
    Up -> ui.pill(ui.Good, "circle-check", "Hosted gateways are up")
    Down ->
      html.p([], [
        text(
          "The shared host is not answering yet. You can still save the gateway, servers, and rules. Connect shows how to run it yourself.",
        ),
      ])
  }
}

fn plan_card(plan: api.Plan) -> Element(Msg) {
  ui.plan([attribute.id("plan-limits")], [
    html.h2([], [text(plan.name <> " plan")]),
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

fn text_input(
  id: String,
  value: String,
  placeholder: String,
  msg: fn(String) -> Msg,
) -> Element(Msg) {
  ui.input([
    attribute.id(id),
    attribute.type_("text"),
    attribute.autocomplete("off"),
    attribute.placeholder(placeholder),
    attribute.value(value),
    event.on_input(msg),
  ])
}

fn option(value: String, label: String, selected: Bool) -> Element(Msg) {
  html.option([attribute.value(value), attribute.selected(selected)], label)
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

/// The URL to show on Overview: the hosted URL for a shared gateway, the
/// published one for a self-hosted gateway.
fn endpoint_url(model: Model) -> String {
  case current_public_url(model) {
    "" -> "No URL yet"
    url -> url
  }
}

// Example data for /app/preview/<name> --------------------------------------------

pub fn preview(name: String) -> Model {
  let id = "11111111-1111-4111-8111-111111111111"
  let base =
    Model(
      ..empty(),
      loaded: True,
      hosted: Down,
      id: id,
      details_id: id,
      name: "home",
      mode: "shared",
      public_url: "https://gw.fizzlayer.com/w/" <> id <> "/mcp",
      registration: "fizz_reg_" <> string.repeat("ab", 32),
      minted: "eyJhbGciOiJub25lIn0.eyJzdWIiOiJleGFtcGxlIn0.e30",
      minted_for: "claude-code",
      minted_name: "Claude Code on laptop",
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
          url: "https://api.githubcopilot.com/mcp/",
          transport: "http",
          auth_kind: "key",
          has_secret: True,
          enabled: True,
        ),
      ],
      server_pick: "22222222-2222-4222-8222-222222222222",
      tools: dict.from_list([
        #(
          "22222222-2222-4222-8222-222222222222",
          ToolsLoaded([
            api.Tool("ping", "Checks that the server answers."),
            api.Tool("create_issue", "Opens an issue in a repository."),
            api.Tool("move_funds", "Moves money between accounts."),
          ]),
        ),
      ]),
      policies: [
        api.PolicyRow(
          id: "33333333-3333-4333-8333-333333333334",
          server_id: "22222222-2222-4222-8222-222222222222",
          tool_name: "*",
          effect: "allow",
          notify_channel: "log",
        ),
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
      server_url: "https://api.githubcopilot.com/mcp/",
    )
  let quiet = Model(..base, registration: "", minted: "", api_key: "")
  case name {
    "gateways" | "choose" -> Model(..quiet, screen: List)
    "empty" -> Model(..quiet, screen: List, gateways: [])
    "create" -> Model(..quiet, screen: Create, id: "", details_id: "")
    "overview" -> Model(..quiet, screen: Page(route.Overview))
    "server" | "servers" -> Model(..quiet, screen: Page(route.Servers))
    "add-server" ->
      case catalog.featured() {
        [first, ..] ->
          Model(
            ..quiet,
            screen: Page(route.Servers),
            sheet: FromCatalog(first),
            server_name: "github-2",
          )
        [] -> Model(..quiet, screen: Page(route.Servers), sheet: Custom)
      }
    "tools" -> Model(..quiet, screen: Page(route.Rules))
    "tools-pro" ->
      Model(
        ..quiet,
        screen: Page(route.Rules),
        plan: api.Plan(
          ..api.hobbyist(),
          id: "pro",
          name: "Pro",
          phone_calls: api.Limited(100),
          dedicated: True,
          stdio: True,
        ),
      )
    "pin" | "alerts" -> Model(..quiet, screen: Page(route.Changes))
    "client" -> Model(..base, screen: Page(route.Connect))
    "client-hosted" -> Model(..base, screen: Page(route.Connect), hosted: Up)
    "approvals" -> Model(..quiet, screen: Page(route.Approvals))
    "tokens" -> Model(..base, screen: Page(route.Connect), minted: "")
    "settings" -> Model(..quiet, screen: Page(route.Settings))
    "limit" ->
      Model(
        ..quiet,
        screen: Create,
        id: "",
        details_id: "",
        upgrade: "Your plan's gateway limit is reached. Hobbyist and Tinkerer include 1 shared gateway, and Pro includes 1 dedicated gateway. Remove a gateway or upgrade.",
      )
    _ -> Model(..quiet, screen: List)
  }
}
