//// The Enterprise page at `/enterprise`. `public/enterprise.js` sends the
//// form to `/api/contact`. Limits here are the `enterprise` plan in
//// `src/gateway/limits.rs`.

import lustre/element.{type Element, text}
import lustre/element/html
import ui/site

pub fn page() -> Element(msg) {
  site.document(
    site.Meta(
      title: "Enterprise | Fizzlayer",
      description: "Fizzlayer Enterprise is a custom plan for teams that run Fizzlayer Gateway. Gateway, MCP server and seat limits are set for your team, and phone approvals are set by contract.",
      path: "/enterprise",
      image_alt: "Fizzlayer Enterprise.",
      scripts: ["/webmcp.js", "/enterprise.js", "/analytics.js"],
    ),
    [
      site.page_hero_split(
        "Enterprise",
        "Fizzlayer Gateway for your team.",
        "On Enterprise, the number of gateways, MCP servers and seats is set for your team instead of the fixed plan limits. Use the hosted gateway or run it yourself with Docker. This form does not start a dedicated gateway.",
        [site.link_arrow("/pricing", "See the other plans")],
        site.sales_form(
          "Bring Fizzlayer to your team.",
          "Tell us how many servers, agents and people you have. We'll be in touch about Enterprise.",
        ),
      ),
      site.section("included", "Included", "What Enterprise adds.", "", [
        site.feature_row([
          site.feature_text(
            "Limits set for your team",
            "Gateways, MCP servers and seats are agreed with you. Pro stops at 1 gateway, 25 servers and 3 seats.",
          ),
          site.feature_text(
            "Phone approvals by contract",
            "When an Ask first rule holds a call, Fizzlayer phones a paired number and reads the request. You approve it in the app. Calls are unlimited unless a contract sets a cap.",
          ),
          site.feature_text(
            "Hosted or self-hosted",
            "Use the shared hosted gateway at gw.fizzlayer.com, or run the open-source gateway with Docker and link it to your account. Dedicated hosted gateways aren't ready yet.",
          ),
        ]),
        site.notes([
          html.p([], [
            text(
              "Tinkerer includes 20 phone calls a month and Pro includes 100. The cap resets on the first of each month (UTC). Hobbyist ($0) does not place calls. Approvals there go to a webhook or the log.",
            ),
          ]),
        ]),
      ]),
      site.pro_callout(),
    ],
  )
}
