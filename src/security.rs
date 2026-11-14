//! Shared browser request boundaries. Bearer-token devices may omit Origin.
use std::env;

use reqwest::Url;
use vercel_runtime::{Response, ResponseBody};

use crate::{customer::error, store::Supabase};

/// Self-host on a private HTTP network (the Docker gateway, or Ollama on another host).
/// Production leaves this unset, so Supabase and chat URLs stay HTTPS except loopback.
pub fn allow_insecure_http() -> bool {
    matches!(
        env::var("FIZZ_ALLOW_INSECURE_HTTP").ok().as_deref(),
        Some("1" | "true")
    )
}

fn public_host_match(host: &str) -> bool {
    let Ok(value) = env::var("FIZZ_PUBLIC_HOST") else {
        return false;
    };
    value.split(',').any(|item| {
        let item = item.trim().trim_end_matches('/');
        if item.is_empty() {
            return false;
        }
        let bare = item
            .strip_prefix("https://")
            .or_else(|| item.strip_prefix("http://"))
            .unwrap_or(item);
        bare.eq_ignore_ascii_case(host)
    })
}

pub fn site_origin(host: Option<&str>) -> Option<String> {
    let host = host?;
    if host.is_empty()
        || host
            .bytes()
            .any(|c| !c.is_ascii_alphanumeric() && !b".-:[]".contains(&c))
    {
        return None;
    }
    let parsed = Url::parse(&format!("https://{host}")).ok()?;
    let local = matches!(parsed.host_str(), Some("localhost" | "127.0.0.1" | "[::1]"));
    let configured = [
        "VERCEL_URL",
        "VERCEL_BRANCH_URL",
        "VERCEL_PROJECT_PRODUCTION_URL",
    ]
    .iter()
    .filter_map(|key| env::var(key).ok())
    .any(|value| value.eq_ignore_ascii_case(host));
    let extra = public_host_match(host);
    if !local
        && !configured
        && !extra
        && !matches!(
            host,
            "fizzlayer.com" | "www.fizzlayer.com" | "fizz-zeta.vercel.app"
        )
    {
        return None;
    }
    let mut origin = parsed;
    // Loopback stays HTTP unless a self-host explicitly terminates TLS on it.
    // An extra host listed in FIZZ_PUBLIC_HOST is HTTPS unless FIZZ_PUBLIC_SCHEME=http.
    let http = match env::var("FIZZ_PUBLIC_SCHEME").ok().as_deref() {
        Some("http") if local || extra => true,
        Some("https") => false,
        _ => local,
    };
    if http {
        origin.set_scheme("http").ok()?;
    }
    Some(origin.origin().ascii_serialization())
}

/// Vercel's local proxy replaces Host with an internal function port. Use an explicit
/// browser-facing origin only in development and only for loopback requests.
pub fn request_origin<B>(request: &http::Request<B>) -> Option<String> {
    let host = request
        .headers()
        .get("host")
        .and_then(|v| v.to_str().ok())
        .or_else(|| request.uri().authority().map(http::uri::Authority::as_str));
    let origin = site_origin(host)?;
    development_origin(
        origin,
        env::var("VERCEL_DEV").as_deref() == Ok("1"),
        env::var("FIZZ_DEV_ORIGIN").ok().as_deref(),
    )
}

fn development_origin(
    origin: String,
    development: bool,
    configured: Option<&str>,
) -> Option<String> {
    if !development || !origin.starts_with("http://") {
        return Some(origin);
    }
    let Some(configured) = configured else {
        return Some(origin);
    };
    let url = Url::parse(configured).ok()?;
    if url.scheme() != "http"
        || !matches!(url.host_str(), Some("localhost" | "127.0.0.1" | "[::1]"))
        || !url.username().is_empty()
        || url.password().is_some()
        || url.path() != "/"
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return None;
    }
    Some(url.origin().ascii_serialization())
}

pub fn guard_request<B>(request: &http::Request<B>) -> Result<(), Response<ResponseBody>> {
    let header = |name: &str| request.headers().get(name).and_then(|v| v.to_str().ok());
    // Never use client-supplied x-forwarded-host to authorize an origin.
    let Some(expected) = request_origin(request) else {
        return Err(error(
            400,
            "invalid_host",
            "Request host is not configured.",
        ));
    };
    if request.headers().contains_key("origin") && header("origin") != Some(expected.as_str()) {
        return Err(error(
            403,
            "forbidden_origin",
            "Request origin is not allowed.",
        ));
    }
    if !matches!(request.method().as_str(), "GET" | "HEAD" | "OPTIONS")
        && header("sec-fetch-site").is_some_and(|site| !matches!(site, "same-origin" | "none"))
    {
        return Err(error(403, "forbidden_origin", "Use this site's own pages."));
    }
    Ok(())
}

pub fn is_json(content_type: &str) -> bool {
    content_type
        .split(';')
        .next()
        .is_some_and(|mime| mime.trim().eq_ignore_ascii_case("application/json"))
}

/// Validate the session and consume a database-backed budget before paid work.
pub async fn paid_request_budget(
    store: &Supabase,
    token: &str,
    operation: &str,
) -> Result<(), Response<ResponseBody>> {
    let value = store
        .rpc(
            "fizz_request_budget",
            serde_json::json!({"p_token": token, "p_operation": operation}),
        )
        .await;
    match value {
        Ok(value) if value["ok"] == true => Ok(()),
        Ok(value) if value["error"] == "unauthorized" => {
            Err(error(401, "unauthorized", "Sign in to continue."))
        }
        Ok(value) if value["error"] == "rate_limited" => {
            let mut response = error(429, "rate_limited", "Usage limit reached. Try again later.");
            response
                .headers_mut()
                .insert("retry-after", "60".parse().expect("valid header"));
            Err(response)
        }
        Ok(value) if value["error"] == "credits_exhausted" => Err(error(
            402,
            "credits_exhausted",
            "You've used this month's Fizz credits. Upgrade your plan for more, or wait until they reset next month.",
        )),
        _ => Err(error(
            503,
            "unavailable",
            "Usage checks are temporarily unavailable.",
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(host: &str, origin: Option<&str>, site: Option<&str>) -> http::Request<()> {
        let mut builder = http::Request::builder()
            .method("POST")
            .uri("/api/sensors")
            .header("host", host);
        if let Some(origin) = origin {
            builder = builder.header("origin", origin);
        }
        if let Some(site) = site {
            builder = builder.header("sec-fetch-site", site);
        }
        builder.body(()).unwrap()
    }

    #[test]
    fn development_origin_override_is_local_only() {
        let internal = "http://127.0.0.1:45737";
        let public = "http://localhost:3000";
        assert_eq!(
            development_origin(internal.into(), true, Some(public)).as_deref(),
            Some(public)
        );
        assert_eq!(
            development_origin(internal.into(), false, Some(public)).as_deref(),
            Some(internal)
        );
        assert_eq!(
            development_origin(internal.into(), true, None).as_deref(),
            Some(internal)
        );
        assert_eq!(
            development_origin("https://fizzlayer.com".into(), true, Some(public)).as_deref(),
            Some("https://fizzlayer.com")
        );
        for invalid in [
            "https://evil.com",
            "http://localhost.evil.com",
            "http://localhost:3000/path",
            "http://user@localhost:3000",
            "http://localhost:3000?x=1",
            "http://localhost:3000/#fragment",
        ] {
            assert!(development_origin(internal.into(), true, Some(invalid)).is_none());
        }
    }

    #[test]
    fn browser_and_device_origin_boundaries() {
        assert!(
            guard_request(&request(
                "fizzlayer.com",
                Some("https://fizzlayer.com"),
                Some("same-origin")
            ))
            .is_ok()
        );
        assert!(guard_request(&request("fizzlayer.com", None, None)).is_ok());
        for origin in [
            "https://evil.example",
            "https://evil.fizzlayer.com",
            "null",
            "http://fizzlayer.com",
        ] {
            assert!(guard_request(&request("fizzlayer.com", Some(origin), None)).is_err());
        }
        assert!(guard_request(&request("fizzlayer.com", None, Some("cross-site"))).is_err());
        assert!(guard_request(&request("fizzlayer.com", None, Some("same-site"))).is_err());
        assert!(
            guard_request(&request("evil.example", Some("https://evil.example"), None)).is_err()
        );
        let mut forged = request("fizzlayer.com", Some("https://evil.example"), None);
        forged
            .headers_mut()
            .insert("x-forwarded-host", "evil.example".parse().unwrap());
        assert!(guard_request(&forged).is_err());
    }

    #[test]
    fn localhost_is_exact_and_json_media_types_are_exact() {
        assert_eq!(
            site_origin(Some("localhost:3000")).as_deref(),
            Some("http://localhost:3000")
        );
        let previous = env::var("FIZZ_PUBLIC_HOST").ok();
        let previous_scheme = env::var("FIZZ_PUBLIC_SCHEME").ok();
        // SAFETY: tests in this process do not read these variables. Restored below.
        unsafe {
            env::set_var(
                "FIZZ_PUBLIC_HOST",
                "sensors.example.com, https://edge.example.com/",
            );
            env::set_var("FIZZ_PUBLIC_SCHEME", "http");
        }
        assert_eq!(
            site_origin(Some("sensors.example.com")).as_deref(),
            Some("http://sensors.example.com")
        );
        unsafe {
            env::set_var("FIZZ_PUBLIC_SCHEME", "https");
        }
        assert_eq!(
            site_origin(Some("edge.example.com")).as_deref(),
            Some("https://edge.example.com")
        );
        assert!(site_origin(Some("other.example.com")).is_none());
        unsafe {
            match previous {
                Some(value) => env::set_var("FIZZ_PUBLIC_HOST", value),
                None => env::remove_var("FIZZ_PUBLIC_HOST"),
            }
            match previous_scheme {
                Some(value) => env::set_var("FIZZ_PUBLIC_SCHEME", value),
                None => env::remove_var("FIZZ_PUBLIC_SCHEME"),
            }
        }
        for host in [
            "localhost.evil.com",
            "127.0.0.1.evil.com",
            "evil.com/path",
            "fizzlayer.com:444",
        ] {
            assert!(site_origin(Some(host)).is_none(), "{host}");
        }
        assert!(is_json("application/json; charset=utf-8"));
        assert!(is_json("Application/JSON"));
        assert!(!is_json("application/jsonp"));
        assert!(!is_json("text/plain"));
    }
}
