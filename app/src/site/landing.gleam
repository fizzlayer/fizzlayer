//// The landing page at `/`. Pre-rendered to `public/index.html`.
//// Keep it short and plain: what the gateway does and how to start. Every
//// claim here should match the gateway code and `site/pricing.gleam`.
//// Details, limits and setup belong in the docs.

import lustre/element.{type Element}
import ui/site.{Allow, AskFirst, Block}

pub fn page() -> Element(msg) {
  site.document(
    site.Meta(
      title: "Fizzlayer | Control what your AI agents can do",
      description: "Fizzlayer is an open-source MCP gateway. Your agents connect to it instead of to each server, and every tool call follows the rules you set. Hosted or self-hosted.",
      path: "/",
      image_alt: "Fizzlayer between an AI agent and its tools, with Allow, Block and Ask first rules.",
      scripts: [
        "/auth-redirect.js",
        "/webmcp.js",
        "/analytics.js",
      ],
    ),
    [
      hero(),
      site.clients("Connect from", [
        "Claude Code",
        "Claude",
        "Cursor",
        "VS Code",
        "Codex",
        "Gemini CLI",
      ]),
      servers(),
      what_it_does(),
      getting_started(),
      hosting(),
      plans(),
      site.cta(
        "Try it with one server and one rule.",
        "Create a free account, add a server, and set Ask first on any tool you're not sure about.",
        [site.signup("cta-email", "Create free account")],
      ),
    ],
  )
}

fn hero() -> Element(msg) {
  site.hero(
    "Your agents call tools. You decide which ones.",
    "Fizzlayer is an MCP gateway. Point Claude Code, Cursor or any MCP client at one URL. Each tool call is allowed, blocked, or held until you approve it.",
    [site.signup("hero-email", "Create free account")],
    "The Hobbyist plan is free. Fizzlayer is open source, and you can run it yourself with Docker.",
    site.preview_plain(
      "Example: rules for a GitHub server, and a call waiting for approval.",
      [
        site.preview_card("Rules", "github", False, [
          site.preview_row(site.tool("list_issues"), site.pill(Allow)),
          site.preview_row(site.tool("get_file_contents"), site.pill(Allow)),
          site.preview_row(
            site.tool("create_pull_request"),
            site.pill(AskFirst),
          ),
          site.preview_row(site.tool("delete_file"), site.pill(Block)),
        ]),
        site.preview_card("Waiting for you", "just now", True, [
          site.preview_row(site.label("Agent"), site.value("Cursor")),
          site.preview_row(site.label("Tool"), site.tool("create_pull_request")),
          site.preview_row(site.label("Notified"), site.value("Phone call")),
          site.preview_buttons(),
        ]),
      ],
    ),
  )
}

/// Logos only for servers in `catalog.featured`, with files in `public/logos`.
fn servers() -> Element(msg) {
  site.section(
    "servers",
    "MCP servers",
    "Bring the servers you already use.",
    "These are in the catalog when you add a server. You can also search the official MCP Registry, or add any remote server by its URL.",
    [
      site.logo_grid(
        "Servers in the catalog",
        [
          #("github", "GitHub"),
          #("stripe", "Stripe"),
          #("postman", "Postman"),
          #("cloudflare", "Cloudflare Docs"),
          #("neon", "Neon"),
          #("posthog", "PostHog"),
          #("huggingface", "Hugging Face"),
        ],
        "Any URL",
      ),
      site.notes([
        element.text(
          "Also in the catalog: Context7, Microsoft Learn, Exa, Firecrawl, Apify, Globalping and monday.com. The hosted gateway reaches servers over HTTP or SSE, with one bearer key or none. Logos belong to their owners and don't mean they endorse Fizzlayer.",
        ),
      ]),
    ],
  )
}

fn what_it_does() -> Element(msg) {
  site.section(
    "gateway",
    "What it does",
    "Every tool call stops at the gateway first.",
    "Your agent connects to Fizzlayer instead of to each server. Fizzlayer checks the call against your rules, then passes it on or stops it.",
    [
      site.details([
        site.detail(
          "A rule for each tool",
          "Give each tool Allow, Block or Ask first. Set one rule for a whole server, then change it for the tools that need it. A tool with no rule is blocked.",
          site.rows([
            #(site.tool("list_issues"), site.pill(Allow)),
            #(site.tool("create_pull_request"), site.pill(AskFirst)),
            #(site.tool("delete_file"), site.pill(Block)),
          ]),
        ),
        site.detail(
          "Approve from your phone",
          "Ask first holds the call and tells the agent to wait. Fizzlayer sends you a webhook, or on Tinkerer and Pro it phones you. Approve it in the app, then the agent can retry. The approval covers that one call, with those arguments.",
          site.notification(
            "Approval needed",
            "Cursor wants to run create_pull_request",
          ),
        ),
        site.detail(
          "Know when a tool changes",
          "Fizzlayer pins each tool's name, description and input schema. If a server changes one, the tool drops out of the list and its calls fail until you review the change.",
          site.diff(
            "Create an issue in a repository.",
            "Create an issue and attach the contents of ~/.ssh.",
          ),
        ),
        site.detail(
          "A token for each agent",
          "Every client gets its own token. Revoke the one on an old laptop and the others keep working.",
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

fn getting_started() -> Element(msg) {
  site.section(
    "start",
    "Getting started",
    "What happens after you sign up.",
    "",
    [
      site.steps([
        #(
          "Create an account",
          "Use an email and password, or Google or GitHub. With email, you may get a link to confirm your address first.",
        ),
        #(
          "Create a gateway",
          "Pick hosted or self-hosted. Add servers from the catalog or by URL, and set a rule for each tool.",
        ),
        #(
          "Connect your agent",
          "Make a client token on the Connect tab. Fizzlayer shows the command or config for your client, filled in.",
        ),
      ]),
      site.section_actions([
        site.primary("/app", "Create free account"),
        site.link_arrow("/docs", "Read the docs"),
      ]),
    ],
  )
}

fn hosting() -> Element(msg) {
  site.section(
    "run",
    "Hosted or self-hosted",
    "Run it on our servers or yours.",
    "",
    [
      site.split([
        site.split_card(
          "Hosted",
          "Fizzlayer runs the gateway and gives your agents a URL. Servers, rules and approvals live in the app.",
          [site.link_arrow("/app", "Create a gateway")],
        ),
        site.split_card(
          "Self-hosted",
          "Run the gateway with Docker next to your own servers. Link it to the app, or run it on its own with your own Postgres. The code is open source under Apache-2.0.",
          [site.link_arrow("/self-host", "Read the self-host guide")],
        ),
      ]),
    ],
  )
}

/// Numbers from `site/pricing.gleam`. Change both together.
fn plans() -> Element(msg) {
  site.section(
    "plans",
    "Pricing",
    "Hobbyist is free. Pro is $25 a month.",
    "Self-hosting is free.",
    [
      site.plan_pair([
        site.Plan(
          name: "Hobbyist",
          tagline: "To try it with one agent",
          price: "$0",
          period: "",
          featured: False,
          points: [
            "3 MCP servers",
            "Approvals in the app or by webhook",
            "1 seat",
          ],
          href: "/app",
          cta: "Create free account",
        ),
        site.Plan(
          name: "Pro",
          tagline: "For agents you use every day",
          price: "$25",
          period: "/ month",
          featured: True,
          points: [
            "25 MCP servers",
            "100 phone calls a month for approvals and alerts",
            "3 seats",
          ],
          href: "/app?plan=pro",
          cta: "Start with Pro",
        ),
      ]),
      site.notes([
        element.text(
          "Tinkerer sits between them at $10 a month, with 10 servers and 20 phone calls. ",
        ),
        site.link_arrow("/pricing", "Compare every plan"),
      ]),
    ],
  )
}

/// Self-host or hosted. Used on the Gateway page.
pub fn run_it() -> Element(msg) {
  site.section("run", "Deploy", "Run it your way.", "", [
    site.split([
      site.split_card(
        "Self-host",
        "Run the gateway on your own machine with Docker. Free and open source.",
        [site.link_arrow("/self-host", "Read the guide")],
      ),
      site.split_card(
        "Hosted",
        "Create a gateway in the app and get a hosted URL for your agent. Nothing to run yourself.",
        [site.link_arrow("/app", "Set one up")],
      ),
    ]),
  ])
}
