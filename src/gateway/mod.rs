//! Gateway control plane. Routes live under `/api/gateway/*`.
//!
//! Signed-in calls use a Supabase access token (`Authorization: Bearer` or the
//! `fizz_supabase` cookie). Owner and admin can change a gateway; a member can
//! read it. A gateway agent pulls config with a registration token, which is
//! the only response that contains decrypted upstream credentials.

mod crypto;
mod limits;
#[cfg(test)]
mod memory;
mod store;

use std::time::{SystemTime, UNIX_EPOCH};

use bytes::Bytes;
use fizz_gateway::config::{CredentialMode, GatewaySpec, Mode, ServerSpec, Transport, render_yaml};
use fizz_gateway::jwt;
use http_body_util::BodyExt;
use serde_json::{Value, json};
use uuid::Uuid;
use vercel_runtime::{Request, Response, ResponseBody};

use crate::customer::{self, ApiError};
use crate::security::{is_json, request_origin};
use crate::sensors::valid_uuid;

use store::Backend;

const DEFAULT_TTL: u64 = 60 * 60;
const MAX_TTL: u64 = 30 * 24 * 60 * 60;

pub async fn handle(request: Request) -> Response<ResponseBody> {
    handle_with(request, &store::Live).await
}

async fn handle_with<B>(request: http::Request<B>, backend: &impl Backend) -> Response<ResponseBody>
where
    B: http_body::Body<Data = Bytes> + Send,
    B::Error: std::fmt::Display + Send,
{
    let method = request.method().clone();
    let query = request.uri().query().unwrap_or("").to_string();
    let path = resource_path(request.uri().path(), &query);
    let if_none = header(&request, "if-none-match");
    let origin = request_origin(&request).unwrap_or_else(|| "https://fizzlayer.com".to_string());
    let bearer = bearer_token(&request);
    let Some(route) = parse_route(&path) else {
        return ApiError::new(404, "not_found", "No gateway route matches that path.")
            .into_response();
    };
    if method.as_str() == "GET" && matches!(route, Route::Jwks) {
        return jwks(backend);
    }
    if matches!(route, Route::AgentConfig) {
        if method.as_str() != "GET" {
            return ApiError::new(405, "method_not_allowed", "Use GET.").into_response();
        }
        let Some(token) = bearer else {
            return ApiError::new(401, "unauthorized", "Registration token was rejected.")
                .into_response();
        };
        return agent_config(backend, &token, &query, if_none.as_deref(), &origin).await;
    }
    let Some(token) = bearer else {
        return ApiError::new(401, "unauthorized", "Sign in to continue.").into_response();
    };
    let user = match backend.authenticate(&token).await {
        Ok(user) => user,
        Err(error) => return error.into_response(),
    };
    let body = if matches!(method.as_str(), "POST" | "PUT" | "PATCH") {
        match read_json(request, 32 * 1024).await {
            Ok(body) => body,
            Err(error) => return error.into_response(),
        }
    } else {
        Value::Null
    };
    let view = View {
        query: &query,
        if_none: if_none.as_deref(),
        origin: &origin,
    };
    match dispatch(backend, method.as_str(), route, user, body, &view).await {
        Ok(response) => response,
        Err(error) => error.into_response(),
    }
}

struct View<'a> {
    query: &'a str,
    if_none: Option<&'a str>,
    origin: &'a str,
}

async fn dispatch(
    backend: &impl Backend,
    method: &str,
    route: Route,
    user: Uuid,
    body: Value,
    view: &View<'_>,
) -> Result<Response<ResponseBody>, ApiError> {
    match (method, route) {
        ("GET", Route::Gateways) => Ok(json_ok(map_db(
            backend.call(Some(user), "context", json!({})).await?,
            false,
        )?)),
        ("POST", Route::Gateways) => create_gateway(backend, user, &body).await,
        ("DELETE", Route::Gateway(id)) => Ok(json_ok(map_db(
            backend
                .call(Some(user), "delete_gateway", json!({"gateway_id": id}))
                .await?,
            false,
        )?)),
        ("GET", Route::Servers(id)) => Ok(json_ok(map_db(
            backend
                .call(Some(user), "list_servers", json!({"gateway_id": id}))
                .await?,
            false,
        )?)),
        ("POST", Route::Servers(id)) => add_server(backend, user, &id, &body).await,
        ("DELETE", Route::Server(id, server)) => Ok(json_ok(map_db(
            backend
                .call(
                    Some(user),
                    "remove_server",
                    json!({"gateway_id": id, "server_id": server}),
                )
                .await?,
            false,
        )?)),
        ("GET", Route::Policies(id)) => Ok(json_ok(map_db(
            backend
                .call(Some(user), "list_policies", json!({"gateway_id": id}))
                .await?,
            false,
        )?)),
        ("PUT", Route::Policies(id)) => set_policy(backend, user, &id, &body).await,
        ("PATCH", Route::Gateway(id)) => set_unreviewed(backend, user, &id, &body).await,
        ("GET", Route::Pins(id)) => Ok(json_ok(map_db(
            backend
                .call(Some(user), "list_pins", json!({"gateway_id": id}))
                .await?,
            false,
        )?)),
        ("POST", Route::PinApprove(id)) => approve_pin(backend, user, &id, &body).await,
        ("GET", Route::PinAlerts(id)) => Ok(json_ok(map_db(
            backend
                .call(Some(user), "list_pin_alerts", json!({"gateway_id": id}))
                .await?,
            false,
        )?)),
        ("POST", Route::PinAlertAck(id, alert)) => Ok(json_ok(map_db(
            backend
                .call(
                    Some(user),
                    "ack_pin_alert",
                    json!({"gateway_id": id, "alert_id": alert}),
                )
                .await?,
            false,
        )?)),
        ("GET", Route::Approvals(id)) => Ok(json_ok(map_db(
            backend
                .call(Some(user), "list_approvals", json!({"gateway_id": id}))
                .await?,
            false,
        )?)),
        ("POST", Route::ApprovalDecision(id, approval)) => {
            decide_approval(backend, user, &id, &approval, &body).await
        }
        ("DELETE", Route::Policy(id, policy)) => Ok(json_ok(map_db(
            backend
                .call(
                    Some(user),
                    "delete_policy",
                    json!({"gateway_id": id, "policy_id": policy}),
                )
                .await?,
            false,
        )?)),
        ("GET", Route::Config(id)) => user_config(backend, user, &id, view).await,
        ("GET", Route::Tokens(id)) => Ok(json_ok(map_db(
            backend
                .call(Some(user), "list_tokens", json!({"gateway_id": id}))
                .await?,
            false,
        )?)),
        ("POST", Route::Tokens(id)) => mint_token(backend, user, &id, &body).await,
        ("DELETE", Route::Token(id, token)) => Ok(json_ok(map_db(
            backend
                .call(
                    Some(user),
                    "revoke_token",
                    json!({"gateway_id": id, "token_id": token}),
                )
                .await?,
            false,
        )?)),
        ("POST", Route::Registration(id)) => rotate_registration(backend, user, &id).await,
        _ => Err(ApiError::new(
            405,
            "method_not_allowed",
            "That method is not supported on this gateway route.",
        )),
    }
}

async fn create_gateway(
    backend: &impl Backend,
    user: Uuid,
    body: &Value,
) -> Result<Response<ResponseBody>, ApiError> {
    let name = body["name"].as_str().unwrap_or("");
    if !limits::gateway_name_ok(name) {
        return Err(ApiError::new(
            400,
            "invalid_request",
            "Gateway name must start with a letter and use lowercase letters, digits, and hyphens.",
        ));
    }
    if let Some(mode) = body["mode"].as_str()
        && !matches!(mode, "shared" | "dedicated" | "selfhost")
    {
        return Err(ApiError::new(
            400,
            "invalid_request",
            "Gateway mode must be shared, dedicated, or selfhost.",
        ));
    }
    if let Some(url) = body["public_url"].as_str()
        && !limits::remote_url_ok(url)
    {
        return Err(ApiError::new(
            400,
            "invalid_request",
            "public_url must be an http or https URL without credentials.",
        ));
    }
    let token = crypto::registration_token()?;
    let mut payload = json!({
        "name": name,
        "registration_hash": crypto::sha256_hex(token.as_bytes()),
    });
    copy_field(&mut payload, body, "mode");
    copy_field(&mut payload, body, "region");
    copy_field(&mut payload, body, "public_url");
    if let Some(port) = body["listen_port"].as_u64() {
        payload["listen_port"] = json!(port);
    }
    let mut created = map_db(
        backend.call(Some(user), "create_gateway", payload).await?,
        false,
    )?;
    created["registration_token"] = json!(token);
    Ok(json_ok(created))
}

async fn add_server(
    backend: &impl Backend,
    user: Uuid,
    gateway: &str,
    body: &Value,
) -> Result<Response<ResponseBody>, ApiError> {
    let name = body["name"].as_str().unwrap_or("");
    let transport = body["transport"].as_str().unwrap_or("http");
    if !limits::server_name_ok(name) || !matches!(transport, "http" | "sse" | "stdio") {
        return Err(ApiError::new(
            400,
            "invalid_request",
            "Server name and transport were not accepted.",
        ));
    }
    let target = if transport == "stdio" {
        body["command"].as_str().unwrap_or("")
    } else {
        body["url"].as_str().unwrap_or("")
    };
    if transport == "stdio" && !limits::command_ok(target) {
        return Err(ApiError::new(
            400,
            "invalid_request",
            "The stdio command was not accepted.",
        ));
    }
    if transport != "stdio" && !limits::remote_url_ok(target) {
        return Err(ApiError::new(
            400,
            "invalid_request",
            "Server url must be an http or https URL without credentials.",
        ));
    }
    let api_key = body["api_key"].as_str().filter(|value| !value.is_empty());
    let auth_kind = if api_key.is_some() {
        "key"
    } else {
        body["auth_kind"].as_str().unwrap_or("none")
    };
    if !matches!(auth_kind, "none" | "key" | "passthrough") {
        return Err(ApiError::new(
            400,
            "invalid_request",
            "auth_kind must be none, key, or passthrough.",
        ));
    }
    let ciphertext = if let Some(api_key) = api_key {
        Some(crypto::seal(&backend.secret_key()?, api_key.as_bytes())?)
    } else if auth_kind == "key" {
        return Err(ApiError::new(
            400,
            "invalid_request",
            "Send api_key when auth_kind is key.",
        ));
    } else {
        None
    };
    let args = body.get("args").cloned().unwrap_or_else(|| json!([]));
    let mut payload = json!({
        "gateway_id": gateway,
        "name": name,
        "transport": transport,
        "url": target,
        "args": args,
        "auth_kind": auth_kind,
    });
    if let Some(ciphertext) = ciphertext {
        payload["ciphertext"] = json!(ciphertext);
        payload["key_id"] = json!(crypto::KEY_ID);
    }
    Ok(json_ok(map_db(
        backend.call(Some(user), "add_server", payload).await?,
        false,
    )?))
}

async fn set_policy(
    backend: &impl Backend,
    user: Uuid,
    gateway: &str,
    body: &Value,
) -> Result<Response<ResponseBody>, ApiError> {
    let tool = body["tool_name"].as_str().unwrap_or("");
    let effect = body["effect"].as_str().unwrap_or("");
    if !limits::tool_name_ok(tool) || !limits::effect_ok(effect) {
        return Err(ApiError::new(
            400,
            "invalid_request",
            "tool_name must be * or a tool name, and effect must be allow, deny, or approve.",
        ));
    }
    let mut payload = json!({
        "gateway_id": gateway,
        "tool_name": tool,
        "effect": effect,
    });
    if let Some(server) = body["server_id"].as_str() {
        if !valid_uuid(server) {
            return Err(ApiError::new(
                400,
                "invalid_request",
                "server_id must be a UUID.",
            ));
        }
        payload["server_id"] = json!(server);
    }
    if let Some(channel) = body["notify_channel"].as_str() {
        if !matches!(channel, "log" | "webhook" | "phone") {
            return Err(ApiError::new(
                400,
                "invalid_request",
                "notify_channel must be log, webhook, or phone.",
            ));
        }
        payload["notify_channel"] = json!(channel);
    }
    Ok(json_ok(map_db(
        backend.call(Some(user), "set_policy", payload).await?,
        false,
    )?))
}

async fn set_unreviewed(
    backend: &impl Backend,
    user: Uuid,
    gateway: &str,
    body: &Value,
) -> Result<Response<ResponseBody>, ApiError> {
    let mode = body["unreviewed_tools"].as_str().unwrap_or("");
    if !matches!(mode, "hide" | "show") {
        return Err(ApiError::new(
            400,
            "invalid_request",
            "unreviewed_tools must be hide or show.",
        ));
    }
    Ok(json_ok(map_db(
        backend
            .call(
                Some(user),
                "set_unreviewed",
                json!({"gateway_id": gateway, "unreviewed_tools": mode}),
            )
            .await?,
        false,
    )?))
}

async fn approve_pin(
    backend: &impl Backend,
    user: Uuid,
    gateway: &str,
    body: &Value,
) -> Result<Response<ResponseBody>, ApiError> {
    let server = body["server"].as_str().unwrap_or("");
    let tool = body["tool"].as_str().unwrap_or("");
    if !limits::server_name_ok(server) || !limits::tool_name_ok(tool) || tool == "*" {
        return Err(ApiError::new(
            400,
            "invalid_request",
            "Name the server and the tool to approve.",
        ));
    }
    Ok(json_ok(map_db(
        backend
            .call(
                Some(user),
                "approve_pin",
                json!({"gateway_id": gateway, "server": server, "tool": tool}),
            )
            .await?,
        false,
    )?))
}

async fn decide_approval(
    backend: &impl Backend,
    user: Uuid,
    gateway: &str,
    approval: &str,
    body: &Value,
) -> Result<Response<ResponseBody>, ApiError> {
    let status = body["status"].as_str().unwrap_or("");
    if !matches!(status, "approved" | "denied") {
        return Err(ApiError::new(
            400,
            "invalid_request",
            "status must be approved or denied.",
        ));
    }
    Ok(json_ok(map_db(
        backend
            .call(
                Some(user),
                "decide_approval",
                json!({"gateway_id": gateway, "approval_id": approval, "status": status}),
            )
            .await?,
        false,
    )?))
}

async fn mint_token(
    backend: &impl Backend,
    user: Uuid,
    gateway: &str,
    body: &Value,
) -> Result<Response<ResponseBody>, ApiError> {
    let name = body["name"].as_str().unwrap_or("");
    if name.is_empty() || name.len() > 80 || name.chars().any(char::is_control) {
        return Err(ApiError::new(
            400,
            "invalid_request",
            "Token name must be 1 to 80 characters.",
        ));
    }
    let ttl = body["ttl_seconds"].as_u64().unwrap_or(DEFAULT_TTL);
    if !(60..=MAX_TTL).contains(&ttl) {
        return Err(ApiError::new(
            400,
            "invalid_request",
            "ttl_seconds must be between 60 and 2592000 (30 days).",
        ));
    }
    let jti = Uuid::new_v4();
    let expires_at = unix_now().saturating_add(ttl);
    let minted = map_db(
        backend
            .call(
                Some(user),
                "insert_token",
                json!({
                    "gateway_id": gateway,
                    "name": name,
                    "jti": jti.to_string(),
                    "expires_at": expires_at,
                }),
            )
            .await?,
        false,
    )?;
    let audience = minted["token"]["audience"]
        .as_str()
        .ok_or_else(unavailable)?;
    let workspace = minted["token"]["workspace_id"]
        .as_str()
        .and_then(|value| Uuid::parse_str(value).ok())
        .ok_or_else(unavailable)?;
    let material = jwt::from_pem(&backend.signing_pem()?).map_err(|_| signing_bad())?;
    let token = material
        .issue(&user.to_string(), workspace, audience, jti, ttl)
        .map_err(|_| signing_bad())?;
    let mut body = minted;
    body["token"]["token"] = json!(token);
    Ok(json_ok(body))
}

async fn rotate_registration(
    backend: &impl Backend,
    user: Uuid,
    gateway: &str,
) -> Result<Response<ResponseBody>, ApiError> {
    let token = crypto::registration_token()?;
    let mut rotated = map_db(
        backend
            .call(
                Some(user),
                "rotate_registration",
                json!({
                    "gateway_id": gateway,
                    "registration_hash": crypto::sha256_hex(token.as_bytes()),
                }),
            )
            .await?,
        false,
    )?;
    rotated["registration_token"] = json!(token);
    Ok(json_ok(rotated))
}

async fn user_config(
    backend: &impl Backend,
    user: Uuid,
    gateway: &str,
    view: &View<'_>,
) -> Result<Response<ResponseBody>, ApiError> {
    let source = map_db(
        backend
            .call(Some(user), "render_source", json!({"gateway_id": gateway}))
            .await?,
        false,
    )?;
    let revision = source["config_revision"].as_i64().unwrap_or(0);
    let etag = format!("\"{revision}-redacted\"");
    if fresh(
        view.if_none,
        query_value(view.query, "rev").as_deref(),
        &etag,
        revision,
    ) {
        return Ok(not_modified(&etag, revision));
    }
    let yaml = render(backend, &source, CredentialMode::Omit, None, view.origin)?;
    Ok(yaml_response(yaml, &etag, revision))
}

async fn agent_config(
    backend: &impl Backend,
    token: &str,
    query: &str,
    if_none: Option<&str>,
    origin: &str,
) -> Response<ResponseBody> {
    if !crypto::registration_token_ok(token) {
        return ApiError::new(401, "unauthorized", "Registration token was rejected.")
            .into_response();
    }
    let source = match backend
        .call(
            None,
            "agent_config",
            json!({"token_hash": crypto::sha256_hex(token.as_bytes())}),
        )
        .await
    {
        Ok(value) => value,
        Err(error) => return error.into_response(),
    };
    let source = match map_db(source, true) {
        Ok(value) => value,
        Err(error) => return error.into_response(),
    };
    let revision = source["config_revision"].as_i64().unwrap_or(0);
    let etag = format!("\"{revision}\"");
    if fresh(
        if_none,
        query_value(query, "rev").as_deref(),
        &etag,
        revision,
    ) {
        return not_modified(&etag, revision);
    }
    let key = if source["servers"].as_array().is_some_and(|servers| {
        servers
            .iter()
            .any(|server| server["ciphertext"].is_string())
    }) {
        match backend.secret_key() {
            Ok(key) => Some(key),
            Err(error) => return error.into_response(),
        }
    } else {
        None
    };
    match render(
        backend,
        &source,
        CredentialMode::Embed,
        key.as_ref(),
        origin,
    ) {
        Ok(yaml) => yaml_response(yaml, &etag, revision),
        Err(error) => error.into_response(),
    }
}

fn render(
    backend: &impl Backend,
    source: &Value,
    mode: CredentialMode,
    key: Option<&[u8; 32]>,
    origin: &str,
) -> Result<String, ApiError> {
    let gateway_id = uuid_value(&source["gateway_id"])?;
    let workspace_id = uuid_value(&source["workspace_id"])?;
    let gateway_mode = Mode::parse(source["mode"].as_str().unwrap_or(""))
        .ok_or_else(|| ApiError::new(400, "invalid_request", "Gateway mode is not usable."))?;
    let listen_port = u16::try_from(source["listen_port"].as_u64().unwrap_or(0))
        .map_err(|_| ApiError::new(400, "invalid_request", "Gateway listen port is not usable."))?;
    let mut servers = Vec::new();
    for server in source["servers"].as_array().ok_or_else(unavailable)? {
        let transport =
            Transport::parse(server["transport"].as_str().unwrap_or("")).ok_or_else(|| {
                ApiError::new(400, "invalid_request", "Server transport is not usable.")
            })?;
        let auth_kind = server["auth_kind"].as_str().unwrap_or("none").to_string();
        let credential = if mode == CredentialMode::Embed && auth_kind == "key" {
            let encoded = server["ciphertext"].as_str().ok_or_else(|| {
                ApiError::new(
                    503,
                    "missing_secret",
                    "A stored MCP credential could not be read.",
                )
            })?;
            let key = key.ok_or_else(|| {
                ApiError::new(
                    503,
                    "encryption_unavailable",
                    "Storing an MCP credential needs GATEWAY_SECRET_KEY on the server.",
                )
            })?;
            let plain = crypto::open(key, encoded)?;
            Some(String::from_utf8(plain).map_err(|_| {
                ApiError::new(
                    503,
                    "missing_secret",
                    "A stored MCP credential could not be read.",
                )
            })?)
        } else {
            None
        };
        let args = server["args"]
            .as_array()
            .map(|items| {
                items
                    .iter()
                    .filter_map(Value::as_str)
                    .map(str::to_string)
                    .collect()
            })
            .unwrap_or_default();
        servers.push(ServerSpec {
            name: server["name"].as_str().unwrap_or("").to_string(),
            transport,
            url_or_cmd: server["url"].as_str().unwrap_or("").to_string(),
            command_args: args,
            auth_kind,
            credential,
        });
    }
    let spec = GatewaySpec {
        gateway_id,
        workspace_id,
        mode: gateway_mode,
        public_url: source["public_url"].as_str().unwrap_or("").to_string(),
        listen_port,
        config_revision: source["config_revision"].as_i64().unwrap_or(1),
        ag_version: source["ag_version"].as_str().map(str::to_string),
        guard_host: backend.guard_host()?,
        jwks_file: String::new(),
        jwks_url: Some(backend.jwks_url(origin)),
        credential_mode: mode,
        servers,
    };
    render_yaml(&spec).map_err(|_| {
        ApiError::new(
            400,
            "invalid_request",
            "The gateway config could not be rendered.",
        )
    })
}

fn jwks(backend: &impl Backend) -> Response<ResponseBody> {
    let pem = match backend.signing_pem() {
        Ok(pem) => pem,
        Err(error) => return error.into_response(),
    };
    let Ok(material) = jwt::from_pem(&pem) else {
        return signing_bad().into_response();
    };
    let Ok(body) = material.jwks_json() else {
        return unavailable().into_response();
    };
    Response::builder()
        .status(200)
        .header("content-type", "application/json")
        .header("cache-control", "public, max-age=300")
        .body(ResponseBody::from(body))
        .expect("jwks response")
}

fn map_db(value: Value, agent: bool) -> Result<Value, ApiError> {
    match value.get("error").and_then(Value::as_str) {
        Some(code) => Err(limits::map_code(code, agent)),
        None if value.is_object() => Ok(value),
        None => Err(unavailable()),
    }
}

fn json_ok(body: Value) -> Response<ResponseBody> {
    customer::reply(200, body, None)
}

fn yaml_response(body: String, etag: &str, revision: i64) -> Response<ResponseBody> {
    Response::builder()
        .status(200)
        .header("content-type", "text/yaml; charset=utf-8")
        .header("cache-control", "no-store")
        .header("etag", etag)
        .header("x-config-revision", revision.to_string())
        .header("x-content-type-options", "nosniff")
        .body(ResponseBody::from(body))
        .expect("yaml response")
}

fn not_modified(etag: &str, revision: i64) -> Response<ResponseBody> {
    Response::builder()
        .status(304)
        .header("etag", etag)
        .header("x-config-revision", revision.to_string())
        .header("cache-control", "no-store")
        .body(ResponseBody::from(Vec::<u8>::new()))
        .expect("not modified")
}

fn fresh(if_none: Option<&str>, rev: Option<&str>, etag: &str, revision: i64) -> bool {
    if rev.is_some_and(|value| value == revision.to_string()) {
        return true;
    }
    let Some(header) = if_none else {
        return false;
    };
    header.split(',').any(|part| {
        let part = part.trim();
        part == "*" || part == etag || part == format!("W/{etag}")
    })
}

fn copy_field(payload: &mut Value, body: &Value, key: &str) {
    if let Some(value) = body.get(key).filter(|value| !value.is_null()) {
        payload[key] = value.clone();
    }
}

fn uuid_value(value: &Value) -> Result<Uuid, ApiError> {
    value
        .as_str()
        .and_then(|text| Uuid::parse_str(text).ok())
        .ok_or_else(unavailable)
}

fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .unwrap_or(0)
}

fn unavailable() -> ApiError {
    ApiError::new(
        503,
        "database_unavailable",
        "Gateway data is temporarily unavailable.",
    )
}

fn signing_bad() -> ApiError {
    ApiError::new(
        503,
        "signing_unavailable",
        "GATEWAY_SIGNING_KEY must be a PKCS#8 PEM for an ES256 key.",
    )
}

fn bearer_token<B>(request: &http::Request<B>) -> Option<String> {
    let header = request
        .headers()
        .get("authorization")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "))
        .map(str::trim)
        .filter(|value| !value.is_empty());
    let cookie = request
        .headers()
        .get("cookie")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| {
            value.split(';').find_map(|part| {
                let (name, cookie) = part.trim().split_once('=')?;
                (name == customer::SUPABASE_COOKIE).then_some(cookie)
            })
        });
    header.or(cookie).map(str::to_owned)
}

async fn read_json<B>(request: http::Request<B>, limit: usize) -> Result<Value, ApiError>
where
    B: http_body::Body<Data = Bytes> + Send,
    B::Error: std::fmt::Display + Send,
{
    let is_json = request
        .headers()
        .get("content-type")
        .and_then(|value| value.to_str().ok())
        .is_some_and(is_json);
    if !is_json {
        return Err(ApiError::new(415, "unsupported_media_type", "Send JSON."));
    }
    let bytes = request
        .into_body()
        .collect()
        .await
        .map_err(|_| ApiError::new(400, "invalid_request", "Send a JSON object."))?
        .to_bytes();
    if bytes.len() > limit {
        return Err(ApiError::new(
            413,
            "invalid_request",
            "Request is too large.",
        ));
    }
    let value: Value = serde_json::from_slice(&bytes)
        .map_err(|_| ApiError::new(400, "invalid_request", "Send a JSON object."))?;
    if !value.is_object() {
        return Err(ApiError::new(400, "invalid_request", "Send a JSON object."));
    }
    Ok(value)
}

fn header<B>(request: &http::Request<B>, name: &str) -> Option<String> {
    request
        .headers()
        .get(name)
        .and_then(|value| value.to_str().ok())
        .map(str::to_owned)
}

fn resource_path(path: &str, query: &str) -> String {
    let suffix = path
        .trim_start_matches("/api/gateway")
        .trim_start_matches('/');
    if !suffix.is_empty() {
        return percent_decode(suffix);
    }
    query_value(query, "__path").unwrap_or_default()
}

fn query_value(query: &str, key: &str) -> Option<String> {
    query.split('&').find_map(|pair| {
        let (name, value) = pair.split_once('=').unwrap_or((pair, ""));
        (name == key).then(|| percent_decode(value))
    })
}

fn percent_decode(value: &str) -> String {
    let bytes = value.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' && index + 2 < bytes.len() {
            let hex = &value[index + 1..index + 3];
            if let Ok(byte) = u8::from_str_radix(hex, 16) {
                out.push(byte);
                index += 3;
                continue;
            }
        }
        out.push(bytes[index]);
        index += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

enum Route {
    Jwks,
    AgentConfig,
    Gateways,
    Gateway(String),
    Servers(String),
    Server(String, String),
    Policies(String),
    Policy(String, String),
    Pins(String),
    PinApprove(String),
    PinAlerts(String),
    PinAlertAck(String, String),
    Approvals(String),
    ApprovalDecision(String, String),
    Config(String),
    Tokens(String),
    Token(String, String),
    Registration(String),
}

fn parse_route(path: &str) -> Option<Route> {
    let path = path.trim_matches('/');
    if path.is_empty() {
        return None;
    }
    let parts: Vec<&str> = path.split('/').filter(|part| !part.is_empty()).collect();
    match parts.as_slice() {
        ["jwks"] => Some(Route::Jwks),
        ["agent", "config"] => Some(Route::AgentConfig),
        ["gateways"] => Some(Route::Gateways),
        ["gateways", id] if valid_uuid(id) => Some(Route::Gateway((*id).to_string())),
        ["gateways", id, "servers"] if valid_uuid(id) => Some(Route::Servers((*id).to_string())),
        ["gateways", id, "servers", server] if valid_uuid(id) && valid_uuid(server) => {
            Some(Route::Server((*id).to_string(), (*server).to_string()))
        }
        ["gateways", id, "policies"] if valid_uuid(id) => Some(Route::Policies((*id).to_string())),
        ["gateways", id, "policies", policy] if valid_uuid(id) && valid_uuid(policy) => {
            Some(Route::Policy((*id).to_string(), (*policy).to_string()))
        }
        ["gateways", id, "pins"] if valid_uuid(id) => Some(Route::Pins((*id).to_string())),
        ["gateways", id, "pins", "approve"] if valid_uuid(id) => {
            Some(Route::PinApprove((*id).to_string()))
        }
        ["gateways", id, "pin-alerts"] if valid_uuid(id) => {
            Some(Route::PinAlerts((*id).to_string()))
        }
        ["gateways", id, "pin-alerts", alert, "ack"] if valid_uuid(id) && valid_uuid(alert) => {
            Some(Route::PinAlertAck((*id).to_string(), (*alert).to_string()))
        }
        ["gateways", id, "approvals"] if valid_uuid(id) => {
            Some(Route::Approvals((*id).to_string()))
        }
        ["gateways", id, "approvals", approval, "decision"]
            if valid_uuid(id) && valid_uuid(approval) =>
        {
            Some(Route::ApprovalDecision(
                (*id).to_string(),
                (*approval).to_string(),
            ))
        }
        ["gateways", id, "config"] if valid_uuid(id) => Some(Route::Config((*id).to_string())),
        ["gateways", id, "tokens"] if valid_uuid(id) => Some(Route::Tokens((*id).to_string())),
        ["gateways", id, "tokens", token] if valid_uuid(id) && valid_uuid(token) => {
            Some(Route::Token((*id).to_string(), (*token).to_string()))
        }
        ["gateways", id, "registration-token"] if valid_uuid(id) => {
            Some(Route::Registration((*id).to_string()))
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use http_body_util::{BodyExt, Full};

    use super::memory;

    fn request(
        method: &str,
        path: &str,
        token: Option<&str>,
        body: Option<Value>,
    ) -> http::Request<Full<Bytes>> {
        let mut builder = http::Request::builder()
            .method(method)
            .uri(path)
            .header("host", "localhost");
        if let Some(token) = token {
            builder = builder.header("authorization", format!("Bearer {token}"));
        }
        let bytes = if let Some(body) = body {
            builder = builder.header("content-type", "application/json");
            serde_json::to_vec(&body).unwrap()
        } else {
            Vec::new()
        };
        builder.body(Full::new(Bytes::from(bytes))).unwrap()
    }

    async fn call(
        backend: &impl Backend,
        method: &str,
        path: &str,
        token: Option<&str>,
        body: Option<Value>,
    ) -> (u16, http::HeaderMap, Value) {
        let response = handle_with(request(method, path, token, body), backend).await;
        let status = response.status().as_u16();
        let headers = response.headers().clone();
        let bytes = response.into_body().collect().await.unwrap().to_bytes();
        let value = if bytes.is_empty() {
            Value::Null
        } else {
            serde_json::from_slice(&bytes)
                .unwrap_or_else(|_| json!({"raw": String::from_utf8_lossy(&bytes)}))
        };
        (status, headers, value)
    }

    fn text_of(value: &Value) -> String {
        value["raw"].as_str().unwrap_or("").to_string()
    }

    fn harness() -> (memory::Memory, Vec<u8>) {
        let dir = std::env::temp_dir().join(format!("fizz-cp-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("signing.pem");
        jwt::load_or_create(&path).unwrap();
        let pem = std::fs::read(&path).unwrap();
        let _ = std::fs::remove_dir_all(&dir);
        let mut secret = [9u8; 32];
        secret[0] = 3;
        (memory::Memory::new(pem.clone(), secret), pem)
    }

    #[test]
    fn routes_cover_the_control_plane() {
        assert!(parse_route("jwks").is_some());
        assert!(parse_route("agent/config").is_some());
        assert!(parse_route("gateways").is_some());
        let id = "11111111-1111-4111-8111-111111111111";
        assert!(parse_route(&format!("gateways/{id}/servers")).is_some());
        assert!(parse_route(&format!("gateways/{id}/policies")).is_some());
        assert!(parse_route(&format!("gateways/{id}/pins/approve")).is_some());
        assert!(parse_route(&format!("gateways/{id}/pin-alerts")).is_some());
        assert!(parse_route(&format!("gateways/{id}/approvals")).is_some());
        assert!(parse_route(&format!("gateways/{id}/config")).is_some());
        assert!(parse_route(&format!("gateways/{id}/tokens")).is_some());
        assert!(parse_route(&format!("gateways/{id}/registration-token")).is_some());
        assert!(parse_route("gateways/not-a-uuid").is_none());
        assert_eq!(
            resource_path("/api/gateway", "__path=gateways%2Fabc"),
            "gateways/abc"
        );
    }

    #[tokio::test]
    async fn creates_a_gateway_mints_a_token_and_isolates_workspaces() {
        let (backend, pem) = harness();
        backend.add_member("user-a", "user-c", "member");
        let (status, _, created) = call(
            &backend,
            "POST",
            "/api/gateway/gateways",
            Some("user-a"),
            Some(json!({"name": "home"})),
        )
        .await;
        assert_eq!(status, 200, "{created}");
        assert_eq!(created["gateway"]["mode"], "shared");
        let gateway = created["gateway"]["id"].as_str().unwrap().to_string();
        let registration = created["registration_token"].as_str().unwrap().to_string();
        assert!(registration.starts_with("fizz_reg_"));
        let secret = "upstream-token-sample";
        let (status, _, server) = call(
            &backend,
            "POST",
            &format!("/api/gateway/gateways/{gateway}/servers"),
            Some("user-a"),
            Some(json!({"name": "github", "url": "https://example.com/mcp", "api_key": secret})),
        )
        .await;
        assert_eq!(status, 200, "{server}");
        assert_eq!(server["server"]["has_secret"], true);
        assert_eq!(server["server"]["auth_kind"], "key");
        assert!(!server.to_string().contains(secret));
        assert!(!server.to_string().contains("ciphertext"));
        let server_id = server["server"]["id"].as_str().unwrap();
        let (status, _, policy) = call(
            &backend,
            "PUT",
            &format!("/api/gateway/gateways/{gateway}/policies"),
            Some("user-a"),
            Some(json!({
                "server_id": server_id,
                "tool_name": "create_issue",
                "effect": "approve",
                "notify_channel": "phone"
            })),
        )
        .await;
        assert_eq!(status, 200, "{policy}");
        assert_eq!(policy["policy"]["effect"], "approve");
        assert_eq!(policy["policy"]["notify_channel"], "phone");
        backend.seed_pin(&gateway, "github", "create_issue");
        let (status, _, pins) = call(
            &backend,
            "GET",
            &format!("/api/gateway/gateways/{gateway}/pins"),
            Some("user-a"),
            None,
        )
        .await;
        assert_eq!(status, 200, "{pins}");
        assert_eq!(pins["pins"][0]["status"], "unreviewed");
        let (status, _, approved_pin) = call(
            &backend,
            "POST",
            &format!("/api/gateway/gateways/{gateway}/pins/approve"),
            Some("user-a"),
            Some(json!({"server": "github", "tool": "create_issue"})),
        )
        .await;
        assert_eq!(status, 200, "{approved_pin}");
        let (status, _, hidden) = call(
            &backend,
            "POST",
            &format!("/api/gateway/gateways/{gateway}/pins/approve"),
            Some("user-b"),
            Some(json!({"server": "github", "tool": "create_issue"})),
        )
        .await;
        assert_eq!(status, 404, "{hidden}");
        let approval = backend.seed_approval(&gateway, "create_issue");
        let (status, _, decision) = call(
            &backend,
            "POST",
            &format!("/api/gateway/gateways/{gateway}/approvals/{approval}/decision"),
            Some("user-a"),
            Some(json!({"status": "approved"})),
        )
        .await;
        assert_eq!(status, 200, "{decision}");
        assert_eq!(decision["status"], "approved");
        let (status, _, shown) = call(
            &backend,
            "PATCH",
            &format!("/api/gateway/gateways/{gateway}"),
            Some("user-a"),
            Some(json!({"unreviewed_tools": "show"})),
        )
        .await;
        assert_eq!(status, 200, "{shown}");
        assert_eq!(shown["gateway"]["unreviewed_tools"], "show");
        let (status, _, minted) = call(
            &backend,
            "POST",
            &format!("/api/gateway/gateways/{gateway}/tokens"),
            Some("user-a"),
            Some(json!({"name": "Cursor on laptop", "ttl_seconds": 3600})),
        )
        .await;
        assert_eq!(status, 200, "{minted}");
        let client = minted["token"]["token"].as_str().unwrap();
        let audience = minted["token"]["audience"].as_str().unwrap();
        let claims = jwt::read_claims(client, &pem, audience).unwrap();
        assert_eq!(claims.aud, audience);
        assert_eq!(claims.ws, minted["token"]["workspace_id"].as_str().unwrap());
        assert_eq!(claims.jti, minted["token"]["jti"].as_str().unwrap());
        let (status, headers, pulled) = call(
            &backend,
            "GET",
            "/api/gateway/agent/config",
            Some(&registration),
            None,
        )
        .await;
        assert_eq!(status, 200, "{pulled}");
        let yaml = text_of(&pulled);
        assert!(
            yaml.contains(secret),
            "agent pull includes the upstream credential"
        );
        assert!(yaml.contains("backendAuth"));
        assert!(yaml.contains("https://fizzlayer.com/api/gateway/jwks"));
        let etag = headers.get("etag").unwrap().to_str().unwrap().to_string();
        let mut again = request(
            "GET",
            "/api/gateway/agent/config",
            Some(&registration),
            None,
        );
        again
            .headers_mut()
            .insert("if-none-match", etag.parse().unwrap());
        let again = handle_with(again, &backend).await;
        assert_eq!(again.status().as_u16(), 304);
        let (status, _, preview) = call(
            &backend,
            "GET",
            &format!("/api/gateway/gateways/{gateway}/config"),
            Some("user-a"),
            None,
        )
        .await;
        assert_eq!(status, 200, "{preview}");
        assert!(!text_of(&preview).contains(secret));
        let (status, _, listed) = call(
            &backend,
            "GET",
            "/api/gateway/gateways",
            Some("user-b"),
            None,
        )
        .await;
        assert_eq!(status, 200, "{listed}");
        assert!(listed["gateways"].as_array().unwrap().is_empty());
        for (method, path, body) in [
            ("DELETE", format!("/api/gateway/gateways/{gateway}"), None),
            (
                "POST",
                format!("/api/gateway/gateways/{gateway}/servers"),
                Some(json!({"name": "other", "url": "https://example.com/mcp"})),
            ),
            (
                "PUT",
                format!("/api/gateway/gateways/{gateway}/policies"),
                Some(json!({"tool_name": "*", "effect": "deny"})),
            ),
            (
                "POST",
                format!("/api/gateway/gateways/{gateway}/tokens"),
                Some(json!({"name": "nope"})),
            ),
        ] {
            let (status, _, body) = call(&backend, method, &path, Some("user-b"), body).await;
            assert_eq!(status, 404, "{method} {path} {body}");
        }
        let (status, _, seen) = call(
            &backend,
            "GET",
            "/api/gateway/gateways",
            Some("user-c"),
            None,
        )
        .await;
        assert_eq!(status, 200, "{seen}");
        assert!(
            seen["gateways"]
                .as_array()
                .unwrap()
                .iter()
                .any(|gateway_row| gateway_row["id"] == gateway)
        );
        let (status, _, denied) = call(
            &backend,
            "DELETE",
            &format!("/api/gateway/gateways/{gateway}"),
            Some("user-c"),
            None,
        )
        .await;
        assert_eq!(status, 403, "{denied}");
        let (status, _, rejected) = call(
            &backend,
            "GET",
            "/api/gateway/agent/config",
            Some(&format!("fizz_reg_{}", "ab".repeat(32))),
            None,
        )
        .await;
        assert_eq!(status, 401, "{rejected}");
        let (status, _, jwks) = call(&backend, "GET", "/api/gateway/jwks", None, None).await;
        assert_eq!(status, 200, "{jwks}");
        assert!(jwks["keys"].as_array().is_some());
    }

    #[tokio::test]
    async fn enforces_tier_limits_and_marks_pro_dedicated() {
        let (backend, _) = harness();
        let (status, _, first) = call(
            &backend,
            "POST",
            "/api/gateway/gateways",
            Some("user-a"),
            Some(json!({"name": "home"})),
        )
        .await;
        assert_eq!(status, 200, "{first}");
        let gateway = first["gateway"]["id"].as_str().unwrap();
        let (status, _, second) = call(
            &backend,
            "POST",
            "/api/gateway/gateways",
            Some("user-a"),
            Some(json!({"name": "extra"})),
        )
        .await;
        assert_eq!(status, 402, "{second}");
        assert_eq!(second["error"]["code"], "gateway_limit");
        let (status, _, dedicated) = call(
            &backend,
            "POST",
            "/api/gateway/gateways",
            Some("user-b"),
            Some(json!({"name": "box", "mode": "dedicated"})),
        )
        .await;
        assert_eq!(status, 402, "{dedicated}");
        assert_eq!(dedicated["error"]["code"], "dedicated_not_included");
        for name in ["one", "two", "three"] {
            let (status, _, added) = call(
                &backend,
                "POST",
                &format!("/api/gateway/gateways/{gateway}/servers"),
                Some("user-a"),
                Some(json!({"name": name, "url": "https://example.com/mcp"})),
            )
            .await;
            assert_eq!(status, 200, "{added}");
        }
        let (status, _, fourth) = call(
            &backend,
            "POST",
            &format!("/api/gateway/gateways/{gateway}/servers"),
            Some("user-a"),
            Some(json!({"name": "four", "url": "https://example.com/mcp"})),
        )
        .await;
        assert_eq!(status, 402, "{fourth}");
        assert_eq!(fourth["error"]["code"], "server_limit");
        let (status, _, stdio) = call(
            &backend,
            "POST",
            &format!("/api/gateway/gateways/{gateway}/servers"),
            Some("user-a"),
            Some(json!({"name": "local", "transport": "stdio", "command": "uvx"})),
        )
        .await;
        assert_eq!(status, 402, "{stdio}");
        assert_eq!(stdio["error"]["code"], "stdio_not_included");
        let (status, _, pro) = call(
            &backend,
            "POST",
            "/api/gateway/gateways",
            Some("user-pro"),
            Some(json!({"name": "studio"})),
        )
        .await;
        assert_eq!(status, 200, "{pro}");
        assert_eq!(pro["gateway"]["mode"], "dedicated");
        assert!(
            pro["gateway"]["public_url"]
                .as_str()
                .unwrap()
                .contains("studio.gw.fizzlayer.com")
        );
        let pro_id = pro["gateway"]["id"].as_str().unwrap();
        let (status, _, local) = call(
            &backend,
            "POST",
            &format!("/api/gateway/gateways/{pro_id}/servers"),
            Some("user-pro"),
            Some(json!({"name": "local", "transport": "stdio", "command": "uvx", "args": ["mcp-server-time"]})),
        )
        .await;
        assert_eq!(status, 200, "{local}");
        assert_eq!(local["server"]["transport"], "stdio");
    }
}
