//! Minute scheduler for silence alerts and the notification queue.
//! Vercel Cron calls `GET /api/cron` with `Authorization: Bearer $CRON_SECRET`.
//! The same endpoint accepts a POST from an external scheduler. Overlapping runs
//! are safe: the database claims each rule and each call at most once.

use std::{
    env,
    time::{Duration, Instant},
};

use ring::digest;
use serde_json::{Value, json};
use vercel_runtime::{Request, Response, ResponseBody};

use crate::{
    customer::{error, reply},
    notify::{self, DispatchReport},
    store::Supabase,
};

/// A missing or blank secret means the scheduler is not configured.
pub fn configured_cron_secret(value: Option<&str>) -> Option<&str> {
    value.map(str::trim).filter(|secret| !secret.is_empty())
}

#[must_use]
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
    // ring's compare is deprecated as a public API, but it is still the
    // constant-time check. Hashing first keeps both slices the same length.
    #[allow(deprecated)]
    {
        ring::constant_time::verify_slices_are_equal(presented.as_ref(), secret.as_ref()).is_ok()
    }
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

/// Stop starting new calls after this long. One more pass is an agent lookup
/// plus one dial, each capped at 8 seconds, so a run still ends inside the
/// 60-second function budget the docs ask for.
const DISPATCH_BUDGET: Duration = Duration::from_secs(36);

/// Send queued calls one at a time until the queue is empty or the budget is
/// spent. Silence calls have no reading to ride on, so this is their only path:
/// one call per run would cap the whole deployment at about 60 calls an hour.
async fn drain_queue(store: &Supabase, started: Instant) -> DispatchReport {
    let mut total = DispatchReport {
        configured: false,
        claimed: 0,
        sent: 0,
        retry: 0,
        failed: 0,
    };
    while started.elapsed() < DISPATCH_BUDGET {
        let pass = notify::dispatch_limited(store, 1).await;
        total.configured |= pass.configured;
        total.claimed += pass.claimed;
        total.sent += pass.sent;
        total.retry += pass.retry;
        total.failed += pass.failed;
        // Nothing claimed means the queue is empty, AgentPhone is unconfigured,
        // or the claim failed. A retry stays in the queue for the next run.
        if pass.claimed == 0 || pass.retry > 0 {
            break;
        }
    }
    total
}

struct Tick {
    ok: bool,
    silence: Value,
    notifications: Value,
}

async fn tick(store: &Supabase) -> Tick {
    let started = Instant::now();
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
    let report = drain_queue(store, started).await;
    let failed = silence.get("error").is_some();
    Tick {
        ok: !failed,
        silence,
        notifications: notifications(report),
    }
}

/// One scheduler pass. The self-host server calls this every minute. There is no
/// HTTP secret here: the process is already inside the deployment. `GET /api/cron`
/// still requires `CRON_SECRET`.
///
/// # Errors
///
/// Returns an error when Supabase is not configured. A failed tick is reported in
/// the log and still returns `Ok`.
pub async fn run_scheduled() -> Result<(), String> {
    let store = Supabase::from_env().map_err(|_| "database is not configured".to_owned())?;
    let tick = tick(&store).await;
    if tick.ok {
        Ok(())
    } else {
        Err("silence scan failed".to_owned())
    }
}

pub async fn handle(request: Request) -> Response<ResponseBody> {
    if !matches!(request.method().as_str(), "GET" | "POST") {
        return error(405, "method_not_allowed", "Use GET or POST.");
    }
    let secret_var = env::var("CRON_SECRET").ok();
    let Some(secret) = configured_cron_secret(secret_var.as_deref()) else {
        return error(
            503,
            "cron_unconfigured",
            "Set CRON_SECRET before scheduling alerts.",
        );
    };
    if !cron_authorized(
        request
            .headers()
            .get("authorization")
            .and_then(|value| value.to_str().ok()),
        secret,
    ) {
        return error(401, "unauthorized", "Unauthorized.");
    }
    let Ok(store) = Supabase::from_env() else {
        return error(
            503,
            "database_unavailable",
            "Alerts are temporarily unavailable.",
        );
    };
    let tick = tick(&store).await;
    reply(
        if tick.ok { 200 } else { 503 },
        json!({
            "ok": tick.ok,
            "silence": tick.silence,
            "notifications": tick.notifications,
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
        assert_eq!(configured_cron_secret(None), None);
        assert_eq!(configured_cron_secret(Some("")), None);
        assert_eq!(configured_cron_secret(Some("   ")), None);
        assert_eq!(
            configured_cron_secret(Some("  closet-secret  ")),
            Some("closet-secret")
        );
    }
}
