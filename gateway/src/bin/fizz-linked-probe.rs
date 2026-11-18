//! Linked-mode probe. It asks the mock control plane to add a server, waits
//! until agentgateway lists the new tool without a process restart, then asks
//! for a bad config and checks that the previous tools still answer.
//! The registration token and client JWT are not printed.

use std::env;
use std::path::PathBuf;
use std::time::Duration;

use fizz_gateway::agent::registration_token_ok;
use fizz_gateway::db::Db;
use fizz_gateway::error::{GatewayError, GatewayResult};
use fizz_gateway::jwt;
use reqwest::header::{ACCEPT, AUTHORIZATION, CONTENT_TYPE, HeaderMap, HeaderValue};
use serde_json::{Value, json};
use uuid::Uuid;

#[tokio::main]
async fn main() {
    let code = match run().await {
        Ok(()) => {
            eprintln!("fizz-linked-probe: passed");
            0
        }
        Err(err) => {
            eprintln!("fizz-linked-probe: {err}");
            1
        }
    };
    std::process::exit(code);
}

async fn run() -> GatewayResult<()> {
    let registration = required("FIZZ_REGISTRATION_TOKEN")?;
    if !registration_token_ok(&registration) {
        return Err(GatewayError::message("registration token was rejected"));
    }
    let db = Db::connect(&required("DATABASE_URL")?).await?;
    let spec = db
        .load_gateway(None, "unused:1", "/config/jwks.json")
        .await?;
    let material = jwt::load_or_create(PathBuf::from(required("FIZZ_SIGNING_KEY")?).as_path())?;
    let (workspace, user_id, audience) = db.user_for_gateway(spec.gateway_id).await?;
    if workspace != spec.workspace_id {
        return Err(GatewayError::message("gateway record did not match"));
    }
    let jti = Uuid::new_v4();
    db.insert_token(spec.gateway_id, user_id, "linked probe", jti, 3600)
        .await?;
    let client_jwt = material.issue(&user_id.to_string(), workspace, &audience, jti, 3600)?;
    let http = reqwest::Client::builder()
        .timeout(Duration::from_secs(20))
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .map_err(|_| GatewayError::message("http client failed"))?;
    let gateway = required("GATEWAY_URL")?;
    let control = required("FIZZ_CONTROL_URL")?;
    initialize(&http, &gateway, &client_jwt).await?;
    let initial = wait_tools(&http, &gateway, &client_jwt, "ping", true, 45).await?;
    if has_tool(&initial, "echo") {
        return Err(GatewayError::message(
            "echo was listed before the server was added",
        ));
    }
    if !db.reapprove_pin(spec.gateway_id, "sample", "ping").await? {
        return Err(GatewayError::message(
            "tool pin was not recorded from tools/list",
        ));
    }
    expect_pong(&http, &gateway, &client_jwt).await?;
    control_post(&http, &control, &registration, "/test/add-server").await?;
    let added = wait_tools(&http, &gateway, &client_jwt, "echo", true, 40).await?;
    if !has_tool(&added, "ping") {
        return Err(GatewayError::message(
            "adding a server dropped the original tool",
        ));
    }
    eprintln!("fizz-linked-probe: added server is visible");
    control_post(&http, &control, &registration, "/test/bad-config").await?;
    wait_report(&http, &control, &registration).await?;
    let still = tools(&http, &gateway, &client_jwt).await?;
    if !has_tool(&still, "ping") || !has_tool(&still, "echo") {
        return Err(GatewayError::message(
            "bad config replaced the running gateway",
        ));
    }
    expect_pong(&http, &gateway, &client_jwt).await?;
    let file = std::fs::read_to_string(required("FIZZ_CONFIG_FILE")?)
        .map_err(|_| GatewayError::message("config file was not readable"))?;
    if file.contains("not-a-gateway") {
        return Err(GatewayError::message("bad config was written"));
    }
    if !file.contains("sample-mcp:8080") || !file.contains("sample-extra:8081") {
        return Err(GatewayError::message(
            "config file lost a server that is still serving",
        ));
    }
    eprintln!("fizz-linked-probe: bad config was rejected and the previous config still serves");
    Ok(())
}

async fn initialize(client: &reqwest::Client, gateway: &str, token: &str) -> GatewayResult<()> {
    let mut last = GatewayError::message("gateway was not ready");
    for _ in 0..45 {
        match post_raw(
            client,
            gateway,
            token,
            json!({
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "protocolVersion": "2025-03-26",
                    "capabilities": {},
                    "clientInfo": {"name": "fizz-linked-probe", "version": "0.1.0"}
                }
            }),
        )
        .await
        {
            Ok(_) => {
                let _ = post_raw(
                    client,
                    gateway,
                    token,
                    json!({"jsonrpc": "2.0", "method": "notifications/initialized"}),
                )
                .await;
                return Ok(());
            }
            Err(err) => {
                last = err;
                tokio::time::sleep(Duration::from_secs(1)).await;
            }
        }
    }
    Err(last)
}

async fn wait_tools(
    client: &reqwest::Client,
    gateway: &str,
    token: &str,
    needle: &str,
    want: bool,
    attempts: u32,
) -> GatewayResult<Vec<String>> {
    let mut last = GatewayError::message("tools/list was not ready");
    for _ in 0..attempts {
        match tools(client, gateway, token).await {
            Ok(names) if has_tool(&names, needle) == want => return Ok(names),
            Ok(_) => last = GatewayError::message("gateway had not picked up the config"),
            Err(err) => last = err,
        }
        tokio::time::sleep(Duration::from_secs(1)).await;
    }
    Err(last)
}

async fn tools(client: &reqwest::Client, gateway: &str, token: &str) -> GatewayResult<Vec<String>> {
    let body = post_raw(
        client,
        gateway,
        token,
        json!({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}}),
    )
    .await?;
    if body.get("error").is_some() {
        return Err(GatewayError::message("tools/list was rejected"));
    }
    Ok(body
        .pointer("/result/tools")
        .and_then(Value::as_array)
        .map(|tools| {
            tools
                .iter()
                .filter_map(|tool| tool.get("name").and_then(Value::as_str).map(str::to_string))
                .collect()
        })
        .unwrap_or_default())
}

fn has_tool(names: &[String], needle: &str) -> bool {
    let prefixed = format!("_{needle}");
    names
        .iter()
        .any(|name| name == needle || name.ends_with(&prefixed))
}

async fn expect_pong(client: &reqwest::Client, gateway: &str, token: &str) -> GatewayResult<()> {
    let body = post_raw(
        client,
        gateway,
        token,
        json!({
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/call",
            "params": {"name": "ping", "arguments": {}}
        }),
    )
    .await?;
    let text = body.to_string();
    if text.contains("eyJ") || text.to_ascii_lowercase().contains("bearer ") {
        return Err(GatewayError::message("gateway response was redacted"));
    }
    if !text.contains("pong") {
        return Err(GatewayError::message(
            "previous config stopped serving ping",
        ));
    }
    Ok(())
}

async fn control_post(
    client: &reqwest::Client,
    control: &str,
    token: &str,
    path: &str,
) -> GatewayResult<()> {
    let response = client
        .post(format!("{}{path}", control.trim_end_matches('/')))
        .bearer_auth(token)
        .send()
        .await
        .map_err(|_| GatewayError::message("control plane was unreachable"))?;
    if response.status().is_success() {
        Ok(())
    } else {
        Err(GatewayError::message(format!(
            "control plane returned {}",
            response.status().as_u16()
        )))
    }
}

async fn wait_report(client: &reqwest::Client, control: &str, token: &str) -> GatewayResult<()> {
    let url = format!("{}/test/report", control.trim_end_matches('/'));
    for _ in 0..40 {
        match client.get(&url).bearer_auth(token).send().await {
            Ok(response) if response.status().is_success() => {
                let value = response
                    .json::<Value>()
                    .await
                    .map_err(|_| GatewayError::message("status report was unreadable"))?;
                if value["status"] == "rejected" {
                    let detail = value["detail"].as_str().unwrap_or("");
                    if detail.contains("fizz_reg_") || detail.contains("eyJ") {
                        return Err(GatewayError::message(
                            "status report contained credential material",
                        ));
                    }
                    return Ok(());
                }
            }
            _ => {}
        }
        tokio::time::sleep(Duration::from_secs(1)).await;
    }
    Err(GatewayError::message(
        "bad config was not reported as rejected",
    ))
}

async fn post_raw(
    client: &reqwest::Client,
    gateway: &str,
    token: &str,
    body: Value,
) -> GatewayResult<Value> {
    let mut headers = HeaderMap::new();
    headers.insert(
        AUTHORIZATION,
        HeaderValue::from_str(&format!("Bearer {token}"))
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

fn required(name: &str) -> GatewayResult<String> {
    env::var(name).map_err(|_| GatewayError::message(format!("missing {name}")))
}
