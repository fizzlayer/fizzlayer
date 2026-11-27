//// Components for the public site: header, footer, hero, sections. Like
//// `ui.gleam`, this module names CSS classes from `assets/fizz.css` (the
//// `site` layer) so page modules never do. Pages are pre-rendered to HTML by
//// `prerender.gleam`, so nothing here sends messages.

import gleam/list
import lustre/attribute
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
      // The browser bar matches the site header, which matches the logo tile.
      html.meta([attribute.name("theme-color"), attribute.content("#0b1722")]),
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
      header(meta.path),
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

/// `path` is the page's own path; its nav item gets `aria-current="page"`.
fn header(path: String) -> Element(msg) {
  let links = fn() {
    list.map(nav_items, fn(item) {
      // A list, not `attribute.none()`, which renders as a trailing space in
      // `class`.
      let current = case item.0 == path {
        True -> [attribute.aria_current("page")]
        False -> []
      }
      html.a(
        [attribute.class("site-nav-link"), attribute.href(item.0), ..current],
        [text(item.1)],
      )
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
            text("Rules and approvals for the MCP tools your AI agents call."),
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

/// A wide row that points to another product.
pub fn band(title: String, body: String, link: Element(msg)) -> Element(msg) {
  html.section([attribute.class("container")], [
    html.div([attribute.class("band")], [
      html.div([], [html.h2([], [text(title)]), html.p([], [text(body)])]),
      link,
    ]),
  ])
}

/// A short pitch for the Pro plan, near the end of a public page. The limits
/// are the Pro column of `site/pricing.gleam` and must change with it.
pub fn pro_callout() -> Element(msg) {
  html.section(
    [
      attribute.class("container section-tight"),
      attribute.attribute("aria-labelledby", "pro-callout-title"),
    ],
    [
      html.div([attribute.class("band pro-callout")], [
        html.div([], [
          html.h2([attribute.id("pro-callout-title")], [
            text("Fizzlayer Pro is $25 a month"),
          ]),
          html.p([], [
            text(
              "Hobbyist stops at 3 MCP servers and does not place phone calls. Pro allows 25 servers, includes 100 phone calls a month for approvals, and has 3 seats.",
            ),
          ]),
        ]),
        html.div([attribute.class("pro-callout-actions")], [
          primary("/app?plan=pro", "Start Pro"),
          link_arrow("/pricing", "Compare plans"),
        ]),
      ]),
    ],
  )
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

// Inner pages ------------------------------------------------------------------

/// The top of a page that has no product picture: kicker, title, one line.
pub fn page_hero(
  kicker: String,
  title: String,
  sub: String,
  actions: List(Element(msg)),
) -> Element(msg) {
  html.section([attribute.class("page-hero")], [
    html.div([attribute.class("container")], [
      html.p([attribute.class("section-kicker")], [text(kicker)]),
      html.h1([attribute.class("page-title")], [text(title)]),
      html.p([attribute.class("hero-sub")], [text(sub)]),
      case actions {
        [] -> element.none()
        _ -> html.div([attribute.class("hero-actions")], actions)
      },
    ]),
  ])
}

/// The top of a page with something beside the title, such as a form.
pub fn page_hero_split(
  kicker: String,
  title: String,
  sub: String,
  actions: List(Element(msg)),
  aside: Element(msg),
) -> Element(msg) {
  html.section([attribute.class("page-hero")], [
    html.div([attribute.class("container hero-grid hero-grid-top")], [
      html.div([], [
        html.p([attribute.class("section-kicker")], [text(kicker)]),
        html.h1([attribute.class("page-title")], [text(title)]),
        html.p([attribute.class("hero-sub")], [text(sub)]),
        case actions {
          [] -> element.none()
          _ -> html.div([attribute.class("hero-actions")], actions)
        },
      ]),
      aside,
    ]),
  ])
}

/// Three cards in a row.
pub fn feature_row(children: List(Element(msg))) -> Element(msg) {
  html.div([attribute.class("feature-grid feature-grid-3")], children)
}

/// A card with a title and a sentence, and no picture.
pub fn feature_text(title: String, body: String) -> Element(msg) {
  html.article([attribute.class("feature")], [
    html.h3([], [text(title)]),
    html.p([], [text(body)]),
  ])
}

/// A card with a title and a ticked list.
pub fn list_card(title: String, items: List(String)) -> Element(msg) {
  html.div([attribute.class("split-card")], [
    html.h3([], [text(title)]),
    checklist(items),
  ])
}

pub fn checklist(items: List(String)) -> Element(msg) {
  html.ul(
    [attribute.class("checklist")],
    list.map(items, fn(item) { html.li([], [text(item)]) }),
  )
}

/// Questions that open in place. Each item is `#(question, answer)`.
pub fn faq(items: List(#(String, String))) -> Element(msg) {
  html.div(
    [attribute.class("faq")],
    list.map(items, fn(item) {
      html.details([attribute.class("faq-item")], [
        html.summary([], [text(item.0)]),
        html.p([], [text(item.1)]),
      ])
    }),
  )
}

// Pricing ----------------------------------------------------------------------

pub type Plan {
  Plan(
    name: String,
    tagline: String,
    price: String,
    period: String,
    featured: Bool,
    points: List(String),
    href: String,
    cta: String,
  )
}

pub fn plans(cards: List(Plan)) -> Element(msg) {
  html.div(
    [attribute.class("plans")],
    list.map(cards, fn(plan) {
      html.article(
        [
          attribute.class(case plan.featured {
            True -> "plan-card plan-card-featured"
            False -> "plan-card"
          }),
        ],
        [
          html.h2([attribute.class("plan-name")], [
            text(plan.name),
            case plan.featured {
              True ->
                html.span([attribute.class("plan-badge")], [
                  text("Recommended"),
                ])
              False -> element.none()
            },
          ]),
          html.p([attribute.class("plan-tagline")], [text(plan.tagline)]),
          html.p([attribute.class("plan-price")], [
            text(plan.price),
            case plan.period {
              "" -> element.none()
              period -> html.small([], [text(" " <> period)])
            },
          ]),
          checklist(plan.points),
          html.a(
            [
              attribute.class(case plan.featured {
                True -> "button button-primary button-lg button-block"
                False -> "button button-secondary button-lg button-block"
              }),
              attribute.href(plan.href),
            ],
            [text(plan.cta)],
          ),
        ],
      )
    }),
  )
}

/// A table with a header row. The first cell of each row is its label.
pub fn compare(
  caption: String,
  head: List(String),
  rows: List(List(String)),
) -> Element(msg) {
  html.div([attribute.class("compare-wrap")], [
    html.table([attribute.class("compare")], [
      html.caption([attribute.class("visually-hidden")], [text(caption)]),
      html.thead([], [
        html.tr(
          [],
          list.map(head, fn(cell) {
            html.th([attribute.attribute("scope", "col")], [text(cell)])
          }),
        ),
      ]),
      html.tbody(
        [],
        list.map(rows, fn(row) {
          case row {
            [] -> element.none()
            [label, ..cells] ->
              html.tr([], [
                html.th([attribute.attribute("scope", "row")], [text(label)]),
                ..list.map(cells, fn(cell) { html.td([], [text(cell)]) })
              ])
          }
        }),
      ),
    ]),
  ])
}

/// Small print under a section.
pub fn notes(children: List(Element(msg))) -> Element(msg) {
  html.div([attribute.class("notes")], children)
}

// Docs -------------------------------------------------------------------------

/// A docs page: title and lede, a sticky contents list, and the article.
/// `lede`, `toc` and `body` are trusted HTML from `app/content/docs`.
/// `public/docs.js` adds Copy buttons to `.legal-body pre` and marks the
/// current entry in `.docs-toc`.
pub fn docs(
  kicker: String,
  title: String,
  lede: String,
  toc: String,
  body: String,
) -> List(Element(msg)) {
  [
    html.section([attribute.class("page-hero page-hero-docs")], [
      html.div([attribute.class("container")], [
        html.p([attribute.class("section-kicker")], [text(kicker)]),
        html.h1([attribute.class("page-title"), attribute.id("title")], [
          text(title),
        ]),
        element.unsafe_raw_html("", "p", [attribute.class("hero-sub")], lede),
      ]),
    ]),
    html.div([attribute.class("container docs-layout")], [
      element.unsafe_raw_html(
        "",
        "nav",
        [
          attribute.class("docs-toc"),
          attribute.aria_label("On this page"),
        ],
        toc,
      ),
      element.unsafe_raw_html(
        "",
        "article",
        [
          attribute.class("legal-body prose"),
          attribute.attribute("aria-labelledby", "title"),
        ],
        body,
      ),
    ]),
  ]
}

// Changelog --------------------------------------------------------------------

/// Days, newest first. Each item is `#(date, changes)`.
pub fn changelog(days: List(#(String, List(String)))) -> Element(msg) {
  html.section([attribute.class("container")], [
    html.article(
      [attribute.class("prose changelog")],
      list.flat_map(days, fn(day) {
        [
          html.h2([], [text(day.0)]),
          html.ul(
            [],
            list.map(day.1, fn(change) { html.li([], [text(change)]) }),
          ),
        ]
      }),
    ),
  ])
}

// Status -----------------------------------------------------------------------

/// The list `public/status.js` fills in, with its first "Checking" row.
/// `status.js` finds it and the line under it by id.
pub fn status_list(checking: String) -> Element(msg) {
  html.section([attribute.class("container")], [
    html.ul([attribute.class("status-list"), attribute.id("status-list")], [
      html.li([], [
        html.div([], [
          html.strong([], [text("Checking")]),
          html.p([], [text(checking)]),
        ]),
      ]),
    ]),
    html.p(
      [
        attribute.class("status-checked"),
        attribute.id("status-checked"),
        attribute.role("status"),
      ],
      [],
    ),
  ])
}

// Contact form -----------------------------------------------------------------

/// The Enterprise contact form. `public/enterprise.js` finds the form, its
/// fields and the status line by id and posts them to `/api/contact`.
pub fn sales_form(title: String, intro: String) -> Element(msg) {
  html.div([attribute.class("contact-card"), attribute.id("business")], [
    html.h2([], [text(title)]),
    html.p([], [text(intro)]),
    html.form(
      [
        attribute.class("contact-form"),
        attribute.id("business-form"),
        attribute.attribute("novalidate", ""),
      ],
      [
        field("business-email", "Work email", False, False, [
          html.input([
            attribute.class("input"),
            attribute.id("business-email"),
            attribute.name("email"),
            attribute.type_("email"),
            attribute.autocomplete("email"),
            attribute.attribute("maxlength", "254"),
            attribute.required(True),
            attribute.placeholder("you@company.com"),
          ]),
        ]),
        field("business-company", "Company", False, False, [
          html.input([
            attribute.class("input"),
            attribute.id("business-company"),
            attribute.name("company"),
            attribute.type_("text"),
            attribute.autocomplete("organization"),
            attribute.attribute("maxlength", "120"),
            attribute.required(True),
            attribute.placeholder("Acme Logistics"),
          ]),
        ]),
        field(
          "business-interest",
          "What do you need from the gateway?",
          True,
          True,
          [
            html.textarea(
              [
                attribute.class("input"),
                attribute.id("business-interest"),
                attribute.name("interest"),
                attribute.attribute("maxlength", "500"),
                attribute.rows(3),
                attribute.placeholder(
                  "e.g. 40 MCP servers for 12 engineers, with phone approvals",
                ),
              ],
              "",
            ),
          ],
        ),
        html.div([attribute.class("contact-actions")], [
          html.button(
            [
              attribute.class("button button-primary button-lg button-arrow"),
              attribute.type_("submit"),
            ],
            [text("Contact sales ")],
          ),
        ]),
        html.p(
          [
            attribute.class("form-status"),
            attribute.id("business-status"),
            attribute.role("status"),
            attribute.attribute("aria-live", "polite"),
          ],
          [],
        ),
      ],
    ),
  ])
}

fn field(
  id: String,
  label: String,
  optional: Bool,
  wide: Bool,
  control: List(Element(msg)),
) -> Element(msg) {
  html.div(
    [
      attribute.class(case wide {
        True -> "field field-wide"
        False -> "field"
      }),
    ],
    [
      html.label([attribute.class("field-label"), attribute.for(id)], [
        text(label),
        case optional {
          True ->
            html.span([attribute.class("field-optional")], [
              text(" (optional)"),
            ])
          False -> element.none()
        },
      ]),
      ..control
    ],
  )
}

/// Page-width content with no section spacing of its own.
pub fn container(children: List(Element(msg))) -> Element(msg) {
  html.section([attribute.class("container")], children)
}
