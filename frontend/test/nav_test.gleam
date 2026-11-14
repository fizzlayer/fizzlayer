import gleeunit/should
import nav

pub fn toggle_opens_and_closes_without_moving_focus_test() {
  let opened = nav.next_menu(False, "toggle")
  opened.open |> should.equal(True)
  opened.focus_toggle |> should.equal(False)
  nav.menu_open(True, "toggle") |> should.equal(False)
}

pub fn choosing_a_link_closes_the_menu_test() {
  let closed = nav.next_menu(True, "link")
  closed.open |> should.equal(False)
  closed.focus_toggle |> should.equal(False)
}

pub fn escape_closes_an_open_menu_and_returns_focus_test() {
  let closed = nav.next_menu(True, "escape")
  closed.open |> should.equal(False)
  closed.focus_toggle |> should.equal(True)
  nav.menu_focus(False, "escape") |> should.equal(False)
  nav.menu_open(False, "escape") |> should.equal(False)
}

pub fn other_keys_leave_the_menu_alone_test() {
  nav.menu_open(True, "tab") |> should.equal(True)
  nav.menu_focus(True, "tab") |> should.equal(False)
}
