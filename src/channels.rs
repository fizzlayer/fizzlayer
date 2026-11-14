//! Alert notification channels.
//!
//! Dashboard and phone are the channels an alert could already use. Email and
//! webhook are additional. Phone calls stay on paid plans. Email and webhook
//! are on every plan while [`MESSAGE_CHANNELS_ON_ALL_PLANS`] is true.
//!
//! The database function `public.fizz_message_channels_on_all_plans()` is what
//! create and update enforce, including MCP. Keep that function returning the
//! same value as this constant. Set both to false to require a paid plan later.
//! Prices do not change.

use serde_json::Value;

use crate::notify;

/// Email and webhook alerts are included on every plan.
/// Phone calls stay on Tinkerer, Pro, and Enterprise either way.
pub const MESSAGE_CHANNELS_ON_ALL_PLANS: bool = true;

const ORDER: [&str; 4] = ["dashboard", "phone", "email", "webhook"];

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChannelChoice {
    pub channels: Vec<String>,
    pub phone: Option<String>,
    pub webhook_url: Option<String>,
    pub webhook_secret: Option<String>,
}

#[derive(Debug, PartialEq, Eq)]
pub enum ChannelError {
    Unknown,
    Empty,
    Phone,
    Webhook,
    Secret,
    EmailUnavailable,
}

impl ChannelError {
    pub fn message(self) -> &'static str {
        match self {
            Self::Unknown | Self::Empty => {
                "Choose dashboard, phone, email, webhook, or a combination."
            }
            Self::Phone => {
                "Enter a real US phone number. Toll-free, premium, and fictional numbers can't be called."
            }
            Self::Webhook => {
                "Use an https webhook URL on a public host. Private and loopback addresses are refused."
            }
            Self::Secret => "A webhook signing secret is 16 to 128 characters, without spaces.",
            Self::EmailUnavailable => {
                "Email alerts are off until RESEND_API_KEY and FIZZ_ALERT_FROM are set."
            }
        }
    }
}

fn secret_ok(secret: &str) -> bool {
    (16..=128).contains(&secret.chars().count())
        && secret
            .chars()
            .all(|c| !c.is_whitespace() && !c.is_control())
}

/// Channels from an API body.
///
/// A missing `channels` array keeps the old choice: dashboard, plus a phone
/// call when `notify_channel` is `call`. An explicit array can combine channels.
/// `email_configured` is false when the mail provider key is unset, and then
/// selecting email is refused so a self-hosted server does not queue mail it
/// cannot send.
pub fn select_channels(
    data: &Value,
    email_configured: bool,
) -> Result<ChannelChoice, ChannelError> {
    let explicit = data.get("channels");
    let channels = if let Some(value) = explicit {
        let Some(list) = value.as_array() else {
            return Err(ChannelError::Unknown);
        };
        let mut chosen = Vec::new();
        for item in list {
            let Some(name) = item.as_str() else {
                return Err(ChannelError::Unknown);
            };
            if !ORDER.contains(&name) {
                return Err(ChannelError::Unknown);
            }
            if !chosen.contains(&name) {
                chosen.push(name);
            }
        }
        if chosen.is_empty() {
            return Err(ChannelError::Empty);
        }
        ORDER
            .into_iter()
            .filter(|name| chosen.contains(name))
            .map(str::to_owned)
            .collect()
    } else {
        match data
            .get("notify_channel")
            .and_then(Value::as_str)
            .unwrap_or("none")
        {
            "none" => vec!["dashboard".to_owned()],
            "call" => vec!["dashboard".to_owned(), "phone".to_owned()],
            _ => return Err(ChannelError::Unknown),
        }
    };

    if explicit.is_some()
        && data.get("notify_channel").and_then(Value::as_str) == Some("call")
        && !channels.iter().any(|channel| channel == "phone")
    {
        return Err(ChannelError::Phone);
    }

    let wants_phone = channels.iter().any(|channel| channel == "phone");
    let phone = if wants_phone {
        let raw = data
            .get("notify_phone")
            .and_then(Value::as_str)
            .or_else(|| data.get("call_phone").and_then(Value::as_str))
            .unwrap_or("");
        Some(notify::us_phone(raw).ok_or(ChannelError::Phone)?)
    } else if data.get("notify_channel").and_then(Value::as_str) == Some("call") {
        return Err(ChannelError::Phone);
    } else {
        None
    };

    let webhook_url = data
        .get("webhook_url")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|url| !url.is_empty())
        .map(str::to_owned);
    let webhook_secret = data
        .get("webhook_secret")
        .and_then(Value::as_str)
        .filter(|secret| !secret.is_empty())
        .map(str::to_owned);
    let wants_webhook = channels.iter().any(|channel| channel == "webhook");
    if wants_webhook {
        let url = webhook_url.as_deref().ok_or(ChannelError::Webhook)?;
        if crate::webhook::webhook_target(url).is_err() {
            return Err(ChannelError::Webhook);
        }
        if let Some(secret) = &webhook_secret
            && !secret_ok(secret)
        {
            return Err(ChannelError::Secret);
        }
    } else if webhook_url.is_some() || webhook_secret.is_some() {
        return Err(ChannelError::Webhook);
    }

    if channels.iter().any(|channel| channel == "email") && !email_configured {
        return Err(ChannelError::EmailUnavailable);
    }

    Ok(ChannelChoice {
        channels,
        phone,
        webhook_url: wants_webhook.then_some(webhook_url).flatten(),
        webhook_secret: wants_webhook.then_some(webhook_secret).flatten(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn missing_channels_stay_dashboard_or_dashboard_and_phone() {
        let dashboard = select_channels(&json!({"sensor_id": "s"}), false).unwrap();
        assert_eq!(dashboard.channels, ["dashboard"]);
        assert_eq!(dashboard.phone, None);

        let explicit_none = select_channels(&json!({"notify_channel": "none"}), false).unwrap();
        assert_eq!(explicit_none.channels, ["dashboard"]);

        let call = select_channels(
            &json!({"notify_channel": "call", "notify_phone": "(415) 555-0123"}),
            false,
        )
        .unwrap();
        assert_eq!(call.channels, ["dashboard", "phone"]);
        assert_eq!(call.phone.as_deref(), Some("+14155550123"));
    }

    #[test]
    fn explicit_channels_combine_and_reject_unknown_or_empty() {
        let chosen = select_channels(
            &json!({
                "channels": ["webhook", "email", "dashboard", "email"],
                "webhook_url": "https://alerts.example.com/fizz"
            }),
            true,
        )
        .unwrap();
        assert_eq!(chosen.channels, ["dashboard", "email", "webhook"]);
        assert_eq!(
            chosen.webhook_url.as_deref(),
            Some("https://alerts.example.com/fizz")
        );

        assert_eq!(
            select_channels(&json!({"channels": []}), true).unwrap_err(),
            ChannelError::Empty
        );
        assert_eq!(
            select_channels(&json!({"channels": ["sms"]}), true).unwrap_err(),
            ChannelError::Unknown
        );
        assert_eq!(
            select_channels(&json!({"notify_channel": "sms"}), true).unwrap_err(),
            ChannelError::Unknown
        );
    }

    #[test]
    fn phone_email_and_webhook_each_require_their_own_settings() {
        assert_eq!(
            select_channels(&json!({"channels": ["phone"]}), true).unwrap_err(),
            ChannelError::Phone
        );
        assert_eq!(
            select_channels(
                &json!({"channels": ["dashboard"], "notify_channel": "call", "notify_phone": "+14155550123"}),
                true
            )
            .unwrap_err(),
            ChannelError::Phone
        );
        assert_eq!(
            select_channels(&json!({"channels": ["webhook"]}), true).unwrap_err(),
            ChannelError::Webhook
        );
        assert_eq!(
            select_channels(
                &json!({"channels": ["webhook"], "webhook_url": "http://alerts.example.com/hook"}),
                true
            )
            .unwrap_err(),
            ChannelError::Webhook
        );
        assert_eq!(
            select_channels(
                &json!({"channels": ["webhook"], "webhook_url": "https://127.0.0.1/hook"}),
                true
            )
            .unwrap_err(),
            ChannelError::Webhook
        );
        assert_eq!(
            select_channels(
                &json!({"channels": ["webhook"], "webhook_url": "https://alerts.example.com/h", "webhook_secret": "too-short"}),
                true
            )
            .unwrap_err(),
            ChannelError::Secret
        );
        assert_eq!(
            select_channels(&json!({"channels": ["email"]}), false).unwrap_err(),
            ChannelError::EmailUnavailable
        );
        let email = select_channels(&json!({"channels": ["email"]}), true).unwrap();
        assert_eq!(email.channels, ["email"]);
        assert_eq!(email.phone, None);
        assert_eq!(email.webhook_url, None);
    }
}
