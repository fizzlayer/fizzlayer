use std::{
    error::Error as StdError,
    fmt,
    net::{IpAddr, Ipv6Addr},
};

use http::header::RETRY_AFTER;
use http_body_util::{BodyExt, Limited};
use reqwest::Method;
use serde_json::{Value, json};
use vercel_runtime::{Request, Response, ResponseBody};

use crate::store::Supabase;

const COOKIE_NAME: &str = "fizz_session";
/// A signed-in person's Supabase access token, kept for up to an hour so they can add a passkey.
pub const SUPABASE_COOKIE: &str = "fizz_supabase";
pub const CLEAR_SUPABASE_COOKIE: &str =
    "fizz_supabase=; HttpOnly; Secure; SameSite=Lax; Path=/api; Max-Age=0";

#[must_use]
pub fn reply(status: u16, body: Value, cookie: Option<&str>) -> Response<ResponseBody> {
    reply_with(status, body, cookie.as_slice())
}

/// # Panics
///
/// Panics if a header value is not a valid HTTP header. Callers pass static
/// header names and cookie strings this crate already built.
#[must_use]
pub fn reply_with(status: u16, body: Value, cookies: &[&str]) -> Response<ResponseBody> {
    let mut builder = Response::builder()
        .status(status)
        .header("content-type", "application/json; charset=utf-8")
        .header("cache-control", "no-store")
        .header("x-content-type-options", "nosniff");
    for cookie in cookies {
        builder = builder.header("set-cookie", *cookie);
    }
    builder
        .body(ResponseBody::from(body))
        .expect("valid response")
}

/// Shown wherever adding an API sensor, phone, or paired device would exceed the plan.
pub const DEVICE_LIMIT_MESSAGE: &str =
    "Your plan's device limit is reached. Remove a device or upgrade your plan to add more.";

#[must_use]
pub fn device_limit() -> Response<ResponseBody> {
    error(403, "device_limit", DEVICE_LIMIT_MESSAGE)
}

/// A failure a handler can return without building an HTTP response.
///
/// `into_response` is the only place this becomes the JSON body and headers
/// clients see. `error` uses that same mapping for handlers that return a
/// response directly.
#[derive(Debug)]
pub struct ApiError {
    status: u16,
    code: &'static str,
    message: &'static str,
    retry_after: Option<&'static str>,
}

impl ApiError {
    #[must_use]
    pub fn new(status: u16, code: &'static str, message: &'static str) -> Self {
        Self {
            status,
            code,
            message,
            retry_after: None,
        }
    }

    /// `Retry-After` in seconds. The value is a static header, the same way
    /// the rate-limit responses have always sent `60`.
    #[must_use]
    pub fn retry_after(mut self, seconds: &'static str) -> Self {
        self.retry_after = Some(seconds);
        self
    }

    #[must_use]
    pub fn into_response(self) -> Response<ResponseBody> {
        error_response(self.status, self.code, self.message, self.retry_after)
    }
}

impl fmt::Display for ApiError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{} {}: {}", self.status, self.code, self.message)
    }
}

impl StdError for ApiError {}

#[must_use]
pub fn error(status: u16, code: &str, message: &str) -> Response<ResponseBody> {
    error_response(status, code, message, None)
}

fn error_response(
    status: u16,
    code: &str,
    message: &str,
    retry_after: Option<&'static str>,
) -> Response<ResponseBody> {
    let mut response = reply(
        status,
        json!({"error": {"code": code, "message": message}}),
        None,
    );
    if let Some(seconds) = retry_after {
        response
            .headers_mut()
            .insert(RETRY_AFTER, http::HeaderValue::from_static(seconds));
    }
    response
}

/// # Errors
///
/// Returns 415 when the body is not JSON, 413 when it is over `limit`, and 400
/// when it is not a JSON object.
pub async fn json_body(request: Request, limit: usize) -> Result<Value, ApiError> {
    json_body_with(request, limit, "invalid_request").await
}

/// `json_body` with the error code to return when the body is over `limit`.
///
/// # Errors
///
/// Returns 415 when the body is not JSON, 413 with `too_large` when it is over
/// `limit`, and 400 when it is not a JSON object.
pub async fn json_body_with(
    request: Request,
    limit: usize,
    too_large: &'static str,
) -> Result<Value, ApiError> {
    let is_json = request
        .headers()
        .get("content-type")
        .and_then(|v| v.to_str().ok())
        .is_some_and(crate::security::is_json);
    if !is_json {
        return Err(ApiError::new(415, "unsupported_media_type", "Send JSON."));
    }
    let bytes = Limited::new(request.into_body(), limit)
        .collect()
        .await
        .map_err(|_| ApiError::new(413, too_large, "Request is too large."))?
        .to_bytes();
    let value: Value = serde_json::from_slice(&bytes)
        .map_err(|_| ApiError::new(400, "invalid_request", "Send a JSON object."))?;
    if !value.is_object() {
        return Err(ApiError::new(400, "invalid_request", "Send a JSON object."));
    }
    Ok(value)
}

/// The caller's network for rate limiting. Vercel sets `x-real-ip` and overwrites
/// `x-forwarded-for`, so clients cannot choose these values in production. An IPv6
/// address is reduced to its /64 block, the smallest one a single subscriber is usually
/// given, so rotating through one block counts as one caller.
pub fn client_ip(request: &Request) -> Option<String> {
    ip_from_headers(|name| request.headers().get(name).and_then(|v| v.to_str().ok()))
}

fn ip_from_headers<'a>(header: impl Fn(&str) -> Option<&'a str>) -> Option<String> {
    header("x-real-ip")
        .or_else(|| header("x-forwarded-for").and_then(|v| v.split(',').next()))
        .and_then(|v| v.trim().parse::<IpAddr>().ok())
        .map(|ip| match ip {
            IpAddr::V6(v6) => {
                if let Some(v4) = v6.to_ipv4_mapped() {
                    v4.to_string()
                } else {
                    let [a, b, c, d, ..] = v6.segments();
                    format!("{}/64", Ipv6Addr::new(a, b, c, d, 0, 0, 0, 0))
                }
            }
            IpAddr::V4(v4) => v4.to_string(),
        })
}

/// A plausible address: one @, a dotted domain, no spaces or control characters.
/// Delivery is the real test; this keeps obvious junk out of the list.
#[must_use]
pub fn normalize_email(value: &str) -> Option<String> {
    let email = value.trim().to_ascii_lowercase();
    let (local, domain) = email.split_once('@')?;
    let valid = email.len() <= 254
        && !local.is_empty()
        && local.len() <= 64
        && domain.contains('.')
        && !domain.starts_with('.')
        && !domain.ends_with('.')
        && !domain.contains('@')
        && email.chars().all(|c| !c.is_whitespace() && !c.is_control());
    valid.then_some(email)
}

pub fn cookie<'a>(request: &'a Request, name: &str) -> Option<&'a str> {
    request
        .headers()
        .get("cookie")?
        .to_str()
        .ok()?
        .split(';')
        .filter_map(|part| part.trim().split_once('='))
        .find(|(key, _)| *key == name)
        .map(|(_, value)| value)
}

pub fn session_token(request: &Request) -> Option<String> {
    cookie(request, COOKIE_NAME)
        .filter(|value| value.len() == 64 && value.bytes().all(|c| c.is_ascii_hexdigit()))
        .map(str::to_owned)
}

#[must_use]
pub fn session_cookie(token: &str) -> String {
    format!("{COOKIE_NAME}={token}; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=43200")
}

#[must_use]
pub fn clear_cookie() -> &'static str {
    "fizz_session=; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=0"
}

pub async fn current(request: Request) -> Response<ResponseBody> {
    let Some(token) = session_token(&request) else {
        return error(401, "unauthorized", "Sign in to continue.");
    };
    let Ok(store) = Supabase::from_env() else {
        return error(503, "database_unavailable", "Session check is unavailable.");
    };
    match store
        .rpc("fizz_current_customer", json!({"p_token": token}))
        .await
    {
        Ok(value) if value.get("username").is_some() => reply(200, value, None),
        Ok(_) => error(401, "unauthorized", "Sign in to continue."),
        Err(_) => error(503, "database_unavailable", "Session check is unavailable."),
    }
}

pub async fn sign_out(request: Request) -> Response<ResponseBody> {
    let Ok(store) = Supabase::from_env() else {
        return error(
            503,
            "database_unavailable",
            "Sign-out is temporarily unavailable.",
        );
    };
    if let Some(token) = session_token(&request)
        && store
            .rpc("fizz_sign_out", json!({"p_token": token}))
            .await
            .is_err()
    {
        return error(
            503,
            "database_unavailable",
            "Sign-out is temporarily unavailable.",
        );
    }
    // Also end the Supabase session kept for adding passkeys. It expires within the hour anyway,
    // so a failure here does not block signing out.
    if let Some(token) = cookie(&request, SUPABASE_COOKIE) {
        let _ = store
            .auth(
                Method::POST,
                "logout",
                &[("scope", "local")],
                Some(token),
                None,
                None,
            )
            .await;
    }
    reply_with(
        200,
        json!({"ok": true}),
        &[clear_cookie(), CLEAR_SUPABASE_COOKIE],
    )
}

pub async fn sensor_choices(request: Request) -> Response<ResponseBody> {
    let Some(token) = session_token(&request) else {
        return error(401, "unauthorized", "Sign in to continue.");
    };
    let Ok(store) = Supabase::from_env() else {
        return error(
            503,
            "database_unavailable",
            "Sensor setup is temporarily unavailable.",
        );
    };
    match store
        .rpc("fizz_get_sensor_choices", json!({"p_token": token}))
        .await
    {
        Ok(value) if value.get("error").and_then(Value::as_str) == Some("unauthorized") => {
            error(401, "unauthorized", "Sign in to continue.")
        }
        Ok(value) if value.get("choices").and_then(Value::as_array).is_some() => {
            reply(200, value, None)
        }
        _ => error(
            503,
            "database_unavailable",
            "Sensor setup is temporarily unavailable.",
        ),
    }
}

pub async fn select_sensor(request: Request) -> Response<ResponseBody> {
    update_sensor(request, false).await
}

pub async fn remove_sensor(request: Request) -> Response<ResponseBody> {
    update_sensor(request, true).await
}

async fn update_sensor(request: Request, removing: bool) -> Response<ResponseBody> {
    let Some(token) = session_token(&request) else {
        return error(401, "unauthorized", "Sign in to continue.");
    };
    let is_json = request
        .headers()
        .get("content-type")
        .and_then(|value| value.to_str().ok())
        .is_some_and(crate::security::is_json);
    if !is_json {
        return error(415, "unsupported_media_type", "Send JSON.");
    }
    let bytes = match Limited::new(request.into_body(), 512).collect().await {
        Ok(body) => body.to_bytes(),
        Err(_) => return error(413, "invalid_request", "Request is too large."),
    };
    let data: Value = match serde_json::from_slice(&bytes) {
        Ok(value) => value,
        Err(_) => return error(400, "invalid_request", "Choose a sensor type."),
    };
    let kind = data.get("kind").and_then(Value::as_str).unwrap_or("");
    if !matches!(
        kind,
        "water"
            | "gas"
            | "radio"
            | "temperature"
            | "pressure"
            | "humidity"
            | "sound"
            | "phone"
            | "custom"
    ) {
        return error(
            400,
            "invalid_kind",
            "Choose one of the listed sensor types.",
        );
    }
    let Ok(store) = Supabase::from_env() else {
        return error(
            503,
            "database_unavailable",
            "Sensor setup is temporarily unavailable.",
        );
    };
    match store
        .rpc(
            if removing {
                "fizz_remove_sensor_choice"
            } else {
                "fizz_add_sensor_choice"
            },
            json!({"p_token": token, "p_kind": kind}),
        )
        .await
    {
        Ok(value) if value.get("error").and_then(Value::as_str) == Some("unauthorized") => {
            error(401, "unauthorized", "Sign in to continue.")
        }
        Ok(value) if value.get("choices").and_then(Value::as_array).is_some() => {
            reply(200, value, None)
        }
        _ => error(
            503,
            "database_unavailable",
            "Sensor setup is temporarily unavailable.",
        ),
    }
}

#[cfg(test)]
mod tests {
    use http_body_util::BodyExt;

    use super::*;

    async fn json_body(response: Response<ResponseBody>) -> Value {
        let bytes = response.into_body().collect().await.unwrap().to_bytes();
        serde_json::from_slice(&bytes).unwrap()
    }

    #[tokio::test]
    async fn api_error_is_the_json_error_clients_already_receive() {
        let direct = error(400, "invalid_request", "Send a JSON object.");
        let mapped = ApiError::new(400, "invalid_request", "Send a JSON object.").into_response();
        assert_eq!(direct.status(), mapped.status());
        for response in [direct, mapped] {
            assert_eq!(response.status(), 400);
            assert_eq!(
                response
                    .headers()
                    .get("content-type")
                    .and_then(|value| value.to_str().ok()),
                Some("application/json; charset=utf-8")
            );
            assert_eq!(
                response
                    .headers()
                    .get("cache-control")
                    .and_then(|value| value.to_str().ok()),
                Some("no-store")
            );
            assert_eq!(
                response
                    .headers()
                    .get("x-content-type-options")
                    .and_then(|value| value.to_str().ok()),
                Some("nosniff")
            );
            assert!(response.headers().get("retry-after").is_none());
            assert!(response.headers().get("set-cookie").is_none());
            assert_eq!(
                json_body(response).await,
                json!({"error": {"code": "invalid_request", "message": "Send a JSON object."}})
            );
        }
    }

    #[tokio::test]
    async fn retry_after_is_a_header_and_does_not_change_the_body() {
        let response = ApiError::new(429, "rate_limited", "Usage limit reached. Try again later.")
            .retry_after("60")
            .into_response();
        assert_eq!(response.status(), 429);
        assert_eq!(
            response
                .headers()
                .get("retry-after")
                .and_then(|value| value.to_str().ok()),
            Some("60")
        );
        assert_eq!(
            json_body(response).await,
            json!({"error": {"code": "rate_limited", "message": "Usage limit reached. Try again later."}})
        );
    }

    #[test]
    fn api_error_display_names_the_status_and_code() {
        let error = ApiError::new(415, "unsupported_media_type", "Send JSON.");
        assert_eq!(error.to_string(), "415 unsupported_media_type: Send JSON.");
    }

    #[test]
    fn emails_are_trimmed_lowercased_and_sanity_checked() {
        assert_eq!(
            normalize_email("  Ann@Example.COM "),
            Some("ann@example.com".into())
        );
        assert_eq!(
            normalize_email("a.b+fizz@mail.co.uk"),
            Some("a.b+fizz@mail.co.uk".into())
        );
        for bad in [
            "",
            "ann",
            "ann@",
            "@example.com",
            "ann@example",
            "ann@.com",
            "ann@example.",
            "a@b@c.com",
            "an n@example.com",
            "ann@exa\u{7}mple.com",
        ] {
            assert_eq!(normalize_email(bad), None, "{bad:?}");
        }
        assert_eq!(
            normalize_email(&format!("{}@example.com", "a".repeat(65))),
            None
        );
    }

    #[test]
    fn client_ip_prefers_real_ip_and_ignores_non_addresses() {
        let ip = |headers: &[(&'static str, &'static str)]| {
            let headers = headers.to_vec();
            ip_from_headers(move |name| headers.iter().find(|(n, _)| *n == name).map(|(_, v)| *v))
        };
        assert_eq!(
            ip(&[
                ("x-real-ip", "203.0.113.9"),
                ("x-forwarded-for", "198.51.100.1")
            ]),
            Some("203.0.113.9".into())
        );
        assert_eq!(
            ip(&[("x-forwarded-for", "2001:db8::1, 10.0.0.1")]),
            Some("2001:db8::/64".into())
        );
        assert_eq!(
            ip(&[("x-real-ip", "2001:db8:1:2:aaaa:bbbb:cccc:dddd")]),
            ip(&[("x-real-ip", "2001:db8:1:2::9")])
        );
        assert_eq!(
            ip(&[("x-real-ip", "2001:db8:1:2:aaaa::1")]),
            Some("2001:db8:1:2::/64".into())
        );
        assert_eq!(
            ip(&[("x-real-ip", "::ffff:203.0.113.9")]),
            Some("203.0.113.9".into())
        );
        assert_eq!(ip(&[("x-real-ip", "not-an-ip")]), None);
        assert_eq!(ip(&[]), None);
    }
}
