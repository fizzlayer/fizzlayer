//// Fizzlayer's UI components. This is the only module that names CSS classes
//// from `assets/fizz.css`; `scripts/check-ui-classes.sh` fails CI if another
//// module calls `attribute.class`. Screens are built from these functions so
//// every page shares one look.

import gleam/list
import lustre/attribute.{type Attribute}
import lustre/element.{type Element, text}
import lustre/element/html

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
          html.a(
            [
              attribute.href(href),
              case current {
                True -> attribute.aria_current("step")
                False -> attribute.none()
              },
            ],
            [text(label)],
          ),
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
