//! Discover the Compute stream endpoint and mint a short-lived subscribe token.
//! Devices still publish with their sensor key. This route never accepts readings.

use serde_json::{Value, json};
use vercel_runtime::{Request, Response, ResponseBody};

use crate::{
    customer::{ApiError, error, json_body, reply, session_token},
    live::{CredentialKind, classify_credential, stream_urls},
    sensors::valid_uuid,
    store::Supabase,
};

fn bearer(request: &Request) -> Option<&str> {
    request
        .headers()
        .get("authorization")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "))
        .filter(|value| !value.is_empty())
}

fn urls() -> Result<Option<crate::live::StreamUrls>, ApiError> {
    match std::env::var("FIZZ_STREAM_URL") {
        Err(_) => Ok(None),
        Ok(value) if value.trim().is_empty() => Ok(None),
        Ok(value) => stream_urls(value.trim())
            .map(Some)
            .map_err(|_| ApiError::new(503, "unavailable", "Live streaming is misconfigured.")),
    }
}

fn describe(urls: &crate::live::StreamUrls) -> Value {
    json!({
        "enabled": true,
        "websocket_url": urls.websocket_url,
        "live_url": urls.live_url,
        "mqtt_ws_url": urls.mqtt_ws_url,
        "mqtt_tcp_url": std::env::var("FIZZ_MQTT_TCP_URL").ok().filter(|value| !value.trim().is_empty()),
    })
}

#[must_use]
pub fn config() -> Response<ResponseBody> {
    match urls() {
        Ok(Some(urls)) => reply(200, describe(&urls), None),
        Ok(None) => reply(200, json!({"enabled": false}), None),
        Err(failure) => failure.into_response(),
    }
}

pub async fn issue(request: Request) -> Response<ResponseBody> {
    let Some(urls) = (match urls() {
        Ok(urls) => urls,
        Err(failure) => return failure.into_response(),
    }) else {
        return error(
            503,
            "unavailable",
            "Live streaming is not configured on this Fizzlayer.",
        );
    };
    let session = session_token(&request);
    let agent = bearer(&request)
        .filter(|token| classify_credential(token) == Some(CredentialKind::AgentToken))
        .map(str::to_owned);
    if session.is_none() && agent.is_none() {
        return error(
            401,
            "unauthorized",
            "Sign in, or use an agent token, to subscribe.",
        );
    }
    let data = match json_body(request, 2048).await {
        Ok(value) => value,
        Err(failure) => return failure.into_response(),
    };
    let sensor = match data.get("sensor_id").filter(|value| !value.is_null()) {
        None => None,
        Some(Value::String(sensor)) if valid_uuid(sensor) => Some(sensor.to_ascii_lowercase()),
        Some(_) => {
            return error(400, "invalid_request", "sensor_id must be a sensor UUID.");
        }
    };
    let Ok(store) = Supabase::from_env() else {
        return error(
            503,
            "database_unavailable",
            "Live streaming is temporarily unavailable.",
        );
    };
    let (function, payload) = if let Some(token) = agent {
        (
            "fizz_stream_issue_agent",
            json!({"p_agent_token": token, "p_sensor_id": sensor}),
        )
    } else {
        (
            "fizz_stream_issue",
            json!({"p_token": session, "p_sensor_id": sensor}),
        )
    };
    match store.rpc(function, payload).await {
        Ok(value) => outcome(value, &urls),
        Err(_) => error(
            503,
            "database_unavailable",
            "Live streaming is temporarily unavailable.",
        ),
    }
}

fn outcome(value: Value, urls: &crate::live::StreamUrls) -> Response<ResponseBody> {
    match value.get("error").and_then(Value::as_str) {
        Some("unauthorized") => error(401, "unauthorized", "Sign in to subscribe."),
        Some("not_found") => error(404, "not_found", "Sensor not found."),
        Some("rate_limited") => error(
            429,
            "rate_limited",
            "Too many stream tokens. Try again later.",
        ),
        None if value.get("token").and_then(Value::as_str).is_some() => {
            let mut body = value;
            if let Some(object) = body.as_object_mut() {
                object.insert("enabled".into(), json!(true));
                object.insert("websocket_url".into(), json!(urls.websocket_url));
                object.insert("live_url".into(), json!(urls.live_url));
                object.insert("mqtt_ws_url".into(), json!(urls.mqtt_ws_url));
            }
            reply(201, body, None)
        }
        // Unknown errors and a missing token are the same client-facing failure.
        Some(_) | None => error(
            503,
            "database_unavailable",
            "Live streaming is temporarily unavailable.",
        ),
    }
}
