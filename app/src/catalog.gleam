//// MCP servers to add to a gateway, from the official MCP Registry
//// (registry.modelcontextprotocol.io).
////
//// `featured` is a short list copied from the registry by exact name, picked
//// because the vendor publishes it, it has a remote URL, and it takes either
//// no credential or one key sent as `Authorization: Bearer`, which is how the
//// gateway sends a stored key. Search goes through `GET
//// /api/gateway/registry`, which returns the same shape for every server in
//// the registry.

import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option
import gleam/result
import gleam/string

/// What the server needs before the gateway can call it.
pub type Auth {
  /// One key, sent as `Authorization: Bearer <key>`.
  KeyRequired
  /// Works without a key; a key raises limits or unlocks tools.
  KeyOptional
  /// The registry lists no credential.
  NoKey
  /// Needs other headers. The gateway can only send `Authorization`.
  OtherHeaders(names: List(String))
}

pub type Entry {
  Entry(
    /// The registry name, such as `io.github.github/github-mcp-server`.
    id: String,
    title: String,
    description: String,
    url: String,
    transport: String,
    auth: Auth,
    key_hint: String,
    /// Font Awesome classes, such as `fa-brands fa-github`.
    icon: String,
    category: String,
    website: String,
  )
}

pub type Page {
  Page(entries: List(Entry), next: String)
}

pub const categories = [
  #("all", "All"),
  #("developer", "Developer"),
  #("data", "Data and AI"),
  #("web", "Web and search"),
  #("business", "Business"),
]

pub fn featured() -> List(Entry) {
  [
    Entry(
      id: "io.github.github/github-mcp-server",
      title: "GitHub",
      description: "Connect AI assistants to GitHub - manage repos, issues, PRs, and workflows through natural language.",
      url: "https://api.githubcopilot.com/mcp/",
      transport: "http",
      auth: KeyRequired,
      key_hint: "A GitHub personal access token or GitHub App token.",
      icon: "fa-brands fa-github",
      category: "developer",
      website: "https://github.com/github/github-mcp-server",
    ),
    Entry(
      id: "com.stripe/mcp",
      title: "Stripe",
      description: "MCP server integrating with Stripe - tools for customers, products, payments, and more.",
      url: "https://mcp.stripe.com",
      transport: "http",
      auth: KeyRequired,
      key_hint: "A Stripe secret or restricted key. A restricted key limits what the agent can do.",
      icon: "fa-brands fa-stripe",
      category: "business",
      website: "https://docs.stripe.com/mcp",
    ),
    Entry(
      id: "com.postman/postman-mcp-server",
      title: "Postman",
      description: "Give your AI agents trusted access to the full Postman platform.",
      url: "https://mcp.postman.com/mcp",
      transport: "http",
      auth: KeyRequired,
      key_hint: "A Postman API key.",
      icon: "fa-solid fa-paper-plane",
      category: "developer",
      website: "https://www.postman.com/product/mcp-server/",
    ),
    Entry(
      id: "io.github.upstash/context7",
      title: "Context7",
      description: "Up-to-date docs for AI agents.",
      url: "https://mcp.context7.com/mcp",
      transport: "http",
      auth: KeyOptional,
      key_hint: "Optional. A Context7 API key raises the rate limit.",
      icon: "fa-solid fa-book",
      category: "developer",
      website: "https://context7.com",
    ),
    Entry(
      id: "com.microsoft/microsoft-learn-mcp",
      title: "Microsoft Learn",
      description: "Official Microsoft Learn MCP Server – real-time, trusted docs & code samples for AI and LLMs.",
      url: "https://learn.microsoft.com/api/mcp",
      transport: "http",
      auth: NoKey,
      key_hint: "",
      icon: "fa-brands fa-microsoft",
      category: "developer",
      website: "https://github.com/MicrosoftDocs/mcp",
    ),
    Entry(
      id: "com.cloudflare.mcp/mcp",
      title: "Cloudflare Docs",
      description: "Cloudflare MCP servers. This is the public documentation server.",
      url: "https://docs.mcp.cloudflare.com/mcp",
      transport: "http",
      auth: NoKey,
      key_hint: "",
      icon: "fa-brands fa-cloudflare",
      category: "developer",
      website: "https://github.com/cloudflare/mcp-server-cloudflare",
    ),
    Entry(
      id: "com.neon/mcp",
      title: "Neon",
      description: "Official Neon MCP server for managing Neon projects and Lakebase Postgres databases.",
      url: "https://mcp.neon.tech/mcp",
      transport: "http",
      auth: KeyRequired,
      key_hint: "A Neon API key.",
      icon: "fa-solid fa-database",
      category: "data",
      website: "https://neon.com/docs/ai/neon-mcp-server",
    ),
    Entry(
      id: "io.github.PostHog/mcp",
      title: "PostHog",
      description: "Official PostHog MCP Server for product analytics, feature flags, experiments, and more.",
      url: "https://mcp.posthog.com/mcp",
      transport: "http",
      auth: KeyRequired,
      key_hint: "A PostHog personal API key, created with the 'MCP Server' preset.",
      icon: "fa-solid fa-chart-line",
      category: "data",
      website: "https://posthog.com/docs/model-context-protocol",
    ),
    Entry(
      id: "co.huggingface/hf-mcp-server",
      title: "Hugging Face",
      description: "Connect to Hugging Face Hub and thousands of Gradio AI Applications.",
      url: "https://huggingface.co/mcp",
      transport: "http",
      auth: KeyOptional,
      key_hint: "Optional. A Hugging Face access token for your own models and Spaces.",
      icon: "fa-solid fa-robot",
      category: "data",
      website: "https://huggingface.co/settings/mcp",
    ),
    Entry(
      id: "ai.exa/exa",
      title: "Exa",
      description: "Connect AI agents to Exa for web search, content fetching, and multi-step research.",
      url: "https://mcp.exa.ai/mcp",
      transport: "http",
      auth: NoKey,
      key_hint: "",
      icon: "fa-solid fa-magnifying-glass",
      category: "web",
      website: "https://exa.ai",
    ),
    Entry(
      id: "io.github.firecrawl/firecrawl-mcp-server",
      title: "Firecrawl",
      description: "Firecrawl, the context API for AI agents: search, scrape, interact with the web, plus paper search.",
      url: "https://mcp.firecrawl.dev/v2/mcp",
      transport: "http",
      auth: KeyRequired,
      key_hint: "A Firecrawl API key from firecrawl.dev/app/api-keys.",
      icon: "fa-solid fa-fire",
      category: "web",
      website: "https://firecrawl.dev",
    ),
    Entry(
      id: "com.apify/apify-mcp-server",
      title: "Apify",
      description: "Extract data from any website with thousands of scrapers, crawlers, and automations on Apify Store.",
      url: "https://mcp.apify.com/",
      transport: "http",
      auth: KeyRequired,
      key_hint: "An Apify API token.",
      icon: "fa-solid fa-spider",
      category: "web",
      website: "https://mcp.apify.com",
    ),
    Entry(
      id: "io.globalping/mcp",
      title: "Globalping",
      description: "Interact with a global network measurement platform. Run network commands from any point in the world.",
      url: "https://mcp.globalping.io/mcp",
      transport: "http",
      auth: NoKey,
      key_hint: "",
      icon: "fa-solid fa-globe",
      category: "web",
      website: "https://globalping.io",
    ),
    Entry(
      id: "com.monday/monday.com",
      title: "monday.com",
      description: "MCP server for monday.com integration.",
      url: "https://mcp.monday.com/mcp",
      transport: "http",
      auth: KeyRequired,
      key_hint: "A monday.com API token.",
      icon: "fa-solid fa-table-columns",
      category: "business",
      website: "https://monday.com",
    ),
  ]
}

pub fn in_category(entries: List(Entry), category: String) -> List(Entry) {
  case category {
    "all" | "" -> entries
    _ -> list.filter(entries, fn(entry) { entry.category == category })
  }
}

/// Whether the gateway can call this server with what it can store.
pub fn addable(entry: Entry) -> Bool {
  case entry.auth {
    OtherHeaders(_) -> False
    _ -> True
  }
}

/// The URL still has `{placeholders}` from the registry to fill in.
pub fn needs_fill(url: String) -> Bool {
  string.contains(url, "{") || string.contains(url, "}")
}

/// The Auth select value a new server starts with.
pub fn auth_kind(entry: Entry) -> String {
  case entry.auth {
    KeyRequired -> "key"
    _ -> "none"
  }
}

pub fn auth_label(auth: Auth) -> String {
  case auth {
    KeyRequired -> "API key"
    KeyOptional -> "Key optional"
    NoKey -> "No key listed"
    OtherHeaders(_) -> "Custom headers"
  }
}

/// A server name the API accepts: a lowercase letter, then lowercase letters,
/// digits, hyphens or underscores, at most 41 characters.
pub fn slug(title: String) -> String {
  let cleaned =
    title
    |> string.lowercase
    |> string.to_graphemes
    |> list.map(fn(char) {
      case is_slug_char(char) {
        True -> char
        False -> "-"
      }
    })
    |> string.concat
    |> string.split("-")
    |> list.filter(fn(part) { part != "" })
    |> string.join("-")
  let cleaned = drop_leading_non_letters(cleaned)
  let cut = string.slice(cleaned, 0, 41)
  let cut = trim_trailing_hyphens(cut)
  case cut {
    "" -> "server"
    name -> name
  }
}

fn is_slug_char(char: String) -> Bool {
  case char {
    "-" | "_" -> True
    _ -> is_letter(char) || is_digit(char)
  }
}

fn is_letter(char: String) -> Bool {
  string.contains("abcdefghijklmnopqrstuvwxyz", char) && char != ""
}

fn is_digit(char: String) -> Bool {
  string.contains("0123456789", char) && char != ""
}

fn drop_leading_non_letters(value: String) -> String {
  case string.pop_grapheme(value) {
    Ok(#(first, rest)) ->
      case is_letter(first) {
        True -> value
        False -> drop_leading_non_letters(rest)
      }
    Error(_) -> ""
  }
}

fn trim_trailing_hyphens(value: String) -> String {
  case string.ends_with(value, "-") || string.ends_with(value, "_") {
    True -> trim_trailing_hyphens(string.drop_end(value, 1))
    False -> value
  }
}

// Registry search -------------------------------------------------------------

type Header {
  Header(name: String, secret: Bool, required: Bool, description: String)
}

type Remote {
  Remote(kind: String, url: String, headers: List(Header))
}

/// One page from `GET /api/gateway/registry`.
pub fn page_of(body: String) -> Result(Page, Nil) {
  json.parse(body, page_decoder())
  |> result.replace_error(Nil)
}

fn page_decoder() -> decode.Decoder(Page) {
  use servers <- decode.field("servers", decode.list(server_decoder()))
  use next <- decode.optional_field(
    "next",
    "",
    decode.optional(decode.string) |> decode.map(option.unwrap(_, "")),
  )
  decode.success(Page(entries: list.filter_map(servers, fn(x) { x }), next:))
}

fn server_decoder() -> decode.Decoder(Result(Entry, Nil)) {
  use name <- decode.field("name", decode.string)
  use title <- decode.optional_field("title", name, decode.string)
  use description <- decode.optional_field("description", "", decode.string)
  use website <- decode.optional_field("website", "", decode.string)
  use remotes <- decode.field("remotes", decode.list(remote_decoder()))
  decode.success(entry_of(name, title, description, website, remotes))
}

fn remote_decoder() -> decode.Decoder(Remote) {
  use kind <- decode.field("type", decode.string)
  use url <- decode.field("url", decode.string)
  use headers <- decode.optional_field(
    "headers",
    [],
    decode.list(header_decoder()),
  )
  decode.success(Remote(kind:, url:, headers:))
}

fn header_decoder() -> decode.Decoder(Header) {
  use name <- decode.field("name", decode.string)
  use secret <- decode.optional_field("secret", False, decode.bool)
  use required <- decode.optional_field("required", False, decode.bool)
  use description <- decode.optional_field("description", "", decode.string)
  decode.success(Header(name:, secret:, required:, description:))
}

/// Streamable HTTP first, then SSE.
fn entry_of(
  name: String,
  title: String,
  description: String,
  website: String,
  remotes: List(Remote),
) -> Result(Entry, Nil) {
  let pick =
    list.find(remotes, fn(remote) { remote.kind == "streamable-http" })
    |> result.lazy_or(fn() {
      list.find(remotes, fn(remote) { remote.kind == "sse" })
    })
  use remote <- result.map(pick)
  let #(auth, hint) = auth_of(remote.headers)
  Entry(
    id: name,
    title: title,
    description: description,
    url: remote.url,
    transport: case remote.kind {
      "sse" -> "sse"
      _ -> "http"
    },
    auth: auth,
    key_hint: hint,
    icon: "fa-solid fa-plug",
    category: "registry",
    website: website,
  )
}

fn auth_of(headers: List(Header)) -> #(Auth, String) {
  let authorization =
    list.find(headers, fn(header) {
      string.lowercase(header.name) == "authorization"
    })
  let others =
    list.filter(headers, fn(header) {
      string.lowercase(header.name) != "authorization"
      && { header.required || header.secret }
    })
  case others, authorization {
    [_, ..], _ -> #(
      OtherHeaders(list.map(others, fn(header) { header.name })),
      "",
    )
    [], Ok(header) ->
      case header.required {
        True -> #(KeyRequired, header.description)
        False -> #(KeyOptional, header.description)
      }
    [], Error(_) -> #(NoKey, "")
  }
}
