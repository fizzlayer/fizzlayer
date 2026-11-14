//! Home Assistant links an install to the signed-in owner, then posts each chosen entity
//! through the same ingest path as any other device. The device key is returned once, to
//! Home Assistant, and is never sent back to the browser.

use serde_json::{Value, json};
use vercel_runtime::{Response, ResponseBody};

use crate::{
    customer::{self, error, reply},
    sensors::valid_uuid,
    store::Supabase,
};

const MY_HOME_ASSISTANT: &str =
    "https://my.home-assistant.io/redirect/config_flow_start?domain=fizzlayer";

fn valid_state(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase())
}

/// The code Home Assistant shows on its own screen. Spaces are ignored so "482 913" matches.
fn confirm_code(value: &str) -> Option<String> {
    let compact: String = value.chars().filter(|c| !c.is_whitespace()).collect();
    (compact.len() == 6 && compact.bytes().all(|c| c.is_ascii_digit())).then_some(compact)
}

fn clean_label(value: Option<&Value>, max_chars: usize) -> Option<String> {
    let text = value.and_then(Value::as_str)?.trim();
    if text.is_empty() || text.chars().count() > max_chars || text.chars().any(char::is_control) {
        None
    } else {
        Some(text.to_owned())
    }
}

/// Entity sync is bounded before it reaches the database. The database checks each entity again.
fn entities_are_bounded(value: &Value) -> bool {
    let Some(entities) = value.as_array() else {
        return false;
    };
    if entities.len() > 50 {
        return false;
    }
    entities.iter().all(|entity| {
        let Some(object) = entity.as_object() else {
            return false;
        };
        object.len() <= 8
            && object.iter().all(|(key, item)| {
                key.len() <= 40
                    && match item {
                        Value::Null | Value::Bool(_) => true,
                        Value::String(text) => {
                            text.len() <= 160 && !text.chars().any(char::is_control)
                        }
                        _ => false,
                    }
            })
    })
}

fn outcome(value: Value) -> Response<ResponseBody> {
    match value.get("error").and_then(Value::as_str) {
        None => reply(200, value, None),
        Some("unauthorized") => error(401, "unauthorized", "Sign in to continue."),
        Some("rate_limited") => error(
            429,
            "rate_limited",
            "Too many Home Assistant requests. Try again later.",
        ),
        Some("invalid_request" | "invalid_entity") => {
            error(400, "invalid_request", "Check the Home Assistant request.")
        }
        Some("invalid_code") => error(
            400,
            "invalid_code",
            "That code does not match this Home Assistant.",
        ),
        Some("not_ready") => error(
            409,
            "not_ready",
            "Home Assistant has not shown a code yet. Open it and try again.",
        ),
        Some("expired") => error(
            410,
            "expired",
            "This link expired. Start it again from Fizzlayer.",
        ),
        Some("already_linked") => error(
            409,
            "already_linked",
            "This Home Assistant link was already used.",
        ),
        Some("not_found") => error(
            404,
            "not_found",
            "That Home Assistant connection was not found.",
        ),
        Some("device_limit") => customer::device_limit(),
        Some(_) => error(
            503,
            "unavailable",
            "Home Assistant linking is temporarily unavailable.",
        ),
    }
}

async fn rpc(store: &Supabase, name: &str, args: Value) -> Response<ResponseBody> {
    match store.rpc(name, args).await {
        Ok(value) => outcome(value),
        Err(_) => error(
            503,
            "database_unavailable",
            "Home Assistant linking is temporarily unavailable.",
        ),
    }
}

/// Handles `ha_*` device actions. Returns None when `action` belongs to device pairing.
pub async fn dispatch(
    store: &Supabase,
    action: &str,
    data: &Value,
    session: Option<&str>,
    key: Option<&str>,
    ip: Option<&str>,
) -> Option<Response<ResponseBody>> {
    if !action.starts_with("ha_") {
        return None;
    }
    Some(match action {
        "ha_prepare" => {
            let Some(session) = session else {
                return Some(error(
                    401,
                    "unauthorized",
                    "Sign in to connect Home Assistant.",
                ));
            };
            rpc(store, "fizz_ha_prepare", json!({"p_token": session})).await
        }
        "ha_authorize" => ha_authorize(store, data, session).await,
        "ha_preview" => {
            let state = data.get("state").and_then(Value::as_str).unwrap_or("");
            if !valid_state(state) {
                return Some(error(
                    400,
                    "invalid_request",
                    "The Home Assistant link is not valid.",
                ));
            }
            rpc(
                store,
                "fizz_ha_preview",
                json!({"p_state": state, "p_ip": ip}),
            )
            .await
        }
        "ha_exchange" => ha_exchange(store, data, ip).await,
        "ha_exchange_code" => {
            let code = data
                .get("code")
                .and_then(Value::as_str)
                .unwrap_or("")
                .trim();
            if code.is_empty() || code.len() > 24 {
                return Some(error(
                    400,
                    "invalid_code",
                    "Enter the pairing code from Fizzlayer.",
                ));
            }
            rpc(
                store,
                "fizz_ha_exchange_code",
                json!({"p_code": code, "p_ip": ip}),
            )
            .await
        }
        "ha_sync" => ha_sync(store, data, key).await,
        "ha_list" => {
            let Some(session) = session else {
                return Some(error(401, "unauthorized", "Sign in to continue."));
            };
            rpc(store, "fizz_ha_list", json!({"p_token": session})).await
        }
        "ha_revoke" => {
            if let Some(id) = data.get("id").and_then(Value::as_str) {
                let Some(session) = session else {
                    return Some(error(401, "unauthorized", "Sign in to continue."));
                };
                if !valid_uuid(id) {
                    return Some(error(
                        400,
                        "invalid_request",
                        "Choose a Home Assistant connection.",
                    ));
                }
                rpc(
                    store,
                    "fizz_ha_revoke",
                    json!({"p_token": session, "p_id": id}),
                )
                .await
            } else if let Some(key) = key {
                rpc(store, "fizz_ha_revoke_key", json!({"p_key": key})).await
            } else {
                error(
                    401,
                    "unauthorized",
                    "Sign in, or use the Home Assistant connection key.",
                )
            }
        }
        _ => error(400, "invalid_request", "Unknown Home Assistant action."),
    })
}

async fn ha_authorize(
    store: &Supabase,
    data: &Value,
    session: Option<&str>,
) -> Response<ResponseBody> {
    let Some(session) = session else {
        return error(401, "unauthorized", "Sign in to connect Home Assistant.");
    };
    let state = data.get("state").and_then(Value::as_str).unwrap_or("");
    if !valid_state(state) {
        return error(
            400,
            "invalid_request",
            "The Home Assistant link is not valid.",
        );
    }
    let Some(code) = data
        .get("code")
        .and_then(Value::as_str)
        .and_then(confirm_code)
    else {
        return error(
            400,
            "invalid_code",
            "Type the 6-digit code shown in Home Assistant.",
        );
    };
    rpc(
        store,
        "fizz_ha_authorize",
        json!({"p_token": session, "p_state": state, "p_code": code}),
    )
    .await
}

async fn ha_sync(store: &Supabase, data: &Value, key: Option<&str>) -> Response<ResponseBody> {
    let Some(key) = key else {
        return error(
            401,
            "unauthorized",
            "Use the Home Assistant connection key.",
        );
    };
    let entities = data.get("entities").cloned().unwrap_or(Value::Null);
    if !entities_are_bounded(&entities) {
        return error(
            400,
            "invalid_request",
            "Choose up to 50 Home Assistant entities.",
        );
    }
    let name = match data.get("name") {
        None => None,
        Some(value) => match clean_label(Some(value), 80) {
            Some(name) => Some(name),
            None => return error(400, "invalid_request", "Use a name under 80 characters."),
        },
    };
    let version = match data.get("ha_version") {
        None => None,
        Some(value) => match clean_label(Some(value), 40) {
            Some(version) => Some(version),
            None => {
                return error(
                    400,
                    "invalid_request",
                    "The Home Assistant version is not valid.",
                );
            }
        },
    };
    let replace = data.get("replace").and_then(Value::as_bool).unwrap_or(true);
    rpc(
        store,
        "fizz_ha_sync",
        json!({"p_key": key, "p_entities": entities, "p_name": name, "p_ha_version": version, "p_replace": replace}),
    )
    .await
}

async fn ha_exchange(store: &Supabase, data: &Value, ip: Option<&str>) -> Response<ResponseBody> {
    let state = data.get("state").and_then(Value::as_str).unwrap_or("");
    if !valid_state(state) {
        return error(
            400,
            "invalid_request",
            "The Home Assistant link is not valid.",
        );
    }
    let Some(code) = data
        .get("confirm_code")
        .and_then(Value::as_str)
        .and_then(confirm_code)
    else {
        return error(
            400,
            "invalid_request",
            "Home Assistant must send the code it is showing.",
        );
    };
    let name = match data.get("name").filter(|value| !value.is_null()) {
        None => None,
        Some(value) => match clean_label(Some(value), 80) {
            Some(name) => Some(name),
            None => return error(400, "invalid_request", "Use a name under 80 characters."),
        },
    };
    let version = match data.get("ha_version").filter(|value| !value.is_null()) {
        None => None,
        Some(value) => match clean_label(Some(value), 40) {
            Some(version) => Some(version),
            None => {
                return error(
                    400,
                    "invalid_request",
                    "The Home Assistant version is not valid.",
                );
            }
        },
    };
    rpc(
        store,
        "fizz_ha_exchange",
        json!({
            "p_state": state,
            "p_ip": ip,
            "p_code": code,
            "p_name": name,
            "p_ha_version": version
        }),
    )
    .await
}

/// Where the dashboard sends someone to start the integration. My Home Assistant only
/// forwards the domain; the pairing state is created inside Home Assistant and approved
/// on the Fizzlayer page that it opens.
pub fn redirect_url() -> &'static str {
    MY_HOME_ASSISTANT
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn states_are_64_lowercase_hex_and_the_redirect_carries_the_domain() {
        assert!(valid_state(&"ab".repeat(32)));
        assert!(!valid_state(&"AB".repeat(32)));
        assert!(!valid_state("abc"));
        assert!(redirect_url().contains("domain=fizzlayer"));
        assert!(!redirect_url().contains("code="));
        assert_eq!(confirm_code("482913").as_deref(), Some("482913"));
        assert_eq!(confirm_code("482 913").as_deref(), Some("482913"));
        assert_eq!(confirm_code("48291"), None);
        assert_eq!(confirm_code("ABCDEF"), None);
        assert_eq!(confirm_code(""), None);
    }

    #[test]
    fn entity_lists_are_bounded_before_they_are_stored() {
        let one = json!([{"entity_id": "sensor.closet_temperature", "name": "Closet", "device_class": "temperature"}]);
        assert!(entities_are_bounded(&one));
        assert!(entities_are_bounded(&json!([])));
        assert!(!entities_are_bounded(&json!({"entity_id": "sensor.a"})));
        let too_many = Value::Array(
            (0..51)
                .map(|i| json!({"entity_id": format!("sensor.e{i}")}))
                .collect(),
        );
        assert!(!entities_are_bounded(&too_many));
        assert!(!entities_are_bounded(&json!([{"name": "bad\u{0001}"}])));
        assert!(!entities_are_bounded(&json!([{"reading": 21.5}])));
    }
}
