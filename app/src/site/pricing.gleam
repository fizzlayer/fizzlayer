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
      description: "Hobbyist is free. Tinkerer is $10 a month and Pro is $25. Each plan covers Gateway and Sensors.",
      path: "/pricing",
      image_alt: "Fizzlayer plans: Hobbyist, Tinkerer, Pro and Enterprise.",
      scripts: ["/webmcp.js", "/analytics.js"],
    ),
    [
      site.page_hero(
        "Pricing",
        "Start free. Upgrade when you need more.",
        "Every plan covers Gateway and Sensors. Self-hosting is free.",
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
              "3 MCP servers",
              "3 connected devices",
              "10 Fizz credits a month",
              "Webhook and dashboard alerts",
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
              "10 MCP servers",
              "10 connected devices",
              "100 Fizz credits a month",
              "20 phone calls a month",
            ],
            href: "/app?plan=tinkerer",
            cta: "Get started",
          ),
          site.Plan(
            name: "Pro",
            tagline: "For serious setups",
            price: "$25",
            period: "/ month",
            featured: True,
            points: [
              "25 MCP servers",
              "50 connected devices",
              "1,000 Fizz credits a month",
              "100 phone calls a month",
              "3 seats",
            ],
            href: "/app?plan=pro",
            cta: "Get started",
          ),
          site.Plan(
            name: "Enterprise",
            tagline: "For teams and sites",
            price: "Custom",
            period: "",
            featured: False,
            points: [
              "Custom servers and devices",
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
            ["MCP servers", "3", "10", "25", "Custom"],
            ["Connected devices", "3", "10", "50", "Custom"],
            ["Fizz credits a month", "10", "100", "1,000", "Custom"],
            ["Phone calls a month", "None", "20", "100", "By contract"],
            ["Seats", "1", "1", "3", "Custom"],
          ],
        ),
        site.notes([
          html.p([], [
            text(
              "Phone calls cover alert calls and approval calls, and reset on the first of each month (UTC). Sample sensors don't count as devices. One Fizz credit is one message to Fizz.",
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
        "Start on Hobbyist. You can upgrade any time in Settings.",
        [
          site.primary("/app", "Get started"),
          site.link_arrow("/enterprise", "Talk to us"),
        ],
      ),
    ],
  )
}
