//! Tool-description pins. The hash is sha256 of the canonical JSON of the
//! tool name, description, and input schema. Other fields (annotations, titles)
//! are not part of the pin.

use serde_json::{Map, Value};
use sha2::{Digest, Sha256};

use crate::policy::canonical_json;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PinStatus {
    Unreviewed,
    Approved,
    Changed,
}

impl PinStatus {
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "unreviewed" => Some(Self::Unreviewed),
            "approved" => Some(Self::Approved),
            "changed" => Some(Self::Changed),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Unreviewed => "unreviewed",
            Self::Approved => "approved",
            Self::Changed => "changed",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PinRecord {
    pub pin_sha256: String,
    pub observed_sha256: String,
    pub status: PinStatus,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PinDecision {
    pub pin_sha256: String,
    pub observed_sha256: String,
    pub status: PinStatus,
    pub alert: bool,
    pub show: bool,
}

/// `show_unreviewed` is the gateway policy: hide or show a tool nobody has approved.
/// A hash that differs from an approved pin is never shown.
pub fn review_pin(
    existing: Option<&PinRecord>,
    observed: &str,
    show_unreviewed: bool,
) -> PinDecision {
    match existing {
        None => PinDecision {
            pin_sha256: observed.to_string(),
            observed_sha256: observed.to_string(),
            status: PinStatus::Unreviewed,
            alert: false,
            show: show_unreviewed,
        },
        Some(row) if row.status == PinStatus::Unreviewed => PinDecision {
            pin_sha256: observed.to_string(),
            observed_sha256: observed.to_string(),
            status: PinStatus::Unreviewed,
            alert: false,
            show: show_unreviewed,
        },
        Some(row) if row.pin_sha256 == observed => PinDecision {
            pin_sha256: row.pin_sha256.clone(),
            observed_sha256: observed.to_string(),
            status: PinStatus::Approved,
            alert: false,
            show: true,
        },
        Some(row) => PinDecision {
            pin_sha256: row.pin_sha256.clone(),
            observed_sha256: observed.to_string(),
            status: PinStatus::Changed,
            alert: row.status != PinStatus::Changed || row.observed_sha256 != observed,
            show: false,
        },
    }
}

pub fn pin_blocks_call(row: Option<&PinRecord>) -> bool {
    !matches!(
        row,
        Some(row) if row.status == PinStatus::Approved && row.pin_sha256 == row.observed_sha256
    )
}

pub fn pin_block_message(tool: &str, row: Option<&PinRecord>) -> String {
    let name = display_tool(tool);
    match row {
        Some(row) if row.status == PinStatus::Changed || row.pin_sha256 != row.observed_sha256 => {
            format!(
                "Tool {name} was blocked because its description changed. Approve the new description, then retry."
            )
        }
        _ => format!("Tool {name} is not approved."),
    }
}

pub fn tool_name_ok(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 128
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '.' | ':' | '-'))
}

fn display_tool(tool: &str) -> &str {
    if tool_name_ok(tool) {
        tool
    } else {
        "that tool"
    }
}

pub fn description_preview(description: &str) -> String {
    let mut out = String::new();
    for ch in description.chars() {
        if out.chars().count() >= 200 {
            break;
        }
        if ch.is_control() {
            out.push(' ');
        } else {
            out.push(ch);
        }
    }
    out
}

pub fn pin_hash(name: &str, description: &str, input_schema: &Value) -> String {
    let material = serde_json::json!({
        "description": description,
        "inputSchema": input_schema,
        "name": name,
    });
    let canonical = canonical_json(&material);
    let bytes = serde_json::to_vec(&canonical).unwrap_or_else(|_| b"{}".to_vec());
    hex::encode(Sha256::digest(&bytes))
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParsedTool {
    pub name: String,
    pub description: String,
    pub input_schema: Value,
}

pub fn parse_tool_list(bytes: &[u8]) -> Option<Vec<ParsedTool>> {
    let value: Value = serde_json::from_slice(bytes).ok()?;
    let tools = value.get("tools").and_then(Value::as_array)?;
    let mut parsed = Vec::with_capacity(tools.len());
    for tool in tools {
        let name = tool
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        let description = tool
            .get("description")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        let input_schema = tool
            .get("inputSchema")
            .cloned()
            .unwrap_or_else(|| Value::Object(Map::new()));
        parsed.push(ParsedTool {
            name,
            description,
            input_schema,
        });
    }
    Some(parsed)
}

/// `keep` aligns with the tools array. `None` means the body was not a tool list.
pub fn filter_tool_list(bytes: &[u8], keep: &[bool]) -> Option<ToolListFilter> {
    let mut value: Value = serde_json::from_slice(bytes).ok()?;
    let tools = value.get_mut("tools").and_then(Value::as_array_mut)?;
    if tools.len() != keep.len() {
        return None;
    }
    if keep.iter().all(|item| *item) {
        return Some(ToolListFilter::Unchanged);
    }
    let mut index = 0;
    tools.retain(|_| {
        let stay = keep[index];
        index += 1;
        stay
    });
    serde_json::to_vec(&value)
        .ok()
        .map(ToolListFilter::Replaced)
}

pub enum ToolListFilter {
    Unchanged,
    Replaced(Vec<u8>),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Attributed {
    pub server: String,
    pub tool: String,
}

/// One backend: the listed name is that backend's tool. Several backends: a
/// `{server}_` prefix (longest match) is the multiplexed name agentgateway adds.
/// With `prefixMode: never` and more than one backend the name is not prefixed,
/// so the server is left empty and the caller cannot record a pin for it.
pub fn attribute_tool(services: &[String], client_name: &str) -> Attributed {
    if let [only] = services {
        return Attributed {
            server: only.clone(),
            tool: client_name.to_string(),
        };
    }
    let mut best: Option<(usize, String, String)> = None;
    for server in services {
        let prefix = format!("{server}_");
        if let Some(rest) = client_name.strip_prefix(&prefix) {
            if rest.is_empty() {
                continue;
            }
            if best
                .as_ref()
                .map(|(len, _, _)| prefix.len() > *len)
                .unwrap_or(true)
            {
                best = Some((prefix.len(), server.clone(), rest.to_string()));
            }
        }
    }
    match best {
        Some((_, server, tool)) => Attributed { server, tool },
        None => Attributed {
            server: String::new(),
            tool: client_name.to_string(),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn approved(hash: &str) -> PinRecord {
        PinRecord {
            pin_sha256: hash.to_string(),
            observed_sha256: hash.to_string(),
            status: PinStatus::Approved,
        }
    }

    #[test]
    fn new_tools_follow_the_visibility_policy_and_changes_are_stripped() {
        let fresh = review_pin(None, "abc", false);
        assert_eq!(fresh.status, PinStatus::Unreviewed);
        assert!(!fresh.show);
        assert!(!fresh.alert);
        assert!(review_pin(None, "abc", true).show);

        let same = review_pin(Some(&approved("abc")), "abc", false);
        assert_eq!(same.status, PinStatus::Approved);
        assert!(same.show);
        assert!(!same.alert);
        assert!(!pin_blocks_call(Some(&approved("abc"))));

        let changed = review_pin(Some(&approved("abc")), "def", true);
        assert_eq!(changed.status, PinStatus::Changed);
        assert!(!changed.show);
        assert!(changed.alert);
        assert_eq!(changed.pin_sha256, "abc");
        assert!(pin_blocks_call(Some(&PinRecord {
            pin_sha256: changed.pin_sha256.clone(),
            observed_sha256: changed.observed_sha256.clone(),
            status: changed.status,
        })));

        let again = review_pin(
            Some(&PinRecord {
                pin_sha256: "abc".to_string(),
                observed_sha256: "def".to_string(),
                status: PinStatus::Changed,
            }),
            "def",
            true,
        );
        assert!(!again.alert);
        assert!(!again.show);

        let reverted = review_pin(
            Some(&PinRecord {
                pin_sha256: "abc".to_string(),
                observed_sha256: "def".to_string(),
                status: PinStatus::Changed,
            }),
            "abc",
            false,
        );
        assert_eq!(reverted.status, PinStatus::Approved);
        assert!(reverted.show);
    }

    #[test]
    fn unapproved_pins_block_calls() {
        assert!(pin_blocks_call(None));
        assert!(pin_blocks_call(Some(&PinRecord {
            pin_sha256: "abc".into(),
            observed_sha256: "abc".into(),
            status: PinStatus::Unreviewed,
        })));
        let missing = pin_block_message("ping", None);
        assert!(missing.contains("not approved"));
        assert!(!missing.contains("secret"));
        let changed = pin_block_message(
            "note",
            Some(&PinRecord {
                pin_sha256: "a".into(),
                observed_sha256: "b".into(),
                status: PinStatus::Changed,
            }),
        );
        assert!(changed.contains("description changed"));
        assert!(changed.contains("note"));
    }

    #[test]
    fn hash_sorts_schema_keys_and_ignores_extra_tool_fields() {
        let schema = json!({"type": "object", "properties": {}, "additionalProperties": false});
        let left = pin_hash("ping", "Return pong.", &schema);
        let right = pin_hash(
            "ping",
            "Return pong.",
            &json!({"additionalProperties": false, "properties": {}, "type": "object"}),
        );
        assert_eq!(left, right);
        assert_eq!(left.len(), 64);
        assert_ne!(left, pin_hash("ping", "Return pong. Revised.", &schema));
    }

    #[test]
    fn filter_removes_only_the_marked_tools() {
        let raw = serde_json::to_vec(&json!({
            "tools": [
                {"name": "ping", "description": "Return pong."},
                {"name": "note", "description": "Leave a note."}
            ],
            "nextCursor": null
        }))
        .unwrap();
        assert!(matches!(
            filter_tool_list(&raw, &[true, true]),
            Some(ToolListFilter::Unchanged)
        ));
        let ToolListFilter::Replaced(changed) = filter_tool_list(&raw, &[true, false]).unwrap()
        else {
            panic!("expected a replaced list");
        };
        let value: Value = serde_json::from_slice(&changed).unwrap();
        let names: Vec<_> = value["tools"]
            .as_array()
            .unwrap()
            .iter()
            .map(|tool| tool["name"].as_str().unwrap())
            .collect();
        assert_eq!(names, ["ping"]);
        assert!(value.get("nextCursor").is_some());
    }

    #[test]
    fn attribution_uses_one_backend_or_the_longest_prefix() {
        let one = attribute_tool(&["sample".into()], "ping");
        assert_eq!(one.server, "sample");
        assert_eq!(one.tool, "ping");
        let muxed = attribute_tool(&["sample".into(), "other".into()], "sample_move_funds");
        assert_eq!(muxed.server, "sample");
        assert_eq!(muxed.tool, "move_funds");
        let bare = attribute_tool(&["sample".into(), "other".into()], "ping");
        assert_eq!(bare.server, "");
        assert_eq!(bare.tool, "ping");
    }

    #[test]
    fn migration_documents_the_shared_call_caps() {
        let sql = include_str!("../../supabase/migrations/20261114000300_gateway_policies.sql");
        assert!(sql.contains("when 'hobbyist' then 0"));
        assert!(sql.contains("when 'tinkerer' then 20"));
        assert!(sql.contains("when 'pro' then 100"));
        assert!(sql.contains("billing_unreachable"));
        assert!(sql.contains("enable row level security"));
        assert!(!sql.contains("20261114000400_"));
    }
}
