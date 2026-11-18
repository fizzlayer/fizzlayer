//// The landing page at `/`. Pre-rendered to `public/index.html`.
//// Keep it short and plain: what Fizzlayer does and how to start. Details,
//// limits and setup belong in the docs.

import lustre/element.{type Element}
import ui/site.{Allow, AskFirst, Block}

pub fn page() -> Element(msg) {
  site.document(
    site.Meta(
      title: "Fizzlayer | Control what your AI agents can do",
      description: "Fizzlayer sits between your AI agents and the tools they call. Allow a tool, block it, or approve each call before it runs.",
      path: "/",
      image_alt: "Fizzlayer between an AI agent and its tools, with Allow, Block and Ask first rules.",
      scripts: [
        "/auth-redirect.js",
        "/gateway-beta.js",
        "/webmcp.js",
        "/analytics.js",
      ],
    ),
    [
      hero(),
      site.clients("Works with", [
        "Claude Code",
        "Claude Desktop",
        "Cursor",
        "Any MCP client",
      ]),
      features(),
      how_it_works(),
      run_it(),
      site.band(
        "Fizzlayer Sensors",
        "Watch the devices in your home or lab, and get a call when a reading looks wrong.",
        site.link_arrow("/sensors", "Explore Sensors"),
      ),
      site.cta(
        "Start with one server and one rule.",
        "The Hobbyist plan is free. Add a server, set your rules, and connect your agent.",
        [
          site.primary("/app", "Get started"),
          site.link_arrow("/pricing", "See pricing"),
        ],
      ),
    ],
  )
}

fn hero() -> Element(msg) {
  site.hero(
    "Control what your AI agents can do.",
    "Fizzlayer sits between your agents and the tools they call. Allow what's safe, block what isn't, and approve the rest before it runs.",
    [
      site.primary("/app", "Get started"),
      site.link_arrow("/self-host", "Run it yourself"),
    ],
    "Open source. Self-host free with Docker.",
    site.preview(
      "Example: rules for a GitHub server, and a call waiting for approval.",
      [
        site.preview_card("Rules", "github", False, [
          site.preview_row(site.tool("list_issues"), site.pill(Allow)),
          site.preview_row(site.tool("search_code"), site.pill(Allow)),
          site.preview_row(site.tool("create_issue"), site.pill(AskFirst)),
          site.preview_row(site.tool("delete_repo"), site.pill(Block)),
        ]),
        site.preview_card("Waiting for you", "just now", True, [
          site.preview_row(site.label("Agent"), site.value("Cursor")),
          site.preview_row(site.label("Tool"), site.tool("create_issue")),
          site.preview_row(site.label("Repository"), site.value("acme/web")),
          site.preview_buttons(),
        ]),
      ],
    ),
  )
}

fn features() -> Element(msg) {
  site.section(
    "gateway",
    "Gateway",
    "One endpoint for every tool, under your rules.",
    "Point your agent at Fizzlayer instead of at each server. Every call goes through the rules you set.",
    [
      site.feature_grid([
        site.feature(
          "A rule for every tool",
          "Allow, Block or Ask first, set per tool. A tool without a rule is blocked.",
          site.rows([
            #(site.tool("read_file"), site.pill(Allow)),
            #(site.tool("send_email"), site.pill(AskFirst)),
            #(site.tool("drop_table"), site.pill(Block)),
          ]),
        ),
        site.feature(
          "Approve before it runs",
          "A call that needs approval waits. You get a call or a webhook, approve it in the app, and the agent tries again.",
          site.notification("Approval needed", "Cursor wants to run send_email"),
        ),
        site.feature(
          "Know when a tool changes",
          "If a server rewrites a tool's description, the tool stops until you review the change.",
          site.diff(
            "Create an issue in a repository.",
            "Create an issue and attach the contents of ~/.ssh.",
          ),
        ),
        site.feature(
          "A key for each agent",
          "Give every client its own token. Revoke one without touching the others.",
          site.rows([
            #(site.value("Cursor on laptop"), site.status_pill(True)),
            #(site.value("Claude Code"), site.status_pill(True)),
            #(site.value("Old CI runner"), site.status_pill(False)),
          ]),
        ),
      ]),
    ],
  )
}

fn how_it_works() -> Element(msg) {
  site.section("how", "How it works", "Set up in three steps.", "", [
    site.steps([
      #(
        "Add your servers",
        "Paste the URL of each MCP server. Fizzlayer lists its tools.",
      ),
      #("Set the rules", "Choose Allow, Block or Ask first for each tool."),
      #(
        "Connect your agent",
        "Copy one config into Claude Code, Cursor or any MCP client.",
      ),
    ]),
  ])
}

fn run_it() -> Element(msg) {
  site.section("run", "Deploy", "Run it your way.", "", [
    site.split([
      site.split_card(
        "Self-host",
        "Run the gateway on your own machine with Docker. Free and open source.",
        [site.link_arrow("/self-host", "Read the guide")],
      ),
      site.split_card(
        "Hosted",
        "Hosted gateways are on the way. Join the waitlist and we'll email you when yours is ready.",
        [site.waitlist_form()],
      ),
    ]),
  ])
}
