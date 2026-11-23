//// The Enterprise page at `/enterprise`. `public/enterprise.js` sends the
//// form to `/api/contact`.

import lustre/element.{type Element, text}
import lustre/element/html
import ui/site

pub fn page() -> Element(msg) {
  site.document(
    site.Meta(
      title: "Enterprise | Fizzlayer",
      description: "Fizzlayer Enterprise is a custom plan for sites such as cold storage and factory floors. Tell us what you need to watch.",
      path: "/enterprise",
      image_alt: "Fizzlayer Enterprise.",
      scripts: ["/webmcp.js", "/enterprise.js", "/analytics.js"],
    ),
    [
      site.page_hero_split(
        "Enterprise",
        "Sensors for a site, and a gateway when you need one.",
        "Cold storage, logistics, or the factory floor. Bring your signals into one workspace and get the right person on the phone when a threshold is crossed. Gateway limits on Enterprise are custom. This form does not start a dedicated gateway.",
        [site.link_arrow("/pricing", "See the other plans")],
        site.sales_form(
          "Bring Fizzlayer to your team.",
          "Tell us what you need to watch. We'll be in touch about Enterprise.",
        ),
      ),
      site.section("included", "Included", "What Enterprise adds.", "", [
        site.feature_row([
          site.feature_text(
            "Control access, device by device.",
            "Separate, revocable keys for your sensors and tokens for your agents.",
          ),
          site.feature_text(
            "Start before install day.",
            "Explore with simulated sensor streams while your hardware is on its way.",
          ),
          site.feature_text(
            "Reach the right person.",
            "Pair the number first. Fizz calls it when an alert fires. Phone calls are included with Enterprise, unlimited unless a contract sets a cap.",
          ),
        ]),
        site.notes([
          html.p([], [
            text(
              "Tinkerer and Pro share one monthly call cap for phone-call alerts and phone approvals. Tinkerer includes 20 calls a month and Pro includes 100. The cap resets on the first of each month (UTC). Hobbyist ($0) does not place calls. It includes dashboard and webhook alerts. Email alerts are included on every plan and stay hidden in the dashboard until mail is configured.",
            ),
          ]),
        ]),
      ]),
    ],
  )
}
