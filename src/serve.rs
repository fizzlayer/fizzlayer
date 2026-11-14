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
    account, agent, agents, auth, billing, call_phones, contact, cron, customer, devices, mcp,
    phone, security, sensors, status, stream, voice,
};

pub async fn run() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let port = env::var("PORT").unwrap_or_else(|_| "8080".into());
    let addr: SocketAddr = format!("0.0.0.0:{port}").parse()?;
    let listener = TcpListener::bind(addr).await?;
    eprintln!("fizz-serve listening on {addr}");
    tokio::spawn(cron_loop());
    loop {
        let (stream, _) = listener.accept().await?;
        tokio::spawn(async move {
            let io = TokioIo::new(stream);
            let service = service_fn(handle);
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

async fn handle(request: Request<Incoming>) -> Result<Response<Full<Bytes>>, Infallible> {
    let https = request
        .headers()
        .get("x-forwarded-proto")
        .and_then(|value| value.to_str().ok())
        == Some("https");
    let path = request.uri().path().to_owned();
    let response = if path == "/auth/v1" || path.starts_with("/auth/v1/") {
        proxy_auth(request).await
    } else if path == "/api/waitlist" || path.starts_with("/api/") {
        freeze(api(request).await).await
    } else if let Some(location) = redirect_target(&path, request.uri().query()) {
        redirect(location)
    } else {
        static_file(&path).await
    };
    Ok(with_security(response, https))
}

async fn api(request: Request<Incoming>) -> vercel_runtime::Response<ResponseBody> {
    if let Err(response) = security::guard_request(&request) {
        return response;
    }
    let path = request.uri().path();
    let method = request.method().clone();
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
        .map_or_default(|query| format!("?{query}"));
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

/// Permanent redirects for URLs that moved. Query strings are added by `redirect_target`.
pub fn redirect_path(path: &str) -> Option<&'static str> {
    match path {
        "/sensors.html" => Some("/sensors"),
        "/docs.html" => Some("/sensors/docs"),
        "/agents.html" => Some("/sensors/agents"),
        "/self-host.html" => Some("/sensors/self-host"),
        _ => None,
    }
}

pub fn redirect_target(path: &str, query: Option<&str>) -> Option<String> {
    let dest = redirect_path(path)?;
    match query {
        Some(query) if !query.is_empty() => Some(format!("{dest}?{query}")),
        _ => Some(dest.to_owned()),
    }
}

pub fn mapped_path(path: &str) -> &str {
    match path {
        "/" | "/index.html" => "/index.html",
        "/docs" | "/docs/" => "/gateway-docs.html",
        "/sensors" | "/sensors/" => "/sensors.html",
        "/sensors/docs" | "/sensors/docs/" => "/docs.html",
        "/sensors/agents" | "/sensors/agents/" => "/agents.html",
        "/sensors/self-host" | "/sensors/self-host/" => "/self-host.html",
        "/pricing" | "/pricing/" => "/pricing.html",
        "/status" | "/status/" => "/status.html",
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
    path.is_file().then_some(path)
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

fn redirect(location: String) -> Response<Full<Bytes>> {
    let mut response = text(StatusCode::MOVED_PERMANENTLY, "Moved");
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
    let mut connect = String::from(
        "'self' https://*.supabase.co wss://*.supabase.co ws://localhost:8080 http://localhost:8080 ws://127.0.0.1:8080 http://127.0.0.1:8080",
    );
    connect.push_str(&stream_connect());
    let mut policy = format!(
        "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src 'self' https://fonts.gstatic.com; img-src 'self' data:; media-src 'self' blob:; connect-src {connect}; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'"
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
    let port = url.port().map_or_default(|port| format!(":{port}"));
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
        assert_eq!(mapped_path("/sensors"), "/sensors.html");
        assert_eq!(mapped_path("/sensors/docs"), "/docs.html");
        assert_eq!(mapped_path("/sensors/agents/"), "/agents.html");
        assert_eq!(mapped_path("/sensors/self-host"), "/self-host.html");
        assert_eq!(mapped_path("/pricing/"), "/pricing.html");
        assert_eq!(mapped_path("/status"), "/status.html");
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
    fn moved_pages_redirect_and_keep_the_query() {
        assert_eq!(redirect_path("/sensors.html"), Some("/sensors"));
        assert_eq!(redirect_path("/docs.html"), Some("/sensors/docs"));
        assert_eq!(redirect_path("/agents.html"), Some("/sensors/agents"));
        assert_eq!(redirect_path("/self-host.html"), Some("/sensors/self-host"));
        assert_eq!(
            redirect_target("/docs.html", Some("plan=pro")).as_deref(),
            Some("/sensors/docs?plan=pro")
        );
        assert_eq!(redirect_path("/app.html"), None);
        assert_eq!(redirect_path("/install.sh"), None);
        assert_eq!(redirect_path("/api/ingest"), None);
        assert_eq!(redirect_path("/api/mcp"), None);
        assert_eq!(redirect_path("/ha.html"), None);
        assert_eq!(redirect_path("/.well-known/mcp.json"), None);
    }

    #[test]
    fn static_paths_reject_parent_segments() {
        let root = Path::new("public");
        assert!(safe_file(root, "/../Cargo.toml").is_none());
        assert!(safe_file(root, "/index.html").is_some());
    }
}
