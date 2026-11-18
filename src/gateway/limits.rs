//! Plan numbers from the platform plan, section B4.
//! `supabase/migrations/20261114000400_gateway_control_plane.sql` stores the same
//! figures on `fizz_plans`. This module is what the in-memory test double and
//! the upgrade errors use.

use crate::customer::ApiError;

#[cfg_attr(not(test), allow(dead_code))]
pub struct Plan {
    pub id: &'static str,
    pub name: &'static str,
    pub gateway_limit: Option<i64>,
    pub server_limit: Option<i64>,
    pub stdio: bool,
    pub dedicated: bool,
    pub seat_limit: Option<i64>,
    pub tool_calls_per_month: Option<i64>,
    pub phone_calls_per_month: Option<i64>,
    pub audit_retention_days: Option<i64>,
}

#[cfg_attr(not(test), allow(dead_code))]
pub fn plan(id: &str) -> Plan {
    match id {
        "tinkerer" => Plan {
            id: "tinkerer",
            name: "Tinkerer",
            gateway_limit: Some(1),
            server_limit: Some(10),
            stdio: false,
            dedicated: false,
            seat_limit: Some(1),
            tool_calls_per_month: Some(50_000),
            phone_calls_per_month: Some(20),
            audit_retention_days: Some(30),
        },
        "pro" => Plan {
            id: "pro",
            name: "Pro",
            gateway_limit: Some(1),
            server_limit: Some(25),
            stdio: true,
            dedicated: true,
            seat_limit: Some(3),
            tool_calls_per_month: Some(200_000),
            phone_calls_per_month: Some(100),
            audit_retention_days: Some(90),
        },
        "enterprise" => Plan {
            id: "enterprise",
            name: "Enterprise",
            gateway_limit: None,
            server_limit: None,
            stdio: true,
            dedicated: true,
            seat_limit: None,
            tool_calls_per_month: None,
            phone_calls_per_month: None,
            audit_retention_days: None,
        },
        _ => Plan {
            id: "hobbyist",
            name: "Hobbyist",
            gateway_limit: Some(1),
            server_limit: Some(3),
            stdio: false,
            dedicated: false,
            seat_limit: Some(1),
            tool_calls_per_month: Some(10_000),
            phone_calls_per_month: Some(0),
            audit_retention_days: Some(7),
        },
    }
}

#[cfg_attr(not(test), allow(dead_code))]
pub fn default_mode(dedicated: bool) -> &'static str {
    if dedicated { "dedicated" } else { "shared" }
}

pub fn map_code(code: &str, agent: bool) -> ApiError {
    match code {
        "unauthorized" => ApiError::new(401, "unauthorized", "Sign in to continue."),
        "not_found" if agent => {
            ApiError::new(401, "unauthorized", "Registration token was rejected.")
        }
        "not_found" => ApiError::new(404, "not_found", "Gateway not found."),
        "forbidden" => ApiError::new(
            403,
            "forbidden",
            "Only an owner or admin can change this gateway.",
        ),
        "gateway_limit" => ApiError::new(
            402,
            "gateway_limit",
            "Your plan's gateway limit is reached. Hobbyist and Tinkerer include 1 shared gateway, and Pro includes 1 dedicated gateway. Remove a gateway or upgrade.",
        ),
        "server_limit" => ApiError::new(
            402,
            "server_limit",
            "Your plan's MCP server limit is reached. Hobbyist includes 3, Tinkerer 10, and Pro 25. Remove a server or upgrade.",
        ),
        "stdio_not_included" => ApiError::new(
            402,
            "stdio_not_included",
            "stdio servers are included on Pro, which also includes a dedicated gateway. Upgrade to Pro, or add a remote http or sse server.",
        ),
        "stdio_shared" => ApiError::new(
            400,
            "stdio_shared",
            "A shared gateway does not run stdio servers. Use a dedicated gateway, which is included on Pro.",
        ),
        "dedicated_not_included" => ApiError::new(
            402,
            "dedicated_not_included",
            "A dedicated gateway is included on Pro. Upgrade to Pro, or create a shared gateway.",
        ),
        "seat_limit" => ApiError::new(
            402,
            "seat_limit",
            "Your plan's seat limit is reached. Pro includes 3 seats. Remove a member or upgrade.",
        ),
        "conflict" => ApiError::new(409, "conflict", "That name is already used."),
        "invalid_request" => ApiError::new(400, "invalid_request", "Check the gateway request."),
        "rate_limited" => ApiError::new(
            429,
            "rate_limited",
            "Too many gateway requests. Try again later.",
        )
        .retry_after("60"),
        "disabled" => ApiError::new(
            409,
            "gateway_disabled",
            "This gateway is disabled because it is over the plan limit. Remove one or upgrade, then it can run again.",
        ),
        "missing_secret" => ApiError::new(
            503,
            "missing_secret",
            "A stored MCP credential could not be read.",
        ),
        _ => ApiError::new(
            503,
            "database_unavailable",
            "Gateway data is temporarily unavailable.",
        ),
    }
}

pub fn gateway_name_ok(name: &str) -> bool {
    let bytes = name.as_bytes();
    !bytes.is_empty()
        && bytes.len() <= 41
        && bytes[0].is_ascii_lowercase()
        && bytes
            .iter()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || *c == b'-')
        && *bytes.last().unwrap_or(&b'-') != b'-'
}

pub fn server_name_ok(name: &str) -> bool {
    let bytes = name.as_bytes();
    !bytes.is_empty()
        && bytes.len() <= 41
        && bytes[0].is_ascii_lowercase()
        && bytes
            .iter()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || matches!(*c, b'-' | b'_'))
}

pub fn tool_name_ok(name: &str) -> bool {
    name == "*"
        || (1..=128).contains(&name.len())
            && name
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, b'_' | b'.' | b':' | b'-'))
}

pub fn remote_url_ok(value: &str) -> bool {
    if !(8..=500).contains(&value.len())
        || value.chars().any(|c| c.is_control() || c.is_whitespace())
        || value.contains('@')
    {
        return false;
    }
    let Some(rest) = value
        .strip_prefix("https://")
        .or_else(|| value.strip_prefix("http://"))
    else {
        return false;
    };
    let host = rest.split(['/', '?', '#']).next().unwrap_or("");
    !host.is_empty() && !host.starts_with(':')
}

pub fn command_ok(value: &str) -> bool {
    (1..=200).contains(&value.len()) && !value.chars().any(|c| c.is_control() || c.is_whitespace())
}

pub fn effect_ok(value: &str) -> bool {
    matches!(value, "allow" | "deny" | "approve")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn approved_tier_limits() {
        let hobbyist = plan("hobbyist");
        assert_eq!(hobbyist.gateway_limit, Some(1));
        assert_eq!(hobbyist.server_limit, Some(3));
        assert!(!hobbyist.stdio);
        assert!(!hobbyist.dedicated);
        assert_eq!(hobbyist.phone_calls_per_month, Some(0));
        let tinkerer = plan("tinkerer");
        assert_eq!(tinkerer.server_limit, Some(10));
        assert_eq!(tinkerer.phone_calls_per_month, Some(20));
        let pro = plan("pro");
        assert!(pro.dedicated && pro.stdio);
        assert_eq!(pro.server_limit, Some(25));
        assert_eq!(pro.seat_limit, Some(3));
        assert_eq!(pro.tool_calls_per_month, Some(200_000));
        assert_eq!(pro.phone_calls_per_month, Some(100));
        assert_eq!(pro.audit_retention_days, Some(90));
        let enterprise = plan("enterprise");
        assert!(enterprise.gateway_limit.is_none() && enterprise.server_limit.is_none());
        assert!(enterprise.dedicated && enterprise.stdio);
        assert_eq!(default_mode(true), "dedicated");
        assert_eq!(default_mode(false), "shared");
    }
}
