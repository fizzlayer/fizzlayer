//! Stripe billing. Checkout starts a subscription on Fizzlayer's own `/app/checkout` page,
//! which mounts Stripe's embedded form. The billing portal changes or cancels it,
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
/// Checkout Sessions are created at this API version so `ui_mode=embedded_page` means the same
/// thing whatever the account's default version is. It is the release train the Stripe.js loader
/// in `app/package.json` loads.
const CHECKOUT_API_VERSION: &str = "2026-09-30.endive";

pub struct Stripe {
    client: Client,
    key: String,
    publishable_key: String,
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
        let key = read("STRIPE_SECRET_KEY")?;
        let publishable_key = read("STRIPE_PUBLISHABLE_KEY")?;
        if !keys_pair(&key, &publishable_key) {
            return None;
        }
        Some(Self {
            client,
            key,
            publishable_key,
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
        headers: &[(&str, &str)],
    ) -> Option<Value> {
        let mut request = self
            .client
            .post(format!("{STRIPE_API}/{path}"))
            .bearer_auth(&self.key)
            .form(form);
        for (name, value) in headers {
            request = request.header(*name, *value);
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

/// `test` or `live`, read from a key such as `sk_test_...`, `rk_live_...` or `pk_test_...`.
fn key_mode(key: &str) -> Option<&str> {
    let (_, rest) = key.split_once('_')?;
    let (mode, _) = rest.split_once('_')?;
    matches!(mode, "test" | "live").then_some(mode)
}

/// A test-mode publishable key with a live secret key (or the reverse) loads a form that can
/// never open the session, so that pair counts as unconfigured.
fn keys_pair(secret: &str, publishable: &str) -> bool {
    publishable.starts_with("pk_")
        && key_mode(publishable).is_some_and(|mode| key_mode(secret) == Some(mode))
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

/// Where the browser goes after checkout or the portal. Only these app paths are allowed.
fn checkout_return_path(return_to: Option<&str>) -> Option<&'static str> {
    match return_to {
        None | Some("settings") => Some("/settings.html"),
        Some("app") => Some("/app.html"),
        Some("gateway") => Some("/app/gateways"),
        Some(_) => None,
    }
}

/// The Checkout Session form. The form is embedded in `/app/checkout`, which handles a finished
/// payment itself; Stripe only sends the browser to `return_url` for a payment method that has
/// to leave the page, such as a bank redirect.
fn checkout_form<'a>(
    stripe_customer: &'a str,
    customer_id: &'a str,
    price: &'a str,
    return_url: &'a str,
) -> [(&'static str, &'a str); 9] {
    [
        ("mode", "subscription"),
        ("ui_mode", "embedded_page"),
        ("redirect_on_completion", "if_required"),
        ("return_url", return_url),
        ("customer", stripe_customer),
        ("client_reference_id", customer_id),
        ("line_items[0][price]", price),
        ("line_items[0][quantity]", "1"),
        ("subscription_data[metadata][fizz_customer_id]", customer_id),
    ]
}

/// The secret Stripe.js opens the embedded form with: `cs_<id>_secret_<token>`.
fn client_secret(session: &Value) -> Option<&str> {
    session["client_secret"]
        .as_str()
        .filter(|secret| secret.starts_with("cs_") && secret.contains("_secret_"))
}

/// `GET /api/billing` reports whether paid checkout is configured, with no session.
/// `POST /api/billing` with `{"action": "checkout", "plan": "tinkerer" | "pro"}` answers with
/// `client_secret` and `publishable_key` for the embedded form. `{"action": "portal"}` answers
/// with a Stripe-hosted `url` to open. `return_to` is `"settings"` (the default), `"app"` or
/// `"gateway"`.
pub async fn handle(request: Request) -> Response<ResponseBody> {
    if request.method().as_str() == "GET" {
        return reply(
            200,
            json!({ "available": Stripe::from_env().is_some() }),
            None,
        );
    }
    if request.method().as_str() != "POST" {
        return error(405, "method_not_allowed", "Use GET or POST.");
    }
    let Some(token) = session_token(&request) else {
        return error(401, "unauthorized", "Sign in to continue.");
    };
    let Some(origin) = crate::security::request_origin(&request) else {
        return error(400, "invalid_host", "Request host is not configured.");
    };
    let data = match json_body(request, 1024).await {
        Ok(data) => data,
        Err(failure) => return failure.into_response(),
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
    let Ok(account) = store
        .rpc("fizz_billing_account", json!({"p_token": token}))
        .await
    else {
        return unavailable();
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
    let Some(return_path) = checkout_return_path(data["return_to"].as_str()) else {
        return error(
            400,
            "invalid_return",
            "Choose where to return after checkout.",
        );
    };
    let return_url = format!("{origin}{return_path}");
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
            let paid_url = format!("{return_url}?billing=success");
            let session = stripe
                .post(
                    "checkout/sessions",
                    &checkout_form(&stripe_customer, customer_id, price, &paid_url),
                    &[("stripe-version", CHECKOUT_API_VERSION)],
                )
                .await;
            match session.as_ref().and_then(client_secret) {
                Some(secret) => reply(
                    200,
                    json!({"client_secret": secret, "publishable_key": stripe.publishable_key}),
                    None,
                ),
                None => unavailable(),
            }
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
                    &[],
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
    let idempotency_key = format!("fizz-customer-{customer_id}");
    let created = stripe
        .post("customers", &form, &[("idempotency-key", &idempotency_key)])
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

/// When the plan renews or, if a cancellation is scheduled, ends; and whether it ends.
/// Recent API versions schedule cancellations with `cancel_at` (the customer portal sets it
/// to the period end) rather than `cancel_at_period_end`.
fn period_close(subscription: &Value) -> (Option<i64>, bool) {
    match subscription["cancel_at"].as_i64() {
        Some(cancel_at) => (Some(cancel_at), true),
        None => (
            period_end(subscription),
            subscription["cancel_at_period_end"] == true,
        ),
    }
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
    let (period_close, cancelling) = period_close(&subscription);
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
                "p_current_period_end": period_close,
                "p_cancel_at_period_end": cancelling,
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
        let mut hex = String::with_capacity(tag.as_ref().len() * 2);
        for byte in tag.as_ref() {
            let _ = std::fmt::Write::write_fmt(&mut hex, format_args!("{byte:02x}"));
        }
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

    #[test]
    fn checkout_returns_only_to_known_app_pages() {
        assert_eq!(checkout_return_path(None), Some("/settings.html"));
        assert_eq!(
            checkout_return_path(Some("settings")),
            Some("/settings.html")
        );
        assert_eq!(checkout_return_path(Some("app")), Some("/app.html"));
        assert_eq!(checkout_return_path(Some("gateway")), Some("/app/gateways"));
        assert_eq!(checkout_return_path(Some("https://evil.example")), None);
        assert_eq!(checkout_return_path(Some("/app.html")), None);
    }

    #[test]
    fn checkout_embeds_the_form_and_returns_only_after_a_redirect() {
        let form = checkout_form(
            "cus_1",
            "uuid",
            "price_1",
            "https://x.test/app.html?billing=success",
        );
        let field = |name: &str| {
            form.iter()
                .find(|(key, _)| *key == name)
                .map(|(_, value)| *value)
        };
        assert_eq!(field("ui_mode"), Some("embedded_page"));
        assert_eq!(field("redirect_on_completion"), Some("if_required"));
        assert_eq!(
            field("return_url"),
            Some("https://x.test/app.html?billing=success")
        );
        assert_eq!(field("customer"), Some("cus_1"));
        assert_eq!(
            field("subscription_data[metadata][fizz_customer_id]"),
            Some("uuid")
        );
        // Embedded sessions reject the hosted page's redirect URLs.
        assert_eq!(field("success_url"), None);
        assert_eq!(field("cancel_url"), None);
    }

    #[test]
    fn only_a_checkout_session_secret_opens_the_form() {
        let secret = |value: Value| client_secret(&value).map(str::to_owned);
        assert_eq!(
            secret(json!({"client_secret": "cs_test_a1_secret_b2"})).as_deref(),
            Some("cs_test_a1_secret_b2")
        );
        assert_eq!(secret(json!({"client_secret": "pi_1_secret_2"})), None);
        assert_eq!(secret(json!({"client_secret": "cs_test_a1"})), None);
        assert_eq!(
            secret(json!({"client_secret": null, "url": "https://checkout.stripe.com/x"})),
            None
        );
    }

    #[test]
    fn publishable_key_must_match_the_secret_key_mode() {
        assert!(keys_pair("sk_test_1", "pk_test_2"));
        assert!(keys_pair("rk_live_1", "pk_live_2"));
        assert!(!keys_pair("sk_live_1", "pk_test_2"));
        assert!(!keys_pair("sk_test_1", "pk_live_2"));
        assert!(
            !keys_pair("sk_test_1", "sk_test_2"),
            "a secret key is not publishable"
        );
        assert!(!keys_pair("sk_test_1", "pk_2"));
    }

    #[test]
    fn scheduled_cancellations_use_either_field() {
        let renewing =
            json!({"current_period_end": 10, "cancel_at": null, "cancel_at_period_end": false});
        assert_eq!(period_close(&renewing), (Some(10), false));
        let portal =
            json!({"current_period_end": 10, "cancel_at": 10, "cancel_at_period_end": false});
        assert_eq!(period_close(&portal), (Some(10), true));
        let custom_date = json!({"current_period_end": 10, "cancel_at": 7});
        assert_eq!(period_close(&custom_date), (Some(7), true));
        let legacy = json!({"current_period_end": 10, "cancel_at_period_end": true});
        assert_eq!(period_close(&legacy), (Some(10), true));
    }
}
