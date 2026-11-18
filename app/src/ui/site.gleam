//// Components for the public site: header, footer, hero, sections. Like
//// `ui.gleam`, this module names CSS classes from `assets/fizz.css` (the
//// `site` layer) so page modules never do. Pages are pre-rendered to HTML by
//// `prerender.gleam`, so nothing here sends messages.

import gleam/list
import lustre/attribute.{type Attribute}
import lustre/element.{type Element, text}
import lustre/element/html

pub const origin = "https://fizzlayer.com"

/// What goes in a page's `<head>`.
pub type Meta {
  Meta(
    title: String,
    description: String,
    path: String,
    image_alt: String,
    scripts: List(String),
  )
}

/// A whole HTML document: head, header, main and footer.
pub fn document(meta: Meta, content: List(Element(msg))) -> Element(msg) {
  let url = origin <> meta.path
  html.html([attribute.lang("en")], [
    html.head([], [
      html.meta([attribute.charset("utf-8")]),
      html.meta([
        attribute.name("viewport"),
        attribute.content("width=device-width, initial-scale=1"),
      ]),
      html.meta([attribute.name("theme-color"), attribute.content("#ffffff")]),
      html.title([], meta.title),
      html.meta([
        attribute.name("description"),
        attribute.content(meta.description),
      ]),
      property("og:type", "website"),
      property("og:site_name", "Fizzlayer"),
      property("og:url", url),
      property("og:title", meta.title),
      property("og:description", meta.description),
      property("og:image", origin <> "/og.svg"),
      property("og:image:alt", meta.image_alt),
      named("twitter:card", "summary_large_image"),
      named("twitter:site", "@fizzlayer"),
      html.link([
        attribute.rel("icon"),
        attribute.href("/fizz-agent.svg"),
        attribute.type_("image/svg+xml"),
      ]),
      html.link([attribute.rel("canonical"), attribute.href(url)]),
      html.link([
        attribute.rel("preload"),
        attribute.href("/fonts/Geist-Variable.woff2"),
        attribute.attribute("as", "font"),
        attribute.type_("font/woff2"),
        attribute.attribute("crossorigin", ""),
      ]),
      html.link([attribute.rel("stylesheet"), attribute.href("/fizz.css")]),
      ..list.map(meta.scripts, fn(src) {
        html.script([attribute.src(src), attribute.attribute("defer", "")], "")
      })
    ]),
    html.body([attribute.class("site")], [
      html.a([attribute.class("skip-link"), attribute.href("#main")], [
        text("Skip to content"),
      ]),
      header(),
      html.main([attribute.id("main")], content),
      footer(),
    ]),
  ])
}

fn property(name: String, value: String) -> Element(msg) {
  html.meta([attribute.attribute("property", name), attribute.content(value)])
}

fn named(name: String, value: String) -> Element(msg) {
  html.meta([attribute.name(name), attribute.content(value)])
}

// Header and footer ------------------------------------------------------------

const nav_items = [
  #("/gateway", "Gateway"),
  #("/sensors", "Sensors"),
  #("/docs", "Docs"),
  #("/pricing", "Pricing"),
]

fn header() -> Element(msg) {
  let links = fn() {
    list.map(nav_items, fn(item) {
      html.a([attribute.class("site-nav-link"), attribute.href(item.0)], [
        text(item.1),
      ])
    })
  }
  html.header([attribute.class("site-header")], [
    html.div([attribute.class("container site-header-inner")], [
      wordmark(),
      html.nav(
        [attribute.class("site-nav"), attribute.aria_label("Main")],
        links(),
      ),
      html.div([attribute.class("site-header-actions")], [
        html.a(
          [
            attribute.class("site-nav-link"),
            attribute.href("/app/sign-in"),
          ],
          [text("Sign in")],
        ),
        primary("/app", "Get started"),
      ]),
      html.details([attribute.class("site-menu")], [
        html.summary([], [text("Menu")]),
        html.nav(
          [attribute.class("site-menu-panel"), attribute.aria_label("Main")],
          list.append(links(), [
            html.a(
              [
                attribute.class("site-nav-link"),
                attribute.href("/app/sign-in"),
              ],
              [text("Sign in")],
            ),
            primary("/app", "Get started"),
          ]),
        ),
      ]),
    ]),
  ])
}

fn wordmark() -> Element(msg) {
  html.a(
    [
      attribute.class("wordmark"),
      attribute.href("/"),
      attribute.aria_label("Fizzlayer home"),
    ],
    [
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
    ],
  )
}

const footer_columns = [
  #("Product", [
    #("/gateway", "Gateway"),
    #("/sensors", "Sensors"),
    #("/pricing", "Pricing"),
    #("/enterprise", "Enterprise"),
  ]),
  #("Developers", [
    #("/docs", "Gateway docs"),
    #("/sensors/docs", "Sensors docs"),
    #("/self-host", "Self-host"),
    #("/status", "Status"),
    #("/changelog", "Changelog"),
    #("/llms.txt", "For AI agents"),
  ]),
  #("Company", [
    #("https://github.com/fizzlayer/fizzlayer", "GitHub"),
    #("https://x.com/fizzlayer", "X"),
    #("/privacy.html", "Privacy"),
    #("/terms.html", "Terms"),
  ]),
]

fn footer() -> Element(msg) {
  html.footer([attribute.class("site-footer")], [
    html.div([attribute.class("container")], [
      html.div([attribute.class("footer-grid")], [
        html.div([], [
          wordmark(),
          html.p([attribute.class("footer-tagline")], [
            text("Control what your AI agents can do."),
          ]),
        ]),
        ..list.map(footer_columns, fn(column) {
          html.nav([attribute.aria_label(column.0)], [
            html.h2([attribute.class("footer-title")], [text(column.0)]),
            html.ul(
              [attribute.class("footer-links")],
              list.map(column.1, fn(link) {
                html.li([], [html.a([attribute.href(link.0)], [text(link.1)])])
              }),
            ),
          ])
        })
      ]),
      html.div([attribute.class("footer-bottom")], [
        html.span([], [text("© 2026 Fizzlayer LLC")]),
        html.span([], [text("Open source under Apache-2.0")]),
      ]),
    ]),
  ])
}

// Links and buttons ---------------------------------------------------------------

/// The main call to action: a filled pill with an arrow.
pub fn primary(href: String, label: String) -> Element(msg) {
  html.a(
    [
      attribute.class("button button-primary button-lg button-arrow"),
      attribute.href(href),
    ],
    [text(label <> " ")],
  )
}

/// A text link with an arrow, for the second choice beside `primary`.
pub fn link_arrow(href: String, label: String) -> Element(msg) {
  html.a([attribute.class("link-arrow"), attribute.href(href)], [text(label)])
}

// Hero ---------------------------------------------------------------------------

pub fn hero(
  title: String,
  sub: String,
  actions: List(Element(msg)),
  note: String,
  visual: Element(msg),
) -> Element(msg) {
  html.section([attribute.class("hero")], [
    html.div([attribute.class("container hero-grid")], [
      html.div([], [
        html.h1([attribute.class("hero-title")], [text(title)]),
        html.p([attribute.class("hero-sub")], [text(sub)]),
        html.div([attribute.class("hero-actions")], actions),
        html.p([attribute.class("hero-note")], [text(note)]),
      ]),
      visual,
    ]),
  ])
}

/// A product picture made of cards. Decorative: screen readers get `label`.
pub fn preview(label: String, cards: List(Element(msg))) -> Element(msg) {
  html.div(
    [
      attribute.class("preview"),
      attribute.role("img"),
      attribute.aria_label(label),
    ],
    cards,
  )
}

pub fn preview_card(
  title: String,
  meta: String,
  waiting: Bool,
  body: List(Element(msg)),
) -> Element(msg) {
  html.div([attribute.class("preview-card"), attribute.aria_hidden(True)], [
    html.div([attribute.class("preview-head")], [
      case waiting {
        True -> html.span([attribute.class("pulse")], [])
        False -> element.none()
      },
      text(title),
      html.span([attribute.class("preview-head-meta")], [text(meta)]),
    ]),
    html.div([attribute.class("preview-body")], body),
  ])
}

pub fn preview_row(left: Element(msg), right: Element(msg)) -> Element(msg) {
  html.div([attribute.class("preview-row")], [left, right])
}

pub fn tool(name: String) -> Element(msg) {
  html.span([attribute.class("preview-tool")], [text(name)])
}

pub fn label(content: String) -> Element(msg) {
  html.span([attribute.class("preview-label")], [text(content)])
}

pub fn value(content: String) -> Element(msg) {
  html.span([attribute.class("preview-value")], [text(content)])
}

/// Approve and Reject as they look in the app. Not interactive.
pub fn preview_buttons() -> Element(msg) {
  html.div([attribute.class("preview-buttons")], [
    html.span([attribute.class("button button-primary")], [text("Approve")]),
    html.span([attribute.class("button button-secondary")], [text("Reject")]),
  ])
}

pub type Rule {
  Allow
  Block
  AskFirst
}

pub fn pill(rule: Rule) -> Element(msg) {
  let #(class, name) = case rule {
    Allow -> #("pill pill-allow", "Allow")
    Block -> #("pill pill-block", "Block")
    AskFirst -> #("pill pill-ask", "Ask first")
  }
  html.span([attribute.class(class)], [text(name)])
}

pub fn status_pill(active: Bool) -> Element(msg) {
  case active {
    True -> html.span([attribute.class("pill pill-allow")], [text("Active")])
    False -> html.span([attribute.class("pill pill-block")], [text("Revoked")])
  }
}

// Sections -----------------------------------------------------------------------

/// The names of clients the gateway works with, in one quiet row.
pub fn clients(label: String, names: List(String)) -> Element(msg) {
  html.section([attribute.class("clients"), attribute.aria_label(label)], [
    html.div([attribute.class("container clients-inner")], [
      html.span([attribute.class("clients-label")], [text(label)]),
      ..list.map(names, fn(name) {
        html.span([attribute.class("clients-name")], [text(name)])
      })
    ]),
  ])
}

pub fn section(
  id: String,
  kicker: String,
  title: String,
  sub: String,
  children: List(Element(msg)),
) -> Element(msg) {
  html.section(
    [
      attribute.class("section"),
      attribute.id(id),
      attribute.attribute("aria-labelledby", id <> "-title"),
    ],
    [
      html.div([attribute.class("container")], [
        html.div([attribute.class("section-head")], [
          html.p([attribute.class("section-kicker")], [text(kicker)]),
          html.h2(
            [attribute.class("section-title"), attribute.id(id <> "-title")],
            [
              text(title),
            ],
          ),
          case sub {
            "" -> element.none()
            sub -> html.p([attribute.class("section-sub")], [text(sub)])
          },
        ]),
        ..children
      ]),
    ],
  )
}

pub fn feature_grid(children: List(Element(msg))) -> Element(msg) {
  html.div([attribute.class("feature-grid")], children)
}

pub fn feature(
  title: String,
  body: String,
  visual: Element(msg),
) -> Element(msg) {
  html.article([attribute.class("feature")], [
    html.h3([], [text(title)]),
    html.p([], [text(body)]),
    html.div([attribute.class("feature-visual"), attribute.aria_hidden(True)], [
      visual,
    ]),
  ])
}

/// Rows of a name on the left and a pill on the right.
pub fn rows(items: List(#(Element(msg), Element(msg)))) -> Element(msg) {
  html.div(
    [attribute.class("mini-rules")],
    list.map(items, fn(item) {
      html.div([attribute.class("mini-rule")], [item.0, item.1])
    }),
  )
}

/// A notification as it arrives on a phone.
pub fn notification(title: String, detail: String) -> Element(msg) {
  html.div([attribute.class("mini-notice")], [
    html.img([
      attribute.src("/fizz-logo.svg"),
      attribute.alt(""),
      attribute.width(28),
      attribute.height(28),
    ]),
    html.div([], [
      html.strong([], [text(title)]),
      html.small([], [text(detail)]),
      preview_buttons(),
    ]),
  ])
}

/// A before and after of one line of text.
pub fn diff(before: String, after: String) -> Element(msg) {
  html.p([attribute.class("mini-diff")], [
    html.del([], [text(before)]),
    html.ins([], [text(after)]),
  ])
}

/// Numbered steps. Each item is `#(title, body)`.
pub fn steps(items: List(#(String, String))) -> Element(msg) {
  html.ol(
    [attribute.class("steps-grid")],
    list.map(items, fn(item) {
      html.li([attribute.class("step-item")], [
        html.h3([], [text(item.0)]),
        html.p([], [text(item.1)]),
      ])
    }),
  )
}

pub fn split(children: List(Element(msg))) -> Element(msg) {
  html.div([attribute.class("split")], children)
}

pub fn split_card(
  title: String,
  body: String,
  children: List(Element(msg)),
) -> Element(msg) {
  html.div([attribute.class("split-card")], [
    html.h3([], [text(title)]),
    html.p([], [text(body)]),
    ..children
  ])
}

/// The hosted-gateway waitlist. `public/gateway-beta.js` submits it.
pub fn waitlist_form() -> Element(msg) {
  html.form([attribute.id("beta-form"), attribute.class("waitlist-form")], [
    html.label(
      [attribute.class("visually-hidden"), attribute.for("beta-email")],
      [
        text("Email"),
      ],
    ),
    input("beta-email", "email", "Email", "email", []),
    html.label(
      [attribute.class("visually-hidden"), attribute.for("beta-company")],
      [text("Name or company")],
    ),
    input("beta-company", "text", "Name or company", "organization", [
      attribute.attribute("maxlength", "120"),
    ]),
    html.button(
      [
        attribute.class("button button-primary button-lg"),
        attribute.type_("submit"),
      ],
      [text("Join the waitlist")],
    ),
    html.p(
      [
        attribute.id("beta-status"),
        attribute.class("waitlist-status"),
        attribute.role("status"),
      ],
      [],
    ),
  ])
}

fn input(
  id: String,
  kind: String,
  placeholder: String,
  autocomplete: String,
  extra: List(Attribute(msg)),
) -> Element(msg) {
  html.input([
    attribute.class("input"),
    attribute.id(id),
    attribute.type_(kind),
    attribute.placeholder(placeholder),
    attribute.autocomplete(autocomplete),
    attribute.required(True),
    ..extra
  ])
}

/// A wide row that points to another product.
pub fn band(title: String, body: String, link: Element(msg)) -> Element(msg) {
  html.section([attribute.class("container")], [
    html.div([attribute.class("band")], [
      html.div([], [html.h2([], [text(title)]), html.p([], [text(body)])]),
      link,
    ]),
  ])
}

/// The dark closing panel.
pub fn cta(
  title: String,
  body: String,
  actions: List(Element(msg)),
) -> Element(msg) {
  html.section([attribute.class("container section-tight")], [
    html.div([attribute.class("cta-panel")], [
      html.h2([], [text(title)]),
      html.p([], [text(body)]),
      html.div([attribute.class("hero-actions")], actions),
    ]),
  ])
}
