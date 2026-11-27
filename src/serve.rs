//! One-process HTTP server for self-hosting.
//!
//! It serves `public/` and calls the same `src/` handlers the Vercel functions call.
//! Nothing in those handlers is copied. The minute scheduler runs in this process.

use std::{
    convert::Infallible,
    env, fs,
    net::SocketAddr,
    path::{Component, Path, PathBuf},
    sync::OnceLock,
    time::Duration,
};

use http_body_util::{BodyExt, Full};
use hyper::{
    Method, Request, Response, StatusCode,
    body::{Bytes, Incoming},
    header::{HeaderName, HeaderValue},
    server::conn::http1,
    service::service_fn,
};
use hyper_util::rt::TokioIo;
use tokio::net::TcpListener;
use vercel_runtime::ResponseBody;

use crate::{
    account, agent, agents, auth, billing, call_phones, contact, cron, customer, devices, gateway,
    mcp, phone, security, sensors, status, stream, voice,
};

pub async fn run() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let port = env::var("PORT").unwrap_or_else(|_| "8080".into());
    let addr: SocketAddr = format!("0.0.0.0:{port}").parse()?;
    let listener = TcpListener::bind(addr).await?;
    let sensors = Sensors::from_env();
    eprintln!("fizz-serve listening on {addr}, {}", sensors.describe());
    tokio::spawn(cron_loop());
    loop {
        let (stream, _) = listener.accept().await?;
        tokio::spawn(async move {
            let io = TokioIo::new(stream);
            let service = service_fn(move |request| handle(request, sensors));
            if let Err(error) = http1::Builder::new().serve_connection(io, service).await {
                eprintln!("fizz-serve connection: {error}");
            }
        });
    }
}

async fn cron_loop() {
    let seconds = env::var("FIZZ_CRON_SECONDS")
        .ok()
        .and_then(|value| value.parse::<u64>().ok())
        .filter(|seconds| *seconds >= 15)
        .unwrap_or(60);
    let mut interval = tokio::time::interval(Duration::from_secs(seconds));
    interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    loop {
        interval.tick().await;
        if let Err(message) = cron::run_scheduled().await {
            eprintln!("fizz-serve cron: {message}");
        }
    }
}

/// Sensors is the older device product: the dashboard at `/app.html`, the
/// `/sensors` pages, and the device and agent APIs behind them. fizzlayer.com
/// does not offer it (`vercel.json` sends those pages away). A self-hosted
/// server shows it only when `FIZZ_SENSORS` turns it on.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Sensors {
    Hidden,
    Shown,
}

impl Sensors {
    pub fn from_env() -> Self {
        Self::parse(env::var("FIZZ_SENSORS").ok().as_deref())
    }

    /// `1`, `true`, `yes`, and `on` turn Sensors on. Anything else, or unset, leaves them off.
    pub fn parse(value: Option<&str>) -> Self {
        let on = value.is_some_and(|value| {
            matches!(
                value.trim().to_ascii_lowercase().as_str(),
                "1" | "true" | "yes" | "on"
            )
        });
        if on { Self::Shown } else { Self::Hidden }
    }

    fn describe(self) -> &'static str {
        match self {
            Self::Hidden => "Sensors off (FIZZ_SENSORS=1 turns them on)",
            Self::Shown => "Sensors on",
        }
    }
}

async fn handle(
    request: Request<Incoming>,
    sensors: Sensors,
) -> Result<Response<Full<Bytes>>, Infallible> {
    let https = request
        .headers()
        .get("x-forwarded-proto")
        .and_then(|value| value.to_str().ok())
        == Some("https");
    let path = request.uri().path().to_owned();
    let response = if path == "/auth/v1" || path.starts_with("/auth/v1/") {
        proxy_auth(request).await
    } else if path == "/api/waitlist" || path.starts_with("/api/") {
        freeze(api(request, sensors).await).await
    } else if let Some((status, location)) = redirect_for(&path, request.uri().query(), sensors) {
        redirect(status, location)
    } else if path == "/app/config.json" {
        spa_config(&public_dir(), sensors)
    } else {
        static_file(&path).await
    };
    Ok(with_security(response, https))
}

async fn api(
    request: Request<Incoming>,
    sensors: Sensors,
) -> vercel_runtime::Response<ResponseBody> {
    if let Err(failure) = security::guard_request(&request) {
        return failure.into_response();
    }
    let path = request.uri().path();
    let method = request.method().clone();
    if sensors == Sensors::Hidden && sensors_api(path) {
        return customer::error(
            404,
            "sensors_off",
            "Sensors are off on this server. Set FIZZ_SENSORS=1 to turn them on.",
        );
    }
    if path == "/api/gateway" || path.starts_with("/api/gateway/") {
        return gateway::handle(request).await;
    }
    match path {
        "/api/status" => status::handle(request).await,
        "/api/auth" => match method.as_str() {
            "GET" => auth::oauth(request).await,
            "POST" => auth::action(request).await,
            _ => customer::error(405, "method_not_allowed", "Use GET or POST."),
        },
        "/api/account" => account::handle(request).await,
        "/api/agents" => agents::handle(request).await,
        "/api/alerts" => agent::alerts(request).await,
        "/api/billing" => {
            if method == Method::GET || method == Method::POST {
                billing::handle(request).await
            } else {
                customer::error(405, "method_not_allowed", "Use GET or POST.")
            }
        }
        "/api/chat" => {
            if method == Method::POST {
                agent::chat(request).await
            } else {
                customer::error(405, "method_not_allowed", "Use POST.")
            }
        }
        "/api/contact" | "/api/waitlist" => {
            if method == Method::POST {
                contact::contact(request).await
            } else {
                customer::error(405, "method_not_allowed", "Use POST.")
            }
        }
        "/api/cron" => cron::handle(request).await,
        "/api/devices" => devices::handle(request).await,
        "/api/ingest" => {
            if method == Method::POST {
                sensors::ingest(request).await
            } else {
                customer::error(405, "method_not_allowed", "Use POST.")
            }
        }
        "/api/mcp" => mcp::handle(request).await,
        "/api/me" => {
            if method == Method::GET {
                customer::current(request).await
            } else {
                customer::error(405, "method_not_allowed", "Use GET.")
            }
        }
        "/api/phone" => phone::handle(request).await,
        "/api/phones" => call_phones::handle(request).await,
        "/api/readings" => {
            if method == Method::GET {
                sensors::readings(request).await
            } else {
                customer::error(405, "method_not_allowed", "Use GET.")
            }
        }
        "/api/sensors" => match method.as_str() {
            "GET" => sensors::list(request).await,
            "POST" => sensors::create(request).await,
            "PATCH" => sensors::update(request).await,
            "DELETE" => sensors::delete(request).await,
            _ => customer::error(
                405,
                "method_not_allowed",
                "Use GET, POST, PATCH, or DELETE.",
            ),
        },
        "/api/session" => {
            if method == Method::DELETE {
                customer::sign_out(request).await
            } else {
                customer::error(405, "method_not_allowed", "Use DELETE to sign out.")
            }
        }
        "/api/setup" => match method.as_str() {
            "GET" => customer::sensor_choices(request).await,
            "POST" => customer::select_sensor(request).await,
            "DELETE" => customer::remove_sensor(request).await,
            _ => customer::error(405, "method_not_allowed", "Use GET, POST, or DELETE."),
        },
        "/api/stream" => match method.as_str() {
            "GET" => stream::config(),
            "POST" => stream::issue(request).await,
            _ => customer::error(405, "method_not_allowed", "Use GET or POST."),
        },
        "/api/stripe-webhook" => {
            if method == Method::POST {
                billing::webhook(request).await
            } else {
                customer::error(405, "method_not_allowed", "Use POST.")
            }
        }
        "/api/voice" => voice::handle(request).await,
        _ => customer::error(404, "not_found", "No route matches that path."),
    }
}

async fn freeze(response: vercel_runtime::Response<ResponseBody>) -> Response<Full<Bytes>> {
    let (parts, body) = response.into_parts();
    let bytes = match body.collect().await {
        Ok(collected) => collected.to_bytes(),
        Err(error) => {
            eprintln!("fizz-serve response: {error}");
            Bytes::from_static(
                br#"{"error":"unavailable","message":"The response could not be sent."}"#,
            )
        }
    };
    let mut out = Response::new(Full::new(bytes));
    *out.status_mut() = parts.status;
    *out.headers_mut() = parts.headers;
    out
}

fn http_client() -> &'static reqwest::Client {
    static CLIENT: OnceLock<reqwest::Client> = OnceLock::new();
    CLIENT.get_or_init(|| {
        reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .timeout(Duration::from_secs(15))
            .build()
            .expect("http client")
    })
}

/// Browser OAuth has to reach GoTrue. The server itself uses `SUPABASE_URL`.
async fn proxy_auth(request: Request<Incoming>) -> Response<Full<Bytes>> {
    let upstream = match env::var("FIZZ_AUTH_UPSTREAM") {
        Ok(value) if !value.trim().is_empty() => value.trim().trim_end_matches('/').to_owned(),
        _ => {
            return text(
                StatusCode::NOT_FOUND,
                "Auth is not exposed on this port. Set FIZZ_AUTH_UPSTREAM for a bundled GoTrue, or send the browser to SUPABASE_PUBLIC_URL.",
            );
        }
    };
    let path = request.uri().path().trim_start_matches("/auth/v1");
    let path = if path.is_empty() { "/" } else { path };
    if path.split('/').any(|part| part == "..") {
        return text(StatusCode::BAD_REQUEST, "Bad path.");
    }
    let query = request
        .uri()
        .query()
        .map_or(String::new(), |query| format!("?{query}"));
    let url = format!("{upstream}{path}{query}");
    let Ok(method) = reqwest::Method::from_bytes(request.method().as_str().as_bytes()) else {
        return text(StatusCode::METHOD_NOT_ALLOWED, "Method is not supported.");
    };
    let headers = request.headers().clone();
    let collected = match request.into_body().collect().await {
        Ok(collected) => collected.to_bytes(),
        Err(_) => return text(StatusCode::BAD_REQUEST, "Could not read the request."),
    };
    if collected.len() > 1024 * 1024 {
        return text(StatusCode::PAYLOAD_TOO_LARGE, "Request is too large.");
    }
    let mut builder = http_client().request(method, url);
    for (name, value) in &headers {
        if matches!(
            name.as_str(),
            "host" | "connection" | "content-length" | "transfer-encoding"
        ) {
            continue;
        }
        builder = builder.header(name.as_str(), value.as_bytes());
    }
    let response = match builder.body(collected).send().await {
        Ok(response) => response,
        Err(error) => {
            eprintln!("fizz-serve auth proxy: {error}");
            return text(StatusCode::BAD_GATEWAY, "Auth service is unavailable.");
        }
    };
    let status = response.status();
    let headers = response.headers().clone();
    let bytes = response.bytes().await.unwrap_or_default();
    let mut out = Response::new(Full::new(bytes));
    *out.status_mut() = status;
    for (name, value) in &headers {
        if matches!(
            name.as_str(),
            "connection" | "transfer-encoding" | "content-length"
        ) {
            continue;
        }
        out.headers_mut().append(name.clone(), value.clone());
    }
    out
}

/// API routes that only Sensors use. With Sensors off they answer 404, so a
/// server that never opted in takes no readings and issues no device or agent
/// keys. Sign-in, account, billing, phones, status, cron, contact, and
/// `/api/gateway` stay on because the Gateway app and Settings use them.
/// `/api/stream` stays on: it only reports whether live sockets are set up,
/// and the status page reads it.
pub fn sensors_api(path: &str) -> bool {
    matches!(
        path,
        "/api/agents"
            | "/api/alerts"
            | "/api/chat"
            | "/api/devices"
            | "/api/ingest"
            | "/api/mcp"
            | "/api/phone"
            | "/api/readings"
            | "/api/sensors"
            | "/api/setup"
            | "/api/voice"
    )
}

/// Where a Sensors page sends the browser while Sensors are hidden. Dashboard
/// pages go to the app, where the same account signs in. The rest go to the
/// site. `vercel.json` has the same redirects for fizzlayer.com.
pub fn hidden_sensors_path(path: &str) -> Option<&'static str> {
    let path = path.trim_end_matches('/');
    match path {
        "/app.html" | "/demo.html" | "/phone.html" | "/ha.html" => Some("/app"),
        "/self-host.html" => Some("/self-host"),
        "/sensors.html" | "/docs.html" | "/agents.html" => Some("/"),
        _ if path == "/sensors/self-host" || path.starts_with("/sensors/self-host/") => {
            Some("/self-host")
        }
        _ if path == "/sensors" || path.starts_with("/sensors/") => Some("/"),
        _ => None,
    }
}

/// The redirect for `path`, if it has one. Hidden Sensors pages answer 307, so
/// a browser does not cache it past the day Sensors are turned on. Pages that
/// moved answer 301. The query string is kept.
pub fn redirect_for(
    path: &str,
    query: Option<&str>,
    sensors: Sensors,
) -> Option<(StatusCode, String)> {
    let (status, dest) = match (sensors, hidden_sensors_path(path)) {
        (Sensors::Hidden, Some(dest)) => (StatusCode::TEMPORARY_REDIRECT, dest),
        _ => (StatusCode::MOVED_PERMANENTLY, redirect_path(path)?),
    };
    let location = match query {
        Some(query) if !query.is_empty() => format!("{dest}?{query}"),
        _ => dest.to_owned(),
    };
    Some((status, location))
}

/// Permanent redirects for Sensors URLs that moved, used while Sensors are on.
pub fn redirect_path(path: &str) -> Option<&'static str> {
    match path {
        "/sensors.html" => Some("/sensors"),
        "/docs.html" => Some("/sensors/docs"),
        "/agents.html" => Some("/sensors/agents"),
        "/self-host.html" => Some("/sensors/self-host"),
        _ => None,
    }
}

pub fn mapped_path(path: &str) -> &str {
    match path {
        "/" | "/index.html" => "/index.html",
        "/docs" | "/docs/" => "/gateway-docs.html",
        "/gateway" | "/gateway/" => "/gateway.html",
        "/sensors" | "/sensors/" => "/sensors.html",
        "/sensors/docs" | "/sensors/docs/" => "/docs.html",
        "/sensors/agents" | "/sensors/agents/" => "/agents.html",
        "/sensors/self-host" | "/sensors/self-host/" => "/self-host.html",
        "/pricing" | "/pricing/" => "/pricing.html",
        "/status" | "/status/" => "/status.html",
        "/changelog" | "/changelog/" => "/changelog.html",
        "/enterprise" | "/enterprise/" => "/enterprise.html",
        "/self-host" | "/self-host/" => "/self-host-chooser.html",
        "/.well-known/webmcp" => "/.well-known/webmcp.json",
        other => other,
    }
}

fn public_dir() -> PathBuf {
    env::var("FIZZ_PUBLIC_DIR").map_or_else(|_| PathBuf::from("public"), PathBuf::from)
}

fn safe_file(root: &Path, url_path: &str) -> Option<PathBuf> {
    let relative = mapped_path(url_path).trim_start_matches('/');
    if relative.is_empty() {
        return None;
    }
    let mut path = root.to_path_buf();
    for part in Path::new(relative).components() {
        match part {
            Component::Normal(part) => path.push(part),
            _ => return None,
        }
    }
    if path.is_file() {
        return Some(path);
    }
    // The Gleam app under /app: a pre-rendered page for a static URL, or the
    // loading shell for the rest, as the Vercel rewrites do.
    if url_path == "/app" || url_path.starts_with("/app/") {
        let index = path.join("index.html");
        if index.is_file() {
            return Some(index);
        }
        let shell = root.join("app").join("shell.html");
        if url_path.starts_with("/app/") && shell.is_file() {
            return Some(shell);
        }
    }
    None
}

async fn static_file(url_path: &str) -> Response<Full<Bytes>> {
    let root = public_dir();
    let Some(path) = safe_file(&root, url_path) else {
        return text(StatusCode::NOT_FOUND, "Not found.");
    };
    match fs::read(&path) {
        Ok(bytes) => {
            let mut response = Response::new(Full::new(Bytes::from(bytes)));
            if let Some(kind) = content_type(&path) {
                response
                    .headers_mut()
                    .insert("content-type", HeaderValue::from_static(kind));
            }
            response.headers_mut().insert(
                "cache-control",
                HeaderValue::from_static("public, max-age=300"),
            );
            response
        }
        Err(_) => text(StatusCode::NOT_FOUND, "Not found."),
    }
}

fn content_type(path: &Path) -> Option<&'static str> {
    match path.extension().and_then(|ext| ext.to_str()) {
        Some("html") => Some("text/html; charset=utf-8"),
        Some("css") => Some("text/css; charset=utf-8"),
        Some("js" | "mjs") => Some("text/javascript; charset=utf-8"),
        Some("json") => Some("application/json; charset=utf-8"),
        Some("svg") => Some("image/svg+xml"),
        Some("png") => Some("image/png"),
        Some("jpg" | "jpeg") => Some("image/jpeg"),
        Some("gif") => Some("image/gif"),
        Some("webp") => Some("image/webp"),
        Some("ico") => Some("image/x-icon"),
        Some("woff2") => Some("font/woff2"),
        Some("woff") => Some("font/woff"),
        Some("mp4") => Some("video/mp4"),
        Some("webm") => Some("video/webm"),
        Some("txt") => Some("text/plain; charset=utf-8"),
        Some("xml") => Some("application/xml"),
        _ => None,
    }
}

/// The app's `/app/config.json` with `sensors` set from this server's flag, so
/// the app links to Sensors only where those pages are served. The rest of the
/// file comes from the build (`scripts/write_spa_config.py`). Without a build,
/// the app still gets the flag.
fn spa_config(root: &Path, sensors: Sensors) -> Response<Full<Bytes>> {
    let built = fs::read(root.join("app").join("config.json"))
        .ok()
        .and_then(|bytes| serde_json::from_slice(&bytes).ok());
    let body = spa_config_body(built, sensors);
    let mut response = Response::new(Full::new(Bytes::from(body)));
    let headers = response.headers_mut();
    headers.insert(
        "content-type",
        HeaderValue::from_static("application/json; charset=utf-8"),
    );
    headers.insert("cache-control", HeaderValue::from_static("no-store"));
    response
}

pub fn spa_config_body(built: Option<serde_json::Value>, sensors: Sensors) -> String {
    let mut config = match built {
        Some(serde_json::Value::Object(map)) => map,
        _ => serde_json::Map::new(),
    };
    config.insert(
        "sensors".to_owned(),
        serde_json::Value::Bool(sensors == Sensors::Shown),
    );
    serde_json::Value::Object(config).to_string()
}

fn redirect(status: StatusCode, location: String) -> Response<Full<Bytes>> {
    let mut response = text(status, "Moved");
    response.headers_mut().insert(
        "location",
        HeaderValue::try_from(location).unwrap_or_else(|_| HeaderValue::from_static("/")),
    );
    response
}

fn text(status: StatusCode, message: &str) -> Response<Full<Bytes>> {
    let mut response = Response::new(Full::new(Bytes::from(message.to_owned())));
    *response.status_mut() = status;
    response.headers_mut().insert(
        "content-type",
        HeaderValue::from_static("text/plain; charset=utf-8"),
    );
    response
}

fn with_security(mut response: Response<Full<Bytes>>, https: bool) -> Response<Full<Bytes>> {
    let headers = response.headers_mut();
    insert_missing(headers, "content-security-policy", &csp(https));
    insert_missing(headers, "x-content-type-options", "nosniff");
    insert_missing(headers, "x-frame-options", "DENY");
    insert_missing(headers, "referrer-policy", "no-referrer");
    insert_missing(
        headers,
        "permissions-policy",
        "camera=(), tools=(self), microphone=(self), geolocation=(self), accelerometer=(self), gyroscope=(self), magnetometer=(self), payment=(), usb=()",
    );
    if https {
        insert_missing(
            headers,
            "strict-transport-security",
            "max-age=31536000; includeSubDomains",
        );
    }
    response
}

fn insert_missing(headers: &mut hyper::HeaderMap, name: &str, value: &str) {
    let Ok(name) = HeaderName::from_bytes(name.as_bytes()) else {
        return;
    };
    if headers.contains_key(&name) {
        return;
    }
    if let Ok(value) = HeaderValue::from_str(value) {
        headers.insert(name, value);
    }
}

fn csp(https: bool) -> String {
    policy(https, &stream_connect())
}

/// Stripe.js and its frames come from Stripe for `/app/checkout`. Keep `vercel.json` the same.
fn policy(https: bool, stream: &str) -> String {
    let mut policy = format!(
        "default-src 'self'; script-src 'self' https://js.stripe.com https://*.js.stripe.com; style-src 'self' 'unsafe-inline'; font-src 'self'; img-src 'self' data:; media-src 'self' blob:; connect-src 'self' https://*.supabase.co wss://*.supabase.co ws://localhost:8080 http://localhost:8080 ws://127.0.0.1:8080 http://127.0.0.1:8080 https://api.stripe.com{stream}; frame-src https://js.stripe.com https://*.js.stripe.com https://hooks.stripe.com https://checkout.stripe.com; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'"
    );
    if https {
        policy.push_str("; upgrade-insecure-requests");
    }
    policy
}

fn stream_connect() -> String {
    let Ok(value) = env::var("FIZZ_STREAM_URL") else {
        return String::new();
    };
    let Ok(url) = reqwest::Url::parse(value.trim()) else {
        return String::new();
    };
    let Some(host) = url.host_str() else {
        return String::new();
    };
    if host
        .chars()
        .any(|c| !(c.is_ascii_alphanumeric() || ".-:[]".contains(c)))
    {
        return String::new();
    }
    let port = url.port().map_or(String::new(), |port| format!(":{port}"));
    let (http, ws) = if url.scheme() == "http" {
        ("http", "ws")
    } else if url.scheme() == "https" {
        ("https", "wss")
    } else {
        return String::new();
    };
    format!(" {http}://{host}{port} {ws}://{host}{port}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clean_urls_map_to_the_same_files_as_vercel() {
        assert_eq!(mapped_path("/"), "/index.html");
        assert_eq!(mapped_path("/docs"), "/gateway-docs.html");
        assert_eq!(mapped_path("/gateway"), "/gateway.html");
        assert_eq!(mapped_path("/gateway/"), "/gateway.html");
        assert_eq!(mapped_path("/sensors"), "/sensors.html");
        assert_eq!(mapped_path("/sensors/docs"), "/docs.html");
        assert_eq!(mapped_path("/sensors/agents/"), "/agents.html");
        assert_eq!(mapped_path("/sensors/self-host"), "/self-host.html");
        assert_eq!(mapped_path("/pricing/"), "/pricing.html");
        assert_eq!(mapped_path("/status"), "/status.html");
        assert_eq!(mapped_path("/changelog"), "/changelog.html");
        assert_eq!(mapped_path("/changelog/"), "/changelog.html");
        assert_eq!(mapped_path("/enterprise"), "/enterprise.html");
        assert_eq!(mapped_path("/self-host"), "/self-host-chooser.html");
        assert_eq!(
            mapped_path("/.well-known/webmcp"),
            "/.well-known/webmcp.json"
        );
        assert_eq!(mapped_path("/app.html"), "/app.html");
        assert_eq!(mapped_path("/install.sh"), "/install.sh");
        assert_eq!(mapped_path("/api/mcp"), "/api/mcp");
        assert_eq!(mapped_path("/ha.html"), "/ha.html");
    }

    #[test]
    fn sensors_are_off_unless_the_flag_turns_them_on() {
        assert_eq!(Sensors::parse(None), Sensors::Hidden);
        for off in ["", "0", "false", "no", "off", "2", "sensors"] {
            assert_eq!(Sensors::parse(Some(off)), Sensors::Hidden, "{off}");
        }
        for on in ["1", "true", "TRUE", " yes ", "on"] {
            assert_eq!(Sensors::parse(Some(on)), Sensors::Shown, "{on}");
        }
    }

    #[test]
    fn hidden_sensors_pages_redirect_for_a_while_and_keep_the_query() {
        let hidden = |path: &str, query: Option<&str>| redirect_for(path, query, Sensors::Hidden);
        let temporary = |location: &str| Some((StatusCode::TEMPORARY_REDIRECT, location.into()));
        assert_eq!(hidden("/sensors", None), temporary("/"));
        assert_eq!(hidden("/sensors/", None), temporary("/"));
        assert_eq!(hidden("/sensors/docs", None), temporary("/"));
        assert_eq!(hidden("/sensors/agents/", None), temporary("/"));
        assert_eq!(hidden("/sensors/index.html", None), temporary("/"));
        assert_eq!(hidden("/sensors/self-host", None), temporary("/self-host"));
        assert_eq!(
            hidden("/sensors/self-host/index.html", None),
            temporary("/self-host")
        );
        assert_eq!(hidden("/self-host.html", None), temporary("/self-host"));
        assert_eq!(hidden("/sensors.html", None), temporary("/"));
        assert_eq!(hidden("/docs.html", None), temporary("/"));
        assert_eq!(hidden("/agents.html", None), temporary("/"));
        assert_eq!(
            hidden("/app.html", Some("plan=pro")),
            temporary("/app?plan=pro")
        );
        assert_eq!(hidden("/demo.html", None), temporary("/app"));
        assert_eq!(hidden("/phone.html", Some("")), temporary("/app"));
        assert_eq!(
            hidden("/ha.html", Some("state=abc")),
            temporary("/app?state=abc")
        );
        // The Gateway site, the app, Settings, and shared assets are not Sensors pages.
        for path in [
            "/",
            "/gateway",
            "/docs",
            "/self-host",
            "/app",
            "/app/config.json",
            "/settings.html",
            "/sensors.css",
            "/sensors.js",
            "/sensorsx",
            "/api/sensors",
        ] {
            assert_eq!(hidden(path, None), None, "{path}");
        }
    }

    #[test]
    fn shown_sensors_pages_are_served() {
        for path in [
            "/sensors",
            "/sensors/docs",
            "/sensors/agents",
            "/sensors/self-host",
            "/app.html",
            "/demo.html",
            "/phone.html",
            "/ha.html",
        ] {
            assert_eq!(redirect_for(path, None, Sensors::Shown), None, "{path}");
        }
        let root = Path::new("public");
        assert!(safe_file(root, "/sensors").is_some());
        assert!(safe_file(root, "/sensors/docs").is_some());
        assert!(safe_file(root, "/app.html").is_some());
    }

    #[test]
    fn vercel_sends_hidden_sensors_pages_to_the_same_places() {
        let vercel: serde_json::Value =
            serde_json::from_str(include_str!("../vercel.json")).unwrap();
        let redirects: Vec<(String, String, bool)> = vercel["redirects"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|r| r.get("has").is_none())
            .map(|r| {
                (
                    r["source"].as_str().unwrap().to_owned(),
                    r["destination"].as_str().unwrap().to_owned(),
                    r["permanent"].as_bool().unwrap(),
                )
            })
            .collect();
        // The first entry that matches wins, as on Vercel. `/x/:rest*` matches `/x` and below.
        let vercel_target = |path: &str| {
            redirects.iter().find(|(source, _, _)| {
                source
                    .strip_suffix("/:rest*")
                    .map_or(source == path, |prefix| {
                        path == prefix || path.starts_with(&format!("{prefix}/"))
                    })
            })
        };
        for path in [
            "/sensors",
            "/sensors/docs",
            "/sensors/agents",
            "/sensors/self-host",
            "/sensors/self-host/index.html",
            "/sensors.html",
            "/docs.html",
            "/agents.html",
            "/self-host.html",
            "/app.html",
            "/demo.html",
            "/phone.html",
            "/ha.html",
        ] {
            let (_, destination, permanent) = vercel_target(path).unwrap_or_else(|| {
                panic!("vercel.json has no redirect for {path}");
            });
            assert_eq!(
                Some(destination.as_str()),
                hidden_sensors_path(path),
                "{path}"
            );
            assert!(!permanent, "{path} must not be a permanent redirect");
        }
        for (source, destination, permanent) in &redirects {
            if !permanent {
                let sample = source.trim_end_matches("/:rest*");
                assert_eq!(hidden_sensors_path(sample), Some(destination.as_str()));
            }
        }
    }

    #[test]
    fn sensors_api_routes_are_gated_and_the_rest_are_not() {
        for path in [
            "/api/agents",
            "/api/alerts",
            "/api/chat",
            "/api/devices",
            "/api/ingest",
            "/api/mcp",
            "/api/phone",
            "/api/readings",
            "/api/sensors",
            "/api/setup",
            "/api/voice",
        ] {
            assert!(sensors_api(path), "{path}");
        }
        for path in [
            "/api/account",
            "/api/auth",
            "/api/billing",
            "/api/contact",
            "/api/cron",
            "/api/gateway",
            "/api/gateway/gateways",
            "/api/me",
            "/api/phones",
            "/api/session",
            "/api/status",
            "/api/stream",
            "/api/stripe-webhook",
            "/api/waitlist",
        ] {
            assert!(!sensors_api(path), "{path}");
        }
    }

    #[test]
    fn app_config_carries_the_sensors_flag() {
        let built =
            serde_json::json!({"supabaseUrl": "https://x.supabase.co", "supabaseAnonKey": "k"});
        let shown: serde_json::Value =
            serde_json::from_str(&spa_config_body(Some(built.clone()), Sensors::Shown)).unwrap();
        assert_eq!(shown["sensors"], true);
        assert_eq!(shown["supabaseUrl"], "https://x.supabase.co");
        assert_eq!(shown["supabaseAnonKey"], "k");
        // A build-time value never overrides the server.
        let built = serde_json::json!({"supabaseUrl": "", "sensors": true});
        let hidden: serde_json::Value =
            serde_json::from_str(&spa_config_body(Some(built), Sensors::Hidden)).unwrap();
        assert_eq!(hidden["sensors"], false);
        assert_eq!(spa_config_body(None, Sensors::Shown), r#"{"sensors":true}"#);
        assert_eq!(
            spa_config_body(Some(serde_json::json!([1])), Sensors::Hidden),
            r#"{"sensors":false}"#
        );
    }

    #[test]
    fn moved_pages_redirect_and_keep_the_query() {
        assert_eq!(redirect_path("/sensors.html"), Some("/sensors"));
        assert_eq!(redirect_path("/docs.html"), Some("/sensors/docs"));
        assert_eq!(redirect_path("/agents.html"), Some("/sensors/agents"));
        assert_eq!(redirect_path("/self-host.html"), Some("/sensors/self-host"));
        assert_eq!(
            redirect_for("/docs.html", Some("plan=pro"), Sensors::Shown),
            Some((
                StatusCode::MOVED_PERMANENTLY,
                "/sensors/docs?plan=pro".to_owned()
            ))
        );
        assert_eq!(redirect_path("/app.html"), None);
        assert_eq!(redirect_path("/install.sh"), None);
        assert_eq!(redirect_path("/api/ingest"), None);
        assert_eq!(redirect_path("/api/mcp"), None);
        assert_eq!(redirect_path("/api/gateway/jwks"), None);
        assert_eq!(redirect_path("/api/gateway/gateways"), None);
        assert_eq!(redirect_path("/ha.html"), None);
        assert_eq!(redirect_path("/.well-known/mcp.json"), None);
    }

    #[test]
    fn csp_allows_stripe_checkout_and_matches_vercel() {
        let policy = policy(true, "");
        let directive = |name: &str| {
            policy
                .split("; ")
                .find_map(|part| part.strip_prefix(name)?.strip_prefix(' '))
                .unwrap_or_default()
                .to_owned()
        };
        assert!(directive("script-src").contains("https://js.stripe.com"));
        assert!(directive("frame-src").contains("https://js.stripe.com"));
        assert!(directive("frame-src").contains("https://hooks.stripe.com"));
        assert!(directive("connect-src").contains("https://api.stripe.com"));
        assert_eq!(directive("frame-ancestors"), "'none'");
        let vercel: serde_json::Value =
            serde_json::from_str(include_str!("../vercel.json")).unwrap();
        let header = vercel["headers"][0]["headers"]
            .as_array()
            .unwrap()
            .iter()
            .find(|h| h["key"] == "Content-Security-Policy")
            .unwrap();
        assert_eq!(header["value"].as_str(), Some(policy.as_str()));
    }

    #[test]
    fn static_paths_reject_parent_segments() {
        let root = Path::new("public");
        assert!(safe_file(root, "/../Cargo.toml").is_none());
        assert!(safe_file(root, "/index.html").is_some());
    }

    #[test]
    fn app_paths_use_prerendered_pages_then_the_shell() {
        let root = env::temp_dir().join(format!("fizz-serve-app-{}", std::process::id()));
        fs::create_dir_all(root.join("app/sign-in")).unwrap();
        fs::write(root.join("app/index.html"), "create").unwrap();
        fs::write(root.join("app/sign-in/index.html"), "sign in").unwrap();
        fs::write(root.join("app/shell.html"), "shell").unwrap();
        let read =
            |path: &str| safe_file(&root, path).map(|file| fs::read_to_string(file).unwrap());
        assert_eq!(read("/app").as_deref(), Some("create"));
        assert_eq!(read("/app/").as_deref(), Some("create"));
        assert_eq!(read("/app/sign-in").as_deref(), Some("sign in"));
        assert_eq!(read("/app/gateways/abc/tools").as_deref(), Some("shell"));
        assert_eq!(read("/apple"), None);
        assert_eq!(read("/app/../Cargo.toml"), None);
        fs::remove_dir_all(&root).unwrap();
    }
}
