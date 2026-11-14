//! MCP client for the local end-to-end test. It mints a Fizzlayer JWT in memory,
//! calls the sample tools through agentgateway, and checks the audit table.
//! The token is not printed. Response bodies that look like credentials are dropped.

use std::env;
use std::path::PathBuf;
use std::time::Duration;

use fizz_gateway::db::Db;
use fizz_gateway::error::{GatewayError, GatewayResult};
use fizz_gateway::jwt;
use reqwest::header::{HeaderMap, HeaderValue, ACCEPT, AUTHORIZATION, CONTENT_TYPE};
use serde_json::{json, Value};
use uuid::Uuid;

#[tokio::main]
async fn main() {
    let code = match run().await {
        Ok(()) => {
            eprintln!("fizz-mcp-probe: passed");
            0
        }
        Err(err) => {
            eprintln!("fizz-mcp-probe: {err}");
            1
        }
    };
    std::process::exit(code);
}

async fn run() -> GatewayResult<()> {
    let db = Db::connect(&required("DATABASE_URL")?).await?;
    let spec = db
        .load_gateway(None, "unused:1", "/config/jwks.json")
        .await?;
    assert_config(
        &required("FIZZ_CONFIG_FILE").unwrap_or_else(|_| "/config/config.yaml".to_string()),
    )?;
    let material = jwt::load_or_create(PathBuf::from(required("FIZZ_SIGNING_KEY")?).as_path())?;
    let (workspace, user_id, audience) = db.user_for_gateway(spec.gateway_id).await?;
    if workspace != spec.workspace_id || audience != spec.public_url {
        return Err(GatewayError::message("gateway record did not match"));
    }
    let jti = Uuid::new_v4();
    db.insert_token(spec.gateway_id, user_id, "e2e probe", jti, 3600)
        .await?;
    let token = material.issue(&user_id.to_string(), workspace, &audience, jti, 3600)?;
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(20))
        .build()
        .map_err(|_| GatewayError::message("http client failed"))?;
    let gateway = spec.public_url.clone();
    let init = call_with_retry(
        &client,
        &gateway,
        &token,
        "initialize",
        json!({
            "protocolVersion": "2025-03-26",
            "capabilities": {},
            "clientInfo": {"name": "fizz-mcp-probe", "version": "0.1.0"}
        }),
        1,
    )
    .await?;
    let _ = init;
    let _ = post_raw(
        &client,
        &gateway,
        &token,
        json!({"jsonrpc": "2.0", "method": "notifications/initialized"}),
    )
    .await?;
    let listed = call(&client, &gateway, &token, "tools/list", json!({}), 2).await?;
    let names = tool_names(&listed);
    for needed in ["ping", "admin_reset", "move_funds"] {
        if !names
            .iter()
            .any(|name| name == needed || name.ends_with(needed))
        {
            return Err(GatewayError::message(format!(
                "tools/list did not include {needed}"
            )));
        }
    }
    let ping_name = resolve(&names, "ping");
    let deny_name = resolve(&names, "admin_reset");
    let approve_name = resolve(&names, "move_funds");
    let ping = call(
        &client,
        &gateway,
        &token,
        "tools/call",
        json!({"name": ping_name, "arguments": {}}),
        3,
    )
    .await?;
    if !ping.to_string().contains("pong") {
        return Err(GatewayError::message("allowed tool did not return pong"));
    }
    let denied = call_error(&client, &gateway, &token, &deny_name).await?;
    if !denied.contains("not allowed") {
        return Err(GatewayError::message("denied tool was not rejected"));
    }
    let approval = call_error(&client, &gateway, &token, &approve_name).await?;
    if !approval.contains("Approval required") || !approval.contains("retry the same call") {
        return Err(GatewayError::message(
            "approval stub did not ask for a retry",
        ));
    }
    let calls = client
        .get(required("SAMPLE_CALLS_URL")?)
        .send()
        .await
        .map_err(|_| GatewayError::message("sample call counter was unreachable"))?
        .json::<Value>()
        .await
        .map_err(|_| GatewayError::message("sample call counter was unreadable"))?;
    if calls["ping"].as_u64() != Some(1)
        || calls["admin_reset"].as_u64() != Some(0)
        || calls["move_funds"].as_u64() != Some(0)
    {
        return Err(GatewayError::message(
            "upstream saw a call the guard should have stopped",
        ));
    }
    let rows = db.audit_decisions(spec.gateway_id).await?;
    expect_audit(&rows, "ping", "allow")?;
    expect_audit(&rows, "admin_reset", "deny")?;
    expect_audit(&rows, "move_funds", "approval_required")?;
    let status = db.approval_status(spec.gateway_id, "move_funds").await?;
    if status.as_deref() != Some("pending") {
        return Err(GatewayError::message("approval row was not pending"));
    }
    eprintln!("fizz-mcp-probe: allow, deny audit, and approval stub checked");
    Ok(())
}

fn assert_config(path: &str) -> GatewayResult<()> {
    let text = std::fs::read_to_string(path)
        .map_err(|_| GatewayError::message("generated config was not readable"))?;
    if text.contains("PRIVATE KEY") || text.contains("BEGIN ") {
        return Err(GatewayError::message(
            "generated config contained key material",
        ));
    }
    for needle in [
        "issuer: fizzlayer",
        "failureMode: failClosed",
        "kind: remote",
        "key: disabled",
    ] {
        if !text.contains(needle) {
            return Err(GatewayError::message(
                "generated config was missing a required field",
            ));
        }
    }
    Ok(())
}

fn resolve(names: &[String], suffix: &str) -> String {
    names
        .iter()
        .find(|name| name.as_str() == suffix || name.ends_with(suffix))
        .cloned()
        .unwrap_or_else(|| suffix.to_string())
}

fn tool_names(listed: &Value) -> Vec<String> {
    listed
        .pointer("/result/tools")
        .and_then(Value::as_array)
        .map(|tools| {
            tools
                .iter()
                .filter_map(|tool| tool.get("name").and_then(Value::as_str).map(str::to_string))
                .collect()
        })
        .unwrap_or_default()
}

fn expect_audit(rows: &[(String, String)], tool: &str, decision: &str) -> GatewayResult<()> {
    if rows
        .iter()
        .any(|(name, made)| name == tool && made == decision)
    {
        Ok(())
    } else {
        Err(GatewayError::message(format!(
            "audit row {tool}/{decision} was missing"
        )))
    }
}

async fn call_with_retry(
    client: &reqwest::Client,
    gateway: &str,
    token: &str,
    method: &str,
    params: Value,
    id: u64,
) -> GatewayResult<Value> {
    let mut last = GatewayError::message("gateway was not ready");
    for _ in 0..45 {
        match call(client, gateway, token, method, params.clone(), id).await {
            Ok(value) => return Ok(value),
            Err(err) => {
                last = err;
                tokio::time::sleep(Duration::from_secs(1)).await;
            }
        }
    }
    Err(last)
}

async fn call(
    client: &reqwest::Client,
    gateway: &str,
    token: &str,
    method: &str,
    params: Value,
    id: u64,
) -> GatewayResult<Value> {
    let body = post_raw(
        client,
        gateway,
        token,
        json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params}),
    )
    .await?;
    if body.get("error").is_some() {
        return Err(GatewayError::message(format!(
            "{method} failed: {}",
            shown(&body)
        )));
    }
    Ok(body)
}

async fn call_error(
    client: &reqwest::Client,
    gateway: &str,
    token: &str,
    tool: &str,
) -> GatewayResult<String> {
    let body = post_raw(
        client,
        gateway,
        token,
        json!({"jsonrpc": "2.0", "id": 9, "method": "tools/call", "params": {"name": tool, "arguments": {}}}),
    )
    .await?;
    let text = shown(&body);
    if body.get("error").is_none()
        && !text.contains("not allowed")
        && !text.contains("Approval required")
    {
        return Err(GatewayError::message(format!(
            "{tool} was unexpectedly allowed"
        )));
    }
    Ok(text)
}

async fn post_raw(
    client: &reqwest::Client,
    gateway: &str,
    token: &str,
    body: Value,
) -> GatewayResult<Value> {
    let mut headers = HeaderMap::new();
    let bearer = format!("Bearer {token}");
    headers.insert(
        AUTHORIZATION,
        HeaderValue::from_str(&bearer)
            .map_err(|_| GatewayError::message("token header was rejected"))?,
    );
    headers.insert(CONTENT_TYPE, HeaderValue::from_static("application/json"));
    headers.insert(
        ACCEPT,
        HeaderValue::from_static("application/json, text/event-stream"),
    );
    headers.insert(
        "mcp-protocol-version",
        HeaderValue::from_static("2025-03-26"),
    );
    let response = client
        .post(gateway)
        .headers(headers)
        .json(&body)
        .send()
        .await
        .map_err(|_| GatewayError::message("gateway request failed"))?;
    let status = response.status();
    let text = response
        .text()
        .await
        .map_err(|_| GatewayError::message("gateway response was unreadable"))?;
    if text.contains("eyJ") || text.to_ascii_lowercase().contains("bearer ") {
        return Err(GatewayError::message("gateway response was redacted"));
    }
    if status.as_u16() == 202 {
        return Ok(Value::Null);
    }
    if !status.is_success() {
        if let Ok(value) = parse_mcp(&text) {
            return Ok(value);
        }
        return Err(GatewayError::message(format!(
            "gateway returned {}",
            status.as_u16()
        )));
    }
    if text.trim().is_empty() {
        return Ok(Value::Null);
    }
    parse_mcp(&text)
}

fn parse_mcp(text: &str) -> GatewayResult<Value> {
    if let Ok(value) = serde_json::from_str::<Value>(text) {
        return Ok(value);
    }
    for line in text.lines() {
        let Some(data) = line.strip_prefix("data:") else {
            continue;
        };
        if let Ok(value) = serde_json::from_str::<Value>(data.trim()) {
            return Ok(value);
        }
    }
    Err(GatewayError::message("gateway response was not json"))
}

fn shown(value: &Value) -> String {
    let mut text = value.to_string();
    if text.contains("eyJ") || text.to_ascii_lowercase().contains("bearer ") {
        return "response redacted".to_string();
    }
    if text.len() > 400 {
        text.truncate(400);
    }
    text
}

fn required(name: &str) -> GatewayResult<String> {
    env::var(name).map_err(|_| GatewayError::message(format!("missing {name}")))
}
