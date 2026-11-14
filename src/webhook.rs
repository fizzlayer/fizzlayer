//! Signed webhook delivery for alert notifications.
//!
//! The body is the raw JSON a receiver must verify. The signature is
//! HMAC-SHA256 of those exact bytes, in the `X-Fizzlayer-Signature` header
//! as `sha256=<hex>`. Receivers should compare the header to the HMAC of the
//! raw body and not rebuild the JSON.
//!
//! Only public HTTPS endpoints are called. Literal private, loopback, and
//! link-local addresses are refused, and so is a name that resolves to one.

use std::{
    net::{IpAddr, SocketAddr},
    time::Duration,
};

use reqwest::{Client, StatusCode};
use ring::hmac;
use serde_json::{Value, json};

pub const SIGNATURE_HEADER: &str = "X-Fizzlayer-Signature";
const TIMEOUT: Duration = Duration::from_secs(4);
const RETRY_BACKOFF: Duration = Duration::from_millis(250);

#[derive(Debug, PartialEq, Eq)]
pub enum WebhookBlock {
    Scheme,
    Userinfo,
    Host,
    Address,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WebhookTarget {
    pub url: String,
    pub host: String,
    pub port: u16,
    pub literal_ip: Option<IpAddr>,
}

#[derive(Debug)]
pub enum DeliveryError {
    /// The server redirected. Redirects are not followed. Do not retry.
    Redirect,
    /// A 4xx other than 429. Do not retry.
    Rejected(u16),
    /// Timeout, connection failure, 429, or 5xx. Retry.
    Transient(String),
}

pub fn sign(secret: &str, body: &[u8]) -> String {
    let key = hmac::Key::new(hmac::HMAC_SHA256, secret.as_bytes());
    let tag = hmac::sign(&key, body);
    format!("sha256={}", hex(tag.as_ref()))
}

/// Constant-time check of a `sha256=<hex>` header against the raw body.
pub fn signature_matches(secret: &str, body: &[u8], header: &str) -> bool {
    let expected = sign(secret, body);
    let presented = header.trim();
    if presented.len() != expected.len() {
        return false;
    }
    #[allow(deprecated)]
    {
        ring::constant_time::verify_slices_are_equal(presented.as_bytes(), expected.as_bytes())
            .is_ok()
    }
}

fn hex(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        out.push(DIGITS[(byte >> 4) as usize] as char);
        out.push(DIGITS[(byte & 0xf) as usize] as char);
    }
    out
}

/// True for loopback, private, link-local, documentation, and other
/// non-public addresses, including IPv4-mapped IPv6.
pub fn ip_is_blocked(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => {
            let [a, b, c, _] = v4.octets();
            v4.is_private()
                || v4.is_loopback()
                || v4.is_link_local()
                || v4.is_unspecified()
                || v4.is_multicast()
                || v4.is_broadcast()
                || v4.is_documentation()
                || a == 0
                || a >= 240
                || (a == 100 && (64..=127).contains(&b))
                || (a == 192 && b == 0 && c == 0)
        }
        IpAddr::V6(v6) => {
            if let Some(v4) = v6.to_ipv4_mapped() {
                return ip_is_blocked(IpAddr::V4(v4));
            }
            let o = v6.octets();
            v6.is_loopback()
                || v6.is_unspecified()
                || v6.is_multicast()
                || (o[0] & 0xfe) == 0xfc
                || (o[0] == 0xfe && (o[1] & 0xc0) == 0x80)
                || (o[0] == 0x20 && o[1] == 0x01 && o[2] == 0x0d && o[3] == 0xb8)
        }
    }
}

/// Accept a public HTTPS URL, or say why it is refused.
/// A hostname still has to be resolved before the request is sent.
pub fn webhook_target(raw: &str) -> Result<WebhookTarget, WebhookBlock> {
    let url = raw.trim();
    if url.len() < 12 || url.len() > 2000 {
        return Err(WebhookBlock::Host);
    }
    if url.chars().any(|c| c.is_whitespace() || c.is_control()) || url.contains('\\') {
        return Err(WebhookBlock::Host);
    }
    if url.contains('@') {
        return Err(WebhookBlock::Userinfo);
    }
    let Some(rest) = url.strip_prefix("https://") else {
        return Err(WebhookBlock::Scheme);
    };
    let authority = rest
        .split(['/', '?', '#'])
        .next()
        .filter(|part| !part.is_empty())
        .ok_or(WebhookBlock::Host)?;
    let (host, port) = split_host_port(authority)?;
    if host.is_empty() || host.len() > 253 {
        return Err(WebhookBlock::Host);
    }
    let literal_ip = if host.starts_with('[') {
        let inside = host
            .strip_prefix('[')
            .and_then(|value| value.strip_suffix(']'))
            .ok_or(WebhookBlock::Host)?;
        let ip: IpAddr = inside.parse().map_err(|_| WebhookBlock::Address)?;
        if ip_is_blocked(ip) {
            return Err(WebhookBlock::Address);
        }
        Some(ip)
    } else if let Ok(ip) = host.parse::<IpAddr>() {
        if ip_is_blocked(ip) {
            return Err(WebhookBlock::Address);
        }
        Some(ip)
    } else if host
        .bytes()
        .all(|byte| byte.is_ascii_digit() || byte == b'.')
    {
        return Err(WebhookBlock::Address);
    } else {
        if !public_hostname(&host.to_ascii_lowercase()) {
            return Err(WebhookBlock::Host);
        }
        None
    };
    Ok(WebhookTarget {
        url: url.to_owned(),
        host: host.trim_matches(['[', ']']).to_owned(),
        port,
        literal_ip,
    })
}

fn split_host_port(authority: &str) -> Result<(String, u16), WebhookBlock> {
    if let Some(host) = authority.strip_prefix('[') {
        let (host, rest) = host.split_once(']').ok_or(WebhookBlock::Host)?;
        if host.is_empty() {
            return Err(WebhookBlock::Host);
        }
        let port = if let Some(port) = rest.strip_prefix(':') {
            parse_port(port)?
        } else if rest.is_empty() {
            443
        } else {
            return Err(WebhookBlock::Host);
        };
        return Ok((format!("[{host}]"), port));
    }
    match authority.rsplit_once(':') {
        Some((host, port))
            if !host.is_empty() && port.bytes().all(|byte| byte.is_ascii_digit()) =>
        {
            Ok((host.to_owned(), parse_port(port)?))
        }
        Some(_) => Err(WebhookBlock::Host),
        None => Ok((authority.to_owned(), 443)),
    }
}

fn parse_port(port: &str) -> Result<u16, WebhookBlock> {
    let value: u16 = port.parse().map_err(|_| WebhookBlock::Host)?;
    if value == 0 {
        Err(WebhookBlock::Host)
    } else {
        Ok(value)
    }
}

fn public_hostname(host: &str) -> bool {
    if host.ends_with('.') || !host.contains('.') {
        return false;
    }
    let blocked = host == "localhost"
        || host == "localhost.localdomain"
        || host == "metadata.google.internal"
        || host.ends_with(".local")
        || host.ends_with(".localhost")
        || host.ends_with(".internal")
        || host.ends_with(".localdomain");
    if blocked {
        return false;
    }
    host.split('.').all(|label| {
        !label.is_empty()
            && label.len() <= 63
            && label
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
            && !label.starts_with('-')
            && !label.ends_with('-')
    })
}

/// The public address to connect to, or `Ok(None)` when any answer is not public.
/// `Err` means DNS failed and the send can be retried.
pub async fn public_address(target: &WebhookTarget) -> Result<Option<SocketAddr>, ()> {
    if let Some(ip) = target.literal_ip {
        return Ok((!ip_is_blocked(ip)).then_some(SocketAddr::new(ip, target.port)));
    }
    let addresses = tokio::net::lookup_host((target.host.as_str(), target.port))
        .await
        .map_err(|_| ())?;
    let mut chosen = None;
    let mut saw = false;
    for address in addresses {
        saw = true;
        if ip_is_blocked(address.ip()) {
            return Ok(None);
        }
        if chosen.is_none() {
            chosen = Some(address);
        }
    }
    if saw { Ok(chosen) } else { Err(()) }
}

pub fn alert_body(alert: &Value) -> Vec<u8> {
    let kind = match alert.get("event_kind").and_then(Value::as_str) {
        Some("silence") => "silence",
        Some("recovery") => "recovery",
        _ => "threshold",
    };
    let sensor = alert
        .get("sensor_name")
        .and_then(Value::as_str)
        .unwrap_or("A sensor")
        .chars()
        .filter(|c| !c.is_control())
        .take(80)
        .collect::<String>();
    serde_json::to_vec(&json!({
        "alert_id": alert.get("event_id").cloned().unwrap_or(Value::Null),
        "sensor": sensor,
        "metric": alert.get("metric").cloned().unwrap_or(Value::Null),
        "value": alert.get("numeric_value").cloned().unwrap_or(Value::Null),
        "threshold": alert.get("threshold").cloned().unwrap_or(Value::Null),
        "comparator": alert.get("comparator").cloned().unwrap_or(Value::Null),
        "fired_at": alert.get("observed_at").cloned().unwrap_or(Value::Null),
        "kind": kind,
    }))
    .unwrap_or_default()
}

pub fn email_text(alert: &Value) -> (String, String) {
    let body = alert_body(alert);
    let value: Value = serde_json::from_slice(&body).unwrap_or(json!({}));
    let sensor = value["sensor"].as_str().unwrap_or("A sensor");
    let subject = format!("Fizz alert: {sensor}");
    let fired = value["fired_at"].as_str().unwrap_or("");
    let id = value["alert_id"].as_str().unwrap_or("");
    let text = match value["kind"].as_str() {
        Some("silence") => format!(
            "{sensor} has not reported for {} minutes. The limit is {} minutes.\nFired at {fired}.\nAlert {id}.",
            number(&value["value"]),
            number(&value["threshold"])
        ),
        Some("recovery") => {
            format!("{sensor} is reporting again.\nFired at {fired}.\nAlert {id}.")
        }
        _ => format!(
            "{sensor} {} is {}, {} the limit of {}.\nFired at {fired}.\nAlert {id}.",
            value["metric"].as_str().unwrap_or("value"),
            number(&value["value"]),
            match value["comparator"].as_str() {
                Some("gt") => "above",
                Some("gte") => "at or above",
                Some("lt") => "below",
                _ => "at or below",
            },
            number(&value["threshold"])
        ),
    };
    (subject, text)
}

fn number(value: &Value) -> String {
    value
        .as_f64()
        .map_or_else(|| "unknown".to_owned(), |n| format!("{n}"))
}

/// One attempt plus one backoff retry. `address` is a public address from DNS,
/// and the client is pinned to it so a later lookup cannot swap in a private one.
pub async fn deliver(
    secret: &str,
    body: &[u8],
    target: &WebhookTarget,
    address: SocketAddr,
) -> Result<StatusCode, DeliveryError> {
    let client = Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(TIMEOUT)
        .connect_timeout(TIMEOUT)
        .resolve(&target.host, address)
        .build()
        .map_err(|error| DeliveryError::Transient(error.to_string()))?;
    match post_once(&client, target, secret, body).await {
        Ok(status) => Ok(status),
        Err(DeliveryError::Transient(_)) => {
            tokio::time::sleep(RETRY_BACKOFF).await;
            post_once(&client, target, secret, body).await
        }
        Err(other) => Err(other),
    }
}

async fn post_once(
    client: &Client,
    target: &WebhookTarget,
    secret: &str,
    body: &[u8],
) -> Result<StatusCode, DeliveryError> {
    let response = client
        .post(&target.url)
        .header(SIGNATURE_HEADER, sign(secret, body))
        .header("content-type", "application/json")
        .header("user-agent", "Fizzlayer-Alerts")
        .body(body.to_vec())
        .send()
        .await
        .map_err(|error| DeliveryError::Transient(error.to_string()))?;
    let status = response.status();
    if status.is_success() {
        Ok(status)
    } else if status.is_redirection() {
        Err(DeliveryError::Redirect)
    } else if status == StatusCode::TOO_MANY_REQUESTS || status.is_server_error() {
        Err(DeliveryError::Transient(format!(
            "HTTP {}",
            status.as_u16()
        )))
    } else {
        Err(DeliveryError::Rejected(status.as_u16()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SECRET: &str = "example-webhook-secret";
    const BODY: &[u8] = br#"{"alert_id":"11111111-1111-4111-8111-111111111111","comparator":"gt","fired_at":"2026-11-14T08:00:00Z","kind":"threshold","metric":"temperature_c","sensor":"Freezer","threshold":-10,"value":-8}"#;
    const SIGNATURE: &str =
        "sha256=ebc5fdfaddde22005a1439060644e145a22fbe8926ff5a8a17cbb98bd65b4785";

    #[test]
    fn signature_is_hmac_sha256_of_the_raw_body() {
        assert_eq!(sign(SECRET, BODY), SIGNATURE);
        assert!(signature_matches(SECRET, BODY, SIGNATURE));
        assert!(signature_matches(SECRET, BODY, &format!("  {SIGNATURE}  ")));
        assert!(!signature_matches(SECRET, BODY, "sha256=00"));
        assert!(!signature_matches("other-webhook-secret", BODY, SIGNATURE));
        let mut flipped = BODY.to_vec();
        flipped[0] ^= 0x01;
        assert!(!signature_matches(SECRET, &flipped, SIGNATURE));
    }

    #[test]
    fn alert_body_uses_threshold_silence_or_recovery() {
        let bytes = alert_body(&json!({
            "event_id": "11111111-1111-4111-8111-111111111111",
            "sensor_name": "Freezer",
            "metric": "temperature_c",
            "numeric_value": -8,
            "threshold": -10,
            "comparator": "gt",
            "observed_at": "2026-11-14T08:00:00Z",
            "event_kind": "threshold"
        }));
        let value: Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(value["kind"], "threshold");
        assert_eq!(value["alert_id"], "11111111-1111-4111-8111-111111111111");
        assert_eq!(value["sensor"], "Freezer");
        assert_eq!(value["metric"], "temperature_c");
        assert_eq!(value["comparator"], "gt");
        assert_eq!(value["fired_at"], "2026-11-14T08:00:00Z");
        assert!(signature_matches(SECRET, &bytes, &sign(SECRET, &bytes)));

        let silence = alert_body(&json!({"event_kind": "silence", "sensor_name": "Closet"}));
        assert_eq!(
            serde_json::from_slice::<Value>(&silence).unwrap()["kind"],
            "silence"
        );
        let recovery = alert_body(&json!({"event_kind": "recovery"}));
        assert_eq!(
            serde_json::from_slice::<Value>(&recovery).unwrap()["kind"],
            "recovery"
        );
    }

    #[test]
    fn ssrf_guard_refuses_non_https_and_private_addresses() {
        assert_eq!(
            webhook_target("http://alerts.example.com/hook").unwrap_err(),
            WebhookBlock::Scheme
        );
        assert_eq!(
            webhook_target("https://user:pass@alerts.example.com/hook").unwrap_err(),
            WebhookBlock::Userinfo
        );
        for blocked in [
            "https://localhost/hook",
            "https://localhost.localdomain/hook",
            "https://printer.local/hook",
            "https://db.internal/hook",
            "https://metadata.google.internal/hook",
            "https://closet/hook",
        ] {
            assert_eq!(
                webhook_target(blocked).unwrap_err(),
                WebhookBlock::Host,
                "{blocked}"
            );
        }
        for blocked in [
            "https://127.0.0.1/hook",
            "https://127.0.0.8:8443/hook",
            "https://10.1.2.3/hook",
            "https://192.168.1.20/hook",
            "https://172.16.0.1/hook",
            "https://172.31.255.255/hook",
            "https://169.254.169.254/latest",
            "https://0.0.0.0/hook",
            "https://100.64.0.1/hook",
            "https://[::1]/hook",
            "https://[fd00::1]/hook",
            "https://[fe80::1]/hook",
            "https://[::ffff:127.0.0.1]/hook",
            "https://[::ffff:10.0.0.1]/hook",
        ] {
            assert_eq!(
                webhook_target(blocked).unwrap_err(),
                WebhookBlock::Address,
                "{blocked}"
            );
        }
        let ok = webhook_target("https://alerts.example.com/fizz?x=1").unwrap();
        assert_eq!(ok.host, "alerts.example.com");
        assert_eq!(ok.port, 443);
        assert_eq!(
            webhook_target("https://alerts.example.com:8443/fizz")
                .unwrap()
                .port,
            8443
        );
        assert!(webhook_target("https://8.8.8.8/hook").is_ok());
        assert!(webhook_target("https://172.15.0.1/hook").is_ok());
        assert!(webhook_target("https://172.32.0.1/hook").is_ok());
        assert!(webhook_target("https://[2001:4860:4860::8888]/hook").is_ok());
        assert!(ip_is_blocked("127.0.0.1".parse().unwrap()));
        assert!(ip_is_blocked("10.0.0.1".parse().unwrap()));
        assert!(ip_is_blocked("192.168.0.1".parse().unwrap()));
        assert!(ip_is_blocked("169.254.169.254".parse().unwrap()));
        assert!(!ip_is_blocked("1.1.1.1".parse().unwrap()));
        assert!(!ip_is_blocked("8.8.8.8".parse().unwrap()));
    }
}
