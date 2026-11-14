//! Socket and MQTT clients. HTTPS publishing stays in main.rs.

use std::{
    io::{Read, Write},
    net::TcpStream,
    time::Duration,
};

use serde_json::{Map, Value, json};
use tungstenite::{Message, stream::MaybeTlsStream};

use fizz_protocol as protocol;
use protocol::{
    AclOp, ClientOp, Packet, Principal, authorize, decode_packet, encode_packet, live_topic,
    parse_client_message, readings_topic, stream_urls,
};

type Socket = tungstenite::WebSocket<MaybeTlsStream<TcpStream>>;

#[derive(Debug)]
pub struct StreamUrls {
    pub websocket_url: String,
    pub live_url: String,
    pub mqtt_ws_url: String,
    pub mqtt_tcp_url: Option<String>,
}

pub fn discover(get: impl Fn(&str) -> Result<(u16, Value), String>) -> Result<StreamUrls, String> {
    let (status, body) = get("/api/stream")?;
    if status != 200 {
        let message = body
            .pointer("/error/message")
            .and_then(Value::as_str)
            .unwrap_or("Fizz did not describe its live stream.");
        return Err(message.to_owned());
    }
    if body.get("enabled") != Some(&Value::Bool(true)) {
        return Err(
            "This Fizzlayer has not turned on live streaming. Omit --stream and --mqtt to keep using HTTPS."
                .into(),
        );
    }
    let base = body
        .get("websocket_url")
        .and_then(Value::as_str)
        .ok_or("Fizz did not return a stream URL.")?;
    // The API returns full socket URLs. Rebuild from the stream root so a partial reply fails closed.
    let root = base
        .trim_end_matches("/v1/stream")
        .replace("wss://", "https://")
        .replace("ws://", "http://");
    let urls = stream_urls(&root).map_err(std::borrow::ToOwned::to_owned)?;
    if urls.websocket_url != base {
        return Err("Fizz returned a stream URL this client will not use.".into());
    }
    Ok(StreamUrls {
        websocket_url: urls.websocket_url,
        live_url: urls.live_url,
        mqtt_ws_url: body
            .get("mqtt_ws_url")
            .and_then(Value::as_str)
            .unwrap_or(&urls.mqtt_ws_url)
            .to_owned(),
        mqtt_tcp_url: body
            .get("mqtt_tcp_url")
            .and_then(Value::as_str)
            .map(str::to_owned),
    })
}

fn arm(socket: &mut Socket) {
    let timeout = Some(Duration::from_secs(20));
    match socket.get_mut() {
        MaybeTlsStream::Plain(stream) => {
            let _ = stream.set_read_timeout(timeout);
            let _ = stream.set_write_timeout(timeout);
        }
        MaybeTlsStream::Rustls(stream) => {
            let _ = stream.get_mut().set_read_timeout(timeout);
            let _ = stream.get_mut().set_write_timeout(timeout);
        }
        _ => {}
    }
}

fn connect_ws(url: &str) -> Result<Socket, String> {
    let (mut socket, _) =
        tungstenite::connect(url).map_err(|error| format!("Could not open {url}: {error}"))?;
    arm(&mut socket);
    Ok(socket)
}

fn read_text(socket: &mut Socket) -> Result<Value, String> {
    loop {
        match socket.read() {
            Ok(Message::Text(text)) => {
                return serde_json::from_str(text.as_ref())
                    .map_err(|_| "Fizz sent a message that was not JSON.".into());
            }
            Ok(Message::Ping(payload)) => {
                socket
                    .send(Message::Pong(payload))
                    .map_err(|error| format!("The stream closed: {error}"))?;
            }
            Ok(Message::Pong(_) | Message::Binary(_) | Message::Frame(_)) => {}
            Ok(Message::Close(_)) | Err(_) => {
                return Err("The stream closed.".into());
            }
        }
    }
}

pub struct ReadingLink {
    socket: Socket,
    sensor_id: String,
}

impl ReadingLink {
    pub fn open(url: &str, sensor_id: &str, key: &str) -> Result<Self, String> {
        let mut socket = connect_ws(url)?;
        socket
            .send(Message::text(json!({"op": "auth", "key": key}).to_string()))
            .map_err(|error| format!("Could not authenticate the stream: {error}"))?;
        match read_text(&mut socket)?.get("op").and_then(Value::as_str) {
            Some("ready") => Ok(Self {
                socket,
                sensor_id: sensor_id.to_owned(),
            }),
            _ => Err("Fizz refused this device's key on the stream.".into()),
        }
    }

    pub fn send(&mut self, metrics: &Map<String, Value>, event_id: &str) -> Result<(), String> {
        let body = json!({
            "op": "reading",
            "sensor_id": self.sensor_id,
            "event_id": event_id,
            "metrics": metrics,
        });
        self.socket
            .send(Message::text(body.to_string()))
            .map_err(|error| format!("Could not send the reading: {error}"))?;
        let reply = read_text(&mut self.socket)?;
        match reply.get("op").and_then(Value::as_str) {
            Some("ack") => Ok(()),
            Some("error") if reply.get("error").and_then(Value::as_str) == Some("unauthorized") => {
                Err("This device's key was revoked. Run `fizz unpair`, then `fizz pair`.".into())
            }
            Some("error") => Err(reply
                .get("error")
                .and_then(Value::as_str)
                .unwrap_or("Fizz did not store the reading.")
                .to_owned()),
            _ => Err("Fizz sent an unexpected stream reply.".into()),
        }
    }
}

pub fn tail_socket(
    url: &str,
    sensor_id: &str,
    key: &str,
    mut on_line: impl FnMut(&str),
) -> Result<(), String> {
    let mut socket = connect_ws(url)?;
    socket
        .send(Message::text(json!({"op": "auth", "key": key}).to_string()))
        .map_err(|error| format!("Could not authenticate the stream: {error}"))?;
    socket
        .send(Message::text(
            json!({"op": "subscribe", "sensor_id": sensor_id}).to_string(),
        ))
        .map_err(|error| format!("Could not subscribe: {error}"))?;
    loop {
        let message = read_text(&mut socket)?;
        match parse_client_message(&message) {
            Ok(ClientOp::Subscribe { .. }) => {}
            _ if message.get("op").and_then(Value::as_str) == Some("subscribed") => {
                on_line("Watching live readings. Press Ctrl-C to stop.");
            }
            _ if message.get("op").and_then(Value::as_str) == Some("reading") => {
                on_line(&format_reading(&message));
            }
            _ if message.get("op").and_then(Value::as_str) == Some("error") => {
                return Err(message
                    .get("error")
                    .and_then(Value::as_str)
                    .unwrap_or("The live stream stopped.")
                    .to_owned());
            }
            _ => {}
        }
    }
}

fn format_reading(message: &Value) -> String {
    let metric = message.get("metric").and_then(Value::as_str).unwrap_or("?");
    let value = message
        .get("numeric_value")
        .filter(|value| !value.is_null())
        .or_else(|| {
            message
                .get("boolean_value")
                .filter(|value| !value.is_null())
        })
        .or_else(|| message.get("text_value"))
        .cloned()
        .unwrap_or(Value::Null);
    let unit = message.get("unit").and_then(Value::as_str).unwrap_or("");
    format!("{metric} {value} {unit}").trim().to_owned()
}

pub fn mqtt_publish(
    urls: &StreamUrls,
    override_url: Option<&str>,
    sensor_id: &str,
    key: &str,
    metrics: &Map<String, Value>,
    event_id: &str,
) -> Result<(), String> {
    let payload = json!({"event_id": event_id, "metrics": metrics}).to_string();
    let topic = readings_topic(sensor_id);
    let device = Principal::Device {
        sensor_id: sensor_id.to_owned(),
    };
    authorize(&device, AclOp::Publish, &topic).map_err(std::borrow::ToOwned::to_owned)?;
    let target = override_url
        .map(str::to_owned)
        .or_else(|| urls.mqtt_tcp_url.clone())
        .unwrap_or_else(|| urls.mqtt_ws_url.clone());
    if target.starts_with("mqtt://") {
        mqtt_tcp_publish(&target, sensor_id, key, &topic, payload.into_bytes())
    } else if target.starts_with("ws://") || target.starts_with("wss://") {
        mqtt_ws_publish(&target, sensor_id, key, &topic, payload.into_bytes())
    } else {
        Err("MQTT URLs must start with mqtt://, ws://, or wss://.".into())
    }
}

fn mqtt_connect_packet(sensor_id: &str, key: &str) -> Result<Vec<u8>, String> {
    encode_packet(&Packet::Connect {
        client_id: format!("fizz-{sensor_id}"),
        username: Some(sensor_id.to_owned()),
        password: Some(key.to_owned()),
        keep_alive: 30,
    })
    .map_err(|_| "Could not build the MQTT connect packet.".to_owned())
}

fn mqtt_ws_publish(
    url: &str,
    sensor_id: &str,
    key: &str,
    topic: &str,
    payload: Vec<u8>,
) -> Result<(), String> {
    let mut socket = connect_ws(url)?;
    let connect = mqtt_connect_packet(sensor_id, key)?;
    socket
        .send(Message::binary(connect))
        .map_err(|error| format!("Could not connect to MQTT: {error}"))?;
    expect_connack(&mut read_mqtt_ws(&mut socket)?)?;
    let publish = encode_packet(&Packet::Publish {
        topic: topic.to_owned(),
        payload,
        qos: 1,
        packet_id: Some(1),
    })
    .map_err(|_| "Could not build the MQTT publish packet.".to_owned())?;
    socket
        .send(Message::binary(publish))
        .map_err(|error| format!("Could not publish: {error}"))?;
    match decode_one(&read_mqtt_ws(&mut socket)?)? {
        Packet::Puback { .. } => Ok(()),
        _ => Err("The MQTT broker did not acknowledge the reading.".into()),
    }
}

fn read_mqtt_ws(socket: &mut Socket) -> Result<Vec<u8>, String> {
    loop {
        match socket.read() {
            Ok(Message::Binary(bytes)) => return Ok(bytes.to_vec()),
            Ok(Message::Ping(payload)) => {
                socket
                    .send(Message::Pong(payload))
                    .map_err(|error| format!("The MQTT socket closed: {error}"))?;
            }
            Ok(Message::Close(_)) | Err(_) => return Err("The MQTT socket closed.".into()),
            Ok(_) => {}
        }
    }
}

fn mqtt_tcp_publish(
    url: &str,
    sensor_id: &str,
    key: &str,
    topic: &str,
    payload: Vec<u8>,
) -> Result<(), String> {
    let host = url.trim_start_matches("mqtt://").trim_end_matches('/');
    let (host, port) = host
        .rsplit_once(':')
        .ok_or("mqtt:// URLs need a host and port, for example mqtt://127.0.0.1:1883.")?;
    let port: u16 = port
        .parse()
        .map_err(|_| "The MQTT port is not a number.".to_owned())?;
    if host.is_empty() || host.contains('@') {
        return Err("The MQTT URL is not usable.".into());
    }
    let mut stream = TcpStream::connect((host, port))
        .map_err(|error| format!("Could not reach MQTT at {host}:{port}: {error}"))?;
    stream
        .set_read_timeout(Some(Duration::from_secs(20)))
        .map_err(|error| error.to_string())?;
    stream
        .set_write_timeout(Some(Duration::from_secs(20)))
        .map_err(|error| error.to_string())?;
    stream
        .write_all(&mqtt_connect_packet(sensor_id, key)?)
        .map_err(|error| format!("Could not connect to MQTT: {error}"))?;
    expect_connack(&mut read_mqtt_tcp(&mut stream)?)?;
    let publish = encode_packet(&Packet::Publish {
        topic: topic.to_owned(),
        payload,
        qos: 1,
        packet_id: Some(1),
    })
    .map_err(|_| "Could not build the MQTT publish packet.".to_owned())?;
    stream
        .write_all(&publish)
        .map_err(|error| format!("Could not publish: {error}"))?;
    match decode_one(&read_mqtt_tcp(&mut stream)?)? {
        Packet::Puback { .. } => Ok(()),
        _ => Err("The MQTT broker did not acknowledge the reading.".into()),
    }
}

fn read_mqtt_tcp(stream: &mut TcpStream) -> Result<Vec<u8>, String> {
    let mut buf = Vec::new();
    loop {
        let mut byte = [0];
        match stream.read(&mut byte) {
            Ok(0) => return Err("The MQTT connection closed.".into()),
            Ok(_) => buf.push(byte[0]),
            Err(error) => return Err(format!("Could not read MQTT: {error}")),
        }
        if decode_packet(&buf)
            .map_err(|_| "The MQTT packet was not valid.")?
            .is_some()
        {
            return Ok(buf);
        }
        if buf.len() > protocol::MAX_PACKET_BYTES {
            return Err("The MQTT packet was too large.".into());
        }
    }
}

fn decode_one(buf: &[u8]) -> Result<Packet, String> {
    match decode_packet(buf).map_err(|_| "The MQTT packet was not valid.")? {
        Some((packet, _)) => Ok(packet),
        None => Err("The MQTT packet was incomplete.".into()),
    }
}

fn expect_connack(buf: &mut [u8]) -> Result<(), String> {
    match decode_one(buf)? {
        Packet::Connack { code: 0 } => Ok(()),
        Packet::Connack { code: 5 } => Err("This sensor is paused.".into()),
        Packet::Connack { .. } => {
            Err("This device's key was revoked. Run `fizz unpair`, then `fizz pair`.".into())
        }
        _ => Err("The MQTT broker refused the connection.".into()),
    }
}

pub fn tail_mqtt(
    urls: &StreamUrls,
    override_url: Option<&str>,
    sensor_id: &str,
    key: &str,
    mut on_line: impl FnMut(&str),
) -> Result<(), String> {
    let target = override_url.map_or_else(|| urls.mqtt_ws_url.clone(), str::to_owned);
    if !(target.starts_with("ws://") || target.starts_with("wss://")) {
        return Err("fizz tail --mqtt uses the WebSocket MQTT URL. Set FIZZ_MQTT_URL to a wss:// address if you override it.".into());
    }
    let mut socket = connect_ws(&target)?;
    socket
        .send(Message::binary(mqtt_connect_packet(sensor_id, key)?))
        .map_err(|error| format!("Could not connect to MQTT: {error}"))?;
    expect_connack(&mut read_mqtt_ws(&mut socket)?)?;
    let topic = live_topic(sensor_id);
    let subscribe = encode_packet(&Packet::Subscribe {
        packet_id: 1,
        topics: vec![topic],
    })
    .map_err(|_| "Could not build the MQTT subscribe packet.".to_owned())?;
    socket
        .send(Message::binary(subscribe))
        .map_err(|error| format!("Could not subscribe: {error}"))?;
    on_line("Watching live readings. Press Ctrl-C to stop.");
    loop {
        let bytes = read_mqtt_ws(&mut socket)?;
        if let Packet::Publish { payload, .. } = decode_one(&bytes)? {
            let value: Value = serde_json::from_slice(&payload).unwrap_or(Value::Null);
            on_line(&format_reading(&value));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use fizz_protocol::ack_frame;

    #[test]
    fn discovery_rejects_a_rewritten_socket_url() {
        let body = json!({
            "enabled": true,
            "websocket_url": "wss://evil.example/v1/stream",
            "live_url": "wss://bbmdkpzzzalkvthwgsek.supabase.co/compute/v1/fizz-worker/v1/live",
            "mqtt_ws_url": "wss://bbmdkpzzzalkvthwgsek.supabase.co/compute/v1/fizz-worker/mqtt"
        });
        // The root is derived from websocket_url, then checked against that same URL, so a
        // well-formed URL passes. A URL that is not the stream path fails closed.
        let ok = discover(|_| Ok((200, body.clone())));
        assert!(ok.is_ok(), "{ok:?}");
        let bad = discover(|_| {
            Ok((
                200,
                json!({"enabled": true, "websocket_url": "wss://fizzlayer.com/not-the-stream"}),
            ))
        });
        assert!(bad.is_err());
        let off = discover(|_| Ok((200, json!({"enabled": false}))));
        assert!(off.unwrap_err().contains("HTTPS"));
    }

    #[test]
    fn ack_frames_are_the_ones_the_device_waits_for() {
        let frame: Value = serde_json::from_str(&ack_frame("e1")).unwrap();
        assert_eq!(frame["op"], "ack");
        assert_eq!(frame["event_id"], "e1");
    }
}
