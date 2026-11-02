//! Minute scheduler for silence alerts and the notification queue.
//! Vercel Cron calls `GET /api/cron` with `Authorization: Bearer $CRON_SECRET`.
//! The same endpoint accepts a POST from an external scheduler. Overlapping runs
//! are safe: the database claims each rule and each call at most once.

use std::env;

use ring::digest;
use serde_json::{Value, json};
use vercel_runtime::{Request, Response, ResponseBody};

use crate::{
    customer::{error, reply},
    notify::{self, DispatchReport},
    store::Supabase,
};

pub fn cron_authorized(header: Option<&str>, secret: &str) -> bool {
    let Some(header) = header else {
        return false;
    };
    let Some(presented) = header
        .strip_prefix("Bearer ")
        .or_else(|| header.strip_prefix("bearer "))
    else {
        return false;
    };
    let presented = presented.trim();
    if secret.is_empty() || presented.is_empty() {
        return false;
    }
    // Hash both sides so a different length does not short-circuit the compare.
    let presented = digest::digest(&digest::SHA256, presented.as_bytes());
    let secret = digest::digest(&digest::SHA256, secret.as_bytes());
    let mut diff = 0u8;
    for (left, right) in presented.as_ref().iter().zip(secret.as_ref()) {
        diff |= left ^ right;
    }
    diff == 0
}

fn notifications(report: DispatchReport) -> Value {
    json!({
        "configured": report.configured,
        "claimed": report.claimed,
        "sent": report.sent,
        "retry": report.retry,
        "failed": report.failed,
    })
}

pub async fn handle(request: Request) -> Response<ResponseBody> {
    if !matches!(request.method().as_str(), "GET" | "POST") {
        return error(405, "method_not_allowed", "Use GET or POST.");
    }
    let Ok(secret) = env::var("CRON_SECRET") else {
        return error(
            503,
            "cron_unconfigured",
            "Set CRON_SECRET before scheduling alerts.",
        );
    };
    let secret = secret.trim();
    if secret.is_empty()
        || !cron_authorized(
            request
                .headers()
                .get("authorization")
                .and_then(|value| value.to_str().ok()),
            secret,
        )
    {
        return error(401, "unauthorized", "Unauthorized.");
    }
    let Ok(store) = Supabase::from_env() else {
        return error(
            503,
            "database_unavailable",
            "Alerts are temporarily unavailable.",
        );
    };
    let silence = match store
        .rpc("fizz_scan_silence_alerts", json!({"p_limit": 50}))
        .await
    {
        Ok(value) => value,
        Err(problem) => {
            eprintln!("Fizz silence scan failed: {problem:?}");
            json!({"error": "scan_failed"})
        }
    };
    // Dispatch even when the scan failed, so retries do not wait on it.
    let report = notify::dispatch(&store).await;
    let failed = silence.get("error").is_some();
    reply(
        if failed { 503 } else { 200 },
        json!({
            "ok": !failed,
            "silence": silence,
            "notifications": notifications(report),
        }),
        None,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cron_secret_matches_only_the_bearer_value() {
        assert!(cron_authorized(
            Some("Bearer closet-secret"),
            "closet-secret"
        ));
        assert!(cron_authorized(
            Some("bearer closet-secret"),
            "closet-secret"
        ));
        assert!(cron_authorized(
            Some("Bearer  closet-secret  "),
            "closet-secret"
        ));
        assert!(!cron_authorized(
            Some("Bearer closet-secret"),
            "other-secret"
        ));
        assert!(!cron_authorized(
            Some("Bearer closet-secret-extra"),
            "closet-secret"
        ));
        assert!(!cron_authorized(Some("Bearer short"), "closet-secret"));
        assert!(!cron_authorized(Some("closet-secret"), "closet-secret"));
        assert!(!cron_authorized(None, "closet-secret"));
        assert!(!cron_authorized(Some("Bearer "), "closet-secret"));
        assert!(!cron_authorized(Some("Bearer closet-secret"), ""));
    }
}
