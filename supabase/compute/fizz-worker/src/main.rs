//! Long-lived sensor stream for Fizzlayer.
//!
//! Supabase Compute runs this process. Vercel functions stay request-shaped.
//! Devices publish over a WebSocket or MQTT. Subscribers hear new rows that
//! `fizz_ingest_event` stored, including rows that arrived through HTTPS.
//! Phone calls queued by those rows are sent by `/api/cron`, not by this process.

// protocol.rs is also compiled by the API (`src/live.rs`) and the CLI
// (`cli/src/transport.rs`). Those crates call items this binary does not.
// Dead code in this file is still reported.
#[allow(dead_code)]
mod protocol;

use std::{
    env,
    io::{Read, Write},
    net::{TcpListener, TcpStream},
    sync::{
        Arc, Condvar, Mutex,
        atomic::{AtomicUsize, Ordering},
        mpsc::{self, TrySendError},
    },
    thread,
    time::{Duration, Instant},
};

use base64::{Engine, engine::general_purpose::STANDARD};
use protocol::{
    AclOp, ClientOp, CredentialKind, HttpRoute, Packet, Principal, PrincipalFailure,
    ResolvedPrincipal, ack_frame, authorize, classify_credential, decode_packet, encode_packet,
    error_frame, fanout_frame, http_route, parse_client_message, parse_reading,
    principal_from_json, reading_visible,
};
use serde_json::{Value, json};
use sha1::{Digest, Sha1};
use tungstenite::{Error as WsError, Message, WebSocket};

const WS_GUID: &str = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
const MAX_HEADER: usize = 8 * 1024;
const MAX_CONNECTIONS: usize = 512;

struct App {
    db: Option<Arc<Db>>,
    hub: Hub,
    origins: Vec<String>,
    connections: AtomicUsize,
    mqtt_tcp: bool,
}

struct Hub {
    inner: Mutex<HubInner>,
    wake: Condvar,
}

struct HubInner {
    next: u64,
    generation: u64,
    subs: Vec<Sub>,
    cursor_at: Option<String>,
    cursor_id: Option<String>,
}

struct Sub {
    id: u64,
    customer_id: String,
    sensor_id: Option<String>,
    tx: mpsc::SyncSender<String>,
}

struct Db {
    agent: ureq::Agent,
    rest: String,
    key: String,
}

fn main() {
    let app = Arc::new(App::from_env());
    if app.db.is_some() {
        let poller = Arc::clone(&app);
        thread::spawn(move || poll_loop(&poller));
    } else {
        eprintln!(
            "fizz-worker: SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY is missing; streams will refuse work."
        );
    }
    let port = env::var("PORT").unwrap_or_else(|_| "8080".into());
    let http = TcpListener::bind(format!("0.0.0.0:{port}")).expect("bind http");
    if let Ok(mqtt_port) = env::var("MQTT_TCP_PORT")
        && let Ok(port) = mqtt_port.parse::<u16>()
    {
        match TcpListener::bind(format!("0.0.0.0:{port}")) {
            Ok(listener) => {
                let mqtt = Arc::clone(&app);
                thread::spawn(move || accept_mqtt(&listener, &mqtt));
            }
            Err(error) => {
                eprintln!("fizz-worker: MQTT TCP port {port} is not available: {error}");
            }
        }
    }
    accept_http(&http, &app);
}

impl App {
    fn from_env() -> Self {
        let origins = env::var("FIZZ_STREAM_ORIGINS")
            .ok()
            .filter(|value| !value.trim().is_empty())
            .map_or_else(
                || {
                    vec![
                        "https://fizzlayer.com".into(),
                        "https://www.fizzlayer.com".into(),
                    ]
                },
                |value| {
                    value
                        .split(',')
                        .map(|item| item.trim().to_owned())
                        .filter(|item| !item.is_empty())
                        .collect()
                },
            );
        let mqtt_tcp = env::var("MQTT_TCP_PORT")
            .ok()
            .and_then(|value| value.parse::<u16>().ok())
            .is_some();
        Self {
            db: Db::from_env().map(Arc::new),
            hub: Hub {
                inner: Mutex::new(HubInner {
                    next: 1,
                    generation: 0,
                    subs: Vec::new(),
                    cursor_at: None,
                    cursor_id: None,
                }),
                wake: Condvar::new(),
            },
            origins,
            connections: AtomicUsize::new(0),
            mqtt_tcp,
        }
    }

    fn origin_allowed(&self, origin: Option<&str>) -> bool {
        match origin.map(str::trim).filter(|value| !value.is_empty()) {
            None => true,
            Some(origin) if loopback_origin(origin) => true,
            Some(origin) => self.origins.iter().any(|allowed| allowed == origin),
        }
    }
}

fn loopback_origin(origin: &str) -> bool {
    let Some(rest) = origin
        .strip_prefix("http://")
        .or_else(|| origin.strip_prefix("https://"))
    else {
        return false;
    };
    let host = rest.split(['/', '?', '#']).next().unwrap_or("");
    let host = host.rsplit_once(':').map_or(host, |(host, _)| host);
    matches!(host, "localhost" | "127.0.0.1" | "[::1]")
}

impl Db {
    fn from_env() -> Option<Self> {
        let url = env::var("SUPABASE_URL").ok()?;
        let key = env::var("SUPABASE_SERVICE_ROLE_KEY").ok()?;
        Self::new(url.trim(), key.trim()).ok()
    }

    fn new(url: &str, key: &str) -> Result<Self, ()> {
        if key.is_empty() || !safe_supabase_url(url) {
            return Err(());
        }
        let rest = format!("{}/rest/v1/rpc/", url.trim_end_matches('/'));
        let agent = ureq::Agent::config_builder()
            .http_status_as_error(false)
            .max_redirects(0)
            .timeout_global(Some(Duration::from_secs(10)))
            .user_agent("fizz-worker")
            .build()
            .into();
        Ok(Self {
            agent,
            rest,
            key: key.to_owned(),
        })
    }

    fn rpc(&self, name: &str, body: &Value) -> Result<Value, ()> {
        let url = format!("{}{name}", self.rest);
        let mut response = self
            .agent
            .post(&url)
            .header("apikey", &self.key)
            .header("authorization", &format!("Bearer {}", self.key))
            .header("content-type", "application/json")
            .send(body.to_string())
            .map_err(|_| ())?;
        let status = response.status().as_u16();
        let text = response
            .body_mut()
            .with_config()
            .limit(1024 * 1024)
            .read_to_string()
            .map_err(|_| ())?;
        if !(200..300).contains(&status) {
            return Err(());
        }
        Ok(serde_json::from_str(&text).unwrap_or(Value::Null))
    }

    fn principal(
        &self,
        credential: &str,
        sensor_id: Option<&str>,
    ) -> Result<ResolvedPrincipal, PrincipalFailure> {
        let value = self
            .rpc(
                "fizz_live_principal",
                &json!({"p_credential": credential, "p_sensor_id": sensor_id}),
            )
            .map_err(|()| PrincipalFailure::Unavailable)?;
        principal_from_json(&value)
    }

    fn ingest(&self, key: &str, reading: &protocol::Reading) -> Result<(), &'static str> {
        let value = self
            .rpc("fizz_ingest_event", &{
                let body = protocol::reading_json(reading);
                json!({
                    "p_sensor_id": body["sensor_id"],
                    "p_key": key,
                    "p_event_id": body["event_id"],
                    "p_observed_at": body.get("observed_at").cloned().unwrap_or(Value::Null),
                    "p_metrics": body["metrics"],
                })
            })
            .map_err(|()| "unavailable")?;
        match value.get("error").and_then(Value::as_str) {
            None => Ok(()),
            Some("unauthorized") => Err("unauthorized"),
            Some("paused") => Err("paused"),
            Some("rate_limited") => Err("rate_limited"),
            Some("invalid_reading" | "invalid_request") => Err("invalid_request"),
            Some(_) => Err("unavailable"),
        }
    }
}

fn safe_supabase_url(url: &str) -> bool {
    let allow_insecure = matches!(
        env::var("FIZZ_ALLOW_INSECURE_HTTP").ok().as_deref(),
        Some("1" | "true")
    );
    safe_supabase_url_with(url, allow_insecure)
}

fn safe_supabase_url_with(url: &str, allow_insecure: bool) -> bool {
    let Some((scheme, rest)) = url.split_once("://") else {
        return false;
    };
    if rest.contains('@') || rest.contains('#') || rest.contains('?') || rest.contains('/') {
        return false;
    }
    let host = rest.rsplit_once(':').map_or(rest, |(host, _)| host);
    let local = matches!(host, "localhost" | "127.0.0.1" | "[::1]");
    (scheme == "https" || (scheme == "http" && (local || allow_insecure))) && !host.is_empty()
}

fn accept_http(listener: &TcpListener, app: &Arc<App>) {
    for stream in listener.incoming() {
        let Ok(stream) = stream else { continue };
        if !acquire(app) {
            let _ = write_text(&stream, 503, r#"{"error":"unavailable"}"#);
            continue;
        }
        let app = Arc::clone(app);
        thread::spawn(move || {
            let _guard = ConnectionGuard(&app);
            if let Err(error) = stream.set_read_timeout(Some(Duration::from_secs(10))) {
                eprintln!("fizz-worker: could not time out a connection: {error}");
                return;
            }
            let _ = stream.set_write_timeout(Some(Duration::from_secs(10)));
            let _ = handle_http(stream, &app);
        });
    }
}

fn accept_mqtt(listener: &TcpListener, app: &Arc<App>) {
    for stream in listener.incoming() {
        let Ok(stream) = stream else { continue };
        if !acquire(app) {
            continue;
        }
        let app = Arc::clone(app);
        thread::spawn(move || {
            let _guard = ConnectionGuard(&app);
            let _ = stream.set_read_timeout(Some(Duration::from_secs(10)));
            let _ = stream.set_write_timeout(Some(Duration::from_secs(10)));
            let _ = mqtt_tcp(stream, &app);
        });
    }
}

struct ConnectionGuard<'a>(&'a App);
impl Drop for ConnectionGuard<'_> {
    fn drop(&mut self) {
        self.0.connections.fetch_sub(1, Ordering::Relaxed);
    }
}

fn acquire(app: &Arc<App>) -> bool {
    let mut current = app.connections.load(Ordering::Relaxed);
    loop {
        if current >= MAX_CONNECTIONS {
            return false;
        }
        match app.connections.compare_exchange_weak(
            current,
            current + 1,
            Ordering::Relaxed,
            Ordering::Relaxed,
        ) {
            Ok(_) => return true,
            Err(actual) => current = actual,
        }
    }
}

fn handle_http(mut stream: TcpStream, app: &App) -> std::io::Result<()> {
    let head = read_head(&mut stream)?;
    let Some(request) = parse_request(&head) else {
        return write_text(&stream, 400, r#"{"error":"invalid_request"}"#);
    };
    let Some(route) = http_route(request.path) else {
        return write_text(&stream, 404, r#"{"error":"not_found"}"#);
    };
    if route == HttpRoute::Health {
        let body = json!({
            "service": "fizz-worker",
            "status": "ok",
            "database": if app.db.is_some() { "configured" } else { "unconfigured" },
            "mqtt_tcp": app.mqtt_tcp,
        });
        return write_text(&stream, 200, &body.to_string());
    }
    if !app.origin_allowed(request.origin) {
        return write_text(&stream, 403, r#"{"error":"forbidden_origin"}"#);
    }
    let Some(key) = request.websocket_key else {
        return write_text(&stream, 400, r#"{"error":"invalid_request"}"#);
    };
    write_upgrade(&stream, key, route == HttpRoute::Mqtt)?;
    stream
        .set_read_timeout(Some(Duration::from_millis(250)))
        .ok();
    stream.set_nodelay(true).ok();
    let socket = WebSocket::from_raw_socket(stream, tungstenite::protocol::Role::Server, None);
    match route {
        HttpRoute::Mqtt => mqtt_ws(socket, app),
        HttpRoute::Stream => json_publish(socket, app, request.bearer),
        HttpRoute::Live => json_live(socket, app, request.bearer),
        HttpRoute::Health => Ok(()),
    }
}

struct RequestHead<'a> {
    path: &'a str,
    origin: Option<&'a str>,
    websocket_key: Option<&'a str>,
    bearer: Option<String>,
}

fn parse_request(head: &str) -> Option<RequestHead<'_>> {
    let mut lines = head.split("\r\n");
    let request = lines.next()?;
    let mut parts = request.split(' ');
    let method = parts.next()?;
    let path = parts.next()?;
    if !matches!(method, "GET" | "HEAD") {
        return None;
    }
    let mut origin = None;
    let mut websocket_key = None;
    let mut bearer = None;
    for line in lines {
        let Some((name, value)) = line.split_once(':') else {
            continue;
        };
        let value = value.trim();
        if name.eq_ignore_ascii_case("origin") {
            origin = Some(value);
        } else if name.eq_ignore_ascii_case("sec-websocket-key") {
            websocket_key = Some(value);
        } else if name.eq_ignore_ascii_case("authorization")
            && let Some(token) = value.strip_prefix("Bearer ")
            && classify_credential(token).is_some()
        {
            bearer = Some(token.to_owned());
        }
    }
    Some(RequestHead {
        path,
        origin,
        websocket_key,
        bearer,
    })
}

fn read_head(stream: &mut TcpStream) -> std::io::Result<String> {
    let mut buf = Vec::new();
    let mut byte = [0];
    while buf.len() < MAX_HEADER && !buf.windows(4).any(|window| window == b"\r\n\r\n") {
        if stream.read(&mut byte)? == 0 {
            break;
        }
        buf.push(byte[0]);
    }
    String::from_utf8(buf)
        .map_err(|error| std::io::Error::new(std::io::ErrorKind::InvalidData, error))
}

fn write_text(mut stream: &TcpStream, status: u16, body: &str) -> std::io::Result<()> {
    let reason = match status {
        200 => "OK",
        400 => "Bad Request",
        403 => "Forbidden",
        404 => "Not Found",
        _ => "Unavailable",
    };
    write!(
        stream,
        "HTTP/1.1 {status} {reason}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    )
}

fn write_upgrade(mut stream: &TcpStream, key: &str, mqtt: bool) -> std::io::Result<()> {
    let accept = accept_key(key);
    let protocol = if mqtt {
        "Sec-WebSocket-Protocol: mqtt\r\n"
    } else {
        ""
    };
    write!(
        stream,
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n{protocol}\r\n"
    )
}

fn accept_key(key: &str) -> String {
    let mut hasher = Sha1::new();
    hasher.update(key.as_bytes());
    hasher.update(WS_GUID.as_bytes());
    STANDARD.encode(hasher.finalize())
}

fn json_publish(
    mut socket: WebSocket<TcpStream>,
    app: &App,
    bearer: Option<String>,
) -> std::io::Result<()> {
    let Some(db) = app.db.as_ref() else {
        let _ = socket.send(Message::Text(error_frame("unavailable", None).into()));
        return Ok(());
    };
    let Some(key) = first_credential(&mut socket, bearer, CredentialKind::SensorKey)? else {
        return Ok(());
    };
    let _ = socket.send(Message::Text(
        json!({"op": "ready", "role": "device"}).to_string().into(),
    ));
    let mut idle = Instant::now();
    loop {
        if idle.elapsed() > Duration::from_secs(70) {
            break;
        }
        if idle.elapsed() > Duration::from_secs(25) {
            let _ = socket.send(Message::Ping(Vec::new().into()));
        }
        match read_ws(&mut socket) {
            WsRead::Text(text) => {
                idle = Instant::now();
                if text.len() > protocol::MAX_PACKET_BYTES {
                    let _ = socket.send(Message::Text(error_frame("invalid_request", None).into()));
                    continue;
                }
                let value: Value = if let Ok(value) = serde_json::from_str(&text) {
                    value
                } else {
                    let _ = socket.send(Message::Text(error_frame("invalid_request", None).into()));
                    continue;
                };
                match parse_client_message(&value) {
                    Ok(ClientOp::Reading(reading)) => {
                        let event = reading.event_id.clone();
                        match db.ingest(&key, &reading) {
                            Ok(()) => {
                                let _ = socket.send(Message::Text(ack_frame(&event).into()));
                            }
                            Err(code @ ("unauthorized" | "paused")) => {
                                let _ = socket
                                    .send(Message::Text(error_frame(code, Some(&event)).into()));
                                break;
                            }
                            Err(code) => {
                                let _ = socket
                                    .send(Message::Text(error_frame(code, Some(&event)).into()));
                            }
                        }
                    }
                    Ok(ClientOp::Ping) => {
                        let _ =
                            socket.send(Message::Text(json!({"op": "pong"}).to_string().into()));
                    }
                    _ => {
                        let _ =
                            socket.send(Message::Text(error_frame("invalid_request", None).into()));
                    }
                }
            }
            WsRead::Binary(_) | WsRead::Control => idle = Instant::now(),
            WsRead::Timeout => {}
            WsRead::Closed => break,
        }
    }
    Ok(())
}

fn json_live(
    mut socket: WebSocket<TcpStream>,
    app: &App,
    bearer: Option<String>,
) -> std::io::Result<()> {
    let Some(db) = app.db.clone() else {
        let _ = socket.send(Message::Text(error_frame("unavailable", None).into()));
        return Ok(());
    };
    let credential =
        if let Some(token) = bearer.filter(|token| classify_credential(token).is_some()) {
            token
        } else {
            match read_any_credential(&mut socket)? {
                Some(token) => token,
                None => return Ok(()),
            }
        };
    let mut scope: Option<(String, Option<String>, u64)> = None;
    let (tx, rx) = mpsc::sync_channel::<String>(64);
    let mut idle = Instant::now();
    loop {
        if idle.elapsed() > Duration::from_secs(70) {
            break;
        }
        while let Ok(frame) = rx.try_recv() {
            let _ = socket.send(Message::Text(frame.into()));
        }
        if idle.elapsed() > Duration::from_secs(25) {
            let _ = socket.send(Message::Ping(Vec::new().into()));
        }
        match read_ws(&mut socket) {
            WsRead::Text(text) => {
                idle = Instant::now();
                let Ok(value) = serde_json::from_str::<Value>(&text) else {
                    let _ = socket.send(Message::Text(error_frame("invalid_request", None).into()));
                    continue;
                };
                match parse_client_message(&value) {
                    Ok(ClientOp::Subscribe { sensor_id }) => {
                        match db.principal(&credential, sensor_id.as_deref()) {
                            Ok(resolved) => {
                                if let Some((_, _, id)) = scope.take() {
                                    app.hub.remove(id);
                                }
                                let sensor_scope = match &resolved.principal {
                                    Principal::Device { sensor_id } => Some(sensor_id.clone()),
                                    Principal::Viewer { sensor_id } => sensor_id.clone(),
                                };
                                let id = app.hub.insert(Sub {
                                    id: 0,
                                    customer_id: resolved.customer_id.clone(),
                                    sensor_id: sensor_scope.clone(),
                                    tx: tx.clone(),
                                });
                                scope = Some((resolved.customer_id, sensor_scope.clone(), id));
                                let _ = socket.send(Message::Text(
                                    json!({
                                        "op": "subscribed",
                                        "sensor_id": sensor_scope,
                                    })
                                    .to_string()
                                    .into(),
                                ));
                            }
                            Err(failure) => {
                                let code = failure_code(failure);
                                let _ = socket.send(Message::Text(error_frame(code, None).into()));
                                if matches!(
                                    failure,
                                    PrincipalFailure::Unauthorized | PrincipalFailure::Paused
                                ) {
                                    break;
                                }
                            }
                        }
                    }
                    Ok(ClientOp::Ping) => {
                        let _ =
                            socket.send(Message::Text(json!({"op": "pong"}).to_string().into()));
                    }
                    _ => {
                        let _ =
                            socket.send(Message::Text(error_frame("invalid_request", None).into()));
                    }
                }
            }
            WsRead::Binary(_) | WsRead::Control => idle = Instant::now(),
            WsRead::Timeout => {}
            WsRead::Closed => break,
        }
    }
    if let Some((_, _, id)) = scope {
        app.hub.remove(id);
    }
    Ok(())
}

fn first_credential(
    socket: &mut WebSocket<TcpStream>,
    bearer: Option<String>,
    kind: CredentialKind,
) -> std::io::Result<Option<String>> {
    if let Some(token) = bearer
        && classify_credential(&token) == Some(kind)
    {
        return Ok(Some(token));
    }
    let deadline = Instant::now() + Duration::from_secs(10);
    while Instant::now() < deadline {
        match read_ws(socket) {
            WsRead::Text(text) => {
                let Ok(value) = serde_json::from_str::<Value>(&text) else {
                    let _ = socket.send(Message::Text(error_frame("invalid_request", None).into()));
                    return Ok(None);
                };
                match parse_client_message(&value) {
                    Ok(ClientOp::Auth { key }) if classify_credential(&key) == Some(kind) => {
                        return Ok(Some(key));
                    }
                    _ => {
                        let _ =
                            socket.send(Message::Text(error_frame("unauthorized", None).into()));
                        return Ok(None);
                    }
                }
            }
            WsRead::Binary(_) | WsRead::Control | WsRead::Timeout => {}
            WsRead::Closed => return Ok(None),
        }
    }
    let _ = socket.send(Message::Text(error_frame("unauthorized", None).into()));
    Ok(None)
}

fn read_any_credential(socket: &mut WebSocket<TcpStream>) -> std::io::Result<Option<String>> {
    let deadline = Instant::now() + Duration::from_secs(10);
    while Instant::now() < deadline {
        match read_ws(socket) {
            WsRead::Text(text) => {
                let Ok(value) = serde_json::from_str::<Value>(&text) else {
                    return Ok(None);
                };
                return if let Ok(ClientOp::Auth { key }) = parse_client_message(&value) {
                    Ok(Some(key))
                } else {
                    let _ = socket.send(Message::Text(error_frame("unauthorized", None).into()));
                    Ok(None)
                };
            }
            WsRead::Binary(_) | WsRead::Control | WsRead::Timeout => {}
            WsRead::Closed => return Ok(None),
        }
    }
    Ok(None)
}

enum WsRead {
    Text(String),
    Binary(Vec<u8>),
    Control,
    Timeout,
    Closed,
}

fn read_ws(socket: &mut WebSocket<TcpStream>) -> WsRead {
    match socket.read() {
        Ok(Message::Text(text)) => WsRead::Text(text.to_string()),
        Ok(Message::Binary(bytes)) => WsRead::Binary(bytes.to_vec()),
        Ok(Message::Ping(payload)) => {
            let _ = socket.send(Message::Pong(payload));
            WsRead::Control
        }
        Ok(Message::Close(_)) => WsRead::Closed,
        Ok(_) => WsRead::Control,
        Err(WsError::Io(error))
            if error.kind() == std::io::ErrorKind::TimedOut
                || error.kind() == std::io::ErrorKind::WouldBlock =>
        {
            WsRead::Timeout
        }
        Err(_) => WsRead::Closed,
    }
}

fn failure_code(failure: PrincipalFailure) -> &'static str {
    match failure {
        PrincipalFailure::Unauthorized => "unauthorized",
        PrincipalFailure::Paused => "paused",
        PrincipalFailure::RateLimited => "rate_limited",
        PrincipalFailure::NotFound => "not_found",
        PrincipalFailure::Unavailable => "unavailable",
    }
}

fn mqtt_tcp(mut stream: TcpStream, app: &App) -> std::io::Result<()> {
    let Some(db) = app.db.clone() else {
        return Ok(());
    };
    let mut buf = Vec::new();
    let mut state: Option<MqttState> = None;
    let (tx, rx) = mpsc::sync_channel::<String>(64);
    let mut sub_id = None;
    'read: loop {
        while let Ok(frame) = rx.try_recv() {
            if let Some(state) = &state
                && let Principal::Device { sensor_id }
                | Principal::Viewer {
                    sensor_id: Some(sensor_id),
                } = &state.principal.principal
            {
                let _ = write_mqtt(
                    &mut stream,
                    &Packet::Publish {
                        topic: protocol::live_topic(sensor_id),
                        payload: frame.into_bytes(),
                        qos: 0,
                        packet_id: None,
                    },
                );
            } else if let Some(state) = &state
                && matches!(
                    state.principal.principal,
                    Principal::Viewer { sensor_id: None }
                )
                && let Ok(value) = serde_json::from_str::<Value>(&frame)
                && let Some(sensor) = value.get("sensor_id").and_then(Value::as_str)
            {
                let _ = write_mqtt(
                    &mut stream,
                    &Packet::Publish {
                        topic: protocol::live_topic(sensor),
                        payload: frame.into_bytes(),
                        qos: 0,
                        packet_id: None,
                    },
                );
            }
        }
        let mut byte = [0];
        match stream.read(&mut byte) {
            Ok(0) => break,
            Ok(_) => buf.push(byte[0]),
            Err(error)
                if error.kind() == std::io::ErrorKind::TimedOut
                    || error.kind() == std::io::ErrorKind::WouldBlock =>
            {
                continue;
            }
            Err(_) => break,
        }
        if buf.len() > protocol::MAX_PACKET_BYTES + 8 {
            break;
        }
        loop {
            let decoded = match decode_packet(&buf) {
                Ok(Some((packet, size))) => {
                    buf.drain(..size);
                    packet
                }
                Ok(None) => break,
                Err(_) => break 'read,
            };
            if !mqtt_packet(decoded, &mut stream, app, &db, &mut state, &tx, &mut sub_id)? {
                break 'read;
            }
        }
    }
    if let Some(id) = sub_id {
        app.hub.remove(id);
    }
    Ok(())
}

struct MqttState {
    credential: String,
    principal: ResolvedPrincipal,
}

fn mqtt_packet(
    packet: Packet,
    stream: &mut TcpStream,
    app: &App,
    db: &Db,
    state: &mut Option<MqttState>,
    tx: &mpsc::SyncSender<String>,
    sub_id: &mut Option<u64>,
) -> std::io::Result<bool> {
    match packet {
        Packet::Connect {
            username, password, ..
        } => {
            let Some(password) = password else {
                write_mqtt(stream, &Packet::Connack { code: 4 })?;
                return Ok(false);
            };
            let sensor = username
                .as_deref()
                .filter(|value| protocol::valid_uuid(value));
            match db.principal(&password, sensor) {
                Ok(principal) => {
                    *state = Some(MqttState {
                        credential: password,
                        principal,
                    });
                    write_mqtt(stream, &Packet::Connack { code: 0 })?;
                    Ok(true)
                }
                Err(PrincipalFailure::Paused) => {
                    write_mqtt(stream, &Packet::Connack { code: 5 })?;
                    Ok(false)
                }
                Err(_) => {
                    write_mqtt(stream, &Packet::Connack { code: 4 })?;
                    Ok(false)
                }
            }
        }
        Packet::Publish {
            topic,
            payload,
            qos,
            packet_id,
        } => {
            let Some(session) = state.as_ref() else {
                return Ok(false);
            };
            let allowed = authorize(&session.principal.principal, AclOp::Publish, &topic).is_ok()
                && matches!(session.principal.principal, Principal::Device { .. });
            if !allowed {
                return Ok(false);
            }
            let Ok(value) = serde_json::from_slice::<Value>(&payload) else {
                return Ok(false);
            };
            let Ok(reading) = parse_reading(
                &value,
                authorize(&session.principal.principal, AclOp::Publish, &topic)
                    .ok()
                    .as_deref(),
            ) else {
                return Ok(false);
            };
            if db.ingest(&session.credential, &reading).is_err() {
                return Ok(false);
            }
            if qos == 1
                && let Some(packet_id) = packet_id
            {
                write_mqtt(stream, &Packet::Puback { packet_id })?;
            }
            Ok(true)
        }
        Packet::Subscribe { packet_id, topics } => {
            let Some(session) = state.as_ref() else {
                return Ok(false);
            };
            let mut codes = Vec::new();
            let mut ok = false;
            for topic in &topics {
                match authorize(&session.principal.principal, AclOp::Subscribe, topic) {
                    Ok(sensor) => {
                        let check = match &session.principal.principal {
                            Principal::Viewer { sensor_id: None } => {
                                db.principal(&session.credential, Some(&sensor)).is_ok()
                            }
                            _ => true,
                        };
                        if check {
                            codes.push(0);
                            ok = true;
                            if let Some(id) = sub_id.take() {
                                app.hub.remove(id);
                            }
                            *sub_id = Some(app.hub.insert(Sub {
                                id: 0,
                                customer_id: session.principal.customer_id.clone(),
                                sensor_id: Some(sensor),
                                tx: tx.clone(),
                            }));
                        } else {
                            codes.push(0x80);
                        }
                    }
                    Err(_) => codes.push(0x80),
                }
            }
            write_mqtt(stream, &Packet::Suback { packet_id, codes })?;
            let _ = ok;
            Ok(true)
        }
        Packet::Pingreq => {
            write_mqtt(stream, &Packet::Pingresp)?;
            Ok(true)
        }
        // A clean disconnect and any other packet both end this read loop.
        _ => Ok(false),
    }
}

fn write_mqtt(stream: &mut TcpStream, packet: &Packet) -> std::io::Result<()> {
    let bytes = encode_packet(packet).map_err(|_| std::io::Error::other("mqtt"))?;
    stream.write_all(&bytes)
}

fn mqtt_ws(mut socket: WebSocket<TcpStream>, app: &App) -> std::io::Result<()> {
    // MQTT over WebSocket is the path Compute's public HTTP URL can carry.
    // Bytes are gathered here and handled by the same packet rules as TCP.
    let mut raw = Vec::new();
    let mut bridge = MqttBridge {
        socket: &mut socket,
    };
    let mut state = None;
    let (tx, rx) = mpsc::sync_channel::<String>(64);
    let mut sub_id = None;
    let Some(db) = app.db.clone() else {
        return Ok(());
    };
    'read: loop {
        while let Ok(frame) = rx.try_recv() {
            deliver_ws_reading(&mut bridge, state.as_ref(), &frame);
        }
        match read_ws(bridge.socket) {
            WsRead::Control | WsRead::Timeout => {}
            WsRead::Text(_) | WsRead::Closed => break,
            WsRead::Binary(bytes) => raw.extend(bytes),
        }
        if raw.len() > protocol::MAX_PACKET_BYTES + 8 {
            break;
        }
        // The TCP helper writes to TcpStream. WebSocket MQTT reuses packet
        // decisions by encoding replies onto the socket below.
        loop {
            let packet = match decode_packet(&raw) {
                Ok(Some((packet, size))) => {
                    raw.drain(..size);
                    packet
                }
                Ok(None) => break,
                Err(_) => break 'read,
            };
            if !mqtt_ws_packet(packet, &mut bridge, app, &db, &mut state, &tx, &mut sub_id)? {
                break 'read;
            }
        }
    }
    if let Some(id) = sub_id {
        app.hub.remove(id);
    }
    Ok(())
}

struct MqttBridge<'a> {
    socket: &'a mut WebSocket<TcpStream>,
}

fn deliver_ws_reading(bridge: &mut MqttBridge<'_>, state: Option<&MqttState>, frame: &str) {
    let Some(state) = state else { return };
    let sensor = match &state.principal.principal {
        Principal::Device { sensor_id }
        | Principal::Viewer {
            sensor_id: Some(sensor_id),
        } => Some(sensor_id.clone()),
        Principal::Viewer { sensor_id: None } => {
            serde_json::from_str::<Value>(frame).ok().and_then(|value| {
                value
                    .get("sensor_id")
                    .and_then(Value::as_str)
                    .map(str::to_owned)
            })
        }
    };
    let Some(sensor) = sensor else { return };
    let _ = bridge.send(&Packet::Publish {
        topic: protocol::live_topic(&sensor),
        payload: frame.as_bytes().to_vec(),
        qos: 0,
        packet_id: None,
    });
}

impl MqttBridge<'_> {
    fn send(&mut self, packet: &Packet) -> std::io::Result<()> {
        let bytes = encode_packet(packet).map_err(|_| std::io::Error::other("mqtt"))?;
        self.socket
            .send(Message::Binary(bytes.into()))
            .map_err(|_| std::io::Error::other("websocket"))
    }
}

fn mqtt_ws_packet(
    packet: Packet,
    bridge: &mut MqttBridge<'_>,
    app: &App,
    db: &Db,
    state: &mut Option<MqttState>,
    tx: &mpsc::SyncSender<String>,
    sub_id: &mut Option<u64>,
) -> std::io::Result<bool> {
    match packet {
        Packet::Connect {
            username, password, ..
        } => {
            let Some(password) = password else {
                bridge.send(&Packet::Connack { code: 4 })?;
                return Ok(false);
            };
            let sensor = username
                .as_deref()
                .filter(|value| protocol::valid_uuid(value));
            match db.principal(&password, sensor) {
                Ok(principal) => {
                    *state = Some(MqttState {
                        credential: password,
                        principal,
                    });
                    bridge.send(&Packet::Connack { code: 0 })?;
                    Ok(true)
                }
                Err(PrincipalFailure::Paused) => {
                    bridge.send(&Packet::Connack { code: 5 })?;
                    Ok(false)
                }
                Err(_) => {
                    bridge.send(&Packet::Connack { code: 4 })?;
                    Ok(false)
                }
            }
        }
        Packet::Publish {
            topic,
            payload,
            qos,
            packet_id,
        } => {
            let Some(session) = state.as_ref() else {
                return Ok(false);
            };
            let sensor = match authorize(&session.principal.principal, AclOp::Publish, &topic) {
                Ok(sensor) if matches!(session.principal.principal, Principal::Device { .. }) => {
                    sensor
                }
                _ => return Ok(false),
            };
            let Ok(value) = serde_json::from_slice::<Value>(&payload) else {
                return Ok(false);
            };
            let Ok(reading) = parse_reading(&value, Some(&sensor)) else {
                return Ok(false);
            };
            if db.ingest(&session.credential, &reading).is_err() {
                return Ok(false);
            };
            if qos == 1
                && let Some(packet_id) = packet_id
            {
                bridge.send(&Packet::Puback { packet_id })?;
            }
            Ok(true)
        }
        Packet::Subscribe { packet_id, topics } => {
            let Some(session) = state.as_ref() else {
                return Ok(false);
            };
            let mut codes = Vec::new();
            for topic in &topics {
                match authorize(&session.principal.principal, AclOp::Subscribe, topic) {
                    Ok(sensor) => {
                        let check = match &session.principal.principal {
                            Principal::Viewer { sensor_id: None } => {
                                db.principal(&session.credential, Some(&sensor)).is_ok()
                            }
                            _ => true,
                        };
                        if check {
                            codes.push(0);
                            if let Some(id) = sub_id.take() {
                                app.hub.remove(id);
                            }
                            *sub_id = Some(app.hub.insert(Sub {
                                id: 0,
                                customer_id: session.principal.customer_id.clone(),
                                sensor_id: Some(sensor),
                                tx: tx.clone(),
                            }));
                        } else {
                            codes.push(0x80);
                        }
                    }
                    Err(_) => codes.push(0x80),
                }
            }
            bridge.send(&Packet::Suback { packet_id, codes })?;
            Ok(true)
        }
        Packet::Pingreq => {
            bridge.send(&Packet::Pingresp)?;
            Ok(true)
        }
        // A clean disconnect and any other packet both end this read loop.
        _ => Ok(false),
    }
}

fn poll_loop(app: &Arc<App>) {
    let Some(db) = app.db.clone() else { return };
    loop {
        let (cursor_at, cursor_id, generation) = {
            let mut inner = app.hub.inner.lock().expect("hub");
            while inner.subs.is_empty() {
                inner.cursor_at = None;
                inner.cursor_id = None;
                inner = app.hub.wake.wait(inner).expect("hub");
            }
            (
                inner.cursor_at.clone(),
                inner.cursor_id.clone(),
                inner.generation,
            )
        };
        let page = db.rpc(
            "fizz_live_since",
            &json!({
                "p_received_after": cursor_at,
                "p_after_id": cursor_id,
                "p_limit": 200,
            }),
        );
        let Ok(page) = page else {
            thread::sleep(Duration::from_secs(1));
            continue;
        };
        let mut inner = app.hub.inner.lock().expect("hub");
        if inner.generation != generation {
            continue;
        }
        if cursor_at.is_none() {
            inner.cursor_at = page.get("now").and_then(Value::as_str).map(str::to_owned);
            inner.cursor_id = Some(protocol::nil_cursor().into());
            drop(inner);
            thread::sleep(Duration::from_millis(300));
            continue;
        }
        let rows = page
            .get("readings")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        let full = rows.len() == 200;
        for row in &rows {
            if let Some((customer, sensor, frame)) = fanout_frame(row) {
                inner.subs.retain(|sub| {
                    if !reading_visible(
                        &sub.customer_id,
                        sub.sensor_id.as_deref(),
                        &customer,
                        &sensor,
                    ) {
                        return true;
                    }
                    !matches!(
                        sub.tx.try_send(frame.clone()),
                        Err(TrySendError::Disconnected(_))
                    )
                });
                inner.cursor_at = row
                    .get("received_at")
                    .and_then(Value::as_str)
                    .map(str::to_owned);
                inner.cursor_id = row.get("id").and_then(Value::as_str).map(str::to_owned);
            }
        }
        drop(inner);
        if !full {
            thread::sleep(Duration::from_millis(300));
        }
    }
}

impl Hub {
    fn insert(&self, mut sub: Sub) -> u64 {
        let mut inner = self.inner.lock().expect("hub");
        let id = inner.next;
        inner.next += 1;
        sub.id = id;
        let wake = inner.subs.is_empty();
        inner.subs.push(sub);
        drop(inner);
        if wake {
            self.wake.notify_one();
        }
        id
    }

    fn remove(&self, id: u64) {
        let mut inner = self.inner.lock().expect("hub");
        let before = inner.subs.len();
        inner.subs.retain(|sub| sub.id != id);
        if before > 0 && inner.subs.is_empty() {
            inner.generation += 1;
            inner.cursor_at = None;
            inner.cursor_id = None;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn supabase_url_allows_a_private_http_host_only_when_asked() {
        assert!(safe_supabase_url_with("https://ref.supabase.co", false));
        assert!(safe_supabase_url_with("http://127.0.0.1:54321", false));
        assert!(safe_supabase_url_with("http://gateway:8000", true));
        assert!(!safe_supabase_url_with("http://gateway:8000", false));
        assert!(!safe_supabase_url_with("http://user@gateway:8000", true));
        assert!(!safe_supabase_url_with(
            "https://ref.supabase.co/rest/v1",
            true
        ));
    }

    #[test]
    fn websocket_accept_matches_the_rfc_sample() {
        assert_eq!(
            accept_key("dGhlIHNhbXBsZSBub25jZQ=="),
            "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
        );
    }

    #[test]
    fn health_answers_without_a_database() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let app = Arc::new(App {
            db: None,
            hub: Hub {
                inner: Mutex::new(HubInner {
                    next: 1,
                    generation: 0,
                    subs: Vec::new(),
                    cursor_at: None,
                    cursor_id: None,
                }),
                wake: Condvar::new(),
            },
            origins: vec!["https://fizzlayer.com".into()],
            connections: AtomicUsize::new(0),
            mqtt_tcp: false,
        });
        thread::spawn(move || accept_http(&listener, &app));
        let mut stream = TcpStream::connect(("127.0.0.1", port)).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        stream
            .write_all(b"GET /compute/v1/fizz-worker/health HTTP/1.1\r\nHost: localhost\r\n\r\n")
            .unwrap();
        let mut body = String::new();
        stream.read_to_string(&mut body).unwrap();
        assert!(body.starts_with("HTTP/1.1 200"), "{body}");
        assert!(body.contains("\"service\":\"fizz-worker\""));
        assert!(body.contains("\"database\":\"unconfigured\""));
    }

    #[test]
    fn a_foreign_browser_origin_cannot_upgrade() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let app = Arc::new(App {
            db: None,
            hub: Hub {
                inner: Mutex::new(HubInner {
                    next: 1,
                    generation: 0,
                    subs: Vec::new(),
                    cursor_at: None,
                    cursor_id: None,
                }),
                wake: Condvar::new(),
            },
            origins: vec!["https://fizzlayer.com".into()],
            connections: AtomicUsize::new(0),
            mqtt_tcp: false,
        });
        thread::spawn(move || accept_http(&listener, &app));
        let mut stream = TcpStream::connect(("127.0.0.1", port)).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        stream
            .write_all(
                b"GET /v1/live HTTP/1.1\r\nHost: localhost\r\nOrigin: https://evil.example\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n",
            )
            .unwrap();
        let mut body = String::new();
        stream.read_to_string(&mut body).unwrap();
        assert!(body.starts_with("HTTP/1.1 403"), "{body}");
    }
}
