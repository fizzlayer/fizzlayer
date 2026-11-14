import gleam/list
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html

/// What the public checks can say. The scheduler is never included in those checks.
pub type Health {
  Operational
  Degraded
  Unavailable
  Unreported
}

pub type Row {
  Row(name: String, health: Health, detail: String)
}

pub type Phase {
  Checking
  Reported(rows: List(Row), checked: String)
}

pub type Msg {
  Loaded(
    api_failed: Bool,
    status: String,
    database: String,
    stream_failed: Bool,
    enabled: Bool,
    when: String,
  )
}

pub fn api_row(failed: Bool, status: String, database: String) -> Row {
  case failed {
    True ->
      Row(
        name: "API",
        health: Unavailable,
        detail: "The status check did not answer.",
      )
    False ->
      case status == "ok" {
        True ->
          Row(
            name: "API",
            health: Operational,
            detail: database_detail(database),
          )
        False ->
          Row(name: "API", health: Degraded, detail: database_detail(database))
      }
  }
}

pub fn scheduler_row() -> Row {
  Row(
    name: "Alert scheduler",
    health: Unreported,
    detail: "The public status check does not include silence scans or queued calls.",
  )
}

pub fn stream_row(failed: Bool, enabled: Bool) -> Row {
  case failed {
    True ->
      Row(
        name: "Live streaming",
        health: Unavailable,
        detail: "The stream check did not answer.",
      )
    False ->
      case enabled {
        True ->
          Row(
            name: "Live streaming",
            health: Operational,
            detail: "WebSocket and MQTT-over-WebSocket addresses are available.",
          )
        False ->
          Row(
            name: "Live streaming",
            health: Degraded,
            detail: "Live streaming is not configured.",
          )
      }
  }
}

pub fn report_rows(
  api_failed: Bool,
  status: String,
  database: String,
  stream_failed: Bool,
  enabled: Bool,
) -> List(Row) {
  [
    api_row(api_failed, status, database),
    scheduler_row(),
    stream_row(stream_failed, enabled),
  ]
}

pub fn checked_line(when: String) -> String {
  "Checked just now from this browser ("
  <> when
  <> "). This page does not keep an uptime history or state an SLA."
}

pub fn health_name(health: Health) -> String {
  case health {
    Operational -> "operational"
    Degraded -> "degraded"
    Unavailable -> "unavailable"
    Unreported -> "unreported"
  }
}

pub fn health_label(health: Health) -> String {
  case health {
    Operational -> "Operational"
    Degraded -> "Degraded"
    Unavailable -> "Unavailable"
    Unreported -> "Not reported"
  }
}

pub fn init(_flags: Nil) -> #(Phase, Effect(Msg)) {
  #(Checking, load_reports())
}

pub fn update(_phase: Phase, message: Msg) -> #(Phase, Effect(Msg)) {
  case message {
    Loaded(api_failed, status, database, stream_failed, enabled, when) -> #(
      Reported(
        rows: report_rows(api_failed, status, database, stream_failed, enabled),
        checked: checked_line(when),
      ),
      effect.none(),
    )
  }
}

pub fn view(phase: Phase) -> Element(Msg) {
  element.fragment([
    html.ul(
      [attribute.class("status-list"), attribute.id("status-list")],
      case phase {
        Checking -> [checking_item()]
        Reported(rows:, ..) -> list.map(rows, reported_item)
      },
    ),
    html.p(
      [
        attribute.class("status-checked"),
        attribute.id("status-checked"),
        attribute.role("status"),
      ],
      [
        element.text(case phase {
          Checking -> ""
          Reported(checked:, ..) -> checked
        }),
      ],
    ),
  ])
}

pub fn install() -> Nil {
  let app = lustre.application(init, update, view)
  case lustre.start(app, "#status-app", Nil) {
    Ok(_) -> Nil
    Error(_) -> Nil
  }
}

fn database_detail(database: String) -> String {
  case database {
    "connected" -> "The API and its database responded."
    "" -> "Database: unknown."
    other -> "Database: " <> other <> "."
  }
}

fn checking_item() -> Element(Msg) {
  html.li([], [
    html.div([], [
      html.strong([], [element.text("Checking")]),
      html.p([], [element.text("Asking /api/status and /api/stream.")]),
    ]),
  ])
}

fn reported_item(row: Row) -> Element(Msg) {
  html.li([], [
    html.div([], [
      html.strong([], [element.text(row.name)]),
      html.p([], [element.text(row.detail)]),
    ]),
    html.span(
      [
        attribute.class("status-state"),
        attribute.attribute("data-state", health_name(row.health)),
      ],
      [element.text(health_label(row.health))],
    ),
  ])
}

fn load_reports() -> Effect(Msg) {
  effect.from(fn(dispatch) {
    request_reports(
      fn(api_failed, status, database, stream_failed, enabled, when) {
        dispatch(Loaded(
          api_failed:,
          status:,
          database:,
          stream_failed:,
          enabled:,
          when:,
        ))
      },
    )
  })
}

@external(javascript, "./status_ffi.mjs", "load")
fn request_reports(
  deliver: fn(Bool, String, String, Bool, Bool, String) -> Nil,
) -> Nil
