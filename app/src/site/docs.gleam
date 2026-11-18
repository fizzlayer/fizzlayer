//// Docs pages. Their text lives in `app/content/docs/<slug>/` as HTML
//// (`lede.html`, `toc.html`, `body.html`); this module wraps it in the site
//// layout. Technical detail belongs here, not on the product pages.

import lustre/element.{type Element}
import ui/site

pub type Doc {
  Doc(
    slug: String,
    path: String,
    title: String,
    description: String,
    kicker: String,
    heading: String,
    scripts: List(String),
  )
}

pub const all = [
  Doc(
    slug: "gateway",
    path: "/docs",
    title: "Gateway docs | Fizzlayer",
    description: "Run Fizzlayer Gateway with Docker, connect an MCP client, and use the /api/gateway control plane.",
    kicker: "Gateway docs",
    heading: "Fizzlayer Gateway",
    scripts: ["/docs.js", "/analytics.js"],
  ),
  Doc(
    slug: "sensors",
    path: "/sensors/docs",
    title: "Sensors docs | Fizzlayer",
    description: "Connect sensors, phones and Linux devices, send readings over HTTP, set alerts, and connect AI agents through MCP and WebMCP.",
    kicker: "Sensors docs",
    heading: "Build with Fizzlayer Sensors",
    scripts: ["/webmcp.js", "/docs.js", "/analytics.js"],
  ),
  Doc(
    slug: "sensors-self-host",
    path: "/sensors/self-host",
    title: "Self-host Fizzlayer Sensors with Docker",
    description: "Run the Fizzlayer Sensors stack on your own machine with Docker, and send readings over HTTPS, WebSocket and MQTT.",
    kicker: "Self-host",
    heading: "Run Fizzlayer Sensors with Docker",
    scripts: ["/webmcp.js", "/docs.js", "/analytics.js"],
  ),
]

pub fn page(doc: Doc, lede: String, toc: String, body: String) -> Element(msg) {
  site.document(
    site.Meta(
      title: doc.title,
      description: doc.description,
      path: doc.path,
      image_alt: "Fizzlayer documentation.",
      scripts: doc.scripts,
    ),
    site.docs(doc.kicker, doc.heading, lede, toc, body),
  )
}
