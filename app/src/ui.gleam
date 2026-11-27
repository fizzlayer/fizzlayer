//// Fizzlayer's UI components. This is the only module that names CSS classes
//// from `assets/fizz.css`; `scripts/check-ui-classes.sh` fails CI if another
//// module calls `attribute.class`. Screens are built from these functions so
//// every page shares one look.

import gleam/int
import gleam/list
import lustre/attribute.{type Attribute}
import lustre/element.{type Element, text}
import lustre/element/html
import lustre/element/keyed

/// How much weight a button carries. One `Primary` per screen section.
pub type Variant {
  Primary
  Secondary
  Quiet
  Danger
}

/// What a notice reports. Colour only marks status.
pub type Tone {
  Neutral
  Good
  Caution
  Bad
}

fn variant_class(variant: Variant) -> String {
  case variant {
    Primary -> "button button-primary"
    Secondary -> "button button-secondary"
    Quiet -> "button button-quiet"
    Danger -> "button button-danger"
  }
}

// App frame ------------------------------------------------------------------

pub fn app_header(children: List(Element(msg))) -> Element(msg) {
  html.header([attribute.class("app-header")], children)
}

/// The Fizzlayer wordmark, the same as on the site header.
pub fn wordmark(href: String) -> Element(msg) {
  html.a([attribute.class("wordmark"), attribute.href(href)], [
    html.img([
      attribute.src("/fizz-logo.svg"),
      attribute.alt(""),
      attribute.width(30),
      attribute.height(30),
    ]),
    html.span([], [
      text("Fizzlayer"),
      html.span([attribute.class("wordmark-dot")], [text(".")]),
    ]),
  ])
}

pub fn nav(label: String, children: List(Element(msg))) -> Element(msg) {
  html.nav([attribute.class("app-nav"), attribute.aria_label(label)], children)
}

pub fn nav_link(href: String, label: String, current: Bool) -> Element(msg) {
  html.a(
    [
      attribute.class("app-nav-link"),
      attribute.href(href),
      case current {
        True -> attribute.aria_current("page")
        False -> attribute.none()
      },
    ],
    [text(label)],
  )
}

pub fn account(children: List(Element(msg))) -> Element(msg) {
  html.div([attribute.class("app-account")], children)
}

pub fn user(name: String) -> Element(msg) {
  html.span([attribute.class("app-user")], [text(name)])
}

pub fn main(wide: Bool, children: List(Element(msg))) -> Element(msg) {
  html.main(
    [
      attribute.id("main"),
      attribute.class(case wide {
        True -> "app-main app-main-wide"
        False -> "app-main"
      }),
    ],
    children,
  )
}

// Content --------------------------------------------------------------------

/// A white panel with a border. `attrs` is usually an id for tests and links.
pub fn card(
  attrs: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.section([attribute.class("card"), ..attrs], children)
}

/// The muted sentence under a page title.
pub fn lead(content: String) -> Element(msg) {
  html.p([attribute.class("lead")], [text(content)])
}

pub fn muted(content: String) -> Element(msg) {
  html.p([attribute.class("muted")], [text(content)])
}

/// A muted paragraph that holds links or other inline elements.
pub fn muted_content(children: List(Element(msg))) -> Element(msg) {
  html.p([attribute.class("muted")], children)
}

pub fn badge(content: String) -> Element(msg) {
  html.span([attribute.class("badge-label")], [text(content)])
}

/// A status message. Neutral and Good are announced politely; Caution and Bad
/// are alerts.
pub fn notice(
  tone: Tone,
  attrs: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  let #(class, role) = case tone {
    Neutral -> #("notice notice-info", "status")
    Good -> #("notice notice-success", "status")
    Caution -> #("notice notice-warning", "alert")
    Bad -> #("notice notice-danger", "alert")
  }
  html.div([attribute.class(class), attribute.role(role), ..attrs], children)
}

pub fn notice_text(tone: Tone, message: String) -> Element(msg) {
  notice(tone, [], [html.p([], [text(message)])])
}

/// A turning ring with a visible label, for work the page is waiting on.
/// Screen readers announce the label; the ring itself is decoration.
pub fn spinner(label: String) -> Element(msg) {
  html.div([attribute.class("spinner"), attribute.role("status")], [
    html.span(
      [attribute.class("spinner-ring"), attribute.aria_hidden(True)],
      [],
    ),
    html.span([attribute.class("spinner-label")], [text(label)]),
  ])
}

// Checkout -------------------------------------------------------------------

/// The `/app/checkout` page. Stripe mounts its form into the element with
/// `frame_id`. That element keeps its key and never gets children from Lustre,
/// so redraws around it leave the form alone.
pub fn checkout_page(
  title: String,
  intro: String,
  status: Element(msg),
  frame_id: String,
  buttons: List(Element(msg)),
) -> Element(msg) {
  keyed.element("section", [attribute.class("card checkout")], [
    #("title", html.h1([], [text(title)])),
    #("intro", lead(intro)),
    #("status", status),
    #(
      "frame",
      html.div([attribute.id(frame_id), attribute.class("checkout-frame")], []),
    ),
    #("actions", actions(buttons)),
  ])
}

// Actions --------------------------------------------------------------------

/// A `<button>`. Pass `attribute.type_` yourself: "submit" in a form,
/// otherwise "button".
pub fn button(
  variant: Variant,
  attrs: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.button([attribute.class(variant_class(variant)), ..attrs], children)
}

/// A button that reads as an inline link, for a secondary action inside a
/// sentence ("Already have an account? Sign in").
pub fn text_button(
  attrs: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.button(
    [attribute.class("text-button"), attribute.type_("button"), ..attrs],
    children,
  )
}

/// A link styled as a button.
pub fn link_button(
  variant: Variant,
  href: String,
  children: List(Element(msg)),
) -> Element(msg) {
  html.a(
    [attribute.class(variant_class(variant)), attribute.href(href)],
    children,
  )
}

/// A row of buttons under a form or a section.
pub fn actions(children: List(Element(msg))) -> Element(msg) {
  html.div([attribute.class("actions")], children)
}

// Forms ----------------------------------------------------------------------

/// A label above its control, with an optional hint under it.
pub fn field(
  label: String,
  id: String,
  hint: String,
  control: Element(msg),
) -> Element(msg) {
  html.div([attribute.class("field")], [
    html.label([attribute.class("field-label"), attribute.for(id)], [
      text(label),
    ]),
    control,
    case hint {
      "" -> element.none()
      hint -> html.p([attribute.class("field-hint")], [text(hint)])
    },
  ])
}

pub fn input(attrs: List(Attribute(msg))) -> Element(msg) {
  html.input([attribute.class("input"), ..attrs])
}

pub fn select(
  attrs: List(Attribute(msg)),
  options: List(Element(msg)),
) -> Element(msg) {
  html.select([attribute.class("input"), ..attrs], options)
}

// Code -----------------------------------------------------------------------

/// Monospace text the reader copies: a URL, a token, a config file.
pub fn code_block(content: String) -> Element(msg) {
  html.pre([attribute.class("code-block")], [text(content)])
}

/// A titled code block, such as one client's config, with its buttons
/// (usually Copy) beside the title.
pub fn snippet(
  title: String,
  content: String,
  snippet_actions: List(Element(msg)),
) -> Element(msg) {
  html.div([attribute.class("snippet")], [
    html.div([attribute.class("snippet-header")], [
      html.h3([attribute.class("snippet-title")], [text(title)]),
      ..snippet_actions
    ]),
    code_block(content),
  ])
}

// Layout pieces -----------------------------------------------------------------

/// Side-by-side options on a start screen.
pub fn choices(children: List(Element(msg))) -> Element(msg) {
  html.div([attribute.class("choices")], children)
}

pub fn choice(default: Bool, children: List(Element(msg))) -> Element(msg) {
  html.div(
    [
      attribute.class(case default {
        True -> "choice choice-default"
        False -> "choice"
      }),
    ],
    children,
  )
}

/// Numbered steps. Each item is `#(href, label, current)`.
pub fn steps(items: List(#(String, String, Bool))) -> Element(msg) {
  html.ol(
    [attribute.class("steps"), attribute.aria_label("Setup steps")],
    list.map(items, fn(item) {
      let #(href, label, current) = item
      html.li(
        [
          attribute.class(case current {
            True -> "step step-current"
            False -> "step"
          }),
        ],
        [
          case href {
            // A step you can't reach yet is text, not a link.
            "" -> html.span([attribute.class("step-locked")], [text(label)])
            _ ->
              html.a(
                [
                  attribute.href(href),
                  case current {
                    True -> attribute.aria_current("step")
                    False -> attribute.none()
                  },
                ],
                [text(label)],
              )
          },
        ],
      )
    }),
  )
}

/// A bordered list of rows.
pub fn list(rows: List(Element(msg))) -> Element(msg) {
  html.div([attribute.class("list")], rows)
}

/// One row: a title, detail beside it, then its buttons.
pub fn list_row(
  title: String,
  detail: List(Element(msg)),
  row_actions: List(Element(msg)),
) -> Element(msg) {
  html.div([attribute.class("list-row")], [
    html.strong([attribute.class("list-row-title")], [text(title)]),
    html.div([attribute.class("list-row-detail")], detail),
    case row_actions {
      [] -> element.none()
      _ -> html.div([attribute.class("list-row-actions")], row_actions)
    },
  ])
}

/// A bordered box for plan limits.
pub fn plan(
  attrs: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.section([attribute.class("plan"), ..attrs], children)
}

// Sign-in ----------------------------------------------------------------------

/// Two or three buttons that act as tabs over one form. Each item is
/// `#(label, selected, on_click)`.
pub fn segmented(
  label: String,
  items: List(#(String, Bool, Attribute(msg))),
) -> Element(msg) {
  html.div(
    [
      attribute.class("segmented"),
      attribute.role("group"),
      attribute.aria_label(label),
    ],
    list.map(items, fn(item) {
      let #(name, selected, on_click) = item
      html.button(
        [
          attribute.class("segmented-option"),
          attribute.type_("button"),
          attribute.aria_pressed(case selected {
            True -> "true"
            False -> "false"
          }),
          on_click,
        ],
        [text(name)],
      )
    }),
  )
}

/// A button that fills the width of its column.
pub fn wide_button(
  variant: Variant,
  attrs: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.button(
    [attribute.class(variant_class(variant) <> " button-block"), ..attrs],
    children,
  )
}

/// Children stacked with even space between them.
pub fn stack(children: List(Element(msg))) -> Element(msg) {
  html.div([attribute.class("stack")], children)
}

/// A full-width primary submit button.
pub fn submit(label: String, disabled: Bool) -> Element(msg) {
  html.button(
    [
      attribute.class("button button-primary button-block"),
      attribute.type_("submit"),
      attribute.disabled(disabled),
    ],
    [text(label)],
  )
}

/// A thin rule with a word in the middle, such as "or".
pub fn divider(word: String) -> Element(msg) {
  html.p([attribute.class("divider")], [html.span([], [text(word)])])
}

pub type Provider {
  Google
  GitHub
}

/// "Continue with Google" and the like, full width, with the provider's mark.
pub fn provider_button(
  provider: Provider,
  label: String,
  attrs: List(Attribute(msg)),
) -> Element(msg) {
  html.button(
    [
      attribute.class("button button-secondary button-block button-provider"),
      attribute.type_("button"),
      ..attrs
    ],
    [
      element.unsafe_raw_html(
        "",
        "span",
        [attribute.class("provider-mark"), attribute.aria_hidden(True)],
        case provider {
          Google -> google_mark
          GitHub -> github_mark
        },
      ),
      text(label),
    ],
  )
}

const google_mark =
  "<svg viewBox=\"0 0 48 48\" width=\"18\" height=\"18\"><path fill=\"#EA4335\" d=\"M24 9.5c3.54 0 6.71 1.22 9.21 3.6l6.85-6.85C35.9 2.38 30.47 0 24 0 14.62 0 6.51 5.38 2.56 13.22l7.98 6.19C12.43 13.72 17.74 9.5 24 9.5z\"/><path fill=\"#4285F4\" d=\"M46.98 24.55c0-1.57-.15-3.09-.38-4.55H24v9.02h12.94c-.58 2.96-2.26 5.48-4.78 7.18l7.73 6c4.51-4.18 7.09-10.36 7.09-17.65z\"/><path fill=\"#FBBC05\" d=\"M10.53 28.59c-.48-1.45-.76-2.99-.76-4.59s.27-3.14.76-4.59l-7.98-6.19C.92 16.46 0 20.12 0 24c0 3.88.92 7.54 2.56 10.78l7.97-6.19z\"/><path fill=\"#34A853\" d=\"M24 48c6.48 0 11.93-2.13 15.89-5.81l-7.73-6c-2.15 1.45-4.92 2.3-8.16 2.3-6.26 0-11.57-4.22-13.47-9.91l-7.98 6.19C6.51 42.62 14.62 48 24 48z\"/></svg>"

const github_mark =
  "<svg viewBox=\"0 0 16 16\" width=\"18\" height=\"18\"><path fill=\"currentColor\" d=\"M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0 0 16 8c0-4.42-3.58-8-8-8z\"/></svg>"

/// Small print under a form, such as the terms note.
pub fn fine_print(children: List(Element(msg))) -> Element(msg) {
  html.p([attribute.class("fine-print")], children)
}

/// A row that puts a link-style button at the end of a field's label line.
pub fn field_extra(children: List(Element(msg))) -> Element(msg) {
  html.div([attribute.class("field-extra")], children)
}

// Icons ------------------------------------------------------------------------

/// A Font Awesome solid icon by name, such as `server` for `fa-server`.
/// Decorative: screen readers skip it, so pair it with text.
pub fn icon(name: String) -> Element(msg) {
  icon_classes("fa-solid fa-" <> name)
}

/// A Font Awesome icon from its full classes, such as `fa-brands fa-github`.
pub fn icon_classes(classes: String) -> Element(msg) {
  html.i([attribute.class(classes), attribute.aria_hidden(True)], [])
}

/// An icon then a label, for the inside of a button or link.
pub fn with_icon(name: String, label: String) -> List(Element(msg)) {
  [icon(name), html.span([], [text(label)])]
}

// Gateway list -------------------------------------------------------------------

/// The heading row of a page outside a card: title, lead, actions.
pub fn page_head(
  title: String,
  lead_text: String,
  head_actions: List(Element(msg)),
) -> Element(msg) {
  html.div([attribute.class("page-head")], [
    html.div([], [
      html.h1([attribute.class("page-title")], [text(title)]),
      case lead_text {
        "" -> element.none()
        _ -> html.p([attribute.class("page-lead")], [text(lead_text)])
      },
    ]),
    case head_actions {
      [] -> element.none()
      _ -> html.div([attribute.class("page-head-actions")], head_actions)
    },
  ])
}

pub fn gateway_grid(children: List(Element(msg))) -> Element(msg) {
  html.div([attribute.class("gw-grid")], children)
}

/// One gateway in the list. The whole card is the link.
pub fn gateway_card(
  href: String,
  name: String,
  mode: String,
  active: Bool,
  status: String,
  url: String,
) -> Element(msg) {
  html.a([attribute.class("gw-card"), attribute.href(href)], [
    html.div([attribute.class("gw-card-top")], [
      html.span([attribute.class("gw-card-icon")], [icon("shield-halved")]),
      status_pill(active, status),
    ]),
    html.h2([attribute.class("gw-card-name")], [text(name)]),
    html.p([attribute.class("gw-card-mode")], [text(mode)]),
    case url {
      "" -> element.none()
      _ -> html.code([attribute.class("gw-card-url")], [text(url)])
    },
    html.span([attribute.class("gw-card-open")], [
      text("Open"),
      icon("arrow-right"),
    ]),
  ])
}

/// The dashed card at the end of the list that starts a new gateway.
pub fn new_card(href: String, title: String, body: String) -> Element(msg) {
  html.a([attribute.class("gw-card gw-card-new"), attribute.href(href)], [
    html.span([attribute.class("gw-card-icon")], [icon("plus")]),
    html.h2([attribute.class("gw-card-name")], [text(title)]),
    html.p([attribute.class("gw-card-mode")], [text(body)]),
  ])
}

/// A dot and a word: green and pulsing while active.
pub fn status_pill(active: Bool, label: String) -> Element(msg) {
  html.span(
    [
      attribute.class(case active {
        True -> "status-pill status-on"
        False -> "status-pill status-off"
      }),
    ],
    [html.span([attribute.class("status-dot")], []), text(label)],
  )
}

/// A big icon, a title, a sentence and actions, for a list with nothing in it.
pub fn empty_state(
  icon_name: String,
  title: String,
  body: String,
  empty_actions: List(Element(msg)),
) -> Element(msg) {
  html.div([attribute.class("empty")], [
    html.span([attribute.class("empty-icon")], [icon(icon_name)]),
    html.h2([], [text(title)]),
    html.p([], [text(body)]),
    case empty_actions {
      [] -> element.none()
      _ -> html.div([attribute.class("actions empty-actions")], empty_actions)
    },
  ])
}

// Gateway page -------------------------------------------------------------------

/// The side menu beside the open tab. On a phone the menu becomes a
/// scrolling row above it.
pub fn gateway_layout(
  side: Element(msg),
  content: Element(msg),
) -> Element(msg) {
  html.div([attribute.class("gw-layout")], [side, content])
}

pub fn side(children: List(Element(msg))) -> Element(msg) {
  html.aside([attribute.class("gw-side")], children)
}

pub fn side_head(
  back_href: String,
  name: String,
  detail: Element(msg),
) -> Element(msg) {
  html.div([attribute.class("gw-side-head")], [
    html.a([attribute.class("gw-back"), attribute.href(back_href)], [
      icon("arrow-left"),
      text("All gateways"),
    ]),
    html.div([attribute.class("gw-side-title")], [
      html.span([attribute.class("gw-card-icon")], [icon("shield-halved")]),
      html.div([], [html.strong([], [text(name)]), detail]),
    ]),
  ])
}

/// One menu item: `#(href, icon, label, count, current, alert)`. A count of
/// 0 shows nothing. `alert` marks a count that wants attention.
pub type MenuItem {
  MenuItem(
    href: String,
    icon: String,
    label: String,
    count: Int,
    current: Bool,
    alert: Bool,
  )
}

pub fn tab_menu(label: String, items: List(MenuItem)) -> Element(msg) {
  html.nav([attribute.class("tab-menu"), attribute.aria_label(label)], [
    html.ul(
      [],
      list.map(items, fn(item) {
        html.li([], [
          html.a(
            [
              attribute.class("tab-link"),
              attribute.href(item.href),
              case item.current {
                True -> attribute.aria_current("page")
                False -> attribute.none()
              },
            ],
            [
              html.span([attribute.class("tab-icon")], [icon(item.icon)]),
              html.span([attribute.class("tab-label")], [text(item.label)]),
              case item.count {
                0 -> element.none()
                count ->
                  html.span(
                    [
                      attribute.class(case item.alert {
                        True -> "tab-count tab-count-alert"
                        False -> "tab-count"
                      }),
                    ],
                    [text(int_text(count))],
                  )
              },
            ],
          ),
        ])
      }),
    ),
  ])
}

/// The open tab. It is keyed by `key`, so switching tabs mounts a new panel
/// and its entry animation plays again.
pub fn panel(key: String, children: List(Element(msg))) -> Element(msg) {
  keyed.div([attribute.class("panel-host")], [
    #(key, html.section([attribute.class("panel")], children)),
  ])
}

/// The title row inside a panel.
pub fn panel_head(
  icon_name: String,
  title: String,
  lead_text: String,
  head_actions: List(Element(msg)),
) -> Element(msg) {
  html.header([attribute.class("panel-head")], [
    html.span([attribute.class("panel-icon")], [icon(icon_name)]),
    html.div([attribute.class("panel-head-text")], [
      html.h1([], [text(title)]),
      case lead_text {
        "" -> element.none()
        _ -> html.p([attribute.class("lead")], [text(lead_text)])
      },
    ]),
    case head_actions {
      [] -> element.none()
      _ -> html.div([attribute.class("panel-head-actions")], head_actions)
    },
  ])
}

/// A titled block inside a panel.
pub fn block(
  title: String,
  block_actions: List(Element(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.section([attribute.class("block")], [
    html.div([attribute.class("block-head")], [
      html.h2([], [text(title)]),
      case block_actions {
        [] -> element.none()
        _ -> html.div([attribute.class("block-actions")], block_actions)
      },
    ]),
    ..children
  ])
}

pub fn stat_grid(children: List(Element(msg))) -> Element(msg) {
  html.div([attribute.class("stat-grid")], children)
}

/// A number with its label that links to the tab it counts.
pub fn stat(
  href: String,
  icon_name: String,
  value: Int,
  label: String,
  alert: Bool,
) -> Element(msg) {
  html.a(
    [
      attribute.class(case alert && value > 0 {
        True -> "stat stat-alert"
        False -> "stat"
      }),
      attribute.href(href),
    ],
    [
      html.span([attribute.class("stat-icon")], [icon(icon_name)]),
      html.strong([attribute.class("stat-value")], [text(int_text(value))]),
      html.span([attribute.class("stat-label")], [text(label)]),
    ],
  )
}

/// Setup steps with a check once each is done: `#(done, title, href, action)`.
pub fn checklist(items: List(#(Bool, String, String, String))) -> Element(msg) {
  html.ol(
    [attribute.class("checklist-steps")],
    list.map(items, fn(item) {
      let #(done, title, href, action) = item
      html.li(
        [
          attribute.class(case done {
            True -> "check-step check-done"
            False -> "check-step"
          }),
        ],
        [
          html.span([attribute.class("check-mark")], [
            icon(case done {
              True -> "check"
              False -> "circle"
            }),
          ]),
          html.span([attribute.class("check-title")], [text(title)]),
          case done {
            True -> element.none()
            False ->
              html.a([attribute.class("check-action"), attribute.href(href)], [
                text(action),
                icon("arrow-right"),
              ])
          },
        ],
      )
    }),
  )
}

/// A URL or token on one line with its buttons at the end.
pub fn copy_line(
  value: String,
  line_actions: List(Element(msg)),
) -> Element(msg) {
  html.div([attribute.class("copy-line")], [
    html.code([attribute.class("copy-line-value")], [text(value)]),
    ..line_actions
  ])
}

/// A small coloured label with an icon, for status and auth.
pub fn pill(tone: Tone, icon_name: String, label: String) -> Element(msg) {
  html.span(
    [
      attribute.class(case tone {
        Neutral -> "pill pill-neutral"
        Good -> "pill pill-good"
        Caution -> "pill pill-caution"
        Bad -> "pill pill-bad"
      }),
    ],
    [icon(icon_name), text(label)],
  )
}

/// A list row with an icon tile before the title.
pub fn item_row(
  icon_classes_name: String,
  title: String,
  detail: List(Element(msg)),
  row_actions: List(Element(msg)),
) -> Element(msg) {
  html.div([attribute.class("item-row")], [
    html.span([attribute.class("item-icon")], [
      icon_classes(icon_classes_name),
    ]),
    html.div([attribute.class("item-body")], [
      html.strong([attribute.class("item-title")], [text(title)]),
      html.div([attribute.class("item-detail")], detail),
    ]),
    case row_actions {
      [] -> element.none()
      _ -> html.div([attribute.class("item-actions")], row_actions)
    },
  ])
}

pub fn item_list(rows: List(Element(msg))) -> Element(msg) {
  html.div([attribute.class("item-list")], rows)
}

/// A bordered box with a red heading for actions that cannot be undone.
pub fn danger_zone(children: List(Element(msg))) -> Element(msg) {
  html.section([attribute.class("danger-zone")], children)
}

/// Facts as label and value pairs.
pub fn facts(rows: List(#(String, Element(msg)))) -> Element(msg) {
  html.dl(
    [attribute.class("facts")],
    list.flat_map(rows, fn(row) {
      [html.dt([], [text(row.0)]), html.dd([], [row.1])]
    }),
  )
}

// Rules --------------------------------------------------------------------------

/// Allow, Block and Ask first as one control: `#(effect, icon, label,
/// pressed, on_click)`. The pressed option takes the effect's colour.
pub fn rule_switch(
  label: String,
  items: List(#(String, String, String, Bool, List(Attribute(msg)))),
) -> Element(msg) {
  html.div(
    [
      attribute.class("rule-switch"),
      attribute.role("group"),
      attribute.aria_label(label),
    ],
    list.map(items, fn(item) {
      let #(effect, icon_name, name, pressed, attrs) = item
      html.button(
        [
          attribute.class("rule-option rule-" <> effect),
          attribute.type_("button"),
          attribute.aria_pressed(case pressed {
            True -> "true"
            False -> "false"
          }),
          ..attrs
        ],
        [icon(icon_name), html.span([], [text(name)])],
      )
    }),
  )
}

/// Buttons that filter a list, one pressed at a time: `#(label, pressed,
/// on_click)`.
pub fn chips(
  label: String,
  items: List(#(String, Bool, Attribute(msg))),
) -> Element(msg) {
  html.div(
    [
      attribute.class("chips"),
      attribute.role("group"),
      attribute.aria_label(label),
    ],
    list.map(items, fn(item) {
      let #(name, pressed, on_click) = item
      html.button(
        [
          attribute.class("chip"),
          attribute.type_("button"),
          attribute.aria_pressed(case pressed {
            True -> "true"
            False -> "false"
          }),
          on_click,
        ],
        [text(name)],
      )
    }),
  )
}

// Server catalog -----------------------------------------------------------------

/// A search field with a magnifier inside and a submit button beside it.
pub fn search_bar(
  form_attrs: List(Attribute(msg)),
  input_attrs: List(Attribute(msg)),
  button_label: String,
  busy: Bool,
) -> Element(msg) {
  html.form([attribute.class("search-bar"), ..form_attrs], [
    html.label([attribute.class("search-field")], [
      icon("magnifying-glass"),
      html.span([attribute.class("visually-hidden")], [text("Search")]),
      html.input([
        attribute.class("search-input"),
        attribute.type_("search"),
        ..input_attrs
      ]),
    ]),
    html.button(
      [
        attribute.class("button button-primary"),
        attribute.type_("submit"),
        attribute.disabled(busy),
      ],
      case busy {
        True -> [icon_classes("fa-solid fa-spinner fa-spin"), text("Searching")]
        False -> [text(button_label)]
      },
    ),
  ])
}

/// Cards keyed by a stable id, so filtering or paging moves the right card
/// and its click handler instead of reusing cards by position.
pub fn catalog_grid(children: List(#(String, Element(msg)))) -> Element(msg) {
  keyed.div([attribute.class("catalog-grid")], children)
}

/// One server to add. `index` staggers the entry animation.
pub fn catalog_card(
  index: Int,
  icon_classes_name: String,
  title: String,
  source: String,
  description: String,
  footer: List(Element(msg)),
) -> Element(msg) {
  html.article(
    [
      attribute.class("catalog-card"),
      attribute.style("--i", int_text(int_min(index, 12))),
    ],
    [
      html.div([attribute.class("catalog-card-head")], [
        html.span([attribute.class("catalog-icon")], [
          icon_classes(icon_classes_name),
        ]),
        html.div([attribute.class("catalog-card-title")], [
          html.h3([], [text(title)]),
          html.span([attribute.class("catalog-source")], [text(source)]),
        ]),
      ]),
      html.p([attribute.class("catalog-desc")], [text(description)]),
      html.div([attribute.class("catalog-foot")], footer),
    ],
  )
}

/// The first card in the grid: add any server by its URL.
pub fn custom_card(attrs: List(Attribute(msg))) -> Element(msg) {
  html.button(
    [
      attribute.class("catalog-card catalog-custom"),
      attribute.type_("button"),
      attribute.style("--i", "0"),
      ..attrs
    ],
    [
      html.span([attribute.class("catalog-icon")], [icon("link")]),
      html.h3([], [text("Any server by URL")]),
      html.p([attribute.class("catalog-desc")], [
        text("Paste the address of a remote MCP server that isn't listed here."),
      ]),
      html.span([attribute.class("catalog-custom-cta")], [
        icon("plus"),
        text("Add by URL"),
      ]),
    ],
  )
}

/// A panel that slides in from the right over a dimmed page.
pub fn sheet(
  title: String,
  icon_classes_name: String,
  close: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.div([attribute.class("sheet-layer")], [
    html.button(
      [
        attribute.class("sheet-backdrop"),
        attribute.type_("button"),
        attribute.aria_label("Close"),
        attribute.tabindex(-1),
        ..close
      ],
      [],
    ),
    html.aside(
      [
        attribute.class("sheet"),
        attribute.role("dialog"),
        attribute.aria_modal(True),
        attribute.aria_labelledby("sheet-title"),
      ],
      [
        html.header([attribute.class("sheet-head")], [
          html.span([attribute.class("catalog-icon")], [
            icon_classes(icon_classes_name),
          ]),
          html.h2([attribute.id("sheet-title")], [text(title)]),
          html.button(
            [
              attribute.class("sheet-close"),
              attribute.type_("button"),
              attribute.aria_label("Close"),
              ..close
            ],
            [icon("xmark")],
          ),
        ]),
        html.div([attribute.class("sheet-body")], children),
      ],
    ),
  ])
}

fn int_text(value: Int) -> String {
  int.to_string(value)
}

fn int_min(a: Int, b: Int) -> Int {
  case a < b {
    True -> a
    False -> b
  }
}

// Tools and clients ----------------------------------------------------------------

/// The tools a server listed, as compact chips. The description is the
/// chip's tooltip and stays readable by screen readers.
pub fn tool_chips(tools: List(#(String, String))) -> Element(msg) {
  html.ul(
    [attribute.class("tool-chips")],
    list.map(tools, fn(tool) {
      let #(name, description) = tool
      html.li([attribute.class("tool-chip"), attribute.title(description)], [
        icon_classes("fa-solid fa-wrench"),
        html.code([], [text(name)]),
        case description {
          "" -> element.none()
          _ ->
            html.span([attribute.class("visually-hidden")], [text(description)])
        },
      ])
    }),
  )
}

/// The tool area under one server: a heading line and what follows.
pub fn server_tools(
  summary: List(Element(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.div([attribute.class("server-tools")], [
    html.p([attribute.class("server-tools-summary")], summary),
    ..children
  ])
}

/// A native disclosure, for lists that are long when open.
pub fn disclosure(
  summary: String,
  open: Bool,
  children: List(Element(msg)),
) -> Element(msg) {
  html.details([attribute.class("disclosure"), attribute.open(open)], [
    html.summary([attribute.class("disclosure-summary")], [
      icon("chevron-right"),
      text(summary),
    ]),
    ..children
  ])
}

pub type ClientChoice(msg) {
  ClientChoice(
    icon: String,
    label: String,
    detail: String,
    current: Bool,
    on_pick: Attribute(msg),
  )
}

/// A grid of MCP clients to set up. The picked one is pressed.
pub fn client_picker(
  label: String,
  items: List(ClientChoice(msg)),
) -> Element(msg) {
  html.div(
    [
      attribute.class("client-picker"),
      attribute.role("group"),
      attribute.aria_label(label),
    ],
    list.index_map(items, fn(item, index) {
      html.button(
        [
          attribute.class("client-option"),
          attribute.type_("button"),
          attribute.aria_pressed(case item.current {
            True -> "true"
            False -> "false"
          }),
          attribute.style("--i", int.to_string(int_min(index, 12))),
          item.on_pick,
        ],
        [
          html.span([attribute.class("client-icon")], [icon_classes(item.icon)]),
          html.span([attribute.class("client-text")], [
            html.strong([], [text(item.label)]),
            html.span([attribute.class("client-detail")], [text(item.detail)]),
          ]),
        ],
      )
    }),
  )
}

/// Numbered setup steps. Each step is a short line and optional content
/// under it, such as a snippet.
pub fn setup_steps(items: List(#(String, List(Element(msg))))) -> Element(msg) {
  html.ol(
    [attribute.class("setup-steps")],
    list.map(items, fn(item) {
      let #(title, children) = item
      html.li([attribute.class("setup-step")], [
        html.p([attribute.class("setup-step-title")], [text(title)]),
        ..children
      ])
    }),
  )
}
