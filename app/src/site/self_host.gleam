//// The self-host chooser at `/self-host`.

import lustre/element.{type Element}
import ui/site

pub fn page() -> Element(msg) {
  site.document(
    site.Meta(
      title: "Self-host | Fizzlayer",
      description: "Run Fizzlayer Gateway or Fizzlayer Sensors on your own machine with Docker.",
      path: "/self-host",
      image_alt: "Fizzlayer running on your own machine.",
      scripts: ["/analytics.js"],
    ),
    [
      site.page_hero(
        "Self-host",
        "Run Fizzlayer on your own machine.",
        "Both parts run with Docker and are free and open source. Pick the one you need.",
        [],
      ),
      site.section("choose", "Choose", "Which part do you want to run?", "", [
        site.split([
          site.split_card(
            "Gateway",
            "Put rules and approvals in front of your MCP servers. Build it from the repository with Docker Compose.",
            [site.link_arrow("/docs#quickstart", "Gateway quickstart")],
          ),
          site.split_card(
            "Sensors",
            "Run the website, API and device connections for your sensors with Docker Compose.",
            [site.link_arrow("/sensors/self-host", "Sensors guide")],
          ),
        ]),
      ]),
      site.pro_callout(),
    ],
  )
}
