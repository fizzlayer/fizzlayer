import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/uri
import gleeunit/should
import lustre/element

import checkout.{
  App, CancelClicked, Checkout, CreateSession, Creating, Failed, Gateways, Go,
  Leaving, Mount, Mounted, Mounting, Nothing, Open, Paid, Pro, RetryClicked,
  SessionCreated, Settings, StripePaid, Tinkerer, Unknown, Waiting,
}
import fizz_spa
import route

const good =
  "{\"publishable_key\":\"pk_test_1\",\"client_secret\":\"cs_test_a_secret_b\"}"

fn at(state) {
  Checkout(Pro, App, state)
}

fn step(state, msg) {
  checkout.update(at(state), msg)
}

pub fn the_url_names_the_plan_and_return_page_test() {
  checkout.init(Some("plan=pro&return=app")) |> should.equal(at(Waiting))
  checkout.init(Some("plan=tinkerer"))
  |> should.equal(Checkout(Tinkerer, Settings, Waiting))
  checkout.init(Some("plan=pro&return=gateway"))
  |> should.equal(Checkout(Pro, Gateways, Waiting))
  checkout.init(Some("plan=enterprise")) |> should.equal(Unknown)
  checkout.init(Some("plan=pro&return=https://evil.example"))
  |> should.equal(Unknown)
  checkout.init(None) |> should.equal(Unknown)
}

pub fn paths_round_trip_test() {
  use plan <- list.each([Tinkerer, Pro])
  use back <- list.each([Settings, App, Gateways])
  let assert Ok(target) = uri.parse(checkout.path(plan, back))
  route.parse(target.path) |> should.equal(route.Checkout)
  checkout.init(target.query) |> should.equal(Checkout(plan, back, Waiting))
}

pub fn the_app_boots_into_checkout_from_its_url_test() {
  let assert Ok(target) = uri.parse("/app/checkout?plan=pro&return=app")
  let model = fizz_spa.first_model(target)
  model.route |> should.equal(route.Checkout)
  model.checkout |> should.equal(at(Waiting))
}

pub fn start_asks_for_one_session_test() {
  let #(model, command) = checkout.start(at(Waiting))
  model |> should.equal(at(Creating))
  command
  |> should.equal(CreateSession(
    "{\"action\":\"checkout\",\"plan\":\"pro\",\"return_to\":\"app\"}",
  ))
  // A second sign-in check while the session is on its way changes nothing.
  checkout.start(model) |> should.equal(#(model, Nothing))
  checkout.start(Unknown) |> should.equal(#(Unknown, Nothing))
}

pub fn a_paid_checkout_mounts_then_returns_with_success_test() {
  step(Creating, SessionCreated(#(200, good)))
  |> should.equal(#(at(Mounting), Mount("pk_test_1", "cs_test_a_secret_b")))
  step(Mounting, Mounted(True)) |> should.equal(#(at(Open), Nothing))
  step(Open, StripePaid)
  |> should.equal(#(at(Paid), Go("/app.html?billing=success")))
}

pub fn refusals_say_why_and_only_server_trouble_retries_test() {
  let refused =
    "{\"error\":{\"code\":\"already_subscribed\",\"message\":\"Use Manage billing.\"}}"
  step(Creating, SessionCreated(#(409, refused)))
  |> should.equal(#(at(Failed("Use Manage billing.", False)), Nothing))
  let assert #(Checkout(_, _, Failed(_, True)), Nothing) =
    step(Creating, SessionCreated(#(503, "")))
  let assert #(Checkout(_, _, Failed(_, True)), Nothing) =
    step(Creating, SessionCreated(#(0, "Network error")))
  // A reply without a usable key and secret is never handed to Stripe.js.
  list.each(
    [
      "{}",
      "not json",
      "{\"publishable_key\":\"sk_test_1\",\"client_secret\":\"cs_test_a_secret_b\"}",
      "{\"publishable_key\":\"pk_test_1\",\"client_secret\":\"pi_1_secret_2\"}",
    ],
    fn(body) {
      let assert #(Checkout(_, _, Failed(_, True)), Nothing) =
        step(Creating, SessionCreated(#(200, body)))
    },
  )
}

pub fn a_form_that_fails_to_load_can_be_retried_test() {
  let assert #(Checkout(_, _, Failed(_, True) as failed), Nothing) =
    step(Mounting, Mounted(False))
  step(failed, RetryClicked)
  |> should.equal(#(
    at(Creating),
    CreateSession(
      "{\"action\":\"checkout\",\"plan\":\"pro\",\"return_to\":\"app\"}",
    ),
  ))
  let refused = Failed("Use Manage billing.", False)
  step(refused, RetryClicked) |> should.equal(#(at(refused), Nothing))
}

pub fn cancel_leaves_from_any_state_but_paid_test() {
  list.each(
    [Waiting, Creating, Mounting, Open, Failed("x", True), Failed("x", False)],
    fn(state) {
      step(state, CancelClicked)
      |> should.equal(#(at(Leaving), Go("/app.html?billing=cancelled")))
    },
  )
  step(Paid, CancelClicked) |> should.equal(#(at(Paid), Nothing))
  checkout.update(Unknown, CancelClicked)
  |> should.equal(#(Unknown, Go("/settings.html?billing=cancelled")))
}

pub fn late_and_out_of_order_replies_change_nothing_test() {
  let ignored = [
    #(Leaving, SessionCreated(#(200, good))),
    #(Leaving, Mounted(True)),
    #(Leaving, StripePaid),
    #(Paid, Mounted(False)),
    #(Waiting, SessionCreated(#(200, good))),
    #(Creating, Mounted(True)),
    #(Creating, StripePaid),
    #(Open, SessionCreated(#(200, good))),
    #(Open, Mounted(False)),
    #(Open, RetryClicked),
  ]
  use #(state, msg) <- list.each(ignored)
  step(state, msg) |> should.equal(#(at(state), Nothing))
  checkout.update(Unknown, msg) |> should.equal(#(Unknown, Nothing))
}

pub fn each_return_page_reports_the_outcome_test() {
  checkout.leave_url(Settings, True)
  |> should.equal("/settings.html?billing=success")
  checkout.leave_url(App, False) |> should.equal("/app.html?billing=cancelled")
  checkout.leave_url(Gateways, True)
  |> should.equal(route.gateways_path <> "?billing=success")
}

pub fn the_view_keeps_the_frame_and_offers_the_right_buttons_test() {
  let html = fn(state) { element.to_string(checkout.view(at(state))) }
  let frame = "id=\"" <> checkout.frame_id <> "\""
  list.each(
    [Waiting, Creating, Mounting, Open, Paid, Leaving, Failed("x", True)],
    fn(state) { string.contains(html(state), frame) |> should.be_true },
  )
  string.contains(html(Creating), "Upgrade to Pro") |> should.be_true
  // Loading shows the spinner as a status, with its label as the text.
  list.each([Waiting, Creating, Mounting], fn(state) {
    let page = html(state)
    string.contains(page, "class=\"spinner\"") |> should.be_true
    string.contains(page, "role=\"status\"") |> should.be_true
    string.contains(page, "Loading secure checkout") |> should.be_true
  })
  list.each([Open, Failed("x", True), Failed("x", False)], fn(state) {
    let page = html(state)
    string.contains(page, "class=\"spinner\"") |> should.be_false
    string.contains(page, "Loading") |> should.be_false
  })
  string.contains(html(Open), "Cancel") |> should.be_true
  string.contains(html(Failed("Use Manage billing.", True)), "Try again")
  |> should.be_true
  string.contains(html(Failed("Use Manage billing.", False)), "Try again")
  |> should.be_false
  string.contains(
    html(Failed("Use Manage billing.", False)),
    "Use Manage billing.",
  )
  |> should.be_true
  string.contains(html(Paid), "Cancel") |> should.be_false
  string.contains(
    element.to_string(checkout.view(Unknown)),
    "does not name a plan",
  )
  |> should.be_true
}

pub fn each_plan_is_offered_the_paid_plans_above_it_test() {
  // Hobbyist has no subscription and buys one; Tinkerer changes its own.
  checkout.upgrades("hobbyist")
  |> should.equal([checkout.Subscribe(Tinkerer), checkout.Subscribe(Pro)])
  checkout.upgrades("tinkerer") |> should.equal([checkout.Switch(Pro)])
  checkout.upgrades("pro") |> should.equal([])
  checkout.upgrades("enterprise") |> should.equal([])
  checkout.upgrades("") |> should.equal([])
}

pub fn the_portal_comes_back_to_the_gateways_test() {
  checkout.portal_body(Gateways)
  |> should.equal("{\"action\":\"portal\",\"return_to\":\"gateway\"}")
  checkout.portal_url(200, "{\"url\":\"https://billing.stripe.com/p/x\"}")
  |> should.equal(Ok("https://billing.stripe.com/p/x"))
  checkout.portal_url(200, "{\"url\":\"javascript:alert(1)\"}")
  |> should.equal(Error(Nil))
  checkout.portal_url(409, "{\"url\":\"https://billing.stripe.com/p/x\"}")
  |> should.equal(Error(Nil))
  checkout.portal_url(200, "{}") |> should.equal(Error(Nil))
}
