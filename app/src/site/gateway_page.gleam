//// The Gateway product page at `/gateway`. Plain words only: how it works
//// and what it protects against. Setup, limits and the API are in the docs.

import lustre/element.{type Element}
import site/landing
import ui/site.{Allow, AskFirst, Block}

pub fn page() -> Element(msg) {
  site.document(
    site.Meta(
      title: "Fizzlayer Gateway | Rules and approvals for every MCP tool",
      description: "Fizzlayer Gateway sits between your AI agents and your MCP servers. Set a rule for each tool, approve risky calls before they run, and keep API keys off the client.",
      path: "/gateway",
      image_alt: "Fizzlayer Gateway between an AI agent and its tools, with Allow, Block and Ask first rules.",
      scripts: ["/analytics.js"],
    ),
    [
      hero(),
      problems(),
      how_it_works(),
      safety(),
      landing.run_it(),
      questions(),
      site.pro_callout(),
      site.cta(
        "Put your first server behind a rule.",
        "Self-host free with Docker, or set up your gateway in the app.",
        [
          site.primary("/app", "Get started"),
          site.link_arrow("/docs", "Read the docs"),
        ],
      ),
    ],
  )
}

fn hero() -> Element(msg) {
  site.hero(
    "Put a rule on every tool your agent can call.",
    "Fizzlayer Gateway sits between your AI agents and your MCP servers. It checks every call, holds risky ones for you, and keeps API keys off the client.",
    [
      site.primary("/app", "Get started"),
      site.link_arrow("/docs", "Read the docs"),
    ],
    "Hosted in the app, or self-host free with Docker.",
    site.preview(
      "Example: rules for a payments server, and a tool that changed.",
      [
        site.preview_card("Rules", "payments", False, [
          site.preview_row(site.tool("list_invoices"), site.pill(Allow)),
          site.preview_row(site.tool("create_refund"), site.pill(AskFirst)),
          site.preview_row(site.tool("delete_customer"), site.pill(Block)),
        ]),
        site.preview_card("Tool changed", "needs review", True, [
          site.preview_row(site.label("Tool"), site.tool("create_refund")),
          site.preview_row(site.label("Change"), site.value("New description")),
          site.preview_row(site.label("Until reviewed"), site.value("Hidden")),
          site.preview_buttons(),
        ]),
      ],
    ),
  )
}

fn problems() -> Element(msg) {
  site.section(
    "problems",
    "Why a gateway",
    "What goes wrong when an agent connects directly.",
    "",
    [
      site.feature_row([
        site.feature_text(
          "Every tool is open",
          "An agent with a server's token can call a refund or a delete as easily as a read. Fizzlayer applies a rule to each tool.",
        ),
        site.feature_text(
          "Tools change under you",
          "A server can rewrite a tool's description after you trusted it. Fizzlayer hides a changed tool until you review it.",
        ),
        site.feature_text(
          "Keys sit on laptops",
          "Pasting an API key into Claude or Cursor leaves it on that machine. Fizzlayer keeps it on the gateway, encrypted.",
        ),
      ]),
    ],
  )
}

fn how_it_works() -> Element(msg) {
  site.section("how", "How it works", "Risky calls wait for you.", "", [
    site.steps([
      #(
        "The agent calls a tool",
        "Fizzlayer checks the agent's token and your rule for that tool.",
      ),
      #(
        "You get asked",
        "Ask first stops the call and notifies you by phone call, webhook or log.",
      ),
      #(
        "The agent retries",
        "After you approve, the agent sends the call again and it goes through once. A different call has to ask again.",
      ),
    ]),
  ])
}

fn safety() -> Element(msg) {
  site.section("safety", "Security", "What it does and doesn't do.", "", [
    site.split([
      site.list_card("What Fizzlayer checks", [
        "The agent's signed token, and whether you revoked it",
        "Your rule for each tool",
        "That a tool hasn't changed since you approved it",
        "That a retried call matches the one you approved",
      ]),
      site.list_card("What it doesn't do", [
        "Stop prompt injection inside a tool's result",
        "Replace the server's own sign-in",
        "Let a call through when its check fails",
      ]),
    ]),
  ])
}

fn questions() -> Element(msg) {
  site.section("faq", "Questions", "Common questions.", "", [
    site.faq([
      #(
        "Can I point Claude or Cursor at a hosted gateway today?",
        "Yes. Create a gateway in the app and paste its hosted URL into Claude Code or Cursor. Dedicated gateways on Pro aren't ready yet.",
      ),
      #(
        "Does it work with ChatGPT or Claude connectors?",
        "Not yet. Those need an OAuth sign-in that isn't built.",
      ),
      #(
        "Where do approvals show up?",
        "As a phone call on paid plans, a webhook or a log line. You approve in the app.",
      ),
      #(
        "Is it open source?",
        "Yes, under Apache-2.0. The proxy is the open-source agentgateway project, unchanged.",
      ),
    ]),
  ])
}
