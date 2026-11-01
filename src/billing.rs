//! Stripe billing. Checkout starts a subscription, the billing portal changes or cancels it,
//! and the webhook copies each subscription's current state from Stripe into
//! `fizz_subscriptions`. Billing is optional: without the Stripe variables every account
//! keeps the plan stored in the database.
use std::env;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use http_body_util::{BodyExt, Limited};
use reqwest::Client;
use ring::hmac;
use serde_json::{Value, json};
use vercel_runtime::{Request, Response, ResponseBody};

use crate::customer::{error, json_body, reply, session_token};
use crate::store::Supabase;

const STRIPE_API: &str = "https://api.stripe.com/v1";
/// Stripe's recommended limit on the age of a signed webhook, which bounds replays.
const SIGNATURE_TOLERANCE_SECS: u64 = 300;

pub struct Stripe {
    client: Client,
    key: String,
    webhook_secret: String,
    tinkerer_price: String,
    pro_price: String,
}

impl Stripe {
    pub fn from_env() -> Option<Self> {
        let read = |name: &str| {
            env::var(name)
                .ok()
                .map(|v| v.trim().to_owned())
                .filter(|v| !v.is_empty())
        };
        let client = Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .timeout(Duration::from_secs(8))
            .build()
            .ok()?;
        Some(Self {
            client,
            key: read("STRIPE_SECRET_KEY")?,
            webhook_secret: read("STRIPE_WEBHOOK_SECRET")?,
            tinkerer_price: read("STRIPE_PRICE_TINKERER")?,
            pro_price: read("STRIPE_PRICE_PRO")?,
        })
    }

    fn price_for(&self, plan: &str) -> Option<&str> {
        match plan {
            "tinkerer" => Some(&self.tinkerer_price),
            "pro" => Some(&self.pro_price),
            _ => None,
        }
    }

    fn plan_for(&self, price: &str) -> Option<&'static str> {
        if price == self.tinkerer_price {
            Some("tinkerer")
        } else if price == self.pro_price {
            Some("pro")
        } else {
            None
        }
    }

    async fn post(
        &self,
        path: &str,
        form: &[(&str, &str)],
        idempotency_key: Option<&str>,
    ) -> Option<Value> {
        let mut request = self
            .client
            .post(format!("{STRIPE_API}/{path}"))
            .bearer_auth(&self.key)
            .form(form);
        if let Some(key) = idempotency_key {
            request = request.header("idempotency-key", key);
        }
        let response = request.send().await.ok()?;
        if !response.status().is_success() {
            return None;
        }
        response.json().await.ok()
    }

    async fn get(&self, path: &str) -> Option<Value> {
        let response = self
            .client
            .get(format!("{STRIPE_API}/{path}"))
            .bearer_auth(&self.key)
            .send()
            .await
            .ok()?;
        if !response.status().is_success() {
            return None;
        }
        response.json().await.ok()
    }
}

fn stripe_id(value: &Value, prefix: &str) -> Option<String> {
    value
        .as_str()
        .filter(|id| {
            id.strip_prefix(prefix).is_some_and(|rest| {
                !rest.is_empty()
                    && rest.len() <= 250
                    && rest.bytes().all(|c| c.is_ascii_alphanumeric())
            })
        })
        .map(str::to_owned)
}

fn unavailable() -> Response<ResponseBody> {
    error(
        503,
        "billing_unavailable",
        "Billing is temporarily unavailable. Please try again.",
    )
}

/// `POST /api/billing` with `{"action": "checkout", "plan": "tinkerer" | "pro"}` or
/// `{"action": "portal"}`. Both answer with a Stripe-hosted `url` to open.
pub async fn handle(request: Request) -> Response<ResponseBody> {
    let Some(token) = session_token(&request) else {
        return error(401, "unauthorized", "Sign in to continue.");
    };
    let Some(origin) = crate::security::request_origin(&request) else {
        return error(400, "invalid_host", "Request host is not configured.");
    };
    let data = match json_body(request, 1024).await {
        Ok(data) => data,
        Err(response) => return response,
    };
    let Some(stripe) = Stripe::from_env() else {
        return error(
            503,
            "billing_not_configured",
            "Paid plans aren't available on this server.",
        );
    };
    let Ok(store) = Supabase::from_env() else {
        return unavailable();
    };
    let account = match store
        .rpc("fizz_billing_account", json!({"p_token": token}))
        .await
    {
        Ok(account) => account,
        Err(_) => return unavailable(),
    };
    match account["error"].as_str() {
        Some("unauthorized") => return error(401, "unauthorized", "Sign in to continue."),
        Some("rate_limited") => {
            return error(
                429,
                "rate_limited",
                "Too many billing requests. Try again later.",
            );
        }
        Some(_) => return unavailable(),
        None => {}
    }
    let Some(customer_id) = account["customer_id"]
        .as_str()
        .filter(|id| crate::sensors::valid_uuid(id))
    else {
        return unavailable();
    };
    let return_url = format!("{origin}/settings.html");
    match data["action"].as_str() {
        Some("checkout") => {
            let Some(price) = data["plan"]
                .as_str()
                .and_then(|plan| stripe.price_for(plan))
            else {
                return error(400, "invalid_plan", "Choose the Tinkerer or Pro plan.");
            };
            if account["subscribed"] == true {
                return error(
                    409,
                    "already_subscribed",
                    "You already have a subscription. Use Manage billing to change your plan.",
                );
            }
            let stripe_customer = match stripe_id(&account["stripe_customer_id"], "cus_") {
                Some(id) => id,
                None => match create_customer(&stripe, &store, customer_id, &account).await {
                    Some(id) => id,
                    None => return unavailable(),
                },
            };
            let success_url = format!("{return_url}?billing=success");
            let cancel_url = format!("{return_url}?billing=cancelled");
            let session = stripe
                .post(
                    "checkout/sessions",
                    &[
                        ("mode", "subscription"),
                        ("customer", stripe_customer.as_str()),
                        ("client_reference_id", customer_id),
                        ("line_items[0][price]", price),
                        ("line_items[0][quantity]", "1"),
                        ("subscription_data[metadata][fizz_customer_id]", customer_id),
                        ("success_url", success_url.as_str()),
                        ("cancel_url", cancel_url.as_str()),
                    ],
                    None,
                )
                .await;
            hosted_url(session)
        }
        Some("portal") => {
            let Some(stripe_customer) = stripe_id(&account["stripe_customer_id"], "cus_") else {
                return error(
                    409,
                    "no_billing_account",
                    "Choose a paid plan first. Billing details appear here after you subscribe.",
                );
            };
            let session = stripe
                .post(
                    "billing_portal/sessions",
                    &[
                        ("customer", stripe_customer.as_str()),
                        ("return_url", return_url.as_str()),
                    ],
                    None,
                )
                .await;
            hosted_url(session)
        }
        _ => error(400, "invalid_request", "Choose checkout or portal."),
    }
}

/// The idempotency key makes retries within Stripe's 24-hour window return the same customer.
async fn create_customer(
    stripe: &Stripe,
    store: &Supabase,
    customer_id: &str,
    account: &Value,
) -> Option<String> {
    let mut form = vec![("metadata[fizz_customer_id]", customer_id)];
    if let Some(email) = account["email"].as_str() {
        form.push(("email", email));
    }
    let created = stripe
        .post(
            "customers",
            &form,
            Some(&format!("fizz-customer-{customer_id}")),
        )
        .await?;
    let created = stripe_id(&created["id"], "cus_")?;
    let linked = store
        .rpc(
            "fizz_billing_link_customer",
            json!({"p_customer": customer_id, "p_stripe_customer": created}),
        )
        .await
        .ok()?;
    stripe_id(&linked["stripe_customer_id"], "cus_")
}

fn hosted_url(session: Option<Value>) -> Response<ResponseBody> {
    match session.as_ref().and_then(|s| s["url"].as_str()) {
        Some(url) if url.starts_with("https://") => reply(200, json!({"url": url}), None),
        _ => unavailable(),
    }
}

/// Checks a `Stripe-Signature` header (`t=<unix>,v1=<hex>[,v1=...]`) against the raw body.
fn valid_signature(secret: &str, header: &str, body: &[u8], now: u64) -> bool {
    let mut timestamp = None;
    let mut signatures = Vec::new();
    for part in header.split(',') {
        match part.trim().split_once('=') {
            Some(("t", value)) => timestamp = value.parse::<u64>().ok(),
            Some(("v1", value)) => signatures.extend(hex_decode(value)),
            _ => {}
        }
    }
    let Some(timestamp) = timestamp else {
        return false;
    };
    if now.abs_diff(timestamp) > SIGNATURE_TOLERANCE_SECS {
        return false;
    }
    let key = hmac::Key::new(hmac::HMAC_SHA256, secret.as_bytes());
    let mut signed = format!("{timestamp}.").into_bytes();
    signed.extend_from_slice(body);
    signatures
        .iter()
        .any(|tag| hmac::verify(&key, &signed, tag).is_ok())
}

fn hex_decode(value: &str) -> Option<Vec<u8>> {
    if value.len() != 64 {
        return None;
    }
    (0..value.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(value.get(i..i + 2)?, 16).ok())
        .collect()
}

/// Recent Stripe API versions report the billing period on each subscription item.
fn period_end(subscription: &Value) -> Option<i64> {
    subscription["items"]["data"][0]["current_period_end"]
        .as_i64()
        .or_else(|| subscription["current_period_end"].as_i64())
}

/// `POST /api/stripe-webhook`. Answers 500 when Stripe or the database fails so Stripe retries.
pub async fn webhook(request: Request) -> Response<ResponseBody> {
    let Some(stripe) = Stripe::from_env() else {
        return error(
            503,
            "billing_not_configured",
            "Paid plans aren't available on this server.",
        );
    };
    let signature = request
        .headers()
        .get("stripe-signature")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
        .to_owned();
    let Ok(body) = Limited::new(request.into_body(), 512 * 1024)
        .collect()
        .await
    else {
        return error(413, "too_large", "Event is too large.");
    };
    let body = body.to_bytes();
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs());
    if !valid_signature(&stripe.webhook_secret, &signature, &body, now) {
        return error(400, "invalid_signature", "Signature verification failed.");
    }
    let Ok(event) = serde_json::from_slice::<Value>(&body) else {
        return error(400, "invalid_event", "Event is not valid JSON.");
    };
    let object = &event["data"]["object"];
    let (subscription, customer) = match event["type"].as_str() {
        Some("checkout.session.completed") if object["mode"] == "subscription" => (
            stripe_id(&object["subscription"], "sub_"),
            object["client_reference_id"]
                .as_str()
                .filter(|id| crate::sensors::valid_uuid(id)),
        ),
        Some(
            "customer.subscription.created"
            | "customer.subscription.updated"
            | "customer.subscription.deleted",
        ) => (stripe_id(&object["id"], "sub_"), None),
        _ => return reply(200, json!({"received": true}), None),
    };
    let Some(subscription) = subscription else {
        return error(400, "invalid_event", "Event has no subscription.");
    };
    match sync(&stripe, &subscription, customer).await {
        Some(result) => reply(200, json!({"received": true, "result": result}), None),
        None => error(500, "sync_failed", "Could not sync the subscription."),
    }
}

/// Events can arrive late or out of order, so always store the subscription's current state.
async fn sync(stripe: &Stripe, subscription_id: &str, customer: Option<&str>) -> Option<Value> {
    let subscription = stripe
        .get(&format!("subscriptions/{subscription_id}"))
        .await?;
    let stripe_customer = stripe_id(&subscription["customer"], "cus_")?;
    let plan = subscription["items"]["data"][0]["price"]["id"]
        .as_str()
        .and_then(|price| stripe.plan_for(price));
    let store = Supabase::from_env().ok()?;
    store
        .rpc(
            "fizz_billing_sync",
            json!({
                "p_stripe_customer": stripe_customer,
                "p_customer": customer,
                "p_subscription_id": subscription_id,
                "p_status": subscription["status"].as_str(),
                "p_plan": plan,
                "p_current_period_end": period_end(&subscription),
                "p_cancel_at_period_end": subscription["cancel_at_period_end"].as_bool(),
            }),
        )
        .await
        .ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    const SECRET: &str = "whsec_test";

    fn signed(body: &[u8], timestamp: u64, secret: &str) -> String {
        let key = hmac::Key::new(hmac::HMAC_SHA256, secret.as_bytes());
        let mut payload = format!("{timestamp}.").into_bytes();
        payload.extend_from_slice(body);
        let tag = hmac::sign(&key, &payload);
        let hex: String = tag.as_ref().iter().map(|b| format!("{b:02x}")).collect();
        format!("t={timestamp},v1={hex}")
    }

    #[test]
    fn webhook_signatures_must_match_the_body_secret_and_time() {
        let body = br#"{"type":"customer.subscription.updated"}"#;
        let header = signed(body, 1_000, SECRET);
        assert!(valid_signature(SECRET, &header, body, 1_000));
        assert!(valid_signature(SECRET, &header, body, 1_300));
        assert!(!valid_signature(SECRET, &header, body, 1_301), "too old");
        assert!(
            !valid_signature(SECRET, &header, b"{}", 1_000),
            "tampered body"
        );
        assert!(
            !valid_signature("whsec_other", &header, body, 1_000),
            "wrong secret"
        );
        assert!(!valid_signature(SECRET, "", body, 1_000));
        assert!(!valid_signature(SECRET, "t=1000,v1=zz", body, 1_000));
    }

    #[test]
    fn any_listed_signature_can_match_during_secret_rotation() {
        let body = b"{}";
        let good = signed(body, 50, SECRET);
        let other = signed(body, 50, "whsec_old");
        let v1 = good.split_once(",v1=").unwrap().1;
        let header = format!("{other},v0=ignored,v1={v1}");
        assert!(valid_signature(SECRET, &header, body, 50));
    }

    #[test]
    fn stripe_ids_need_their_prefix_and_plain_characters() {
        assert_eq!(
            stripe_id(&json!("cus_Abc123"), "cus_").as_deref(),
            Some("cus_Abc123")
        );
        assert_eq!(stripe_id(&json!("sub_Abc123"), "cus_"), None);
        assert_eq!(stripe_id(&json!("cus_"), "cus_"), None);
        assert_eq!(stripe_id(&json!("sub_../x"), "sub_"), None);
        assert_eq!(stripe_id(&json!(null), "sub_"), None);
    }

    #[test]
    fn period_end_reads_item_or_subscription_level() {
        let item =
            json!({"items": {"data": [{"current_period_end": 20}]}, "current_period_end": 10});
        assert_eq!(period_end(&item), Some(20));
        assert_eq!(period_end(&json!({"current_period_end": 10})), Some(10));
        assert_eq!(period_end(&json!({})), None);
    }
}
