//! Shared-fleet checks: tenant isolation, policy, credential redaction, reload, rate limit.
//! Tokens and upstream credentials are not printed.

use std::env;
use std::path::PathBuf;
use std::time::Duration;

use fizz_gateway::db::Db;
use fizz_gateway::error::{GatewayError, GatewayResult};
use fizz_gateway::jwt;
use reqwest::header::{ACCEPT, AUTHORIZATION, CONTENT_TYPE, HeaderValue};
use serde_json::{Value, json};
use uuid::Uuid;

const GATEWAY_A: &str = "22222222-2222-4222-8222-222222222222";
const WORKSPACE_A: &str = "11111111-1111-4111-8111-111111111111";
const USER_A: &str = "44444444-4444-4444-8444-444444444444";
const GATEWAY_B: &str = "33333333-3333-4333-8333-333333333333";
const WORKSPACE_B: &str = "66666666-6666-4666-8666-666666666666";
const USER_B: &str = "88888888-8888-4888-8888-888888888888";
const GATEWAY_LIMIT: &str = "77777777-7777-4777-8777-777777777777";
const SECRET_MARK: &str = "upstream-token";

#[tokio::main]
async fn main() {
    let code = match run().await {
        Ok(()) => {
            eprintln!("fizz-hosted-probe: passed");
            0
        }
        Err(err) => {
            eprintln!("fizz-hosted-probe: {err}");
            1
        }
    };
    std::process::exit(code);
}

async fn run() -> GatewayResult<()> {
    let db = Db::connect(&required("DATABASE_URL")?).await?;
    let material = jwt::load_or_create(PathBuf::from(required("FIZZ_SIGNING_KEY")?).as_path())?;
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(20))
        .build()
        .map_err(|_| GatewayError::message("http client failed"))?;
    let base = required("GATEWAY_ORIGIN")?;
    let url_a = format!("{base}/w/{GATEWAY_A}/mcp");
    let url_b = format!("{base}/w/{GATEWAY_B}/mcp");
    let url_limit = format!("{base}/w/{GATEWAY_LIMIT}/mcp");
    let token_a = mint(&db, &material, GATEWAY_A, WORKSPACE_A, USER_A, &url_a).await?;
    let token_b = mint(&db, &material, GATEWAY_B, WORKSPACE_B, USER_B, &url_b).await?;
    let token_limit = mint(
        &db,
        &material,
        GATEWAY_LIMIT,
        WORKSPACE_A,
        USER_A,
        &url_limit,
    )
    .await?;

    let listed = call_ok(&client, &url_a, &token_a, "tools/list", json!({})).await?;
    if !shown(&listed).contains("ping") {
        return Err(GatewayError::message("tools/list did not include ping"));
    }
    if !db
        .reapprove_pin(
            Uuid::parse_str(GATEWAY_A).map_err(|_| GatewayError::message("gateway id"))?,
            "sample",
            "ping",
        )
        .await?
    {
        return Err(GatewayError::message("pin was not recorded"));
    }
    let ping = call_ok(
        &client,
        &url_a,
        &token_a,
        "tools/call",
        json!({"name": "ping", "arguments": {}}),
    )
    .await?;
    let ping_text = shown(&ping);
    if !ping_text.contains("pong") || ping_text.contains(SECRET_MARK) {
        return Err(GatewayError::message(
            "allowed call did not return pong without a credential",
        ));
    }

    let crossed = post_status(&client, &url_b, &token_a).await?;
    if crossed != 401 {
        return Err(GatewayError::message("gateway A token reached gateway B"));
    }
    let crossed_back = post_status(&client, &url_a, &token_b).await?;
    if crossed_back != 401 {
        return Err(GatewayError::message("gateway B token reached gateway A"));
    }

    let _ = call_ok(&client, &url_b, &token_b, "tools/list", json!({})).await?;
    if !db
        .reapprove_pin(
            Uuid::parse_str(GATEWAY_B).map_err(|_| GatewayError::message("gateway id"))?,
            "other",
            "ping",
        )
        .await?
    {
        return Err(GatewayError::message("pin was not recorded"));
    }
    let denied = call_body(
        &client,
        &url_b,
        &token_b,
        "tools/call",
        json!({"name": "ping", "arguments": {}}),
    )
    .await?;
    if !shown(&denied).contains("not allowed") {
        return Err(GatewayError::message("gateway B policy did not deny ping"));
    }

    let audits_a = db
        .audit_decisions(Uuid::parse_str(GATEWAY_A).unwrap())
        .await?;
    let audits_b = db
        .audit_decisions(Uuid::parse_str(GATEWAY_B).unwrap())
        .await?;
    if !audits_a
        .iter()
        .any(|(tool, decision)| tool == "ping" && decision == "allow")
    {
        return Err(GatewayError::message("gateway A allow audit was missing"));
    }
    if audits_b
        .iter()
        .any(|(tool, decision)| tool == "ping" && decision == "allow")
    {
        return Err(GatewayError::message("gateway B recorded an allow"));
    }
    if !audits_b
        .iter()
        .any(|(tool, decision)| tool == "ping" && decision == "deny")
    {
        return Err(GatewayError::message("gateway B deny audit was missing"));
    }

    let check = client
        .get(format!(
            "{}/test/secret-check",
            required("FIZZ_CONTROL_URL")?.trim_end_matches('/')
        ))
        .bearer_auth(required("FIZZ_FLEET_TOKEN")?)
        .send()
        .await
        .map_err(|_| GatewayError::message("secret check was unreachable"))?;
    let check_body: Value = check
        .json()
        .await
        .map_err(|_| GatewayError::message("secret check was unreadable"))?;
    if check_body["embedded"] != true || check_body["redacted"] != true {
        return Err(GatewayError::message(
            "credential was not both embedded for the fleet and omitted from the redacted render",
        ));
    }
    if check_body.to_string().contains(SECRET_MARK) {
        return Err(GatewayError::message("secret check echoed a credential"));
    }

    client
        .post(format!(
            "{}/test/add-server",
            required("FIZZ_CONTROL_URL")?.trim_end_matches('/')
        ))
        .bearer_auth(required("FIZZ_FLEET_TOKEN")?)
        .send()
        .await
        .map_err(|_| GatewayError::message("reload request failed"))?;
    let mut saw_echo = false;
    for _ in 0..20 {
        tokio::time::sleep(Duration::from_secs(1)).await;
        if let Ok(again) = call_ok(&client, &url_a, &token_a, "tools/list", json!({})).await {
            if shown(&again).contains("echo") {
                saw_echo = true;
                break;
            }
        }
    }
    if !saw_echo {
        return Err(GatewayError::message(
            "config reload did not add the server",
        ));
    }

    // agentgateway v1.7 reports a local rate limit as HTTP 200 with
    // "rate limit exceeded" in the body, or as HTTP 429. Either counts.
    let mut saw_limit = false;
    let mut saw_ok = false;
    for _ in 0..6 {
        let (status, text) = post(
            &client,
            &url_limit,
            &token_limit,
            json!({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "fizz-hosted-probe", "version": "0.1.0"}}}),
        )
        .await?;
        if text.contains(SECRET_MARK) || text.contains("eyJ") {
            return Err(GatewayError::message("gateway response was redacted"));
        }
        let limited = status == 429 || text.to_ascii_lowercase().contains("rate limit");
        if limited {
            saw_limit = true;
        } else if (200..300).contains(&status) {
            saw_ok = true;
        }
    }
    if !saw_ok || !saw_limit {
        return Err(GatewayError::message("per-gateway rate limit did not trip"));
    }
    Ok(())
}

async fn mint(
    db: &Db,
    material: &jwt::SigningMaterial,
    gateway: &str,
    workspace: &str,
    user: &str,
    audience: &str,
) -> GatewayResult<String> {
    let gateway_id = Uuid::parse_str(gateway).map_err(|_| GatewayError::message("gateway id"))?;
    let workspace_id =
        Uuid::parse_str(workspace).map_err(|_| GatewayError::message("workspace id"))?;
    let user_id = Uuid::parse_str(user).map_err(|_| GatewayError::message("user id"))?;
    let jti = Uuid::new_v4();
    db.insert_token(gateway_id, user_id, "hosted probe", jti, 3600)
        .await?;
    material.issue(&user_id.to_string(), workspace_id, audience, jti, 3600)
}

async fn call_ok(
    client: &reqwest::Client,
    url: &str,
    token: &str,
    method: &str,
    params: Value,
) -> GatewayResult<Value> {
    let mut last = GatewayError::message("gateway request failed");
    for _ in 0..20 {
        match call_body(client, url, token, method, params.clone()).await {
            Ok(value) if value.get("error").is_none() => return Ok(value),
            Ok(_) => last = GatewayError::message("gateway call was rejected"),
            Err(err) => last = err,
        }
        tokio::time::sleep(Duration::from_secs(1)).await;
    }
    Err(last)
}

async fn call_body(
    client: &reqwest::Client,
    url: &str,
    token: &str,
    method: &str,
    params: Value,
) -> GatewayResult<Value> {
    let (status, text) = post(
        client,
        url,
        token,
        json!({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}),
    )
    .await?;
    if text.contains(SECRET_MARK) || text.contains("eyJ") {
        return Err(GatewayError::message("gateway response was redacted"));
    }
    if status == 401 || status == 429 {
        return Err(GatewayError::message(format!("gateway returned {status}")));
    }
    parse_mcp(&text)
}

async fn post_status(client: &reqwest::Client, url: &str, token: &str) -> GatewayResult<u16> {
    let (status, text) = post(
        client,
        url,
        token,
        json!({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "fizz-hosted-probe", "version": "0.1.0"}}}),
    )
    .await?;
    if text.contains(SECRET_MARK) || text.contains("eyJ") {
        return Err(GatewayError::message("gateway response was redacted"));
    }
    Ok(status)
}

async fn post(
    client: &reqwest::Client,
    url: &str,
    token: &str,
    body: Value,
) -> GatewayResult<(u16, String)> {
    let response = client
        .post(url)
        .header(
            AUTHORIZATION,
            HeaderValue::from_str(&format!("Bearer {token}"))
                .map_err(|_| GatewayError::message("token header was rejected"))?,
        )
        .header(CONTENT_TYPE, "application/json")
        .header(ACCEPT, "application/json, text/event-stream")
        .header("mcp-protocol-version", "2025-03-26")
        .json(&body)
        .send()
        .await
        .map_err(|_| GatewayError::message("gateway request failed"))?;
    let status = response.status().as_u16();
    let text = response
        .text()
        .await
        .map_err(|_| GatewayError::message("gateway response was unreadable"))?;
    Ok((status, text))
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
    let text = value.to_string();
    if text.contains(SECRET_MARK) || text.contains("eyJ") {
        return "response redacted".to_string();
    }
    text
}

fn required(name: &str) -> GatewayResult<String> {
    env::var(name).map_err(|_| GatewayError::message(format!("missing {name}")))
}
