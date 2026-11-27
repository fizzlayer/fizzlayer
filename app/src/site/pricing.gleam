//// The pricing page at `/pricing`. Prices and limits come from `fizz_plans`
//// and must match `public/webmcp.js` and the app's checkout.

import lustre/attribute
import lustre/element.{type Element, text}
import lustre/element/html
import ui/site

pub fn page() -> Element(msg) {
  site.document(
    site.Meta(
      title: "Pricing | Fizzlayer",
      description: "Hobbyist is free. Tinkerer is $10 a month and Pro is $25. Each plan includes a hosted MCP gateway, and self-hosting is free.",
      path: "/pricing",
      image_alt: "Fizzlayer plans: Hobbyist, Tinkerer, Pro and Enterprise.",
      scripts: ["/webmcp.js", "/analytics.js"],
    ),
    [
      site.page_hero(
        "Pricing",
        "Start on Hobbyist for free, and upgrade when you hit a limit.",
        "Every plan includes a hosted MCP gateway, and self-hosting is free. We recommend Pro if you want approvals by phone.",
        [],
      ),
      site.container([
        site.plans([
          site.Plan(
            name: "Hobbyist",
            tagline: "For your first agent",
            price: "$0",
            period: "",
            featured: False,
            points: [
              "1 shared hosted gateway",
              "3 MCP servers",
              "Approvals by webhook or log",
            ],
            href: "/app?plan=hobbyist",
            cta: "Get started",
          ),
          site.Plan(
            name: "Tinkerer",
            tagline: "For the home lab",
            price: "$10",
            period: "/ month",
            featured: False,
            points: [
              "1 shared hosted gateway",
              "10 MCP servers",
              "20 phone calls a month",
            ],
            href: "/app?plan=tinkerer",
            cta: "Get started",
          ),
          site.Plan(
            name: "Pro",
            tagline: "For up to 3 people",
            price: "$25",
            period: "/ month",
            featured: True,
            points: [
              "1 shared hosted gateway",
              "25 MCP servers",
              "100 phone calls a month",
              "3 seats",
            ],
            href: "/app?plan=pro",
            cta: "Start Pro",
          ),
          site.Plan(
            name: "Enterprise",
            tagline: "For teams",
            price: "Custom",
            period: "",
            featured: False,
            points: [
              "Custom gateway and server limits",
              "Phone calls set by contract",
              "Seats for your team",
            ],
            href: "/enterprise",
            cta: "Contact us",
          ),
        ]),
      ]),
      site.section("compare", "Compare", "Plan limits side by side.", "", [
        site.compare(
          "Fizzlayer plan limits",
          ["", "Hobbyist", "Tinkerer", "Pro", "Enterprise"],
          [
            ["Price", "$0", "$10 / month", "$25 / month", "Custom"],
            ["Hosted gateways", "1 shared", "1 shared", "1 shared", "Custom"],
            ["MCP servers", "3", "10", "25", "Custom"],
            ["Phone calls a month", "None", "20", "100", "By contract"],
            ["Seats", "1", "1", "3", "Custom"],
          ],
        ),
        site.notes([
          html.p([], [
            text(
              "Approval calls for Ask first rules count toward the phone call limit, which resets on the first of each month (UTC). On Hobbyist, approvals go to a webhook or the log.",
            ),
          ]),
          html.p([], [
            text(
              "Every plan includes a shared hosted gateway. Dedicated gateways on Pro aren't ready yet. ",
            ),
            html.a([attribute.href("/docs#limits")], [
              text("Full plan details are in the docs."),
            ]),
          ]),
        ]),
      ]),
      site.cta(
        "Not sure which plan?",
        "Pick Pro if you want approval calls on your phone. It includes 100 calls a month and room for 25 MCP servers. Otherwise start on Hobbyist and upgrade in Settings later.",
        [
          site.primary("/app?plan=pro", "Start Pro"),
          site.link_arrow("/app", "Start free on Hobbyist"),
          site.link_arrow("/enterprise", "Talk to us"),
        ],
      ),
    ],
  )
}
