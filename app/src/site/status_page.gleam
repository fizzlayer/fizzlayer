//// The status page at `/status`. `public/status.js` asks the API from the
//// browser and fills in the list.

import lustre/element.{type Element}
import ui/site

pub fn page() -> Element(msg) {
  site.document(
    site.Meta(
      title: "Status | Fizzlayer",
      description: "Current Fizzlayer status from the public API, the alert scheduler, and live-stream checks. No uptime history or SLA.",
      path: "/status",
      image_alt: "Fizzlayer status.",
      scripts: ["/webmcp.js", "/status.js", "/analytics.js"],
    ),
    [
      site.page_hero(
        "Status",
        "Fizzlayer right now.",
        "This page asks the public API from your browser. It shows the answer it just received, including the alert scheduler. It does not keep an uptime history or promise an SLA.",
        [],
      ),
      site.status_list(
        "Asking /api/status, including the alert scheduler, and /api/stream.",
      ),
    ],
  )
}
