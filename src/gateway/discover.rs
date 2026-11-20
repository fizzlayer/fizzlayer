//! List an MCP server's tools from the API, so the app can show them as soon
//! as the server is added instead of after an agent first connects.
//!
//! `GET /api/gateway/gateways/<id>/servers/<server>/tools` runs `initialize`
//! and `tools/list` against the upstream server with its stored credential.
//! The browser cannot do this: the CSP limits `connect-src` to this origin and
//! the decrypted key must not reach the page.
//!
//! The URL is user input, so this is an outbound request to an address a
//! customer chose. Every address the host resolves to must be public, the
//! connection is pinned to the checked address, redirects are not followed,
//! and time and size are capped. Server text is third-party input: names must
//! be valid tool names and descriptions are cut and cleaned.

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::time::Duration;

use reqwest::Url;
use serde_json::{Value, json};

use crate::customer::ApiError;
use crate::gateway::limits;

const MAX_BODY: usize = 2 * 1024 * 1024;
const MAX_TOOLS: usize = 300;
const MAX_PAGES: usize = 5;
const PROTOCOL: &str = "2025-06-18";

/// What the API needs to reach one server.
pub struct Upstream<'a> {
    pub url: &'a str,
    pub transport: &'a str,
    pub auth_kind: &'a str,
    pub key: Option<&'a str>,
}

pub async fn list_tools(upstream: &Upstream<'_>) -> Result<Value, ApiError> {
    if upstream.auth_kind == "passthrough" {
        return Err(ApiError::new(
            409,
            "passthrough",
            "This server uses each agent's own token, so Fizzlayer cannot list its tools. They show up after an agent connects.",
        ));
    }
    let (url, client) = pinned_client(upstream.url).await?;
    let mut session = Session {
        client,
        url,
        bearer: upstream.key.map(|key| format!("Bearer {}", key.trim())),
        session_id: None,
        read: 0,
    };
    let tools = match upstream.transport {
        "http" => session.streamable_tools().await?,
        "sse" => session.sse_tools().await?,
        _ => {
            return Err(ApiError::new(
                400,
                "invalid_request",
                "Only http and sse servers can be listed from here.",
            ));
        }
    };
    Ok(json!({ "tools": tools }))
}

struct Session {
    client: reqwest::Client,
    url: Url,
    bearer: Option<String>,
    session_id: Option<String>,
    read: usize,
}

impl Session {
    /// Streamable HTTP: each JSON-RPC request is a POST, and the answer is
    /// either JSON or a short event stream.
    async fn streamable_tools(&mut self) -> Result<Vec<Value>, ApiError> {
        let url = self.url.clone();
        self.post_rpc(&url, 1, "initialize", initialize_params())
            .await?;
        self.notify(&url).await;
        let mut tools = Vec::new();
        let mut cursor: Option<String> = None;
        for page in 0..MAX_PAGES {
            let params = match &cursor {
                Some(cursor) => json!({ "cursor": cursor }),
                None => json!({}),
            };
            let result = self
                .post_rpc(&url, 2 + page as u64, "tools/list", params)
                .await?;
            cursor = collect(&result, &mut tools);
            if cursor.is_none() || tools.len() >= MAX_TOOLS {
                break;
            }
        }
        Ok(tools)
    }

    /// The older SSE transport: a GET stream announces a POST endpoint, and
    /// answers to those POSTs arrive on the stream.
    async fn sse_tools(&mut self) -> Result<Vec<Value>, ApiError> {
        let mut stream = self
            .request(reqwest::Method::GET, &self.url.clone())
            .header("accept", "text/event-stream")
            .send()
            .await
            .map_err(|_| unreachable_error())?;
        check_status(stream.status())?;
        let mut events = Events::default();
        let endpoint = loop {
            let event = self.next_event(&mut stream, &mut events).await?;
            if event.0 == "endpoint" {
                break self.endpoint(&event.1)?;
            }
        };
        self.post_only(&endpoint, rpc(1, "initialize", initialize_params()))
            .await?;
        let _ = self.wait_for(&mut stream, &mut events, 1).await?;
        self.post_only(
            &endpoint,
            json!({"jsonrpc": "2.0", "method": "notifications/initialized"}),
        )
        .await?;
        let mut tools = Vec::new();
        let mut cursor: Option<String> = None;
        for page in 0..MAX_PAGES {
            let id = 2 + page as u64;
            let params = match &cursor {
                Some(cursor) => json!({ "cursor": cursor }),
                None => json!({}),
            };
            self.post_only(&endpoint, rpc(id, "tools/list", params))
                .await?;
            let result = self.wait_for(&mut stream, &mut events, id).await?;
            cursor = collect(&result, &mut tools);
            if cursor.is_none() || tools.len() >= MAX_TOOLS {
                break;
            }
        }
        Ok(tools)
    }

    fn request(&self, method: reqwest::Method, url: &Url) -> reqwest::RequestBuilder {
        let mut builder = self
            .client
            .request(method, url.clone())
            .header("mcp-protocol-version", PROTOCOL);
        if let Some(bearer) = &self.bearer {
            builder = builder.header("authorization", bearer);
        }
        if let Some(id) = &self.session_id {
            builder = builder.header("mcp-session-id", id);
        }
        builder
    }

    async fn post_rpc(
        &mut self,
        url: &Url,
        id: u64,
        method: &str,
        params: Value,
    ) -> Result<Value, ApiError> {
        let response = self
            .request(reqwest::Method::POST, url)
            .header("accept", "application/json, text/event-stream")
            .json(&rpc(id, method, params))
            .send()
            .await
            .map_err(|_| unreachable_error())?;
        check_status(response.status())?;
        if let Some(session) = response
            .headers()
            .get("mcp-session-id")
            .and_then(|value| value.to_str().ok())
            .filter(|value| (1..=200).contains(&value.len()) && value.is_ascii())
        {
            self.session_id = Some(session.to_string());
        }
        let is_stream = response
            .headers()
            .get("content-type")
            .and_then(|value| value.to_str().ok())
            .is_some_and(|value| value.starts_with("text/event-stream"));
        let mut response = response;
        if is_stream {
            let mut events = Events::default();
            return self.wait_for(&mut response, &mut events, id).await;
        }
        let body = self.read_all(&mut response).await?;
        let value: Value = serde_json::from_slice(&body).map_err(|_| invalid_error())?;
        answer(&value, id).ok_or_else(invalid_error)?
    }

    /// `notifications/initialized` has no answer worth reading.
    async fn notify(&mut self, url: &Url) {
        let _ = self
            .request(reqwest::Method::POST, url)
            .header("accept", "application/json, text/event-stream")
            .json(&json!({"jsonrpc": "2.0", "method": "notifications/initialized"}))
            .send()
            .await;
    }

    async fn post_only(&mut self, url: &Url, body: Value) -> Result<(), ApiError> {
        let response = self
            .request(reqwest::Method::POST, url)
            .header("content-type", "application/json")
            .json(&body)
            .send()
            .await
            .map_err(|_| unreachable_error())?;
        check_status(response.status())
    }

    async fn read_all(&mut self, response: &mut reqwest::Response) -> Result<Vec<u8>, ApiError> {
        let mut body = Vec::new();
        while let Some(chunk) = response.chunk().await.map_err(|_| unreachable_error())? {
            self.read += chunk.len();
            if self.read > MAX_BODY {
                return Err(too_large_error());
            }
            body.extend_from_slice(&chunk);
        }
        Ok(body)
    }

    async fn next_event(
        &mut self,
        response: &mut reqwest::Response,
        events: &mut Events,
    ) -> Result<(String, String), ApiError> {
        loop {
            if let Some(event) = events.pop() {
                return Ok(event);
            }
            let chunk = response
                .chunk()
                .await
                .map_err(|_| unreachable_error())?
                .ok_or_else(invalid_error)?;
            self.read += chunk.len();
            if self.read > MAX_BODY {
                return Err(too_large_error());
            }
            events.push(&chunk);
        }
    }

    async fn wait_for(
        &mut self,
        response: &mut reqwest::Response,
        events: &mut Events,
        id: u64,
    ) -> Result<Value, ApiError> {
        loop {
            let (kind, data) = self.next_event(response, events).await?;
            if kind != "message" {
                continue;
            }
            let Ok(value) = serde_json::from_str::<Value>(&data) else {
                continue;
            };
            if let Some(result) = answer(&value, id) {
                return result;
            }
        }
    }

    /// The SSE endpoint must stay on the same origin as the server URL, so a
    /// server cannot point the API at another host.
    fn endpoint(&self, data: &str) -> Result<Url, ApiError> {
        let url = self.url.join(data.trim()).map_err(|_| invalid_error())?;
        if url.origin() != self.url.origin() {
            return Err(invalid_error());
        }
        Ok(url)
    }
}

/// The parsed URL and a client whose DNS is pinned to the address that was
/// checked, so a second lookup cannot return a private address.
async fn pinned_client(raw: &str) -> Result<(Url, reqwest::Client), ApiError> {
    if !limits::remote_url_ok(raw) {
        return Err(blocked_error());
    }
    let url = Url::parse(raw).map_err(|_| blocked_error())?;
    if !matches!(url.scheme(), "http" | "https")
        || !url.username().is_empty()
        || url.password().is_some()
    {
        return Err(blocked_error());
    }
    let host = url.host_str().ok_or_else(blocked_error)?.to_string();
    let port = url.port_or_known_default().ok_or_else(blocked_error)?;
    let lookup = host
        .trim_start_matches('[')
        .trim_end_matches(']')
        .to_string();
    let addrs: Vec<SocketAddr> = tokio::time::timeout(
        Duration::from_secs(3),
        tokio::net::lookup_host((lookup.as_str(), port)),
    )
    .await
    .map_err(|_| unreachable_error())?
    .map_err(|_| unreachable_error())?
    .collect();
    if addrs.is_empty() || addrs.iter().any(|addr| !public_ip(addr.ip())) {
        return Err(blocked_error());
    }
    // Every checked address is pinned, IPv4 first. Hosts without an IPv6
    // route then still connect, and no unchecked address is ever used.
    let mut addrs = addrs;
    addrs.sort_by_key(SocketAddr::is_ipv6);
    let client = reqwest::Client::builder()
        .resolve_to_addrs(&host, &addrs)
        .redirect(reqwest::redirect::Policy::none())
        .connect_timeout(Duration::from_secs(4))
        .timeout(Duration::from_secs(10))
        .user_agent("fizzlayer-gateway/1.0")
        .build()
        .map_err(|_| unreachable_error())?;
    Ok((url, client))
}

/// True for an address on the public internet. Loopback, private, link-local,
/// carrier-grade NAT, documentation, benchmarking, multicast and reserved
/// ranges are refused, including IPv4 written inside IPv6.
pub fn public_ip(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => public_v4(v4),
        IpAddr::V6(v6) => {
            if let Some(v4) = v6.to_ipv4_mapped() {
                return public_v4(v4);
            }
            public_v6(v6)
        }
    }
}

fn public_v4(ip: Ipv4Addr) -> bool {
    let [a, b, c, _] = ip.octets();
    !(ip.is_unspecified()
        || ip.is_loopback()
        || ip.is_private()
        || ip.is_link_local()
        || ip.is_broadcast()
        || ip.is_multicast()
        || ip.is_documentation()
        || a == 0
        || (a == 100 && (64..=127).contains(&b))
        || (a == 192 && b == 0 && c == 0)
        || (a == 198 && (18..=19).contains(&b))
        || a >= 240)
}

fn public_v6(ip: Ipv6Addr) -> bool {
    let first = ip.segments()[0];
    !(ip.is_unspecified()
        || ip.is_loopback()
        || ip.is_multicast()
        || (first & 0xfe00) == 0xfc00
        || (first & 0xffc0) == 0xfe80
        || (first & 0xffc0) == 0xfec0
        || first == 0x2001 && ip.segments()[1] == 0x0db8
        || first == 0x0064 && ip.segments()[1] == 0xff9b
        || ip.to_ipv4().is_some())
}

#[derive(Default)]
struct Events {
    buffer: String,
    ready: std::collections::VecDeque<(String, String)>,
}

impl Events {
    fn push(&mut self, chunk: &[u8]) {
        self.buffer
            .push_str(&String::from_utf8_lossy(chunk).replace("\r\n", "\n"));
        while let Some(end) = self.buffer.find("\n\n") {
            let block: String = self.buffer.drain(..end + 2).collect();
            let mut kind = "message".to_string();
            let mut data = Vec::new();
            for line in block.lines() {
                if let Some(value) = line.strip_prefix("event:") {
                    kind = value.trim().to_string();
                } else if let Some(value) = line.strip_prefix("data:") {
                    data.push(value.strip_prefix(' ').unwrap_or(value).to_string());
                }
            }
            if !data.is_empty() {
                self.ready.push_back((kind, data.join("\n")));
            }
        }
    }

    fn pop(&mut self) -> Option<(String, String)> {
        self.ready.pop_front()
    }
}

fn rpc(id: u64, method: &str, params: Value) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params})
}

fn initialize_params() -> Value {
    json!({
        "protocolVersion": PROTOCOL,
        "capabilities": {},
        "clientInfo": {"name": "fizzlayer", "version": "1.0"},
    })
}

/// The result for `id`, an error for an error answer, or `None` when the
/// message is about something else.
fn answer(value: &Value, id: u64) -> Option<Result<Value, ApiError>> {
    if value["id"].as_u64() != Some(id) {
        return None;
    }
    if value.get("error").is_some() {
        return Some(Err(ApiError::new(
            502,
            "upstream_error",
            "The MCP server answered with an error. Check its URL and key.",
        )));
    }
    Some(Ok(value["result"].clone()))
}

/// Add a `tools/list` page to `tools` and return the next cursor.
fn collect(result: &Value, tools: &mut Vec<Value>) -> Option<String> {
    if let Some(rows) = result["tools"].as_array() {
        for row in rows {
            if tools.len() >= MAX_TOOLS {
                break;
            }
            let Some(name) = row["name"].as_str() else {
                continue;
            };
            if name == "*" || !limits::tool_name_ok(name) {
                continue;
            }
            tools.push(json!({
                "name": name,
                "description": clean(row["description"].as_str().unwrap_or(""), 300),
            }));
        }
    }
    result["nextCursor"]
        .as_str()
        .filter(|cursor| (1..=300).contains(&cursor.len()))
        .map(str::to_string)
}

fn clean(value: &str, max: usize) -> String {
    value
        .chars()
        .map(|c| if c.is_control() { ' ' } else { c })
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .chars()
        .take(max)
        .collect()
}

fn check_status(status: reqwest::StatusCode) -> Result<(), ApiError> {
    match status.as_u16() {
        200..=299 => Ok(()),
        401 | 403 => Err(ApiError::new(
            502,
            "upstream_auth",
            "The MCP server refused the credential. Check the API key, or remove the server and add it with a new key.",
        )),
        300..=399 => Err(ApiError::new(
            502,
            "upstream_redirect",
            "The MCP server redirected. Use the final URL from its docs.",
        )),
        404 | 405 => Err(ApiError::new(
            502,
            "upstream_not_mcp",
            "Nothing answered as an MCP server at that URL. Check the path, which often ends in /mcp or /sse.",
        )),
        _ => Err(unreachable_error()),
    }
}

fn blocked_error() -> ApiError {
    ApiError::new(
        400,
        "upstream_blocked",
        "That URL does not point to a public address, so Fizzlayer will not call it.",
    )
}

fn unreachable_error() -> ApiError {
    ApiError::new(
        502,
        "upstream_unreachable",
        "The MCP server did not answer in time. Try again in a moment.",
    )
}

fn invalid_error() -> ApiError {
    ApiError::new(
        502,
        "upstream_invalid",
        "The server's answer was not a valid MCP tool list.",
    )
}

fn too_large_error() -> ApiError {
    ApiError::new(
        502,
        "upstream_too_large",
        "The server's tool list was larger than 2 MB.",
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_public_addresses_pass() {
        for blocked in [
            "127.0.0.1",
            "10.1.2.3",
            "172.16.0.1",
            "192.168.1.1",
            "169.254.169.254",
            "100.64.0.1",
            "0.0.0.0",
            "198.18.0.1",
            "224.0.0.1",
            "255.255.255.255",
            "::1",
            "::",
            "fc00::1",
            "fd12::1",
            "fe80::1",
            "::ffff:127.0.0.1",
            "::ffff:10.0.0.1",
            "2001:db8::1",
            "64:ff9b::a00:1",
        ] {
            assert!(!public_ip(blocked.parse().unwrap()), "{blocked}");
        }
        for open in ["1.1.1.1", "104.18.0.1", "2606:4700::1111", "::ffff:8.8.8.8"] {
            assert!(public_ip(open.parse().unwrap()), "{open}");
        }
    }

    #[test]
    fn tool_lists_keep_valid_names_and_clean_text() {
        let mut tools = Vec::new();
        let next = collect(
            &json!({
                "tools": [
                    {"name": "search_docs", "description": "Find\u{0007} pages\n  fast."},
                    {"name": "bad name", "description": "dropped"},
                    {"name": "*", "description": "dropped"},
                    {"description": "no name"},
                ],
                "nextCursor": "page-2",
            }),
            &mut tools,
        );
        assert_eq!(next.as_deref(), Some("page-2"));
        assert_eq!(
            tools,
            vec![json!({"name": "search_docs", "description": "Find pages fast."})]
        );
    }

    #[test]
    fn event_streams_split_into_messages() {
        let mut events = Events::default();
        events.push(b"event: endpoint\r\ndata: /messages?session=1\r\n\r\nevent: mes");
        events.push(b"sage\ndata: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n\n");
        assert_eq!(
            events.pop(),
            Some(("endpoint".to_string(), "/messages?session=1".to_string()))
        );
        let (kind, data) = events.pop().unwrap();
        assert_eq!(kind, "message");
        let value: Value = serde_json::from_str(&data).unwrap();
        assert!(answer(&value, 1).unwrap().is_ok());
        assert!(answer(&value, 2).is_none());
        assert_eq!(events.pop(), None);
    }

    #[tokio::test]
    async fn private_and_odd_urls_are_refused_before_any_request() {
        for url in [
            "http://127.0.0.1:8080/mcp",
            "http://localhost/mcp",
            "http://169.254.169.254/latest/meta-data",
            "http://[::1]/mcp",
            "https://user:pass@example.com/mcp",
            "ftp://example.com/mcp",
        ] {
            let error = pinned_client(url).await.expect_err(url);
            assert_eq!(error.code(), "upstream_blocked", "{url}");
        }
    }

    #[tokio::test]
    async fn passthrough_servers_are_not_called() {
        let error = list_tools(&Upstream {
            url: "https://example.com/mcp",
            transport: "http",
            auth_kind: "passthrough",
            key: None,
        })
        .await
        .err()
        .unwrap();
        assert_eq!(error.code(), "passthrough");
    }

    /// Calls the public Cloudflare Docs MCP server. Run with
    /// `cargo test --lib discover -- --ignored`.
    #[tokio::test]
    #[ignore = "network"]
    async fn lists_a_public_server() {
        let value = list_tools(&Upstream {
            url: "https://docs.mcp.cloudflare.com/mcp",
            transport: "http",
            auth_kind: "none",
            key: None,
        })
        .await
        .unwrap_or_else(|error| panic!("{}", error.code()));
        let tools = value["tools"].as_array().unwrap();
        assert!(!tools.is_empty());
        println!("{value:#}");
    }
}
