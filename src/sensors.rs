use serde_json::{Value, json};
use vercel_runtime::{Request, Response, ResponseBody};

use crate::{
    customer::{ApiError, error, reply, session_token},
    notify,
    store::Supabase,
};

pub(crate) const KINDS: [&str; 9] = [
    "water",
    "gas",
    "radio",
    "temperature",
    "pressure",
    "humidity",
    "sound",
    "phone",
    "custom",
];

#[must_use]
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

/// Sensor endpoints have used `request_too_large` for oversized bodies since launch.
async fn body(request: Request, max: usize) -> Result<Value, ApiError> {
    crate::customer::json_body_with(request, max, "request_too_large").await
}

/// `message` is the sentence this caller shows. Ingest and the dashboard
/// describe the same outage differently.
fn db(message: &'static str) -> Result<Supabase, ApiError> {
    Supabase::from_env().map_err(|_| ApiError::new(503, "database_unavailable", message))
}

fn outcome(value: Value, success: u16) -> Response<ResponseBody> {
    match value.get("error").and_then(Value::as_str) {
        Some("unauthorized") => error(401, "unauthorized", "Sign in to continue."),
        Some("rate_limited") => error(
            429,
            "rate_limited",
            "Reading limit reached. Try again later.",
        ),
        Some("not_found") => error(404, "not_found", "Sensor not found."),
        Some("device_limit") => crate::customer::device_limit(),
        Some("invalid_request" | "invalid_reading") => {
            error(400, "invalid_request", "Check the sensor details.")
        }
        Some(_) => error(
            503,
            "database_unavailable",
            "Sensor data is temporarily unavailable.",
        ),
        None => reply(success, value, None),
    }
}

pub async fn list(request: Request) -> Response<ResponseBody> {
    let Some(token) = session_token(&request) else {
        return error(401, "unauthorized", "Sign in to continue.");
    };
    let store = match db("Sensor data is temporarily unavailable.") {
        Ok(store) => store,
        Err(failure) => return failure.into_response(),
    };
    match store
        .rpc("fizz_tick_simulated", json!({"p_token":token}))
        .await
    {
        Ok(v) if v.get("error").is_some() => return outcome(v, 200),
        Err(_) => {
            return error(
                503,
                "database_unavailable",
                "Sensor data is temporarily unavailable.",
            );
        }
        _ => {
            notify::dispatch(&store).await;
        }
    }
    match store
        .rpc("fizz_list_sensors", json!({"p_token":token}))
        .await
    {
        Ok(v) => outcome(v, 200),
        Err(_) => error(
            503,
            "database_unavailable",
            "Sensor data is temporarily unavailable.",
        ),
    }
}

pub async fn create(request: Request) -> Response<ResponseBody> {
    let Some(token) = session_token(&request) else {
        return error(401, "unauthorized", "Sign in to continue.");
    };
    let data = match body(request, 2048).await {
        Ok(v) => v,
        Err(failure) => return failure.into_response(),
    };
    let kind = data.get("kind").and_then(Value::as_str).unwrap_or("");
    let mode = data
        .get("mode")
        .and_then(Value::as_str)
        .unwrap_or("simulated");
    let default_name = format!("{} sensor", kind.split_once('_').map_or(kind, |(s, _)| s));
    let name = data
        .get("name")
        .and_then(Value::as_str)
        .unwrap_or(&default_name)
        .trim();
    if !KINDS.contains(&kind)
        || !matches!(mode, "simulated" | "api" | "phone")
        || (mode == "phone" && kind != "phone")
        || name.is_empty()
        || name.chars().count() > 80
    {
        return error(
            400,
            "invalid_request",
            "Choose a valid sensor type, mode, and name.",
        );
    }
    let store = match db("Sensor data is temporarily unavailable.") {
        Ok(store) => store,
        Err(failure) => return failure.into_response(),
    };
    match store
        .rpc(
            "fizz_create_sensor",
            json!({"p_token":token,"p_kind":kind,"p_name":name,"p_mode":mode}),
        )
        .await
    {
        Ok(v) => outcome(v, 201),
        Err(_) => error(
            503,
            "database_unavailable",
            "Sensor data is temporarily unavailable.",
        ),
    }
}

pub async fn update(request: Request) -> Response<ResponseBody> {
    let Some(token) = session_token(&request) else {
        return error(401, "unauthorized", "Sign in to continue.");
    };
    let data = match body(request, 2048).await {
        Ok(v) => v,
        Err(failure) => return failure.into_response(),
    };
    let id = data.get("id").and_then(Value::as_str).unwrap_or("");
    let name = data.get("name").and_then(Value::as_str);
    let mode = data.get("mode").and_then(Value::as_str);
    let status = data.get("status").and_then(Value::as_str);
    let rotate = data
        .get("rotate_key")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    if !valid_uuid(id)
        || name.is_some_and(|n| n.trim().is_empty() || n.chars().count() > 80)
        || mode.is_some_and(|m| !matches!(m, "simulated" | "api" | "phone"))
        || status.is_some_and(|s| !matches!(s, "active" | "paused"))
    {
        return error(400, "invalid_request", "Check the sensor details.");
    }
    let store = match db("Sensor data is temporarily unavailable.") {
        Ok(store) => store,
        Err(failure) => return failure.into_response(),
    };
    match store.rpc("fizz_update_sensor",json!({"p_token":token,"p_id":id,"p_name":name,"p_mode":mode,"p_status":status,"p_rotate_key":rotate})).await {
        Ok(v)=>outcome(v,200),Err(_)=>error(503,"database_unavailable","Sensor data is temporarily unavailable.")
    }
}

pub async fn delete(request: Request) -> Response<ResponseBody> {
    let Some(token) = session_token(&request) else {
        return error(401, "unauthorized", "Sign in to continue.");
    };
    let data = match body(request, 1024).await {
        Ok(v) => v,
        Err(failure) => return failure.into_response(),
    };
    let id = data.get("id").and_then(Value::as_str).unwrap_or("");
    if !valid_uuid(id) {
        return error(400, "invalid_request", "Choose a sensor to remove.");
    }
    let store = match db("Sensor data is temporarily unavailable.") {
        Ok(store) => store,
        Err(failure) => return failure.into_response(),
    };
    match store
        .rpc("fizz_delete_sensor", json!({"p_token":token,"p_id":id}))
        .await
    {
        Ok(v) => outcome(v, 200),
        Err(_) => error(
            503,
            "database_unavailable",
            "Sensor data is temporarily unavailable.",
        ),
    }
}

pub async fn readings(request: Request) -> Response<ResponseBody> {
    let Some(token) = session_token(&request) else {
        return error(401, "unauthorized", "Sign in to continue.");
    };
    let query = request.uri().query().unwrap_or("");
    let find = |key: &str| {
        query
            .split('&')
            .filter_map(|pair| pair.split_once('='))
            .find(|(k, _)| *k == key)
            .map(|(_, v)| v)
    };
    let id = find("sensor_id").unwrap_or("");
    let limit = find("limit")
        .and_then(|v| v.parse::<u16>().ok())
        .unwrap_or(100)
        .clamp(1, 500);
    if !valid_uuid(id) {
        return error(400, "invalid_request", "Choose a sensor.");
    }
    let store = match db("Sensor data is temporarily unavailable.") {
        Ok(store) => store,
        Err(failure) => return failure.into_response(),
    };
    match store
        .rpc("fizz_tick_simulated", json!({"p_token":token}))
        .await
    {
        Ok(v) if v.get("error").is_some() => return outcome(v, 200),
        Err(_) => {
            return error(
                503,
                "database_unavailable",
                "Sensor data is temporarily unavailable.",
            );
        }
        _ => {
            notify::dispatch(&store).await;
        }
    }
    match store
        .rpc(
            "fizz_list_readings",
            json!({"p_token":token,"p_sensor_id":id,"p_limit":limit}),
        )
        .await
    {
        Ok(v) => outcome(v, 200),
        Err(_) => error(
            503,
            "database_unavailable",
            "Sensor data is temporarily unavailable.",
        ),
    }
}

/// Ingest payload limits. The request body is capped at `MAX_INGEST_BYTES` before parsing.
/// The database checks the metric count again, and caps text at 512 characters; the
/// 512-byte check here is the stricter of the two for non-ASCII text.
pub const MAX_INGEST_BYTES: usize = 16 * 1024;
pub const MAX_METRICS_PER_READING: usize = 16;
pub const MAX_METRIC_NAME_BYTES: usize = 40;
pub const MAX_TEXT_VALUE_BYTES: usize = 512;
pub const MAX_EVENT_ID_BYTES: usize = 128;
pub const MAX_INGEST_BATCH: usize = 40;

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

/// A validated ingest body.
struct Reading<'a> {
    sensor_id: &'a str,
    event_id: &'a str,
    metrics: &'a serde_json::Map<String, Value>,
}

/// Check one ingest body: the sensor and event IDs, 1 to 16 metrics with valid names, and
/// values that are numbers, booleans, or text up to 512 bytes.
fn check_reading(data: &Value) -> Result<Reading<'_>, &'static str> {
    let id = data.get("sensor_id").and_then(Value::as_str).unwrap_or("");
    let event = data.get("event_id").and_then(Value::as_str).unwrap_or("");
    let Some(metrics) = data.get("metrics").and_then(Value::as_object) else {
        return Err("Send a metrics object.");
    };
    if !valid_uuid(id)
        || event.is_empty()
        || event.len() > MAX_EVENT_ID_BYTES
        || metrics.is_empty()
        || metrics.len() > MAX_METRICS_PER_READING
    {
        return Err("Check the sensor ID, event ID, and metrics.");
    }
    for (metric, value) in metrics {
        if !valid_metric_name(metric) {
            return Err("Metric names must use lowercase letters, digits, and underscores.");
        }
        if !matches!(value, Value::Number(_) | Value::Bool(_))
            && !matches!(value, Value::String(s) if s.len() <= MAX_TEXT_VALUE_BYTES)
        {
            return Err("Metric values must be numbers, booleans, or short text.");
        }
    }
    Ok(Reading {
        sensor_id: id,
        event_id: event,
        metrics,
    })
}

pub async fn ingest(request: Request) -> Response<ResponseBody> {
    let key = request
        .headers()
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .unwrap_or("")
        .to_owned();
    if key.len() != 69
        || !key.starts_with("fizz_")
        || !key[5..].bytes().all(|c| c.is_ascii_hexdigit())
    {
        return error(401, "unauthorized", "Use the sensor API key.");
    }
    let data = match body(request, MAX_INGEST_BYTES).await {
        Ok(v) => v,
        Err(failure) => return failure.into_response(),
    };
    if data.get("readings").is_some() {
        return ingest_batch(key, data).await;
    }
    let Reading {
        sensor_id: id,
        event_id: event,
        metrics,
    } = match check_reading(&data) {
        Ok(reading) => reading,
        Err(message) => return error(400, "invalid_request", message),
    };
    let observed = data.get("observed_at").and_then(Value::as_str);
    let store = match db("Ingestion is temporarily unavailable.") {
        Ok(store) => store,
        Err(failure) => return failure.into_response(),
    };
    match store
        .rpc(
            "fizz_ingest_event",
            json!({"p_sensor_id":id,"p_key":key,"p_event_id":event,
            "p_observed_at":observed,"p_metrics":metrics}),
        )
        .await
    {
        Ok(v) if v.get("error").and_then(Value::as_str) == Some("unauthorized") => {
            error(401, "unauthorized", "Sensor key is invalid or revoked.")
        }
        Ok(v) if v.get("error").and_then(Value::as_str) == Some("paused") => {
            error(409, "paused", "This sensor is paused.")
        }
        Ok(v) if v.get("error").is_some() => outcome(v, 202),
        Ok(v) => {
            notify::dispatch(&store).await;
            reply(202, v, None)
        }
        Err(_) => error(
            503,
            "database_unavailable",
            "Ingestion is temporarily unavailable.",
        ),
    }
}

fn check_batch(data: &Value) -> Result<(), &'static str> {
    let Some(readings) = data.get("readings").and_then(Value::as_array) else {
        return Err("Send a readings array.");
    };
    if readings.is_empty() || readings.len() > MAX_INGEST_BATCH {
        return Err("Send 1 to 40 readings.");
    }
    for reading in readings {
        check_reading(reading)?;
    }
    Ok(())
}

async fn ingest_batch(key: String, data: Value) -> Response<ResponseBody> {
    if let Err(message) = check_batch(&data) {
        return error(400, "invalid_request", message);
    }
    let store = match db("Ingestion is temporarily unavailable.") {
        Ok(store) => store,
        Err(failure) => return failure.into_response(),
    };
    match store
        .rpc(
            "fizz_ingest_batch",
            json!({"p_key": key, "p_readings": data.get("readings")}),
        )
        .await
    {
        Ok(v) if v.get("error").and_then(Value::as_str) == Some("unauthorized") => {
            error(401, "unauthorized", "Sensor key is invalid or revoked.")
        }
        Ok(v) if v.get("error").is_some() => outcome(v, 202),
        Ok(v) => {
            let stored = v
                .get("results")
                .and_then(Value::as_array)
                .is_some_and(|items| items.iter().any(|item| item.get("error").is_none()));
            if stored {
                notify::dispatch(&store).await;
            }
            reply(202, v, None)
        }
        Err(_) => error(
            503,
            "database_unavailable",
            "Ingestion is temporarily unavailable.",
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn reading(metrics: Value) -> Value {
        json!({"sensor_id":"4f1c7e2a-9b3d-4c5e-8f6a-1b2c3d4e5f60","event_id":"e1","metrics":metrics})
    }

    #[test]
    fn ingest_payloads_are_bounded() {
        assert!(
            check_reading(&reading(
                json!({"temperature_c": 21.5, "door_open": true, "note": "ok"})
            ))
            .is_ok()
        );
        let many: serde_json::Map<String, Value> = (0..=MAX_METRICS_PER_READING)
            .map(|i| (format!("m{i}"), json!(1)))
            .collect();
        assert!(check_reading(&reading(Value::Object(many))).is_err());
        assert!(check_reading(&reading(json!({}))).is_err());
        assert!(check_reading(&reading(json!({"note": "x".repeat(MAX_TEXT_VALUE_BYTES)}))).is_ok());
        assert!(
            check_reading(&reading(
                json!({"note": "x".repeat(MAX_TEXT_VALUE_BYTES + 1)})
            ))
            .is_err()
        );
        assert!(
            check_reading(&reading(
                json!({"note": "é".repeat(MAX_TEXT_VALUE_BYTES / 2 + 1)})
            ))
            .is_err()
        );
        assert!(
            check_reading(&reading(json!({"a".repeat(MAX_METRIC_NAME_BYTES + 1): 1}))).is_err()
        );
        assert!(check_reading(&reading(json!({"Temp": 1}))).is_err());
        assert!(check_reading(&reading(json!({"": 1}))).is_err());
        let checked = reading(json!({"t": 1}));
        let parsed = check_reading(&checked).unwrap();
        assert_eq!((parsed.event_id, parsed.metrics.len()), ("e1", 1));
        let batch: Vec<Value> = (0..MAX_INGEST_BATCH)
            .map(|i| reading(json!({"value": i})))
            .collect();
        assert!(check_batch(&json!({"readings": batch})).is_ok());
        let oversized: Vec<Value> = (0..=MAX_INGEST_BATCH)
            .map(|i| reading(json!({"value": i})))
            .collect();
        assert!(check_batch(&json!({"readings": oversized})).is_err());
        assert!(check_batch(&json!({"readings": []})).is_err());
        assert!(check_batch(&json!({"readings": [{"sensor_id": "nope"}]})).is_err());
        assert!(check_reading(&reading(json!({"nested": {"a": 1}}))).is_err());
        assert!(check_reading(&reading(json!({"list": [1, 2]}))).is_err());
        let mut long_event = reading(json!({"t": 1}));
        long_event["event_id"] = json!("e".repeat(MAX_EVENT_ID_BYTES + 1));
        assert!(check_reading(&long_event).is_err());
        let mut bad_id = reading(json!({"t": 1}));
        bad_id["sensor_id"] = json!("not-a-uuid");
        assert!(check_reading(&bad_id).is_err());
    }
}
