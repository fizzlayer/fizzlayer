//! Pure allow / deny / approval decisions. The database and the gRPC server
//! sit outside this module so the rules can be tested without either.

use serde_json::{Map, Value};
use sha2::{Digest, Sha256};
use uuid::Uuid;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Effect {
    Allow,
    Deny,
    Approve,
}

impl Effect {
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "allow" => Some(Self::Allow),
            "deny" => Some(Self::Deny),
            "approve" => Some(Self::Approve),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NotifyChannel {
    Log,
    Webhook,
    Phone,
}

impl NotifyChannel {
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "log" => Some(Self::Log),
            "webhook" => Some(Self::Webhook),
            "phone" => Some(Self::Phone),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Log => "log",
            Self::Webhook => "webhook",
            Self::Phone => "phone",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PolicyRule {
    pub server_name: Option<String>,
    pub tool_name: String,
    pub effect: Effect,
    pub notify_channel: NotifyChannel,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ApprovalHit {
    None,
    Pending { id: Uuid },
    Approved { id: Uuid },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Step {
    Allow {
        decision: &'static str,
    },
    Reject {
        decision: &'static str,
        reason: String,
    },
    /// An approver already accepted this exact call. The caller marks it consumed.
    Consume {
        id: Uuid,
    },
    /// No usable approval yet. The caller inserts a pending row, then rejects.
    OpenApproval,
}

/// Most specific rule wins: server+tool, server+wildcard, any-server+tool, any-server wildcard.
/// No matching rule denies the call.
pub fn match_effect(rules: &[PolicyRule], server: &str, tool: &str) -> Effect {
    let mut best: Option<(u8, Effect)> = None;
    for rule in rules {
        let rank = match (&rule.server_name, rule.tool_name.as_str()) {
            (Some(name), tool_name) if name == server && tool_name == tool => 4,
            (Some(name), "*") if name == server => 3,
            (None, tool_name) if tool_name == tool => 2,
            (None, "*") => 1,
            _ => continue,
        };
        if best.map(|(current, _)| rank > current).unwrap_or(true) {
            best = Some((rank, rule.effect));
        }
    }
    best.map(|(_, effect)| effect).unwrap_or(Effect::Deny)
}

/// Channel on the same winning rule as [`match_effect`]. Missing rules log only.
pub fn match_channel(rules: &[PolicyRule], server: &str, tool: &str) -> NotifyChannel {
    let mut best: Option<(u8, NotifyChannel)> = None;
    for rule in rules {
        let rank = match (&rule.server_name, rule.tool_name.as_str()) {
            (Some(name), tool_name) if name == server && tool_name == tool => 4,
            (Some(name), "*") if name == server => 3,
            (None, tool_name) if tool_name == tool => 2,
            (None, "*") => 1,
            _ => continue,
        };
        if best.map(|(current, _)| rank > current).unwrap_or(true) {
            best = Some((rank, rule.notify_channel));
        }
    }
    best.map(|(_, channel)| channel)
        .unwrap_or(NotifyChannel::Log)
}

pub fn decide(effect: Effect, approval: ApprovalHit, tool: &str) -> Step {
    match effect {
        Effect::Allow => Step::Allow { decision: "allow" },
        Effect::Deny => Step::Reject {
            decision: "deny",
            reason: deny_message(tool),
        },
        Effect::Approve => match approval {
            ApprovalHit::Approved { id } => Step::Consume { id },
            ApprovalHit::Pending { .. } | ApprovalHit::None => Step::OpenApproval,
        },
    }
}

pub fn deny_message(tool: &str) -> String {
    format!("Tool {} is not allowed.", display_tool(tool))
}

/// Reject-then-retry text. The caller has already stored a pending approval.
/// A phone or chat notification is intentionally not sent by this skeleton.
pub fn approval_message(id: Uuid) -> String {
    format!(
        "Approval required: an approver was notified (id {}). Ask the user to approve, then retry the same call.",
        short_id(id)
    )
}

pub fn short_id(id: Uuid) -> String {
    id.simple().to_string().chars().take(8).collect()
}

fn display_tool(tool: &str) -> &str {
    let ok = !tool.is_empty()
        && tool.len() <= 128
        && tool
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '.' | ':' | '-'));
    if ok { tool } else { "that tool" }
}

pub fn fingerprint(arguments: &Value) -> (String, String) {
    let canonical = canonical_json(arguments);
    let bytes = serde_json::to_vec(&canonical).unwrap_or_else(|_| b"{}".to_vec());
    let hash = hex::encode(Sha256::digest(&bytes));
    (hash, preview(arguments))
}

pub(crate) fn canonical_json(value: &Value) -> Value {
    match value {
        Value::Object(map) => {
            let mut keys: Vec<&String> = map.keys().collect();
            keys.sort();
            let mut out = Map::new();
            for key in keys {
                out.insert(key.clone(), canonical_json(&map[key]));
            }
            Value::Object(out)
        }
        Value::Array(items) => Value::Array(items.iter().map(canonical_json).collect()),
        other => other.clone(),
    }
}

fn preview(arguments: &Value) -> String {
    let keys = match arguments {
        Value::Object(map) => {
            let mut keys: Vec<&String> = map.keys().collect();
            keys.sort();
            keys.into_iter().cloned().collect::<Vec<_>>().join(",")
        }
        _ => String::new(),
    };
    let mut text = format!("keys:{keys}");
    if text.len() > 120 {
        text.truncate(120);
    }
    text
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn rule(server: Option<&str>, tool: &str, effect: Effect) -> PolicyRule {
        PolicyRule {
            server_name: server.map(str::to_string),
            tool_name: tool.to_string(),
            effect,
            notify_channel: NotifyChannel::Log,
        }
    }

    fn sample() -> Vec<PolicyRule> {
        vec![
            rule(Some("sample"), "ping", Effect::Allow),
            rule(Some("sample"), "admin_reset", Effect::Deny),
            rule(Some("sample"), "move_funds", Effect::Approve),
            rule(Some("sample"), "*", Effect::Deny),
            rule(None, "ping", Effect::Deny),
        ]
    }

    #[test]
    fn specificity_prefers_the_server_tool_rule() {
        let rules = sample();
        assert_eq!(match_effect(&rules, "sample", "ping"), Effect::Allow);
        assert_eq!(match_effect(&rules, "sample", "admin_reset"), Effect::Deny);
        assert_eq!(
            match_effect(&rules, "sample", "move_funds"),
            Effect::Approve
        );
        assert_eq!(match_effect(&rules, "sample", "other"), Effect::Deny);
        assert_eq!(match_effect(&rules, "other", "ping"), Effect::Deny);
        assert_eq!(match_effect(&[], "sample", "ping"), Effect::Deny);
    }

    #[test]
    fn approval_is_single_use_after_a_matching_grant() {
        assert!(matches!(
            decide(Effect::Allow, ApprovalHit::None, "ping"),
            Step::Allow { decision: "allow" }
        ));
        assert!(matches!(
            decide(
                Effect::Deny,
                ApprovalHit::Approved { id: Uuid::nil() },
                "admin_reset"
            ),
            Step::Reject {
                decision: "deny",
                ..
            }
        ));
        assert!(matches!(
            decide(Effect::Approve, ApprovalHit::None, "move_funds"),
            Step::OpenApproval
        ));
        let id = Uuid::nil();
        assert!(matches!(
            decide(Effect::Approve, ApprovalHit::Pending { id }, "move_funds"),
            Step::OpenApproval
        ));
        assert_eq!(
            decide(Effect::Approve, ApprovalHit::Approved { id }, "move_funds"),
            Step::Consume { id }
        );
    }

    #[test]
    fn approval_text_asks_for_a_retry_and_hides_arguments() {
        let id = Uuid::parse_str("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee").unwrap();
        let message = approval_message(id);
        assert!(message.contains("Approval required"));
        assert!(message.contains("retry the same call"));
        assert!(message.contains(&short_id(id)));
        assert!(!message.contains("secret"));
        assert_eq!(
            deny_message("admin_reset"),
            "Tool admin_reset is not allowed."
        );
        assert_eq!(deny_message("has space"), "Tool that tool is not allowed.");
    }

    #[test]
    fn fingerprint_sorts_keys_and_drops_values() {
        let (left, preview_left) = fingerprint(&json!({"b": "secret-value", "a": 1}));
        let (right, _) = fingerprint(&json!({"a": 1, "b": "secret-value"}));
        assert_eq!(left, right);
        assert_eq!(left.len(), 64);
        assert_eq!(preview_left, "keys:a,b");
        assert!(!preview_left.contains("secret-value"));
        let (empty, preview_empty) = fingerprint(&json!({}));
        assert_ne!(empty, left);
        assert_eq!(preview_empty, "keys:");
    }
}
