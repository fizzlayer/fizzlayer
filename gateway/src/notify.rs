//! Approval notifications. The phone arm is a stub: it checks the shared
//! monthly cap and writes a log line. It does not call AgentPhone and it does
//! not reserve a cap slot. The live dialer, when it exists, must call
//! `gateway.reserve_phone_approval_call` before placing a call. Sensor alerts
//! already dial through `AgentPhone` in the API crate (`src/notify.rs`); this
//! package does not link that client.

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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PhoneAttempt {
    /// Budget allowed a call. The stub still does not dial and does not reserve.
    Stubbed,
    Skipped,
}

impl PhoneAttempt {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Stubbed => "stubbed",
            Self::Skipped => "skipped",
        }
    }
}

pub fn phone_attempt(budget: &PhoneBudget) -> PhoneAttempt {
    if budget.reachable && budget.allowed {
        PhoneAttempt::Stubbed
    } else {
        PhoneAttempt::Skipped
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

    async fn post(&self, url: &str, notice: &ApprovalNotice) -> GatewayResult<()> {
        let response = tokio::time::timeout(NOTIFY_BUDGET, async {
            self.http
                .post(url)
                .json(&webhook_body(notice))
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
    fn caps_match_the_plan_and_a_stub_never_reserves() {
        assert_eq!(tier_cap("hobbyist"), Some(0));
        assert_eq!(tier_cap("tinkerer"), Some(20));
        assert_eq!(tier_cap("pro"), Some(100));
        assert_eq!(tier_cap("enterprise"), None);
        assert_eq!(tier_cap("other"), Some(0));

        let hobbyist = budget_from_json(&json!({
            "reachable": true, "allowed": false, "plan": "hobbyist", "cap": 0, "used": 0, "reason": "cap_reached"
        }));
        assert!(!hobbyist.allowed);
        assert_eq!(phone_attempt(&hobbyist), PhoneAttempt::Skipped);

        let tinkerer = budget_from_json(&json!({
            "reachable": true, "allowed": true, "plan": "tinkerer", "cap": 20, "used": 19, "reason": "ok"
        }));
        assert!(tinkerer.allowed);
        assert_eq!(phone_attempt(&tinkerer), PhoneAttempt::Stubbed);
        assert_ne!(phone_attempt(&tinkerer).as_str(), "reserved");

        let exhausted = budget_from_json(&json!({
            "reachable": true, "allowed": false, "plan": "pro", "cap": 100, "used": 100, "reason": "cap_reached"
        }));
        assert_eq!(phone_attempt(&exhausted), PhoneAttempt::Skipped);

        let missing = budget_from_json(
            &json!({"reachable": false, "allowed": false, "reason": "billing_unreachable"}),
        );
        assert!(!missing.reachable);
        assert_eq!(phone_attempt(&missing), PhoneAttempt::Skipped);

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
