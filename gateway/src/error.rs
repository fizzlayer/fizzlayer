use std::fmt;

/// Errors that are safe to print. They name the failing step and never include
/// tokens, signing keys, database URLs, or upstream credentials.
#[derive(Debug)]
pub struct GatewayError {
    message: String,
}

impl GatewayError {
    pub fn message(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
        }
    }

    pub fn database(err: impl std::error::Error) -> Self {
        let mut parts = Vec::new();
        let mut current = Some(&err as &dyn std::error::Error);
        while let Some(item) = current {
            let text = item.to_string();
            let lower = text.to_ascii_lowercase();
            if !text.contains("://") && !text.contains("BEGIN ") && !lower.contains("password=") {
                parts.push(text);
            }
            current = item.source();
        }
        if parts.is_empty() {
            Self::message("database request failed")
        } else {
            Self::message(format!("database request failed: {}", parts.join(": ")))
        }
    }
}

impl fmt::Display for GatewayError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for GatewayError {}

pub type GatewayResult<T> = Result<T, GatewayError>;
