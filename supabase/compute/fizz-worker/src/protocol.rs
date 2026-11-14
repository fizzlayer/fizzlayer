//! Shared socket and MQTT rules for the Compute worker, the API, and the CLI.
//!
//! The database still decides whether a key owns a sensor. This module decides which
//! topics and frames are even shaped correctly, and which of those a connection is
//! allowed to use once the database has named its principal.

use serde_json::{Map, Value, json};

pub const MAX_PACKET_BYTES: usize = 16 * 1024;
pub const MAX_METRICS: usize = 16;
pub const MAX_METRIC_NAME_BYTES: usize = 40;
pub const MAX_TEXT_VALUE_BYTES: usize = 512;
pub const MAX_EVENT_ID_BYTES: usize = 128;
pub const TOPIC_PREFIX: &str = "fizz/v1/";

const NIL_UUID: &str = "00000000-0000-0000-0000-000000000000";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CredentialKind {
    SensorKey,
    StreamToken,
    AgentToken,
}

/// `fizz_` + 64 hex is a sensor key. Longer prefixes are agent and stream tokens.
pub fn classify_credential(value: &str) -> Option<CredentialKind> {
    if is_hex_token(value, "fizz_stream_") {
        Some(CredentialKind::StreamToken)
    } else if is_hex_token(value, "fizz_agent_") {
        Some(CredentialKind::AgentToken)
    } else if is_hex_token(value, "fizz_") {
        Some(CredentialKind::SensorKey)
    } else {
        None
    }
}

fn is_hex_token(value: &str, prefix: &str) -> bool {
    value.starts_with(prefix)
        && value.len() == prefix.len() + 64
        && value.as_bytes()[prefix.len()..]
            .iter()
            .all(u8::is_ascii_hexdigit)
}

pub fn valid_uuid(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(i, c)| {
            if matches!(i, 8 | 13 | 18 | 23) {
                c == b'-'
            } else {
                c.is_ascii_hexdigit()
            }
        })
}

fn normalize_uuid(value: &str) -> Option<String> {
    valid_uuid(value).then(|| value.to_ascii_lowercase())
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TopicSide {
    Readings,
    Live,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AclOp {
    Publish,
    Subscribe,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Principal {
    /// A sensor API key, bound to that one sensor.
    Device { sensor_id: String },
    /// A stream grant or an agent token. `None` means every sensor of that customer.
    Viewer { sensor_id: Option<String> },
}

/// A topic is `fizz/v1/<sensor uuid>/readings` or `.../live`. Wildcards are rejected.
pub fn parse_topic(topic: &str) -> Result<(String, TopicSide), &'static str> {
    if topic.contains('+') || topic.contains('#') || topic.contains('\0') {
        return Err("Wildcards are not allowed.");
    }
    let rest = topic
        .strip_prefix(TOPIC_PREFIX)
        .ok_or("Topic must start with fizz/v1/.")?;
    let (sensor, side) = rest
        .rsplit_once('/')
        .ok_or("Topic must name a sensor and a side.")?;
    let sensor_id = normalize_uuid(sensor).ok_or("Topic sensor id must be a UUID.")?;
    let side = match side {
        "readings" => TopicSide::Readings,
        "live" => TopicSide::Live,
        _ => return Err("Topic must end in /readings or /live."),
    };
    Ok((sensor_id, side))
}

pub fn readings_topic(sensor_id: &str) -> String {
    format!("{TOPIC_PREFIX}{sensor_id}/readings")
}

pub fn live_topic(sensor_id: &str) -> String {
    format!("{TOPIC_PREFIX}{sensor_id}/live")
}

/// Returns the sensor id the topic names when this principal may perform `op`.
pub fn authorize(principal: &Principal, op: AclOp, topic: &str) -> Result<String, &'static str> {
    let (sensor_id, side) = parse_topic(topic)?;
    match (principal, op, side) {
        (Principal::Device { sensor_id: own }, AclOp::Publish, TopicSide::Readings)
        | (Principal::Device { sensor_id: own }, AclOp::Subscribe, TopicSide::Live)
            if own == &sensor_id =>
        {
            Ok(sensor_id)
        }
        (
            Principal::Viewer {
                sensor_id: Some(own),
            },
            AclOp::Subscribe,
            TopicSide::Live,
        ) if own == &sensor_id => Ok(sensor_id),
        (Principal::Viewer { sensor_id: None }, AclOp::Subscribe, TopicSide::Live) => Ok(sensor_id),
        (Principal::Viewer { .. }, AclOp::Publish, _) => Err("This credential cannot publish."),
        _ => Err("That topic is outside this credential."),
    }
}

/// The worker only forwards a stored row to a subscriber in the same workspace.
pub fn reading_visible(
    subscriber_customer: &str,
    subscriber_sensor: Option<&str>,
    row_customer: &str,
    row_sensor: &str,
) -> bool {
    subscriber_customer == row_customer
        && subscriber_sensor.is_none_or(|sensor| sensor == row_sensor)
}

#[derive(Clone, Debug, PartialEq)]
pub struct Reading {
    pub sensor_id: String,
    pub event_id: String,
    pub metrics: Map<String, Value>,
    pub observed_at: Option<String>,
}

fn valid_metric_name(metric: &str) -> bool {
    !metric.is_empty()
        && metric.len() <= MAX_METRIC_NAME_BYTES
        && metric.bytes().enumerate().all(|(i, c)| {
            if i == 0 {
                c.is_ascii_lowercase()
            } else {
                c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'_'
            }
        })
}

/// Structural checks shared with `/api/ingest`. The database still checks the sensor type.
pub fn parse_reading(value: &Value, topic_sensor: Option<&str>) -> Result<Reading, &'static str> {
    let body_sensor = value.get("sensor_id").and_then(Value::as_str);
    let sensor_raw = match (topic_sensor, body_sensor) {
        (Some(topic), Some(body)) if !topic.eq_ignore_ascii_case(body) => {
            return Err("The topic sensor and the body sensor disagree.");
        }
        (Some(topic), _) => topic,
        (None, Some(body)) => body,
        (None, None) => return Err("Send a sensor_id."),
    };
    let sensor_id = normalize_uuid(sensor_raw).ok_or("Check the sensor ID.")?;
    let event_id = value
        .get("event_id")
        .and_then(Value::as_str)
        .filter(|event| !event.is_empty() && event.len() <= MAX_EVENT_ID_BYTES)
        .ok_or("Check the event ID.")?;
    let metrics = value
        .get("metrics")
        .and_then(Value::as_object)
        .filter(|metrics| !metrics.is_empty() && metrics.len() <= MAX_METRICS)
        .ok_or("Send 1 to 16 metrics.")?;
    for (metric, item) in metrics {
        if !valid_metric_name(metric) {
            return Err("Metric names must use lowercase letters, digits, and underscores.");
        }
        if !matches!(item, Value::Number(_) | Value::Bool(_))
            && !matches!(item, Value::String(text) if text.len() <= MAX_TEXT_VALUE_BYTES)
        {
            return Err("Metric values must be numbers, booleans, or short text.");
        }
    }
    let observed_at = match value.get("observed_at").filter(|v| !v.is_null()) {
        None => None,
        Some(Value::String(stamp))
            if !stamp.is_empty() && stamp.len() <= 40 && !stamp.chars().any(char::is_control) =>
        {
            Some(stamp.clone())
        }
        Some(_) => return Err("observed_at must be a short timestamp."),
    };
    Ok(Reading {
        sensor_id,
        event_id: event_id.to_owned(),
        metrics: metrics.clone(),
        observed_at,
    })
}

pub fn reading_json(reading: &Reading) -> Value {
    let mut body = json!({
        "sensor_id": reading.sensor_id,
        "event_id": reading.event_id,
        "metrics": reading.metrics,
    });
    if let Some(stamp) = &reading.observed_at {
        body["observed_at"] = json!(stamp);
    }
    body
}

#[derive(Debug, PartialEq)]
pub enum ClientOp {
    Auth { key: String },
    Reading(Reading),
    Subscribe { sensor_id: Option<String> },
    Ping,
}

pub fn parse_client_message(value: &Value) -> Result<ClientOp, &'static str> {
    if !value.is_object() {
        return Err("Send a JSON object.");
    }
    match value.get("op").and_then(Value::as_str) {
        Some("auth") => {
            let key = value.get("key").and_then(Value::as_str).unwrap_or("");
            if classify_credential(key).is_none() {
                return Err("Send a sensor key, stream token, or agent token.");
            }
            Ok(ClientOp::Auth {
                key: key.to_owned(),
            })
        }
        Some("reading") => Ok(ClientOp::Reading(parse_reading(value, None)?)),
        Some("subscribe") => {
            let sensor_id = match value.get("sensor_id").filter(|item| !item.is_null()) {
                None => None,
                Some(Value::String(sensor)) => {
                    Some(normalize_uuid(sensor).ok_or("sensor_id must be a UUID.")?)
                }
                Some(_) => return Err("sensor_id must be a UUID."),
            };
            Ok(ClientOp::Subscribe { sensor_id })
        }
        Some("ping") => Ok(ClientOp::Ping),
        _ => Err("Unknown message. Use auth, reading, subscribe, or ping."),
    }
}

/// Drop `customer_id` before a row leaves the worker. Returns (customer, sensor, frame).
pub fn fanout_frame(row: &Value) -> Option<(String, String, String)> {
    let customer = normalize_uuid(row.get("customer_id").and_then(Value::as_str)?)?;
    let sensor = normalize_uuid(row.get("sensor_id").and_then(Value::as_str)?)?;
    let metric = row.get("metric").and_then(Value::as_str)?;
    if !valid_metric_name(metric) {
        return None;
    }
    let frame = json!({
        "op": "reading",
        "sensor_id": sensor,
        "event_id": row.get("event_id").and_then(Value::as_str).unwrap_or(""),
        "metric": metric,
        "numeric_value": row.get("numeric_value").cloned().unwrap_or(Value::Null),
        "boolean_value": row.get("boolean_value").cloned().unwrap_or(Value::Null),
        "text_value": row.get("text_value").cloned().unwrap_or(Value::Null),
        "unit": row.get("unit").cloned().unwrap_or(Value::Null),
        "observed_at": row.get("observed_at").cloned().unwrap_or(Value::Null),
        "received_at": row.get("received_at").cloned().unwrap_or(Value::Null),
        "source": row.get("source").and_then(Value::as_str).unwrap_or(""),
    });
    Some((customer, sensor, frame.to_string()))
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PrincipalFailure {
    Unauthorized,
    Paused,
    RateLimited,
    NotFound,
    Unavailable,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ResolvedPrincipal {
    pub principal: Principal,
    pub customer_id: String,
}

pub fn principal_from_json(value: &Value) -> Result<ResolvedPrincipal, PrincipalFailure> {
    if let Some(error) = value.get("error").and_then(Value::as_str) {
        return Err(match error {
            "paused" => PrincipalFailure::Paused,
            "rate_limited" => PrincipalFailure::RateLimited,
            "not_found" => PrincipalFailure::NotFound,
            "unauthorized" => PrincipalFailure::Unauthorized,
            _ => PrincipalFailure::Unavailable,
        });
    }
    let customer_id = value
        .get("customer_id")
        .and_then(Value::as_str)
        .and_then(normalize_uuid)
        .ok_or(PrincipalFailure::Unavailable)?;
    let sensor_id = match value.get("sensor_id") {
        None | Some(Value::Null) => None,
        Some(Value::String(sensor)) => {
            Some(normalize_uuid(sensor).ok_or(PrincipalFailure::Unavailable)?)
        }
        Some(_) => return Err(PrincipalFailure::Unavailable),
    };
    let principal = match value.get("role").and_then(Value::as_str) {
        Some("device") => Principal::Device {
            sensor_id: sensor_id.ok_or(PrincipalFailure::Unavailable)?,
        },
        Some("viewer") => Principal::Viewer { sensor_id },
        _ => return Err(PrincipalFailure::Unavailable),
    };
    Ok(ResolvedPrincipal {
        principal,
        customer_id,
    })
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StreamUrls {
    pub websocket_url: String,
    pub live_url: String,
    pub mqtt_ws_url: String,
}

/// `base` is the Compute service root, including a path prefix when the gateway adds one.
pub fn stream_urls(base: &str) -> Result<StreamUrls, &'static str> {
    let base = base.trim().trim_end_matches('/');
    let url = parse_stream_base(base)?;
    Ok(StreamUrls {
        websocket_url: join_ws(&url, "/v1/stream"),
        live_url: join_ws(&url, "/v1/live"),
        mqtt_ws_url: join_ws(&url, "/mqtt"),
    })
}

struct CheckedUrl {
    scheme: &'static str,
    host: String,
    port: Option<u16>,
    path: String,
}

fn parse_stream_base(base: &str) -> Result<CheckedUrl, &'static str> {
    if base.contains('#') || base.contains('?') || base.contains('@') || base.contains('\\') {
        return Err("The stream URL must be an https origin, optionally with a path prefix.");
    }
    let (scheme, rest) = base
        .split_once("://")
        .ok_or("The stream URL must start with https://.")?;
    let (host_port, path) = match rest.split_once('/') {
        Some((host, path)) => (host, format!("/{path}")),
        None => (rest, String::new()),
    };
    if host_port.is_empty() || !path_is_safe(&path) {
        return Err("The stream URL path is not usable.");
    }
    let (host, port) = split_host_port(host_port)?;
    let local = matches!(host.as_str(), "localhost" | "127.0.0.1" | "[::1]" | "::1");
    let scheme = match scheme {
        "https" => "wss",
        "http" if local => "ws",
        _ => return Err("The stream URL must be HTTPS (HTTP is allowed only on loopback)."),
    };
    if host.is_empty() || host.chars().any(char::is_control) {
        return Err("The stream URL must have a host.");
    }
    Ok(CheckedUrl {
        scheme,
        host,
        port,
        path,
    })
}

fn path_is_safe(path: &str) -> bool {
    path.is_empty()
        || path
            .trim_start_matches('/')
            .split('/')
            .all(|part| !part.is_empty() && part != "." && part != "..")
}

fn split_host_port(host_port: &str) -> Result<(String, Option<u16>), &'static str> {
    if let Some(host) = host_port.strip_prefix('[') {
        let (host, port) = host
            .split_once(']')
            .ok_or("The stream URL host is not usable.")?;
        let port = if let Some(port) = port.strip_prefix(':') {
            if port.is_empty() {
                return Err("The stream URL port is not usable.");
            }
            Some(
                port.parse()
                    .map_err(|_| "The stream URL port is not usable.")?,
            )
        } else if port.is_empty() {
            None
        } else {
            return Err("The stream URL host is not usable.");
        };
        return Ok((format!("[{host}]"), port));
    }
    if host_port.matches(':').count() > 1 {
        return Err("The stream URL host is not usable.");
    }
    match host_port.split_once(':') {
        Some((host, port)) => Ok((
            host.to_owned(),
            Some(
                port.parse()
                    .map_err(|_| "The stream URL port is not usable.")?,
            ),
        )),
        None => Ok((host_port.to_owned(), None)),
    }
}

fn join_ws(url: &CheckedUrl, suffix: &str) -> String {
    let port = url.port.map_or_default(|port| format!(":{port}"));
    format!(
        "{}://{}{}{}{}",
        url.scheme, url.host, port, url.path, suffix
    )
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HttpRoute {
    Health,
    Stream,
    Live,
    Mqtt,
}

pub fn http_route(path_and_query: &str) -> Option<HttpRoute> {
    let path = path_and_query.split(['?', '#']).next().unwrap_or("");
    if path.contains('\\') || path.split('/').any(|part| part == "..") {
        return None;
    }
    for (suffix, route) in [
        ("/v1/stream", HttpRoute::Stream),
        ("/v1/live", HttpRoute::Live),
        ("/mqtt", HttpRoute::Mqtt),
        ("/health", HttpRoute::Health),
    ] {
        // The suffix starts with '/', so a longer final segment such as /healthcare does not match.
        if path == suffix || path.ends_with(suffix) {
            return Some(route);
        }
    }
    None
}

// ---------------------------------------------------------------------------------------------
// MQTT 3.1.1. QoS 0 and QoS 1, no sessions, no wildcards.

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Packet {
    Connect {
        client_id: String,
        username: Option<String>,
        password: Option<String>,
        keep_alive: u16,
    },
    Connack {
        code: u8,
    },
    Publish {
        topic: String,
        payload: Vec<u8>,
        qos: u8,
        packet_id: Option<u16>,
    },
    Puback {
        packet_id: u16,
    },
    Subscribe {
        packet_id: u16,
        topics: Vec<String>,
    },
    Suback {
        packet_id: u16,
        codes: Vec<u8>,
    },
    Pingreq,
    Pingresp,
    Disconnect,
}

#[derive(Debug, PartialEq, Eq)]
pub enum DecodeError {
    Malformed,
    Unsupported,
}

/// `Ok(None)` means the buffer does not contain a whole packet yet.
pub fn decode_packet(buf: &[u8]) -> Result<Option<(Packet, usize)>, DecodeError> {
    if buf.is_empty() {
        return Ok(None);
    }
    let (remaining, varint_len) = match read_varint(&buf[1..]) {
        Some(value) => value,
        None if buf.len() < 5 => return Ok(None),
        None => return Err(DecodeError::Malformed),
    };
    if remaining > MAX_PACKET_BYTES {
        return Err(DecodeError::Malformed);
    }
    let header = 1 + varint_len;
    let total = header + remaining;
    if buf.len() < total {
        return Ok(None);
    }
    let body = &buf[header..total];
    let packet = decode_body(buf[0], body)?;
    Ok(Some((packet, total)))
}

fn decode_body(first: u8, body: &[u8]) -> Result<Packet, DecodeError> {
    match first >> 4 {
        1 => decode_connect(body),
        3 => decode_publish(first, body),
        8 if first == 0x82 => decode_subscribe(body),
        12 if first == 0xc0 && body.is_empty() => Ok(Packet::Pingreq),
        14 if first == 0xe0 && body.is_empty() => Ok(Packet::Disconnect),
        8 | 12 | 14 => Err(DecodeError::Malformed),
        _ => Err(DecodeError::Unsupported),
    }
}

fn decode_connect(body: &[u8]) -> Result<Packet, DecodeError> {
    let mut cursor = Cursor::new(body);
    let protocol = cursor.string()?;
    let level = cursor.u8()?;
    if protocol != "MQTT" || level != 4 {
        return Err(DecodeError::Unsupported);
    }
    let flags = cursor.u8()?;
    if flags & 0x01 != 0 || (flags & 0x40 != 0 && flags & 0x80 == 0) {
        return Err(DecodeError::Malformed);
    }
    let will = flags & 0x04 != 0;
    let will_qos = (flags >> 3) & 0x03;
    if will_qos == 3 || (!will && (will_qos != 0 || flags & 0x20 != 0)) {
        return Err(DecodeError::Malformed);
    }
    let keep_alive = cursor.u16()?;
    let client_id = cursor.string()?;
    if will {
        let _topic = cursor.string()?;
        let size = cursor.u16()? as usize;
        cursor.skip(size)?;
    }
    let username = if flags & 0x80 != 0 {
        Some(cursor.string()?)
    } else {
        None
    };
    let password = if flags & 0x40 != 0 {
        Some(cursor.string()?)
    } else {
        None
    };
    if !cursor.done() {
        return Err(DecodeError::Malformed);
    }
    Ok(Packet::Connect {
        client_id,
        username,
        password,
        keep_alive,
    })
}

fn decode_publish(first: u8, body: &[u8]) -> Result<Packet, DecodeError> {
    let qos = (first >> 1) & 0x03;
    if qos > 1 {
        return Err(DecodeError::Unsupported);
    }
    let mut cursor = Cursor::new(body);
    let topic = cursor.string()?;
    if topic.is_empty() || topic.len() > 256 {
        return Err(DecodeError::Malformed);
    }
    let packet_id = if qos == 1 { Some(cursor.u16()?) } else { None };
    let payload = cursor.rest().to_vec();
    Ok(Packet::Publish {
        topic,
        payload,
        qos,
        packet_id,
    })
}

fn decode_subscribe(body: &[u8]) -> Result<Packet, DecodeError> {
    let mut cursor = Cursor::new(body);
    let packet_id = cursor.u16()?;
    if packet_id == 0 {
        return Err(DecodeError::Malformed);
    }
    let mut topics = Vec::new();
    while !cursor.done() {
        let topic = cursor.string()?;
        let qos = cursor.u8()?;
        if topic.is_empty() || qos > 2 {
            return Err(DecodeError::Malformed);
        }
        topics.push(topic);
    }
    if topics.is_empty() || topics.len() > 16 {
        return Err(DecodeError::Malformed);
    }
    Ok(Packet::Subscribe { packet_id, topics })
}

pub fn encode_packet(packet: &Packet) -> Result<Vec<u8>, DecodeError> {
    let (first, body) = match packet {
        Packet::Connect {
            client_id,
            username,
            password,
            keep_alive,
        } => {
            let mut flags = 0x02;
            let mut payload = Vec::new();
            write_string(&mut payload, client_id)?;
            if let Some(username) = username {
                flags |= 0x80;
                write_string(&mut payload, username)?;
            }
            if let Some(password) = password {
                if username.is_none() {
                    return Err(DecodeError::Malformed);
                }
                flags |= 0x40;
                write_string(&mut payload, password)?;
            }
            let mut body = Vec::new();
            write_string(&mut body, "MQTT")?;
            body.push(4);
            body.push(flags);
            body.extend_from_slice(&keep_alive.to_be_bytes());
            body.extend(payload);
            (0x10, body)
        }
        Packet::Connack { code } => (0x20, vec![0, *code]),
        Packet::Publish {
            topic,
            payload,
            qos,
            packet_id,
        } => {
            if *qos > 1 || (*qos == 1) != packet_id.is_some() {
                return Err(DecodeError::Malformed);
            }
            let mut body = Vec::new();
            write_string(&mut body, topic)?;
            if let Some(packet_id) = packet_id {
                body.extend_from_slice(&packet_id.to_be_bytes());
            }
            body.extend(payload);
            (0x30 | (qos << 1), body)
        }
        Packet::Puback { packet_id } => (0x40, packet_id.to_be_bytes().to_vec()),
        Packet::Subscribe { packet_id, topics } => {
            if *packet_id == 0 || topics.is_empty() {
                return Err(DecodeError::Malformed);
            }
            let mut body = packet_id.to_be_bytes().to_vec();
            for topic in topics {
                write_string(&mut body, topic)?;
                body.push(0);
            }
            (0x82, body)
        }
        Packet::Suback { packet_id, codes } => {
            let mut body = packet_id.to_be_bytes().to_vec();
            body.extend(codes);
            (0x90, body)
        }
        Packet::Pingreq => (0xc0, Vec::new()),
        Packet::Pingresp => (0xd0, Vec::new()),
        Packet::Disconnect => (0xe0, Vec::new()),
    };
    if body.len() > MAX_PACKET_BYTES {
        return Err(DecodeError::Malformed);
    }
    let mut out = vec![first];
    write_varint(&mut out, body.len());
    out.extend(body);
    Ok(out)
}

struct Cursor<'a> {
    data: &'a [u8],
    index: usize,
}

impl<'a> Cursor<'a> {
    fn new(data: &'a [u8]) -> Self {
        Self { data, index: 0 }
    }
    fn done(&self) -> bool {
        self.index == self.data.len()
    }
    fn rest(&self) -> &'a [u8] {
        &self.data[self.index..]
    }
    fn u8(&mut self) -> Result<u8, DecodeError> {
        let byte = *self.data.get(self.index).ok_or(DecodeError::Malformed)?;
        self.index += 1;
        Ok(byte)
    }
    fn u16(&mut self) -> Result<u16, DecodeError> {
        let bytes = self.take(2)?;
        Ok(u16::from_be_bytes([bytes[0], bytes[1]]))
    }
    fn skip(&mut self, len: usize) -> Result<(), DecodeError> {
        self.take(len).map(|_| ())
    }
    fn take(&mut self, len: usize) -> Result<&'a [u8], DecodeError> {
        let end = self.index.checked_add(len).ok_or(DecodeError::Malformed)?;
        if end > self.data.len() {
            return Err(DecodeError::Malformed);
        }
        let slice = &self.data[self.index..end];
        self.index = end;
        Ok(slice)
    }
    fn string(&mut self) -> Result<String, DecodeError> {
        let len = self.u16()? as usize;
        let bytes = self.take(len)?;
        if bytes.contains(&0) {
            return Err(DecodeError::Malformed);
        }
        String::from_utf8(bytes.to_vec()).map_err(|_| DecodeError::Malformed)
    }
}

fn write_string(out: &mut Vec<u8>, value: &str) -> Result<(), DecodeError> {
    if value.len() > u16::MAX as usize || value.as_bytes().contains(&0) {
        return Err(DecodeError::Malformed);
    }
    out.extend_from_slice(&(value.len() as u16).to_be_bytes());
    out.extend_from_slice(value.as_bytes());
    Ok(())
}

fn read_varint(buf: &[u8]) -> Option<(usize, usize)> {
    let mut value = 0usize;
    let mut shift = 0;
    for i in 0..4 {
        let byte = *buf.get(i)? as usize;
        value += (byte & 0x7f) << shift;
        if byte & 0x80 == 0 {
            return (value <= MAX_PACKET_BYTES).then_some((value, i + 1));
        }
        shift += 7;
        if shift > 21 {
            return None;
        }
    }
    None
}

fn write_varint(out: &mut Vec<u8>, mut value: usize) {
    loop {
        let mut byte = (value & 0x7f) as u8;
        value >>= 7;
        if value > 0 {
            byte |= 0x80;
        }
        out.push(byte);
        if value == 0 {
            break;
        }
    }
}

pub fn ack_frame(event_id: &str) -> String {
    json!({"op": "ack", "event_id": event_id}).to_string()
}

pub fn error_frame(code: &str, event_id: Option<&str>) -> String {
    json!({"op": "error", "error": code, "event_id": event_id}).to_string()
}

pub fn nil_cursor() -> &'static str {
    NIL_UUID
}

#[cfg(test)]
mod tests {
    use super::*;

    const SENSOR: &str = "4f1c7e2a-9b3d-4c5e-8f6a-1b2c3d4e5f60";
    const OTHER: &str = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";

    fn device() -> Principal {
        Principal::Device {
            sensor_id: SENSOR.into(),
        }
    }

    #[test]
    fn credentials_do_not_collapse_into_sensor_keys() {
        let sensor = format!("fizz_{}", "ab".repeat(32));
        let agent = format!("fizz_agent_{}", "ab".repeat(32));
        let stream = format!("fizz_stream_{}", "cd".repeat(32));
        assert_eq!(
            classify_credential(&sensor),
            Some(CredentialKind::SensorKey)
        );
        assert_eq!(
            classify_credential(&agent),
            Some(CredentialKind::AgentToken)
        );
        assert_eq!(
            classify_credential(&stream),
            Some(CredentialKind::StreamToken)
        );
        assert_eq!(classify_credential("fizz_short"), None);
        assert_eq!(
            classify_credential(&format!("fizz_{}", "AB".repeat(32))),
            Some(CredentialKind::SensorKey)
        );
    }

    #[test]
    fn topics_are_isolated_to_the_principal() {
        let own_read = readings_topic(SENSOR);
        let own_live = live_topic(SENSOR);
        let other_read = readings_topic(OTHER);
        let other_live = live_topic(OTHER);
        assert_eq!(
            authorize(&device(), AclOp::Publish, &own_read).as_deref(),
            Ok(SENSOR)
        );
        assert_eq!(
            authorize(&device(), AclOp::Subscribe, &own_live).as_deref(),
            Ok(SENSOR)
        );
        assert!(authorize(&device(), AclOp::Publish, &other_read).is_err());
        assert!(authorize(&device(), AclOp::Subscribe, &other_live).is_err());
        assert!(authorize(&device(), AclOp::Publish, &own_live).is_err());
        assert!(authorize(&device(), AclOp::Subscribe, &own_read).is_err());
        assert!(parse_topic("fizz/v1/+/live").is_err());
        assert!(parse_topic(&format!("fizz/v1/{SENSOR}/live/#")).is_err());
        assert!(parse_topic(&format!("fizz/v1/{SENSOR}/secret")).is_err());

        let one = Principal::Viewer {
            sensor_id: Some(SENSOR.into()),
        };
        let workspace = Principal::Viewer { sensor_id: None };
        assert!(authorize(&one, AclOp::Publish, &own_read).is_err());
        assert_eq!(
            authorize(&one, AclOp::Subscribe, &own_live).as_deref(),
            Ok(SENSOR)
        );
        assert!(authorize(&one, AclOp::Subscribe, &other_live).is_err());
        assert_eq!(
            authorize(&workspace, AclOp::Subscribe, &other_live).as_deref(),
            Ok(OTHER)
        );
        assert!(authorize(&workspace, AclOp::Publish, &other_read).is_err());
    }

    #[test]
    fn fanout_never_crosses_workspaces_or_leaks_the_customer() {
        assert!(reading_visible("cust-a", None, "cust-a", SENSOR));
        assert!(reading_visible("cust-a", Some(SENSOR), "cust-a", SENSOR));
        assert!(!reading_visible("cust-a", None, "cust-b", SENSOR));
        assert!(!reading_visible("cust-a", Some(SENSOR), "cust-a", OTHER));
        let row = json!({
            "customer_id": SENSOR,
            "sensor_id": OTHER,
            "event_id": "e1",
            "metric": "temperature_c",
            "numeric_value": 21.5,
            "unit": "°C",
            "observed_at": "2026-11-11T00:00:00Z",
            "received_at": "2026-11-11T00:00:01Z",
            "source": "api"
        });
        let (customer, sensor, frame) = fanout_frame(&row).unwrap();
        assert_eq!((customer.as_str(), sensor.as_str()), (SENSOR, OTHER));
        assert!(!frame.contains("customer_id"));
        assert!(frame.contains("temperature_c"));
        assert!(fanout_frame(&json!({"sensor_id": SENSOR, "metric": "temperature_c"})).is_none());
    }

    #[test]
    fn readings_match_the_ingest_shape() {
        let value = json!({
            "sensor_id": SENSOR.to_uppercase(),
            "event_id": "e1",
            "metrics": {"temperature_c": 21.5, "door_open": true, "note": "ok"}
        });
        let reading = parse_reading(&value, None).unwrap();
        assert_eq!(reading.sensor_id, SENSOR);
        assert!(parse_reading(&value, Some(OTHER)).is_err());
        assert!(
            parse_reading(
                &json!({"sensor_id": SENSOR, "event_id": "e", "metrics": {}}),
                None
            )
            .is_err()
        );
        assert!(
            parse_reading(
                &json!({"sensor_id": SENSOR, "event_id": "e", "metrics": {"Temp": 1}}),
                None
            )
            .is_err()
        );
        assert!(parse_reading(&json!({"sensor_id": SENSOR, "event_id": "e", "metrics": {"note": "x".repeat(MAX_TEXT_VALUE_BYTES + 1)}}), None).is_err());
        let message =
            parse_client_message(&json!({"op": "auth", "key": format!("fizz_{}", "a".repeat(64))}))
                .unwrap();
        assert!(matches!(message, ClientOp::Auth { .. }));
        assert!(parse_client_message(&json!({"op": "subscribe", "sensor_id": SENSOR})).is_ok());
        assert!(parse_client_message(&json!({"op": "subscribe"})).is_ok());
        assert!(parse_client_message(&json!({"op": "nope"})).is_err());
    }

    #[test]
    fn principal_json_cannot_promote_a_viewer_into_a_device() {
        let viewer = principal_from_json(&json!({
            "role": "viewer",
            "customer_id": SENSOR,
            "sensor_id": null,
            "can_publish": true
        }))
        .unwrap();
        assert_eq!(viewer.principal, Principal::Viewer { sensor_id: None });
        assert!(authorize(&viewer.principal, AclOp::Publish, &readings_topic(OTHER)).is_err());
        let device = principal_from_json(&json!({
            "role": "device",
            "customer_id": OTHER,
            "sensor_id": SENSOR
        }))
        .unwrap();
        assert!(matches!(device.principal, Principal::Device { .. }));
        assert_eq!(
            principal_from_json(&json!({"error": "paused"})).unwrap_err(),
            PrincipalFailure::Paused
        );
        assert!(principal_from_json(&json!({"role": "device", "customer_id": SENSOR})).is_err());
    }

    #[test]
    fn stream_urls_keep_the_gateway_prefix_and_reject_secrets_in_the_url() {
        let urls =
            stream_urls("https://bbmdkpzzzalkvthwgsek.supabase.co/compute/v1/fizz-worker").unwrap();
        assert_eq!(
            urls.websocket_url,
            "wss://bbmdkpzzzalkvthwgsek.supabase.co/compute/v1/fizz-worker/v1/stream"
        );
        assert_eq!(
            urls.mqtt_ws_url,
            "wss://bbmdkpzzzalkvthwgsek.supabase.co/compute/v1/fizz-worker/mqtt"
        );
        assert!(stream_urls("http://fizzlayer.com").is_err());
        assert!(stream_urls("https://user:secret@fizzlayer.com").is_err());
        assert!(stream_urls("https://fizzlayer.com/../admin").is_err());
        let local = stream_urls("http://127.0.0.1:8080").unwrap();
        assert_eq!(local.live_url, "ws://127.0.0.1:8080/v1/live");
    }

    #[test]
    fn http_routes_ignore_a_gateway_prefix() {
        assert_eq!(
            http_route("/compute/v1/fizz-worker/v1/stream"),
            Some(HttpRoute::Stream)
        );
        assert_eq!(http_route("/health"), Some(HttpRoute::Health));
        assert_eq!(http_route("/mqtt?x=1"), Some(HttpRoute::Mqtt));
        assert_eq!(http_route("/v1/live"), Some(HttpRoute::Live));
        assert_eq!(http_route("/healthcare"), None);
        assert_eq!(http_route("/v1/stream/../mqtt"), None);
    }

    #[test]
    fn mqtt_packets_round_trip_and_reject_oversized_headers() {
        let connect = Packet::Connect {
            client_id: "pi".into(),
            username: Some(SENSOR.into()),
            password: Some(format!("fizz_{}", "ab".repeat(32))),
            keep_alive: 30,
        };
        let bytes = encode_packet(&connect).unwrap();
        assert_eq!(decode_packet(&bytes).unwrap().unwrap().0, connect);
        let publish = Packet::Publish {
            topic: readings_topic(SENSOR),
            payload: br#"{"event_id":"e1","metrics":{"temperature_c":22.4}}"#.to_vec(),
            qos: 1,
            packet_id: Some(7),
        };
        let bytes = encode_packet(&publish).unwrap();
        assert!(decode_packet(&bytes[..bytes.len() - 1]).unwrap().is_none());
        assert_eq!(decode_packet(&bytes).unwrap().unwrap().0, publish);
        let subscribe = Packet::Subscribe {
            packet_id: 9,
            topics: vec![live_topic(SENSOR)],
        };
        let bytes = encode_packet(&subscribe).unwrap();
        assert_eq!(decode_packet(&bytes).unwrap().unwrap().0, subscribe);
        assert_eq!(
            decode_packet(&encode_packet(&Packet::Pingreq).unwrap())
                .unwrap()
                .unwrap()
                .0,
            Packet::Pingreq
        );
        assert_eq!(
            decode_packet(&[0x10, 0xff, 0xff, 0xff, 0xff]).unwrap_err(),
            DecodeError::Malformed
        );
        let mut mqtt5 = encode_packet(&connect).unwrap();
        // Protocol level sits after the "MQTT" string: 2 length bytes + 4 chars, then level.
        let level_at = mqtt5.iter().position(|b| *b == 4).unwrap();
        mqtt5[level_at] = 5;
        assert_eq!(decode_packet(&mqtt5).unwrap_err(), DecodeError::Unsupported);
    }
}
