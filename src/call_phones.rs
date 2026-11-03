//! Pair a US number before an alert can call it. The signed-in owner starts a call
//! that reads a 6-digit code; confirming that code saves the number on the workspace.
//! Agent tokens never reach these routes: the session cookie is an owner session.
use serde_json::{Value, json};
use vercel_runtime::{Request, Response, ResponseBody};

use crate::{
    customer::{client_ip, error, json_body, reply, session_token},
    notify,
    store::Supabase,
};

const MAX_BODY_BYTES: usize = 4 * 1024;

pub const CALLS_NOT_INCLUDED: &str = "Phone calls are included with Tinkerer, Pro, and Enterprise. Upgrade to place calls, or create a dashboard-only alert.";
pub const PHONE_NOT_PAIRED: &str = "Pair this phone number in the dashboard before an alert can call it. Open Phones, have Fizzlayer call the number, and enter the 6-digit code.";

fn phone_error(value: &Value) -> Option<Response<ResponseBody>> {
    let code = value.get("error")?.as_str()?;
    let (status, message) = match code {
        "unauthorized" => (401, "Sign in to continue."),
        "invalid_phone" => (400, "Enter a valid US phone number."),
        "calls_not_included" => (402, CALLS_NOT_INCLUDED),
        "phone_limit" => (
            400,
            "This workspace already has 10 paired numbers. Remove one to pair another.",
        ),
        "cooldown" => (429, "Wait a minute before calling this number again."),
        "rate_limited" => (
            429,
            "Too many pairing calls from this account, number, or network. Try again later.",
        ),
        "invalid_code" => (
            400,
            "That code doesn't match. Enter the 6 digits from the call.",
        ),
        "expired" => (
            400,
            "That code expired. Call the number again for a new one.",
        ),
        "too_many_attempts" => (400, "Too many tries for this code. Call the number again."),
        "not_found" => (404, "That paired number was not found."),
        _ => (
            503,
            "Phone pairing is temporarily unavailable. Please try again.",
        ),
    };
    let mut response = error(status, code, message);
    if status == 429 {
        let retry = value["retry_after_seconds"]
            .as_u64()
            .unwrap_or(60)
            .to_string();
        response.headers_mut().insert(
            "retry-after",
            retry
                .parse()
                .unwrap_or_else(|_| "60".parse().expect("valid header")),
        );
    }
    Some(response)
}

/// What the browser receives after a pairing call is accepted. The spoken code is omitted.
fn client_start_body(value: &Value) -> Value {
    json!({
        "ok": true,
        "phone": value["phone"],
        "expires_in_seconds": value["expires_in_seconds"].as_u64().unwrap_or(600),
        "resend_after_seconds": 60,
    })
}

pub async fn handle(request: Request) -> Response<ResponseBody> {
    let Some(token) = session_token(&request) else {
        return error(401, "unauthorized", "Sign in to continue.");
    };
    let method = request.method().as_str().to_owned();
    let ip = client_ip(&request);
    let data = if method == "GET" {
        Value::Null
    } else if method == "POST" {
        match json_body(request, MAX_BODY_BYTES).await {
            Ok(data) => data,
            Err(response) => return response,
        }
    } else {
        return error(405, "method_not_allowed", "Use GET or POST.");
    };
    let Ok(store) = crate::store::Supabase::from_env() else {
        return error(
            503,
            "database_unavailable",
            "Phone pairing is temporarily unavailable.",
        );
    };
    if method == "GET" {
        return finish(&store, "fizz_call_phone_list", json!({"p_token": token})).await;
    }
    match data["action"].as_str() {
        Some("start") => start(&store, &token, &data, ip.as_deref()).await,
        Some("confirm") => {
            finish(
                &store,
                "fizz_call_phone_confirm",
                json!({
                    "p_token": token,
                    "p_phone": data["phone"].as_str().unwrap_or(""),
                    "p_code": data["code"].as_str().unwrap_or(""),
                }),
            )
            .await
        }
        Some("remove") => {
            finish(
                &store,
                "fizz_call_phone_remove",
                json!({"p_token": token, "p_phone": data["phone"].as_str().unwrap_or("")}),
            )
            .await
        }
        _ => error(400, "invalid_request", "Choose start, confirm, or remove."),
    }
}

async fn finish(store: &Supabase, rpc: &str, payload: Value) -> Response<ResponseBody> {
    match store.rpc(rpc, payload).await {
        Ok(value) => match phone_error(&value) {
            Some(response) => response,
            None => reply(200, value, None),
        },
        Err(_) => error(
            503,
            "database_unavailable",
            "Phone pairing is temporarily unavailable.",
        ),
    }
}

async fn start(
    store: &Supabase,
    token: &str,
    data: &Value,
    ip: Option<&str>,
) -> Response<ResponseBody> {
    let started = match store
        .rpc(
            "fizz_call_phone_start",
            json!({
                "p_token": token,
                "p_phone": data["phone"].as_str().unwrap_or(""),
                "p_ip": ip.unwrap_or("unknown"),
            }),
        )
        .await
    {
        Ok(value) => value,
        Err(_) => {
            return error(
                503,
                "database_unavailable",
                "Phone pairing is temporarily unavailable.",
            );
        }
    };
    if let Some(response) = phone_error(&started) {
        return response;
    }
    if started["already_paired"] == true {
        return reply(
            200,
            json!({"already_paired": true, "phone": started["phone"]}),
            None,
        );
    }
    let Some(code) = started["code"].as_str() else {
        return error(
            503,
            "database_unavailable",
            "Phone pairing is temporarily unavailable.",
        );
    };
    let Some(phone) = started["phone"].as_str() else {
        return error(
            503,
            "database_unavailable",
            "Phone pairing is temporarily unavailable.",
        );
    };
    let verification_id = started["verification_id"].clone();
    if let Err(problem) = notify::place_pairing_call(phone, code).await {
        let _ = store
            .rpc(
                "fizz_call_phone_cancel",
                json!({"p_token": token, "p_verification_id": verification_id}),
            )
            .await;
        eprintln!("Fizz pairing call was not placed: {problem}");
        return error(
            503,
            "call_failed",
            "The pairing call could not be placed. Wait a minute, then try again.",
        );
    }
    reply(200, client_start_body(&started), None)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn start_response_never_includes_the_spoken_code() {
        let body = client_start_body(&json!({
            "phone": "+14155550123",
            "code": "120456",
            "expires_in_seconds": 600,
            "verification_id": "11111111-1111-4111-8111-111111111111"
        }));
        assert!(body.get("code").is_none());
        assert!(body.get("verification_id").is_none());
        assert_eq!(body["phone"], "+14155550123");
        assert_eq!(body["expires_in_seconds"], 600);
        assert!(!body.to_string().contains("120456"));
    }

    #[tokio::test]
    async fn pairing_errors_use_the_status_the_dashboard_expects() {
        let response = phone_error(&json!({"error": "calls_not_included"})).unwrap();
        assert_eq!(response.status(), 402);
        let response =
            phone_error(&json!({"error": "cooldown", "retry_after_seconds": 60})).unwrap();
        assert_eq!(response.status(), 429);
        assert_eq!(
            response
                .headers()
                .get("retry-after")
                .and_then(|v| v.to_str().ok()),
            Some("60")
        );
        let response = phone_error(&json!({"error": "invalid_code"})).unwrap();
        assert_eq!(response.status(), 400);
    }
}
