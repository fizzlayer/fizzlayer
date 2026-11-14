//! Service-role calls into `public.fizz_gateway`. The browser never sees this client.

use std::env;

use reqwest::Method;
use serde_json::{Value, json};
use uuid::Uuid;

use crate::customer::ApiError;
use crate::gateway::crypto;
use crate::store::Supabase;

pub trait Backend: Send + Sync {
    async fn authenticate(&self, token: &str) -> Result<Uuid, ApiError>;

    async fn call(
        &self,
        user: Option<Uuid>,
        action: &str,
        payload: Value,
    ) -> Result<Value, ApiError>;

    fn signing_pem(&self) -> Result<Vec<u8>, ApiError>;

    fn secret_key(&self) -> Result<[u8; 32], ApiError>;

    fn guard_host(&self) -> Result<String, ApiError>;

    fn jwks_url(&self, origin: &str) -> String;
}

pub struct Live;

impl Backend for Live {
    async fn authenticate(&self, token: &str) -> Result<Uuid, ApiError> {
        if token.starts_with("fizz_reg_") || token.len() > 8192 {
            return Err(ApiError::new(401, "unauthorized", "Sign in to continue."));
        }
        let store = Supabase::from_env().map_err(|_| unavailable())?;
        let (status, body) = store
            .auth(Method::GET, "user", &[], Some(token), None, None)
            .await
            .map_err(|_| unavailable())?;
        if status == reqwest::StatusCode::UNAUTHORIZED || status == reqwest::StatusCode::FORBIDDEN {
            return Err(ApiError::new(401, "unauthorized", "Sign in to continue."));
        }
        if !status.is_success() || body.get("is_anonymous") == Some(&Value::Bool(true)) {
            return Err(if status.is_success() {
                ApiError::new(401, "unauthorized", "Sign in to continue.")
            } else {
                unavailable()
            });
        }
        let id = body
            .get("id")
            .and_then(Value::as_str)
            .ok_or_else(|| ApiError::new(401, "unauthorized", "Sign in to continue."))?;
        Uuid::parse_str(id).map_err(|_| ApiError::new(401, "unauthorized", "Sign in to continue."))
    }

    async fn call(
        &self,
        user: Option<Uuid>,
        action: &str,
        payload: Value,
    ) -> Result<Value, ApiError> {
        let store = Supabase::from_env().map_err(|_| unavailable())?;
        let user = user.map_or(Value::Null, |id| json!(id.to_string()));
        store
            .rpc(
                "fizz_gateway",
                json!({
                    "p_user": user,
                    "p_action": action,
                    "p_payload": payload,
                }),
            )
            .await
            .map_err(|_| unavailable())
    }

    fn signing_pem(&self) -> Result<Vec<u8>, ApiError> {
        let raw = env::var("GATEWAY_SIGNING_KEY").map_err(|_| {
            ApiError::new(
                503,
                "signing_unavailable",
                "Client tokens need GATEWAY_SIGNING_KEY on the server.",
            )
        })?;
        crypto::signing_pem(&raw)
    }

    fn secret_key(&self) -> Result<[u8; 32], ApiError> {
        let raw = env::var("GATEWAY_SECRET_KEY").map_err(|_| {
            ApiError::new(
                503,
                "encryption_unavailable",
                "Storing an MCP credential needs GATEWAY_SECRET_KEY on the server.",
            )
        })?;
        crypto::secret_key_from(&raw)
    }

    fn guard_host(&self) -> Result<String, ApiError> {
        let host = env::var("GATEWAY_GUARD_HOST").unwrap_or_else(|_| "fizz-guard:9001".to_string());
        let host = host.trim().to_string();
        if host.is_empty() || host.contains([' ', '\n', '/']) {
            return Err(ApiError::new(
                503,
                "unavailable",
                "GATEWAY_GUARD_HOST is not a host and port.",
            ));
        }
        Ok(host)
    }

    fn jwks_url(&self, origin: &str) -> String {
        env::var("GATEWAY_JWKS_URL")
            .ok()
            .map(|value| value.trim().trim_end_matches('/').to_string())
            .filter(|value| !value.is_empty())
            .unwrap_or_else(|| format!("{}/api/gateway/jwks", origin.trim_end_matches('/')))
    }
}

fn unavailable() -> ApiError {
    ApiError::new(
        503,
        "database_unavailable",
        "Gateway data is temporarily unavailable.",
    )
}
