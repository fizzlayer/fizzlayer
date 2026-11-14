import gleam/string
import gleeunit/should
import lustre/element
import status.{
  type Health, Degraded, Loaded, Operational, Unavailable, Unreported,
}

pub fn api_row_follows_the_public_status_payload_test() {
  let ok = status.api_row(False, "ok", "connected")
  ok.health |> should_health(Operational)
  ok.detail |> should.equal("The API and its database responded.")

  let degraded = status.api_row(False, "down", "")
  degraded.health |> should_health(Degraded)
  degraded.detail |> should.equal("Database: unknown.")

  let named = status.api_row(False, "down", "starting")
  named.detail |> should.equal("Database: starting.")

  let down = status.api_row(True, "ok", "connected")
  down.health |> should_health(Unavailable)
  down.detail |> should.equal("The status check did not answer.")
}

pub fn stream_and_scheduler_rows_keep_their_copy_test() {
  let live = status.stream_row(False, True)
  live.health |> should_health(Operational)
  live.detail
  |> should.equal("WebSocket and MQTT-over-WebSocket addresses are available.")

  let off = status.stream_row(False, False)
  off.health |> should_health(Degraded)
  off.detail |> should.equal("Live streaming is not configured.")

  let missing = status.stream_row(True, True)
  missing.health |> should_health(Unavailable)
  missing.detail |> should.equal("The stream check did not answer.")

  let scheduler = status.scheduler_row()
  scheduler.name |> should.equal("Alert scheduler")
  scheduler.health |> should_health(Unreported)
  scheduler.detail
  |> should.equal(
    "The public status check does not include silence scans or queued calls.",
  )
}

pub fn report_rows_are_api_then_scheduler_then_stream_test() {
  let rows = status.report_rows(False, "ok", "connected", False, True)
  case rows {
    [api, scheduler, stream] -> {
      api.name |> should.equal("API")
      scheduler.name |> should.equal("Alert scheduler")
      stream.name |> should.equal("Live streaming")
    }
    _ -> should.equal(True, False)
  }
}

pub fn checked_line_names_the_browser_clock_test() {
  status.checked_line("14/11/2026, 06:00:00")
  |> should.equal(
    "Checked just now from this browser (14/11/2026, 06:00:00). This page does not keep an uptime history or state an SLA.",
  )
}

pub fn checking_view_matches_the_placeholder_copy_test() {
  let #(phase, _effect) = status.init(Nil)
  let html = element.to_string(status.view(phase))
  string.contains(html, "status-list") |> should.equal(True)
  string.contains(html, "Checking") |> should.equal(True)
  string.contains(html, "Asking /api/status and /api/stream.")
  |> should.equal(True)
  string.contains(html, "status-checked") |> should.equal(True)
  string.contains(html, "role=\"status\"") |> should.equal(True)
}

pub fn loaded_view_renders_state_badges_test() {
  let #(phase, _effect) =
    status.update(
      status.Checking,
      Loaded(False, "ok", "connected", False, False, "now"),
    )
  let html = element.to_string(status.view(phase))
  string.contains(html, "data-state=\"operational\"") |> should.equal(True)
  string.contains(html, "data-state=\"unreported\"") |> should.equal(True)
  string.contains(html, "data-state=\"degraded\"") |> should.equal(True)
  string.contains(html, "Operational") |> should.equal(True)
  string.contains(html, "Not reported") |> should.equal(True)
  string.contains(html, "Live streaming is not configured.")
  |> should.equal(True)
  string.contains(html, "Checked just now from this browser (now).")
  |> should.equal(True)
}

fn should_health(actual: Health, expected: Health) {
  actual |> should.equal(expected)
}
