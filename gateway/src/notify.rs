//! Approval notifications. A phone approval calls
//! `gateway.reserve_phone_approval_call` and returns. That function takes the
//! shared monthly cap before any dial. This package does not link AgentPhone.
//! `/api/cron` places the queued call with the same client sensor alerts use
//! (`src/notify.rs`). AgentPhone cannot collect a callee keypress, so the
//! spoken call tells the owner to approve in the app.

use std::time::Duration;

use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use url::Url;
use uuid::Uuid;

use crate::error::{GatewayError, GatewayResult};
use crate::policy::{NotifyChannel, short_id};

/// Upstream's guardrail client aborts the RPC after 10 seconds. Notifications
/// stay inside a shorter budget so this process never waits on a person.
pub const NOTIFY_BUDGET: Duration = Duration::from_secs(2);

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PhoneBudget {
    pub reachable: bool,
    pub allowed: bool,
    pub plan: Option<String>,
    pub cap: Option<i64>,
    pub used: i64,
    pub reason: String,
}

impl PhoneBudget {
    pub fn unreachable() -> Self {
        Self {
            reachable: false,
            allowed: false,
            plan: None,
            cap: None,
            used: 0,
            reason: "billing_unreachable".to_string(),
        }
    }
}

/// Approved plan caps. The SQL function is what production evaluates; this
/// mirror is for tests and for reading a budget document.
pub fn tier_cap(plan: &str) -> Option<i64> {
    match plan {
        "hobbyist" => Some(0),
        "tinkerer" => Some(20),
        "pro" => Some(100),
        "enterprise" => None,
        _ => Some(0),
    }
}

pub fn budget_from_json(value: &Value) -> PhoneBudget {
    let reachable = value.get("reachable").and_then(Value::as_bool);
    let allowed = value.get("allowed").and_then(Value::as_bool);
    let reason = value
        .get("reason")
        .and_then(Value::as_str)
        .unwrap_or("billing_unreachable");
    let (Some(reachable), Some(_allowed)) = (reachable, allowed) else {
        return PhoneBudget::unreachable();
    };
    if !reachable {
        return PhoneBudget {
            reachable: false,
            allowed: false,
            plan: None,
            cap: None,
            used: 0,
            reason: "billing_unreachable".to_string(),
        };
    }
    let plan = value
        .get("plan")
        .and_then(Value::as_str)
        .filter(|plan| {
            !plan.is_empty()
                && plan.len() <= 32
                && plan
                    .chars()
                    .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_')
        })
        .map(str::to_string);
    let cap = match value.get("cap") {
        Some(Value::Null) | None => None,
        Some(Value::Number(number)) => number.as_i64().filter(|cap| *cap >= 0),
        _ => return PhoneBudget::unreachable(),
    };
    let used = value.get("used").and_then(Value::as_i64).unwrap_or(0);
    if used < 0 {
        return PhoneBudget::unreachable();
    }
    let allowed = match (plan.as_deref(), cap) {
        (Some(plan), cap) => match tier_cap(plan) {
            None => true,
            Some(expected) => cap == Some(expected) && used < expected,
        },
        _ => false,
    };
    // Prefer the SQL decision when it is stricter than the local mirror.
    let allowed = allowed && allowed_flag(value, allowed);
    PhoneBudget {
        reachable: true,
        allowed,
        plan,
        cap,
        used,
        reason: if allowed {
            reason.to_string()
        } else if reason == "ok" || reason == "unlimited" {
            "cap_reached".to_string()
        } else {
            reason.to_string()
        },
    }
}

fn allowed_flag(value: &Value, mirrored: bool) -> bool {
    match value.get("allowed").and_then(Value::as_bool) {
        Some(false) => false,
        Some(true) => mirrored,
        None => false,
    }
}

pub const APPROVAL_CAP_MESSAGE: &str = "This month's shared call cap is used. No approval call was placed. Approve it in the app. A webhook is used when one is configured. Tinkerer is 20 a month and Pro is 100, shared with sensor alerts.";

pub const APPROVAL_UNPAIRED_MESSAGE: &str = "No paired phone number is on this account. Pair a number in Settings. No approval call was placed. Approve it in the app.";

/// What `gateway.reserve_phone_approval_call` recorded. `reserved` is the only
/// value that queued a dial and consumed the cap.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PhoneReserve {
    pub recorded: String,
    pub reason: String,
    pub message: String,
}

impl PhoneReserve {
    pub fn skipped(reason: &str) -> Self {
        let message = match reason {
            "cap_reached" => APPROVAL_CAP_MESSAGE.to_string(),
            "phone_not_paired" => APPROVAL_UNPAIRED_MESSAGE.to_string(),
            _ => "Phone billing could not be checked. No approval call was placed. Approve it in the app.".to_string(),
        };
        Self {
            recorded: "skipped".to_string(),
            reason: reason.to_string(),
            message,
        }
    }

    pub fn from_json(value: &Value) -> Self {
        let recorded = value
            .get("recorded")
            .and_then(Value::as_str)
            .unwrap_or("skipped");
        let reason = value
            .get("reason")
            .and_then(Value::as_str)
            .unwrap_or("billing_unreachable");
        let message = value
            .get("message")
            .and_then(Value::as_str)
            .filter(|text| !text.is_empty() && text.len() <= 400 && !text.contains('\n'))
            .map(str::to_string);
        if recorded == "reserved" {
            return Self {
                recorded: "reserved".to_string(),
                reason: reason.to_string(),
                message: message
                    .unwrap_or_else(|| "A call to the paired number is queued.".to_string()),
            };
        }
        let mut skipped = Self::skipped(reason);
        if let Some(message) = message {
            skipped.message = message;
        }
        skipped
    }

    pub fn places_call(&self) -> bool {
        self.recorded == "reserved"
    }
}

/// Digit 1 approves and digit 2 denies. AgentPhone does not deliver these
/// digits today; the SQL function applies the same mapping when one arrives.
pub fn decision_from_digit(digit: &str) -> Option<&'static str> {
    match digit.trim() {
        "1" => Some("approved"),
        "2" => Some("denied"),
        _ => None,
    }
}

#[derive(Debug, Clone)]
pub struct ApprovalNotice {
    pub id: Uuid,
    pub gateway_id: Uuid,
    pub server: String,
    pub tool: String,
    pub args_hash: String,
    pub args_preview: String,
    pub ttl_secs: i64,
}

pub fn webhook_body(notice: &ApprovalNotice) -> Value {
    json!({
        "id": notice.id.to_string(),
        "short_id": short_id(notice.id),
        "gateway_id": notice.gateway_id.to_string(),
        "server": safe_label(&notice.server),
        "tool": safe_label(&notice.tool),
        "args_hash": notice.args_hash,
        "args_preview": notice.args_preview,
        "ttl_secs": notice.ttl_secs,
    })
}

pub fn safe_label(value: &str) -> String {
    if !value.is_empty()
        && value.len() <= 128
        && value
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '.' | ':' | '-'))
    {
        value.to_string()
    } else {
        "invalid".to_string()
    }
}

pub fn log_notice(channel: NotifyChannel, notice: &ApprovalNotice, result: &str) {
    eprintln!(
        "fizz-guard: notify channel={} tool={} server={} approval={} result={}",
        channel.as_str(),
        safe_label(&notice.tool),
        safe_label(&notice.server),
        short_id(notice.id),
        safe_label(result)
    );
}

pub struct Notifiers {
    webhook: Option<String>,
    http: reqwest::Client,
}

impl Notifiers {
    pub fn from_env() -> Self {
        let webhook = std::env::var("FIZZ_APPROVAL_WEBHOOK_URL")
            .ok()
            .and_then(|raw| webhook_url(&raw));
        let http = reqwest::Client::builder()
            .timeout(NOTIFY_BUDGET)
            .build()
            .unwrap_or_else(|_| reqwest::Client::new());
        Self { webhook, http }
    }

    pub async fn notify(&self, channel: NotifyChannel, notice: &ApprovalNotice) -> &'static str {
        match channel {
            NotifyChannel::Log => {
                log_notice(channel, notice, "logged");
                "logged"
            }
            NotifyChannel::Webhook => {
                let Some(url) = &self.webhook else {
                    log_notice(channel, notice, "unconfigured");
                    return "unconfigured";
                };
                let outcome = match self.post(url, notice).await {
                    Ok(()) => "sent",
                    Err(_) => "failed",
                };
                log_notice(channel, notice, outcome);
                outcome
            }
            NotifyChannel::Phone => "phone",
        }
    }

    /// Webhook, or a log line, when a phone approval cannot be dialed.
    pub async fn fallback(&self, notice: &ApprovalNotice, message: &str) -> &'static str {
        let Some(url) = &self.webhook else {
            log_notice(NotifyChannel::Log, notice, "fallback");
            return "logged";
        };
        let mut body = webhook_body(notice);
        body["fallback"] = json!(message);
        let outcome = match self.post_value(url, &body).await {
            Ok(()) => "sent",
            Err(_) => "failed",
        };
        log_notice(NotifyChannel::Webhook, notice, outcome);
        outcome
    }

    async fn post(&self, url: &str, notice: &ApprovalNotice) -> GatewayResult<()> {
        self.post_value(url, &webhook_body(notice)).await
    }

    async fn post_value(&self, url: &str, body: &Value) -> GatewayResult<()> {
        let response = tokio::time::timeout(NOTIFY_BUDGET, async {
            self.http
                .post(url)
                .json(body)
                .send()
                .await
                .map_err(|_| GatewayError::message("approval webhook failed"))?
                .error_for_status()
                .map_err(|_| GatewayError::message("approval webhook failed"))?;
            Ok(())
        })
        .await
        .map_err(|_| GatewayError::message("approval webhook timed out"))?;
        response
    }
}

pub fn webhook_url(raw: &str) -> Option<String> {
    let url = Url::parse(raw).ok()?;
    if !url.username().is_empty() || url.password().is_some() {
        return None;
    }
    if !matches!(url.scheme(), "http" | "https") || url.host_str().is_none() {
        return None;
    }
    Some(url.to_string())
}

pub fn token_matches(presented: &str, expected: &str) -> bool {
    if presented.is_empty() || expected.is_empty() || presented.len() > 256 || expected.len() > 256
    {
        return false;
    }
    let left = Sha256::digest(presented.as_bytes());
    let right = Sha256::digest(expected.as_bytes());
    let mut diff = 0u8;
    for (a, b) in left.iter().zip(right.iter()) {
        diff |= a ^ b;
    }
    diff == 0
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn notice() -> ApprovalNotice {
        ApprovalNotice {
            id: Uuid::nil(),
            gateway_id: Uuid::nil(),
            server: "sample".into(),
            tool: "move_funds".into(),
            args_hash: "ab".repeat(32),
            args_preview: "keys:amount".into(),
            ttl_secs: 600,
        }
    }

    #[test]
    fn caps_match_the_plan_and_only_a_reserve_dials() {
        assert_eq!(tier_cap("hobbyist"), Some(0));
        assert_eq!(tier_cap("tinkerer"), Some(20));
        assert_eq!(tier_cap("pro"), Some(100));
        assert_eq!(tier_cap("enterprise"), None);
        assert_eq!(tier_cap("other"), Some(0));

        let hobbyist = budget_from_json(&json!({
            "reachable": true, "allowed": false, "plan": "hobbyist", "cap": 0, "used": 0, "reason": "cap_reached"
        }));
        assert!(!hobbyist.allowed);
        assert!(!PhoneReserve::skipped("cap_reached").places_call());

        let tinkerer = budget_from_json(&json!({
            "reachable": true, "allowed": true, "plan": "tinkerer", "cap": 20, "used": 19, "reason": "ok"
        }));
        assert!(tinkerer.allowed);
        let queued = PhoneReserve::from_json(&json!({
            "recorded": "reserved", "reason": "ok", "message": "A call to the paired number is queued."
        }));
        assert!(queued.places_call());
        let over = PhoneReserve::from_json(&json!({
            "recorded": "skipped", "reason": "cap_reached", "allowed": false
        }));
        assert!(!over.places_call());
        assert!(over.message.contains("Approve it in the app"));

        let exhausted = budget_from_json(&json!({
            "reachable": true, "allowed": false, "plan": "pro", "cap": 100, "used": 100, "reason": "cap_reached"
        }));
        assert!(!exhausted.allowed);

        let missing = budget_from_json(
            &json!({"reachable": false, "allowed": false, "reason": "billing_unreachable"}),
        );
        assert!(!missing.reachable);
        assert!(!PhoneReserve::skipped("billing_unreachable").places_call());
        assert_eq!(decision_from_digit("1"), Some("approved"));
        assert_eq!(decision_from_digit("2"), Some("denied"));
        assert_eq!(decision_from_digit("9"), None);

        let lied = budget_from_json(&json!({
            "reachable": true, "allowed": true, "plan": "hobbyist", "cap": 0, "used": 0, "reason": "ok"
        }));
        assert!(!lied.allowed);
    }

    #[test]
    fn webhook_body_has_no_argument_values() {
        let body = webhook_body(&notice());
        let text = body.to_string();
        assert!(text.contains("move_funds"));
        assert!(text.contains("keys:amount"));
        assert!(!text.contains("secret-value"));
        assert!(text.contains(&short_id(Uuid::nil())));
        assert!(webhook_url("http://hooks.example/approvals").is_some());
        assert!(webhook_url("http://user:secret@hooks.example/approvals").is_none());
        assert!(NOTIFY_BUDGET < Duration::from_secs(10));
    }

    #[test]
    fn token_compare_rejects_empty_and_matches_equal_values() {
        assert!(!token_matches("", "abc"));
        assert!(token_matches("abc", "abc"));
        assert!(!token_matches("abc", "abd"));
    }
}
