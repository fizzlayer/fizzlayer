//! Search the official MCP Registry for servers a gateway can reach.
//!
//! `GET /api/gateway/registry?search=&cursor=` asks
//! `registry.modelcontextprotocol.io` for the latest version of each server
//! and keeps only active entries with a remote `streamable-http` or `sse`
//! URL. The browser cannot call the registry itself: the app's CSP limits
//! `connect-src` to this origin. Registry text is third-party input, so every
//! field is cut to a fixed length and URLs must be `https://`.

use std::time::Duration;

use serde_json::{Value, json};

use crate::customer::ApiError;

const REGISTRY_URL: &str = "https://registry.modelcontextprotocol.io/v0/servers";
const PAGE_SIZE: &str = "30";
const MAX_BODY: usize = 2 * 1024 * 1024;
const MAX_SEARCH: usize = 100;
const MAX_CURSOR: usize = 300;

/// The search term and page cursor from the query string, trimmed. Either can
/// be empty. Overlong values are rejected rather than cut.
pub fn params(search: &str, cursor: &str) -> Result<(String, String), ApiError> {
    let search = search.trim().to_string();
    let cursor = cursor.trim().to_string();
    if search.chars().count() > MAX_SEARCH || cursor.chars().count() > MAX_CURSOR {
        return Err(ApiError::new(
            400,
            "invalid_request",
            "Search terms are up to 100 characters.",
        ));
    }
    if search.chars().any(char::is_control) || cursor.chars().any(char::is_control) {
        return Err(ApiError::new(
            400,
            "invalid_request",
            "Search terms cannot hold control characters.",
        ));
    }
    Ok((search, cursor))
}

pub async fn search(search: &str, cursor: &str) -> Result<Value, ApiError> {
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(6))
        .redirect(reqwest::redirect::Policy::none())
        .user_agent("fizzlayer-gateway-catalog")
        .build()
        .map_err(|_| unavailable())?;
    let mut query = vec![("version", "latest"), ("limit", PAGE_SIZE)];
    if !search.is_empty() {
        query.push(("search", search));
    }
    if !cursor.is_empty() {
        query.push(("cursor", cursor));
    }
    let response = client
        .get(REGISTRY_URL)
        .query(&query)
        .header("accept", "application/json")
        .send()
        .await
        .map_err(|_| unavailable())?;
    if !response.status().is_success() {
        return Err(unavailable());
    }
    let bytes = response.bytes().await.map_err(|_| unavailable())?;
    if bytes.len() > MAX_BODY {
        return Err(unavailable());
    }
    let body: Value = serde_json::from_slice(&bytes).map_err(|_| unavailable())?;
    Ok(normalize(&body))
}

fn unavailable() -> ApiError {
    ApiError::new(
        502,
        "registry_unavailable",
        "The MCP Registry did not answer. Try again, or add the server by URL.",
    )
}

/// The registry page as `{"servers": [...], "next": cursor|null}`.
pub fn normalize(body: &Value) -> Value {
    let servers: Vec<Value> = body["servers"]
        .as_array()
        .map(|rows| rows.iter().filter_map(entry).collect())
        .unwrap_or_default();
    let next = body["metadata"]["nextCursor"]
        .as_str()
        .filter(|cursor| !cursor.is_empty() && cursor.len() <= MAX_CURSOR)
        .map_or(Value::Null, Value::from);
    json!({"servers": servers, "next": next})
}

fn entry(row: &Value) -> Option<Value> {
    let server = &row["server"];
    let status = row["_meta"]["io.modelcontextprotocol.registry/official"]["status"]
        .as_str()
        .unwrap_or("active");
    if status != "active" {
        return None;
    }
    let name = text(&server["name"], 200)?;
    let remotes: Vec<Value> = server["remotes"]
        .as_array()?
        .iter()
        .filter_map(remote)
        .take(8)
        .collect();
    if remotes.is_empty() {
        return None;
    }
    let title = text(&server["title"], 120).unwrap_or_else(|| name.clone());
    Some(json!({
        "name": name,
        "title": title,
        "description": text(&server["description"], 400).unwrap_or_default(),
        "website": https(&server["websiteUrl"]).unwrap_or_default(),
        "remotes": remotes,
    }))
}

fn remote(value: &Value) -> Option<Value> {
    let kind = value["type"].as_str()?;
    if !matches!(kind, "streamable-http" | "sse") {
        return None;
    }
    let url = https(&value["url"])?;
    let headers: Vec<Value> = value["headers"]
        .as_array()
        .map(|rows| {
            rows.iter()
                .filter_map(|header| {
                    Some(json!({
                        "name": text(&header["name"], 100)?,
                        "secret": header["isSecret"].as_bool().unwrap_or(false),
                        "required": header["isRequired"].as_bool().unwrap_or(false),
                        "description": text(&header["description"], 300).unwrap_or_default(),
                    }))
                })
                .take(10)
                .collect()
        })
        .unwrap_or_default();
    let variables: Vec<Value> = value["variables"]
        .as_object()
        .map(|map| {
            map.keys()
                .filter(|key| key.len() <= 60)
                .take(10)
                .map(|key| Value::from(key.as_str()))
                .collect()
        })
        .unwrap_or_default();
    Some(json!({
        "type": kind,
        "url": url,
        "headers": headers,
        "variables": variables,
    }))
}

/// A trimmed string with control characters removed, cut to `max` characters.
fn text(value: &Value, max: usize) -> Option<String> {
    let clean: String = value
        .as_str()?
        .chars()
        .map(|c| if c.is_control() { ' ' } else { c })
        .collect::<String>()
        .trim()
        .chars()
        .take(max)
        .collect();
    (!clean.is_empty()).then_some(clean)
}

fn https(value: &Value) -> Option<String> {
    let url = value.as_str()?.trim();
    let ok = url.starts_with("https://")
        && url.len() <= 500
        && !url.contains('@')
        && !url.chars().any(|c| c.is_control() || c.is_whitespace());
    ok.then(|| url.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn page() -> Value {
        json!({
            "servers": [
                {
                    "server": {
                        "name": "io.github.github/github-mcp-server",
                        "title": "GitHub",
                        "description": "Repos,\u{0007} issues and PRs.",
                        "websiteUrl": "https://github.com",
                        "remotes": [{
                            "type": "streamable-http",
                            "url": "https://api.githubcopilot.com/mcp/",
                            "headers": [{
                                "name": "Authorization",
                                "isSecret": true,
                                "description": "PAT"
                            }]
                        }]
                    },
                    "_meta": {"io.modelcontextprotocol.registry/official": {"status": "active"}}
                },
                {
                    "server": {"name": "example/stdio-only", "packages": [{}]},
                    "_meta": {"io.modelcontextprotocol.registry/official": {"status": "active"}}
                },
                {
                    "server": {
                        "name": "example/old",
                        "remotes": [{"type": "streamable-http", "url": "https://old.example.com/mcp"}]
                    },
                    "_meta": {"io.modelcontextprotocol.registry/official": {"status": "deprecated"}}
                },
                {
                    "server": {
                        "name": "example/plain-http",
                        "remotes": [
                            {"type": "streamable-http", "url": "http://insecure.example.com/mcp"},
                            {"type": "sse", "url": "https://{region}.example.com/sse",
                             "variables": {"region": {"isRequired": true}}}
                        ]
                    }
                }
            ],
            "metadata": {"nextCursor": "example/plain-http:1.0.0", "count": 4}
        })
    }

    #[test]
    fn keeps_active_servers_with_https_remotes() {
        let value = normalize(&page());
        let servers = value["servers"].as_array().unwrap();
        assert_eq!(servers.len(), 2);
        assert_eq!(servers[0]["title"], "GitHub");
        assert_eq!(servers[0]["description"], "Repos,  issues and PRs.");
        assert_eq!(
            servers[0]["remotes"][0]["headers"][0]["name"],
            "Authorization"
        );
        assert_eq!(servers[0]["remotes"][0]["headers"][0]["secret"], true);
        assert_eq!(servers[0]["remotes"][0]["headers"][0]["required"], false);
        assert_eq!(servers[1]["title"], "example/plain-http");
        let remotes = servers[1]["remotes"].as_array().unwrap();
        assert_eq!(remotes.len(), 1, "the http:// remote is dropped");
        assert_eq!(remotes[0]["type"], "sse");
        assert_eq!(remotes[0]["variables"][0], "region");
        assert_eq!(value["next"], "example/plain-http:1.0.0");
    }

    #[test]
    fn missing_or_odd_pages_are_empty() {
        assert_eq!(normalize(&json!({}))["servers"], json!([]));
        assert_eq!(normalize(&json!({}))["next"], Value::Null);
        assert_eq!(normalize(&json!({"servers": "no"}))["servers"], json!([]));
    }

    #[test]
    fn params_reject_long_or_control_input() {
        assert_eq!(
            params("  github ", "").unwrap(),
            ("github".to_string(), String::new())
        );
        assert!(params(&"a".repeat(101), "").is_err());
        assert!(params("git\nhub", "").is_err());
        assert!(params("", &"c".repeat(301)).is_err());
    }
}
