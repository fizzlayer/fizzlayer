//! Alert email. Resend is a small HTTPS API. Without `RESEND_API_KEY` and
//! `FIZZ_ALERT_FROM`, email is not configured and the channel stays hidden.

use std::{env, future::Future, time::Duration};

use reqwest::Client;
use serde_json::json;

const RESEND_API: &str = "https://api.resend.com/emails";

#[derive(Debug)]
pub enum MailFailure {
    Retry(String),
    Permanent(String),
}

pub trait AlertMailer {
    fn send<'a>(
        &'a self,
        to: &'a str,
        subject: &'a str,
        text: &'a str,
    ) -> impl Future<Output = Result<(), MailFailure>> + Send + 'a;
}

pub struct ResendMailer {
    client: Client,
    api: String,
    key: String,
    from: String,
}

impl ResendMailer {
    pub fn from_env() -> Option<Self> {
        let read = |name: &str| {
            env::var(name)
                .ok()
                .map(|value| value.trim().to_owned())
                .filter(|value| !value.is_empty())
        };
        let client = Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .timeout(Duration::from_secs(8))
            .build()
            .ok()?;
        Some(Self {
            client,
            api: RESEND_API.to_owned(),
            key: read("RESEND_API_KEY")?,
            from: read("FIZZ_ALERT_FROM")?,
        })
    }
}

impl AlertMailer for ResendMailer {
    async fn send(&self, to: &str, subject: &str, text: &str) -> Result<(), MailFailure> {
        let response = self
            .client
            .post(&self.api)
            .bearer_auth(&self.key)
            .json(&json!({
                "from": self.from,
                "to": [to],
                "subject": subject,
                "text": text,
            }))
            .send()
            .await
            .map_err(|error| MailFailure::Retry(error.to_string()))?;
        if response.status().is_success() {
            return Ok(());
        }
        let status = response.status();
        let message = format!("Email provider returned HTTP {}.", status.as_u16());
        if status.as_u16() == 429 || status.is_server_error() {
            Err(MailFailure::Retry(message))
        } else {
            Err(MailFailure::Permanent(message))
        }
    }
}

pub fn configured() -> bool {
    ResendMailer::from_env().is_some()
}
