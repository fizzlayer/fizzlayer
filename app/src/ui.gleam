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
