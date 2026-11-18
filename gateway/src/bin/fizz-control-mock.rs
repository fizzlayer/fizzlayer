//! Local stand-in for `GET /api/gateway/agent/config` and the status report.
//! The registration token is compared in constant time and is not logged.
//! `POST /test/add-server` and `POST /test/bad-config` are for the compose probe.

use std::env;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use axum::body::Bytes;
use axum::extract::{Query, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use fizz_gateway::agent::{fleet_token_ok, registration_token_ok};
use fizz_gateway::config::{
    CredentialMode, GatewaySpec, Mode, ServerSpec, Transport, render_fleet_yaml, render_yaml,
};
use fizz_gateway::error::{GatewayError, GatewayResult};
use fizz_gateway::jwt;
use serde::Deserialize;
use serde_json::{Value, json};
use tokio::net::TcpListener;
use tokio::sync::Mutex;
use uuid::Uuid;

struct App {
    token: String,
    fleet: bool,
    upstream_key: String,
    jwks: Vec<u8>,
    public_url: String,
    state: Mutex<Live>,
}

struct Live {
    revision: i64,
    extra: bool,
    bad: bool,
    report: Option<Value>,
}

#[tokio::main]
async fn main() {
    let code = match run().await {
        Ok(()) => 0,
        Err(err) => {
            eprintln!("fizz-control-mock: {err}");
            1
        }
    };
    std::process::exit(code);
}

async fn run() -> GatewayResult<()> {
    let mut args = env::args().skip(1);
    let listen = env::var("FIZZ_LISTEN").unwrap_or_else(|_| "0.0.0.0:8090".to_string());
    let port = listen
        .rsplit(':')
        .next()
        .unwrap_or("8090")
        .parse::<u16>()
        .map_err(|_| GatewayError::message("listen address is not usable"))?;
    match args.next().as_deref() {
        Some("ready") => {
            let addr = format!("127.0.0.1:{port}");
            match std::net::TcpStream::connect_timeout(
                &addr
                    .parse()
                    .unwrap_or_else(|_| SocketAddr::from(([127, 0, 0, 1], 1))),
                Duration::from_secs(2),
            ) {
                Ok(_) => return Ok(()),
                Err(_) => {
                    eprintln!("fizz-control-mock: not ready");
                    std::process::exit(1);
                }
            }
        }
        Some("serve") | None => {}
        Some(_) => return Err(GatewayError::message("unknown command")),
    }
    let fleet = env::var("FIZZ_FLEET").ok().as_deref() == Some("1");
    let token = if fleet {
        env::var("FIZZ_FLEET_TOKEN")
            .map_err(|_| GatewayError::message("missing FIZZ_FLEET_TOKEN"))?
    } else {
        env::var("FIZZ_REGISTRATION_TOKEN")
            .map_err(|_| GatewayError::message("missing FIZZ_REGISTRATION_TOKEN"))?
    };
    if fleet {
        if !fleet_token_ok(token.trim()) {
            return Err(GatewayError::message("fleet token was rejected"));
        }
    } else if !registration_token_ok(token.trim()) {
        return Err(GatewayError::message("registration token was rejected"));
    }
    let upstream_key =
        env::var("FIZZ_UPSTREAM_KEY").unwrap_or_else(|_| "upstream-token-sample".to_string());
    let key_path = PathBuf::from(
        env::var("FIZZ_SIGNING_KEY").unwrap_or_else(|_| "/keys/signing.pem".to_string()),
    );
    let material = jwt::load_or_create(&key_path)?;
    let jwks = material.jwks_json()?;
    let public_url =
        env::var("FIZZ_PUBLIC_URL").unwrap_or_else(|_| "http://control-plane:8090".to_string());
    let app = Arc::new(App {
        token: token.trim().to_string(),
        fleet,
        upstream_key,
        jwks,
        public_url,
        state: Mutex::new(Live {
            revision: 1,
            extra: false,
            bad: false,
            report: None,
        }),
    });
    let router = Router::new()
        .route("/health", get(|| async { "ok" }))
        .route("/api/gateway/jwks", get(jwks_doc))
        .route("/api/gateway/agent/config", get(config))
        .route("/api/gateway/agent/status", post(status))
        .route("/api/gateway/agent/fleet", get(fleet_config))
        .route("/api/gateway/agent/fleet/status", post(status))
        .route("/test/secret-check", get(secret_check))
        .route("/test/add-server", post(add_server))
        .route("/test/bad-config", post(bad_config))
        .route("/test/report", get(report))
        .with_state(app);
    let addr: SocketAddr = listen
        .parse()
        .map_err(|_| GatewayError::message("listen address is not usable"))?;
    let listener = TcpListener::bind(addr)
        .await
        .map_err(|_| GatewayError::message("control plane could not listen"))?;
    eprintln!("fizz-control-mock: listening");
    axum::serve(listener, router)
        .await
        .map_err(|_| GatewayError::message("control plane stopped"))?;
    Ok(())
}

async fn jwks_doc(State(app): State<Arc<App>>) -> Response {
    Response::builder()
        .status(200)
        .header("content-type", "application/json")
        .body(axum::body::Body::from(app.jwks.clone()))
        .expect("jwks response")
}

#[derive(Deserialize, Default)]
struct RevQuery {
    rev: Option<String>,
}

async fn config(
    State(app): State<Arc<App>>,
    Query(query): Query<RevQuery>,
    headers: HeaderMap,
) -> Response {
    if !authorized(&headers, &app.token) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    let live = app.state.lock().await;
    let revision = live.revision;
    let etag = format!("\"{revision}\"");
    if fresh(&headers, query.rev.as_deref(), revision, &etag) {
        return not_modified(revision, &etag);
    }
    let body = if live.bad {
        "not-a-gateway: [\n".to_string()
    } else {
        match render(&app.public_url, revision, live.extra) {
            Ok(yaml) => yaml,
            Err(_) => return StatusCode::INTERNAL_SERVER_ERROR.into_response(),
        }
    };
    drop(live);
    Response::builder()
        .status(200)
        .header("content-type", "text/yaml; charset=utf-8")
        .header("etag", etag)
        .header("x-config-revision", revision.to_string())
        .header("cache-control", "no-store")
        .body(axum::body::Body::from(body))
        .expect("config response")
}

fn not_modified(revision: i64, etag: &str) -> Response {
    Response::builder()
        .status(304)
        .header("etag", etag)
        .header("x-config-revision", revision.to_string())
        .header("cache-control", "no-store")
        .body(axum::body::Body::empty())
        .expect("not modified")
}

async fn status(State(app): State<Arc<App>>, headers: HeaderMap, body: Bytes) -> StatusCode {
    if !authorized(&headers, &app.token) {
        return StatusCode::UNAUTHORIZED;
    }
    let Ok(text) = std::str::from_utf8(&body) else {
        return StatusCode::BAD_REQUEST;
    };
    if text.len() > 1024
        || text.to_ascii_lowercase().contains("fizz_reg_")
        || text.to_ascii_lowercase().contains("fizz_fleet_")
        || text.contains("eyJ")
    {
        return StatusCode::BAD_REQUEST;
    }
    let Ok(value) = serde_json::from_str::<Value>(text) else {
        return StatusCode::BAD_REQUEST;
    };
    let status = value["status"].as_str().unwrap_or("");
    let revision = value["revision"].as_i64().unwrap_or(-1);
    if !matches!(status, "applied" | "rejected") || revision < 0 {
        return StatusCode::BAD_REQUEST;
    }
    if let Some(detail) = value.get("detail").and_then(Value::as_str) {
        if detail.is_empty() || detail.chars().count() > 300 || detail.chars().any(char::is_control)
        {
            return StatusCode::BAD_REQUEST;
        }
    }
    app.state.lock().await.report = Some(value);
    StatusCode::OK
}

async fn add_server(State(app): State<Arc<App>>, headers: HeaderMap) -> StatusCode {
    if !authorized(&headers, &app.token) {
        return StatusCode::UNAUTHORIZED;
    }
    let mut live = app.state.lock().await;
    live.extra = true;
    live.bad = false;
    live.revision = live.revision.saturating_add(1);
    StatusCode::NO_CONTENT
}

async fn bad_config(State(app): State<Arc<App>>, headers: HeaderMap) -> StatusCode {
    if !authorized(&headers, &app.token) {
        return StatusCode::UNAUTHORIZED;
    }
    let mut live = app.state.lock().await;
    live.bad = true;
    live.revision = live.revision.saturating_add(1);
    StatusCode::NO_CONTENT
}

async fn report(State(app): State<Arc<App>>, headers: HeaderMap) -> Response {
    if !authorized(&headers, &app.token) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    let live = app.state.lock().await;
    Json(live.report.clone().unwrap_or_else(|| json!({}))).into_response()
}

async fn fleet_config(
    State(app): State<Arc<App>>,
    Query(query): Query<RevQuery>,
    headers: HeaderMap,
) -> Response {
    if !app.fleet || !authorized(&headers, &app.token) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    let live = app.state.lock().await;
    let revision = live.revision;
    let etag = format!("\"{revision}\"");
    if fresh(&headers, query.rev.as_deref(), revision, &etag) {
        return not_modified(revision, &etag);
    }
    let body = if live.bad {
        "not-a-gateway: [\n".to_string()
    } else {
        match render_fleet_doc(&app.public_url, &app.upstream_key, revision, live.extra) {
            Ok(yaml) => yaml,
            Err(_) => return StatusCode::INTERNAL_SERVER_ERROR.into_response(),
        }
    };
    drop(live);
    Response::builder()
        .status(200)
        .header("content-type", "text/yaml; charset=utf-8")
        .header("etag", etag)
        .header("x-config-revision", revision.to_string())
        .header("cache-control", "no-store")
        .body(axum::body::Body::from(body))
        .expect("fleet response")
}

async fn secret_check(State(app): State<Arc<App>>, headers: HeaderMap) -> Response {
    if !app.fleet || !authorized(&headers, &app.token) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    let embedded = render_fleet_doc(&app.public_url, &app.upstream_key, 1, false)
        .map(|yaml| yaml.contains(&app.upstream_key))
        .unwrap_or(false);
    let redacted = render_fleet_redacted(&app.public_url, &app.upstream_key)
        .map(|yaml| !yaml.contains(&app.upstream_key))
        .unwrap_or(false);
    Json(json!({"embedded": embedded, "redacted": redacted})).into_response()
}

fn render(public_url: &str, revision: i64, extra: bool) -> GatewayResult<String> {
    let mut servers = vec![server("sample", "http://sample-mcp:8080/mcp")];
    if extra {
        servers.push(server("extra", "http://sample-extra:8081/mcp"));
    }
    let spec = GatewaySpec {
        gateway_id: Uuid::parse_str("22222222-2222-4222-8222-222222222222")
            .map_err(|_| GatewayError::message("gateway id is not usable"))?,
        workspace_id: Uuid::parse_str("11111111-1111-4111-8111-111111111111")
            .map_err(|_| GatewayError::message("gateway id is not usable"))?,
        mode: Mode::Shared,
        public_url: "http://agentgateway:3000/mcp".to_string(),
        listen_port: 3000,
        config_revision: revision,
        ag_version: Some("1.7.0".to_string()),
        guard_host: "fizz-guard:9001".to_string(),
        jwks_file: String::new(),
        jwks_url: Some(format!(
            "{}/api/gateway/jwks",
            public_url.trim_end_matches('/')
        )),
        credential_mode: CredentialMode::Refuse,
        servers,
        requests_per_minute: 0,
    };
    render_yaml(&spec)
}

fn render_fleet_doc(
    public_url: &str,
    upstream_key: &str,
    revision: i64,
    extra: bool,
) -> GatewayResult<String> {
    let mut servers = vec![keyed_server(
        "sample",
        "http://sample-mcp:8080/mcp",
        upstream_key,
    )];
    if extra {
        servers.push(server("extra", "http://sample-extra:8081/mcp"));
    }
    let primary = fleet_gateway(FleetRow {
        id: "22222222-2222-4222-8222-222222222222",
        workspace: "11111111-1111-4111-8111-111111111111",
        audience: "http://agentgateway:3000/w/22222222-2222-4222-8222-222222222222/mcp",
        jwks_origin: public_url,
        revision,
        rpm: 60,
        credentials: CredentialMode::Embed,
        servers,
    })?;
    let other = fleet_gateway(FleetRow {
        id: "33333333-3333-4333-8333-333333333333",
        workspace: "66666666-6666-4666-8666-666666666666",
        audience: "http://agentgateway:3000/w/33333333-3333-4333-8333-333333333333/mcp",
        jwks_origin: public_url,
        revision,
        rpm: 60,
        credentials: CredentialMode::Refuse,
        servers: vec![server("other", "http://sample-b:8082/mcp")],
    })?;
    let limited = fleet_gateway(FleetRow {
        id: "77777777-7777-4777-8777-777777777777",
        workspace: "11111111-1111-4111-8111-111111111111",
        audience: "http://agentgateway:3000/w/77777777-7777-4777-8777-777777777777/mcp",
        jwks_origin: public_url,
        revision,
        rpm: 2,
        credentials: CredentialMode::Refuse,
        servers: vec![server("sample", "http://sample-mcp:8080/mcp")],
    })?;
    render_fleet_yaml(&[primary, other, limited], 3000)
}

fn render_fleet_redacted(public_url: &str, upstream_key: &str) -> GatewayResult<String> {
    let primary = fleet_gateway(FleetRow {
        id: "22222222-2222-4222-8222-222222222222",
        workspace: "11111111-1111-4111-8111-111111111111",
        audience: "http://agentgateway:3000/w/22222222-2222-4222-8222-222222222222/mcp",
        jwks_origin: public_url,
        revision: 1,
        rpm: 60,
        credentials: CredentialMode::Omit,
        servers: vec![keyed_server(
            "sample",
            "http://sample-mcp:8080/mcp",
            upstream_key,
        )],
    })?;
    render_fleet_yaml(&[primary], 3000)
}

struct FleetRow<'a> {
    id: &'a str,
    workspace: &'a str,
    audience: &'a str,
    jwks_origin: &'a str,
    revision: i64,
    rpm: u32,
    credentials: CredentialMode,
    servers: Vec<ServerSpec>,
}

fn fleet_gateway(row: FleetRow<'_>) -> GatewayResult<GatewaySpec> {
    Ok(GatewaySpec {
        gateway_id: Uuid::parse_str(row.id)
            .map_err(|_| GatewayError::message("gateway id is not usable"))?,
        workspace_id: Uuid::parse_str(row.workspace)
            .map_err(|_| GatewayError::message("gateway id is not usable"))?,
        mode: Mode::Shared,
        public_url: row.audience.to_string(),
        listen_port: 3000,
        config_revision: row.revision,
        ag_version: Some("1.7.0".to_string()),
        guard_host: "fizz-guard:9001".to_string(),
        jwks_file: String::new(),
        jwks_url: Some(format!(
            "{}/api/gateway/jwks",
            row.jwks_origin.trim_end_matches('/')
        )),
        credential_mode: row.credentials,
        servers: row.servers,
        requests_per_minute: row.rpm,
    })
}

fn keyed_server(name: &str, url: &str, key: &str) -> ServerSpec {
    ServerSpec {
        auth_kind: "key".to_string(),
        credential: Some(key.to_string()),
        ..server(name, url)
    }
}

fn server(name: &str, url: &str) -> ServerSpec {
    ServerSpec {
        name: name.to_string(),
        transport: Transport::Http,
        url_or_cmd: url.to_string(),
        command_args: Vec::new(),
        auth_kind: "none".to_string(),
        credential: None,
    }
}

fn authorized(headers: &HeaderMap, token: &str) -> bool {
    let Some(presented) = headers
        .get("authorization")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "))
        .map(str::trim)
    else {
        return false;
    };
    token_eq(presented, token)
}

fn token_eq(left: &str, right: &str) -> bool {
    let left = left.as_bytes();
    let right = right.as_bytes();
    let mut diff = left.len() ^ right.len();
    for index in 0..left.len().max(right.len()) {
        let a = left.get(index).copied().unwrap_or(0);
        let b = right.get(index).copied().unwrap_or(0);
        diff |= usize::from(a ^ b);
    }
    diff == 0
}

fn fresh(headers: &HeaderMap, rev: Option<&str>, revision: i64, etag: &str) -> bool {
    if rev.is_some_and(|value| value == revision.to_string()) {
        return true;
    }
    headers
        .get("if-none-match")
        .and_then(|value| value.to_str().ok())
        .is_some_and(|value| {
            value.split(',').any(|part| {
                let part = part.trim();
                part == "*" || part == etag || part == format!("W/{etag}")
            })
        })
}
