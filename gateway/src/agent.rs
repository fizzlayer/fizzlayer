//! Pull agentgateway YAML from the control plane and swap it atomically.
//!
//! The registration token and the YAML body are never written to logs. A pull
//! that fails, or a body that does not validate, leaves the last good file in
//! place so the proxy keeps serving it.

use std::fs;
use std::path::Path;
use std::time::Duration;

use reqwest::header::{AUTHORIZATION, HeaderValue, IF_NONE_MATCH};
use serde_json::Value;

use crate::config::{self, write_public};
use crate::error::{GatewayError, GatewayResult};

const MAX_BYTES: usize = 1_048_576;
const TOKEN_PREFIX: &str = "fizz_reg_";
const FLEET_PREFIX: &str = "fizz_fleet_";

pub fn registration_token_ok(token: &str) -> bool {
    token_body_ok(token, TOKEN_PREFIX)
}

pub fn fleet_token_ok(token: &str) -> bool {
    token_body_ok(token, FLEET_PREFIX)
}

fn token_body_ok(token: &str, prefix: &str) -> bool {
    let Some(rest) = token.strip_prefix(prefix) else {
        return false;
    };
    rest.len() == 64 && rest.bytes().all(|byte| byte.is_ascii_hexdigit())
}

/// Origin of the control plane, with no path and no userinfo.
pub fn control_origin(raw: &str) -> GatewayResult<String> {
    let trimmed = raw.trim().trim_end_matches('/');
    let url = reqwest::Url::parse(trimmed)
        .map_err(|_| GatewayError::message("FIZZ_API_URL is not usable"))?;
    if !url.username().is_empty()
        || url.password().is_some()
        || !matches!(url.scheme(), "http" | "https")
        || url.host_str().is_none()
        || !url.path().is_empty() && url.path() != "/"
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return Err(GatewayError::message("FIZZ_API_URL is not usable"));
    }
    Ok(format!("{}://{}", url.scheme(), url.authority()))
}

pub fn http_client() -> GatewayResult<reqwest::Client> {
    reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(Duration::from_secs(10))
        .build()
        .map_err(|_| GatewayError::message("http client failed"))
}

pub fn next_delay(current: Duration, base: Duration, failed: bool) -> Duration {
    if !failed {
        return base;
    }
    let doubled = current.checked_mul(2).unwrap_or(current);
    doubled.max(base).min(Duration::from_secs(60))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReloadCheck {
    Applied,
    Rejected,
    Unknown,
}

pub fn reload_check(body: &str) -> ReloadCheck {
    let Ok(value) = serde_json::from_str::<Value>(body) else {
        return ReloadCheck::Unknown;
    };
    match value
        .pointer("/configReload/synchronized")
        .and_then(Value::as_bool)
    {
        Some(true) => ReloadCheck::Applied,
        Some(false) => ReloadCheck::Rejected,
        None => ReloadCheck::Unknown,
    }
}

/// Structural check before the file is replaced. The error is a static phrase
/// and does not quote the document, which may contain upstream credentials.
pub fn validate_gateway_yaml(text: &str) -> Result<(), &'static str> {
    if text.is_empty() || text.len() > MAX_BYTES || text.contains('\0') {
        return Err("config was rejected");
    }
    if text.contains("BEGIN PRIVATE KEY") || text.contains("BEGIN OPENSSH") {
        return Err("config was rejected");
    }
    let value: Value =
        serde_saphyr::from_str(text).map_err(|_| "config YAML could not be parsed")?;
    let Some(mcp) = value.get("mcp").filter(|item| item.is_object()) else {
        return Err("config is missing the mcp section");
    };
    let Some(port) = mcp.get("port").and_then(Value::as_u64) else {
        return Err("config is missing the mcp section");
    };
    if !(1..=65535).contains(&port) {
        return Err("config is missing the mcp section");
    }
    let Some(targets) = mcp.get("targets").and_then(Value::as_array) else {
        return Err("config is missing the mcp section");
    };
    let mut names = Vec::with_capacity(targets.len());
    for target in targets {
        let Some(name) = target.get("name").and_then(Value::as_str) else {
            return Err("config has an unusable target");
        };
        if name.is_empty() || name.len() > 80 || names.contains(&name) {
            return Err("config has an unusable target");
        }
        let kinds = ["mcp", "sse", "stdio"]
            .into_iter()
            .filter(|key| target.get(key).is_some())
            .count();
        if kinds != 1 {
            return Err("config has an unusable target");
        }
        names.push(name);
    }
    Ok(())
}

/// Fleet documents use `binds` and one exact path per gateway. A stdio target
/// or a repeated path is rejected. The error does not quote the document.
pub fn validate_fleet_yaml(text: &str) -> Result<(), &'static str> {
    if text.is_empty() || text.len() > MAX_BYTES || text.contains('\0') {
        return Err("config was rejected");
    }
    if text.contains("BEGIN PRIVATE KEY") || text.contains("BEGIN OPENSSH") {
        return Err("config was rejected");
    }
    let value: Value =
        serde_saphyr::from_str(text).map_err(|_| "config YAML could not be parsed")?;
    let Some(binds) = value.get("binds").and_then(Value::as_array) else {
        return Err("config is missing the fleet bind");
    };
    if binds.len() != 1 {
        return Err("config is missing the fleet bind");
    }
    let Some(port) = binds[0].get("port").and_then(Value::as_u64) else {
        return Err("config is missing the fleet bind");
    };
    if !(1..=65535).contains(&port) {
        return Err("config is missing the fleet bind");
    }
    let Some(routes) = binds[0]
        .pointer("/listeners/0/routes")
        .and_then(Value::as_array)
    else {
        return Err("config is missing the fleet bind");
    };
    let mut paths = Vec::new();
    for route in routes {
        let Some(path) = route
            .pointer("/matches/0/path/exact")
            .and_then(Value::as_str)
        else {
            return Err("config has an unusable route");
        };
        if path.is_empty() || paths.contains(&path) {
            return Err("config has an unusable route");
        }
        paths.push(path);
        if path == "/health" {
            continue;
        }
        let empty = Vec::new();
        let targets = route
            .pointer("/backends/0/mcp/targets")
            .and_then(Value::as_array)
            .unwrap_or(&empty);
        let audience = route
            .pointer("/policies/jwtAuth/audiences/0")
            .and_then(Value::as_str)
            .unwrap_or("");
        if audience.is_empty() || !audience.ends_with(path) {
            return Err("config has an unusable route");
        }
        for target in targets {
            if target.get("stdio").is_some() {
                return Err("config has an unusable target");
            }
            let kinds = ["mcp", "sse"]
                .into_iter()
                .filter(|key| target.get(key).is_some())
                .count();
            if kinds != 1 {
                return Err("config has an unusable target");
            }
        }
    }
    Ok(())
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub struct StatusReport {
    pub revision: i64,
    pub status: &'static str,
    pub detail: Option<&'static str>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SyncKind {
    NotModified,
    Applied {
        revision: i64,
    },
    Rejected {
        revision: i64,
        detail: &'static str,
    },
    /// The control plane could not be used. The file on disk is unchanged.
    Hold {
        detail: &'static str,
    },
}

pub struct SyncOutcome {
    pub kind: SyncKind,
    pub etag: Option<String>,
    pub revision: Option<i64>,
    pub report: Option<StatusReport>,
}

pub struct SyncRequest<'a> {
    pub client: &'a reqwest::Client,
    pub origin: &'a str,
    pub token: &'a str,
    pub config_path: &'a Path,
    pub admin_url: Option<&'a str>,
    pub etag: Option<&'a str>,
    pub revision: Option<i64>,
    /// Shared fleet pull. The per-gateway registration pull stays the default.
    pub fleet: bool,
    /// When set, the bind port is rewritten to this value before the file is replaced.
    pub listen_port: Option<u16>,
}

pub async fn sync_once(request: SyncRequest<'_>) -> SyncOutcome {
    let path = if request.fleet {
        "/api/gateway/agent/fleet"
    } else {
        "/api/gateway/agent/config"
    };
    let mut url = format!("{}{path}", request.origin);
    if let Some(revision) = request.revision {
        url.push_str(&format!("?rev={revision}"));
    }
    let mut call = request.client.get(&url).header(
        AUTHORIZATION,
        match HeaderValue::from_str(&format!("Bearer {}", request.token)) {
            Ok(value) => value,
            Err(_) => {
                return hold(
                    "registration token was rejected",
                    request.etag,
                    request.revision,
                );
            }
        },
    );
    if let Some(etag) = request.etag {
        call = call.header(IF_NONE_MATCH, etag);
    }
    let response = match call.send().await {
        Ok(response) => response,
        Err(_) => {
            return hold(
                "control plane was unreachable",
                request.etag,
                request.revision,
            );
        }
    };
    let status = response.status().as_u16();
    let etag =
        header_string(response.headers(), "etag").or_else(|| request.etag.map(str::to_string));
    let revision = header_string(response.headers(), "x-config-revision")
        .and_then(|value| value.parse().ok())
        .or_else(|| etag.as_deref().and_then(revision_of_etag))
        .or(request.revision);
    if status == 304 {
        return SyncOutcome {
            kind: SyncKind::NotModified,
            etag,
            revision,
            report: None,
        };
    }
    if status != 200 {
        return hold(hold_detail(status), etag.as_deref(), revision);
    }
    let body = match read_limited(response).await {
        Ok(body) => body,
        Err(detail) => {
            return rejected(revision.unwrap_or(0), detail, etag, revision);
        }
    };
    let body = if let Some(port) = request.listen_port {
        match crate::config::set_bind_port(&body, port) {
            Ok(rewritten) => rewritten,
            Err(detail) => return rejected(revision.unwrap_or(0), detail, etag, revision),
        }
    } else {
        body
    };
    if let Err(detail) = if request.fleet {
        validate_fleet_yaml(&body)
    } else {
        validate_gateway_yaml(&body)
    } {
        return rejected(revision.unwrap_or(0), detail, etag, revision);
    }
    let previous = fs::read_to_string(request.config_path).ok();
    if previous.as_deref() == Some(body.as_str()) {
        return applied(revision.unwrap_or(0), etag, revision);
    }
    if config::write_if_changed(request.config_path, &body).is_err() {
        return hold(
            "config file could not be written",
            etag.as_deref(),
            revision,
        );
    }
    if let Some(admin) = request.admin_url {
        if let Err(detail) = confirm_reload(
            request.client,
            admin,
            request.config_path,
            previous.as_deref(),
        )
        .await
        {
            return rejected(revision.unwrap_or(0), detail, etag, revision);
        }
    }
    applied(revision.unwrap_or(0), etag, revision)
}

pub async fn report_status(
    client: &reqwest::Client,
    origin: &str,
    token: &str,
    report: StatusReport,
    fleet: bool,
) -> Result<(), &'static str> {
    let mut body = serde_json::json!({
        "revision": report.revision,
        "status": report.status,
    });
    if let Some(detail) = report.detail {
        body["detail"] = serde_json::json!(detail);
    }
    let response = client
        .post(format!(
            "{origin}/api/gateway/agent/{}",
            if fleet { "fleet/status" } else { "status" }
        ))
        .header(
            AUTHORIZATION,
            HeaderValue::from_str(&format!("Bearer {token}"))
                .map_err(|_| "registration token was rejected")?,
        )
        .json(&body)
        .send()
        .await
        .map_err(|_| "status report failed")?;
    if response.status().is_success() {
        Ok(())
    } else {
        Err("status report failed")
    }
}

pub fn load_cursor(path: &Path) -> (Option<String>, Option<i64>) {
    let Ok(text) = fs::read_to_string(path) else {
        return (None, None);
    };
    let mut lines = text.lines();
    let etag = lines
        .next()
        .filter(|line| !line.is_empty())
        .map(str::to_string);
    let revision = lines.next().and_then(|line| line.parse().ok());
    (etag, revision)
}

pub fn store_cursor(path: &Path, etag: &str, revision: i64) -> GatewayResult<()> {
    if etag.contains('\n') || etag.len() > 128 {
        return Err(GatewayError::message("agent cursor was not saved"));
    }
    write_public(path, format!("{etag}\n{revision}\n").as_bytes())
}

fn applied(revision: i64, etag: Option<String>, stored: Option<i64>) -> SyncOutcome {
    SyncOutcome {
        kind: SyncKind::Applied { revision },
        etag,
        revision: stored.or(Some(revision)),
        report: Some(StatusReport {
            revision,
            status: "applied",
            detail: None,
        }),
    }
}

fn rejected(
    revision: i64,
    detail: &'static str,
    etag: Option<String>,
    stored: Option<i64>,
) -> SyncOutcome {
    SyncOutcome {
        kind: SyncKind::Rejected { revision, detail },
        etag,
        revision: stored,
        report: Some(StatusReport {
            revision,
            status: "rejected",
            detail: Some(detail),
        }),
    }
}

fn hold(detail: &'static str, etag: Option<&str>, revision: Option<i64>) -> SyncOutcome {
    SyncOutcome {
        kind: SyncKind::Hold { detail },
        etag: etag.map(str::to_string),
        revision,
        report: None,
    }
}

fn hold_detail(status: u16) -> &'static str {
    match status {
        401 | 403 => "pull token was rejected",
        404 => "config endpoint was not found",
        429 => "control plane rate limited the pull",
        _ => "control plane did not return a config",
    }
}

fn header_string(headers: &reqwest::header::HeaderMap, name: &str) -> Option<String> {
    headers
        .get(name)
        .and_then(|value| value.to_str().ok())
        .map(str::to_string)
}

fn revision_of_etag(etag: &str) -> Option<i64> {
    let trimmed = etag
        .trim()
        .trim_start_matches("W/")
        .trim()
        .trim_matches('"');
    trimmed.parse().ok().filter(|value: &i64| *value >= 0)
}

async fn read_limited(mut response: reqwest::Response) -> Result<String, &'static str> {
    let mut body = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(|_| "config was rejected")? {
        if body.len().saturating_add(chunk.len()) > MAX_BYTES {
            return Err("config was rejected");
        }
        body.extend_from_slice(&chunk);
    }
    String::from_utf8(body).map_err(|_| "config was rejected")
}

async fn confirm_reload(
    client: &reqwest::Client,
    admin: &str,
    path: &Path,
    previous: Option<&str>,
) -> Result<(), &'static str> {
    let url = format!("{}/api/runtime", admin.trim_end_matches('/'));
    let started = std::time::Instant::now();
    loop {
        match client.get(&url).send().await {
            Ok(response) if response.status().is_success() => {
                let text = response.text().await.unwrap_or_default();
                match reload_check(&text) {
                    ReloadCheck::Rejected => {
                        restore(path, previous)?;
                        return Err("agentgateway rejected the reload");
                    }
                    ReloadCheck::Applied if started.elapsed() >= Duration::from_millis(500) => {
                        return Ok(());
                    }
                    ReloadCheck::Applied | ReloadCheck::Unknown => {}
                }
            }
            _ => return Ok(()),
        }
        if started.elapsed() >= Duration::from_secs(2) {
            return Ok(());
        }
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
}

fn restore(path: &Path, previous: Option<&str>) -> Result<(), &'static str> {
    match previous {
        Some(text) => {
            write_public(path, text.as_bytes()).map_err(|_| "config file could not be restored")
        }
        None => {
            let _ = fs::remove_file(path);
            Ok(())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{CredentialMode, GatewaySpec, Mode, ServerSpec, Transport, render_yaml};
    use axum::Router;
    use axum::body::Body;
    use axum::extract::State;
    use axum::http::{HeaderMap, StatusCode};
    use axum::response::Response;
    use axum::routing::{get, post};
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::{Arc, Mutex};
    use uuid::Uuid;

    fn sample_yaml(revision: i64) -> String {
        let spec = GatewaySpec {
            gateway_id: Uuid::parse_str("22222222-2222-4222-8222-222222222222").unwrap(),
            workspace_id: Uuid::parse_str("11111111-1111-4111-8111-111111111111").unwrap(),
            mode: Mode::Shared,
            public_url: "http://agentgateway:3000/mcp".to_string(),
            listen_port: 3000,
            config_revision: revision,
            ag_version: Some("1.7.0".to_string()),
            guard_host: "fizz-guard:9001".to_string(),
            jwks_file: String::new(),
            jwks_url: Some("https://fizzlayer.com/api/gateway/jwks".to_string()),
            credential_mode: CredentialMode::Embed,
            requests_per_minute: 0,
            servers: vec![ServerSpec {
                name: "sample".to_string(),
                transport: Transport::Http,
                url_or_cmd: "http://sample-mcp:8080/mcp".to_string(),
                command_args: Vec::new(),
                auth_kind: "key".to_string(),
                credential: Some("upstream-token-sample".to_string()),
            }],
        };
        render_yaml(&spec).unwrap()
    }

    #[test]
    fn token_shape_and_origin_are_checked_without_echoing_them() {
        let token = format!("{TOKEN_PREFIX}{}", "ab".repeat(32));
        assert!(registration_token_ok(&token));
        assert!(!registration_token_ok("fizz_reg_short"));
        assert!(fleet_token_ok(&format!(
            "{FLEET_PREFIX}{}",
            "ab".repeat(32)
        )));
        assert!(!fleet_token_ok(&token));
        assert_eq!(
            control_origin("https://fizzlayer.com/").unwrap(),
            "https://fizzlayer.com"
        );
        assert!(control_origin("https://user:secret@fizzlayer.com").is_err());
        assert!(control_origin("https://fizzlayer.com/api").is_err());
    }

    #[test]
    fn validation_accepts_a_render_and_does_not_quote_a_bad_body() {
        let yaml = sample_yaml(4);
        assert!(validate_gateway_yaml(&yaml).is_ok());
        let secret = "upstream-token-sample";
        let err = validate_gateway_yaml(&format!("not-a-gateway: [\n{secret}")).unwrap_err();
        assert!(!err.contains(secret));
        assert!(!err.contains(TOKEN_PREFIX));
        assert!(validate_gateway_yaml("mcp:\n  port: 1\n  targets: []\n").is_ok());
        assert!(validate_gateway_yaml("mcp:\n  port: 1\n  targets:\n    - name: only\n").is_err());
    }

    #[test]
    fn reload_flag_and_backoff() {
        assert_eq!(
            reload_check(r#"{"configReload":{"synchronized":false,"lastError":"kept"}}"#),
            ReloadCheck::Rejected
        );
        assert_eq!(
            reload_check(r#"{"configReload":{"synchronized":true,"lastError":null}}"#),
            ReloadCheck::Applied
        );
        assert_eq!(reload_check("nope"), ReloadCheck::Unknown);
        let base = Duration::from_secs(5);
        assert_eq!(next_delay(base, base, false), base);
        assert_eq!(next_delay(base, base, true), Duration::from_secs(10));
        assert_eq!(
            next_delay(Duration::from_secs(40), base, true),
            Duration::from_secs(60)
        );
    }

    struct Fake {
        token: String,
        good: String,
        hits: AtomicUsize,
        bad: Mutex<bool>,
        reports: Mutex<Vec<Value>>,
    }

    async fn config(State(state): State<Arc<Fake>>, headers: HeaderMap) -> Response {
        if !bearer_ok(&headers, &state.token) {
            return StatusCode::UNAUTHORIZED.into_response_empty();
        }
        state.hits.fetch_add(1, Ordering::SeqCst);
        let bad = *state.bad.lock().expect("bad");
        let revision = if bad { 2 } else { 1 };
        let etag = format!("\"{revision}\"");
        if headers
            .get(IF_NONE_MATCH)
            .and_then(|value| value.to_str().ok())
            == Some(etag.as_str())
        {
            return Response::builder()
                .status(304)
                .header("etag", etag)
                .header("x-config-revision", revision.to_string())
                .body(Body::empty())
                .unwrap();
        }
        let body = if bad {
            "not-a-gateway: [\nupstream-token-sample".to_string()
        } else {
            state.good.clone()
        };
        Response::builder()
            .status(200)
            .header("content-type", "text/yaml")
            .header("etag", etag)
            .header("x-config-revision", revision.to_string())
            .body(Body::from(body))
            .unwrap()
    }

    async fn status(
        State(state): State<Arc<Fake>>,
        headers: HeaderMap,
        body: String,
    ) -> StatusCode {
        if !bearer_ok(&headers, &state.token) {
            return StatusCode::UNAUTHORIZED;
        }
        if body.contains(TOKEN_PREFIX) || body.contains("upstream-token-sample") {
            return StatusCode::BAD_REQUEST;
        }
        if let Ok(value) = serde_json::from_str::<Value>(&body) {
            state.reports.lock().expect("reports").push(value);
        }
        StatusCode::OK
    }

    fn bearer_ok(headers: &HeaderMap, token: &str) -> bool {
        headers
            .get(AUTHORIZATION)
            .and_then(|value| value.to_str().ok())
            == Some(format!("Bearer {token}").as_str())
    }

    trait EmptyStatus {
        fn into_response_empty(self) -> Response;
    }

    impl EmptyStatus for StatusCode {
        fn into_response_empty(self) -> Response {
            Response::builder()
                .status(self)
                .body(Body::empty())
                .unwrap()
        }
    }

    #[tokio::test]
    async fn pull_swaps_a_good_config_and_keeps_it_when_the_next_one_is_bad() {
        let token = format!("{TOKEN_PREFIX}{}", "cd".repeat(32));
        let good = sample_yaml(1);
        let state = Arc::new(Fake {
            token: token.clone(),
            good: good.clone(),
            hits: AtomicUsize::new(0),
            bad: Mutex::new(false),
            reports: Mutex::new(Vec::new()),
        });
        let app = Router::new()
            .route("/api/gateway/agent/config", get(config))
            .route("/api/gateway/agent/status", post(status))
            .with_state(state.clone());
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        let dir = std::env::temp_dir().join(format!("fizz-agent-{}", Uuid::new_v4()));
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("config.yaml");
        let client = http_client().unwrap();
        let first = sync_once(SyncRequest {
            client: &client,
            origin: &origin,
            token: &token,
            config_path: &path,
            admin_url: None,
            etag: None,
            revision: None,
            fleet: false,
            listen_port: None,
        })
        .await;
        assert!(matches!(first.kind, SyncKind::Applied { revision: 1 }));
        assert_eq!(fs::read_to_string(&path).unwrap(), good);
        assert!(!format!("{:?}", first.kind).contains("upstream-token-sample"));
        let etag = first.etag.clone().unwrap();
        let second = sync_once(SyncRequest {
            client: &client,
            origin: &origin,
            token: &token,
            config_path: &path,
            admin_url: None,
            etag: Some(&etag),
            revision: Some(1),
            fleet: false,
            listen_port: None,
        })
        .await;
        assert!(matches!(second.kind, SyncKind::NotModified));
        *state.bad.lock().unwrap() = true;
        let third = sync_once(SyncRequest {
            client: &client,
            origin: &origin,
            token: &token,
            config_path: &path,
            admin_url: None,
            etag: second.etag.as_deref(),
            revision: Some(1),
            fleet: false,
            listen_port: None,
        })
        .await;
        match third.kind {
            SyncKind::Rejected { detail, .. } => {
                assert!(!detail.contains("upstream-token-sample"));
                assert!(!detail.contains(&token));
            }
            other => panic!("expected a rejection, got {other:?}"),
        }
        assert_eq!(fs::read_to_string(&path).unwrap(), good);
        let report = third.report.unwrap();
        report_status(&client, &origin, &token, report, false)
            .await
            .unwrap();
        let reports = state.reports.lock().unwrap();
        assert_eq!(reports.len(), 1);
        assert_eq!(reports[0]["status"], "rejected");
        assert!(!reports[0].to_string().contains("upstream-token-sample"));
        assert!(!reports[0].to_string().contains(&token));
        let _ = fs::remove_dir_all(&dir);
    }
}
