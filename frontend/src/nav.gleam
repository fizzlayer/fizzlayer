/// The next open state of the marketing-site menu.
pub type Menu {
  Menu(open: Bool, focus_toggle: Bool)
}

/// `event` is `"toggle"`, `"link"`, `"escape"`, or anything else.
pub fn next_menu(open: Bool, event: String) -> Menu {
  case event {
    "toggle" -> Menu(open: !open, focus_toggle: False)
    "link" -> Menu(open: False, focus_toggle: False)
    "escape" ->
      case open {
        True -> Menu(open: False, focus_toggle: True)
        False -> Menu(open:, focus_toggle: False)
      }
    _ -> Menu(open:, focus_toggle: False)
  }
}

pub fn menu_open(open: Bool, event: String) -> Bool {
  next_menu(open, event).open
}

pub fn menu_focus(open: Bool, event: String) -> Bool {
  next_menu(open, event).focus_toggle
}

pub fn install() -> Nil {
  do_install()
}

@external(javascript, "./nav_ffi.mjs", "install")
fn do_install() -> Nil
