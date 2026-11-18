//! Poll the Fizzlayer control plane and write the agentgateway config file.
//!
//! `FIZZ_API_URL` is the origin (`https://fizzlayer.com`). The registration
//! token comes from `FIZZ_REGISTRATION_TOKEN_FILE` or `FIZZ_REGISTRATION_TOKEN`.
//! Neither the token nor the YAML is written to the log. A failed pull or a
//! rejected document leaves the last good file in place.

use std::env;
use std::path::PathBuf;
use std::time::Duration;

use fizz_gateway::agent::{
    self, SyncKind, SyncRequest, control_origin, fleet_token_ok, registration_token_ok,
};
use fizz_gateway::error::{GatewayError, GatewayResult};

#[tokio::main]
async fn main() {
    let code = match run().await {
        Ok(()) => 0,
        Err(err) => {
            eprintln!("fizz-agent: {err}");
            1
        }
    };
    std::process::exit(code);
}

async fn run() -> GatewayResult<()> {
    let mut args = env::args().skip(1);
    match args.next().as_deref() {
        Some("pull") | None => pull().await,
        Some("help") => {
            eprintln!(
                "usage: fizz-agent pull\n\
                 reads FIZZ_API_URL and a registration token, and writes FIZZ_CONFIG_OUT"
            );
            Ok(())
        }
        Some(_) => Err(GatewayError::message("unknown command")),
    }
}

async fn pull() -> GatewayResult<()> {
    let origin = control_origin(&required("FIZZ_API_URL")?)?;
    let (token, fleet) = load_token()?;
    let config_path = PathBuf::from(
        env::var("FIZZ_CONFIG_OUT").unwrap_or_else(|_| "/config/config.yaml".to_string()),
    );
    let cursor_path = env::var("FIZZ_AGENT_STATE")
        .map(PathBuf::from)
        .unwrap_or_else(|_| sibling_cursor(&config_path));
    let admin = env::var("FIZZ_ADMIN_URL")
        .ok()
        .filter(|value| !value.trim().is_empty());
    if let Some(admin) = &admin {
        control_origin(admin)?;
    }
    let listen_port = match env::var("FIZZ_LISTEN_PORT") {
        Ok(value) if fleet => {
            let port = value
                .trim()
                .parse::<u16>()
                .map_err(|_| GatewayError::message("FIZZ_LISTEN_PORT is not usable"))?;
            if port == 0 {
                return Err(GatewayError::message("FIZZ_LISTEN_PORT is not usable"));
            }
            Some(port)
        }
        Ok(_) => {
            return Err(GatewayError::message(
                "FIZZ_LISTEN_PORT is only used for the shared fleet",
            ));
        }
        Err(_) => None,
    };
    let base = Duration::from_secs(poll_secs()?);
    let client = agent::http_client()?;
    let (mut etag, mut revision) = agent::load_cursor(&cursor_path);
    let mut delay = base;
    let mut reported: Option<(i64, &'static str)> = None;
    loop {
        let outcome = agent::sync_once(SyncRequest {
            client: &client,
            origin: &origin,
            token: &token,
            config_path: &config_path,
            admin_url: admin.as_deref(),
            etag: etag.as_deref(),
            revision,
            fleet,
            listen_port,
        })
        .await;
        let failed = matches!(outcome.kind, SyncKind::Hold { .. });
        match &outcome.kind {
            SyncKind::NotModified => {}
            SyncKind::Applied { revision: applied } => {
                eprintln!("fizz-agent: applied revision {applied}");
            }
            SyncKind::Rejected {
                revision: rejected,
                detail,
            } => {
                eprintln!("fizz-agent: rejected revision {rejected}: {detail}");
            }
            SyncKind::Hold { detail } => {
                eprintln!("fizz-agent: {detail}");
            }
        }
        if !failed {
            etag = outcome.etag;
            revision = outcome.revision;
            if let (Some(saved), Some(saved_revision)) = (etag.as_deref(), revision) {
                if let Err(err) = agent::store_cursor(&cursor_path, saved, saved_revision) {
                    eprintln!("fizz-agent: {err}");
                }
            }
        }
        if let Some(report) = outcome.report {
            let key = (report.revision, report.status);
            if reported != Some(key) {
                match agent::report_status(&client, &origin, &token, report, fleet).await {
                    Ok(()) => reported = Some(key),
                    Err(detail) => eprintln!("fizz-agent: {detail}"),
                }
            }
        }
        delay = agent::next_delay(delay, base, failed);
        tokio::select! {
            () = tokio::time::sleep(delay) => {}
            () = shutdown() => {
                eprintln!("fizz-agent: stopping");
                return Ok(());
            }
        }
    }
}

fn sibling_cursor(config: &std::path::Path) -> PathBuf {
    let mut path = config.to_path_buf();
    path.set_file_name(".fizz-agent-state");
    path
}

fn load_token() -> GatewayResult<(String, bool)> {
    let fleet_file = env::var("FIZZ_FLEET_TOKEN_FILE").ok();
    let fleet_env = env::var("FIZZ_FLEET_TOKEN").ok();
    let reg_file = env::var("FIZZ_REGISTRATION_TOKEN_FILE").ok();
    let reg_env = env::var("FIZZ_REGISTRATION_TOKEN").ok();
    let fleet_set =
        fleet_file.is_some() || fleet_env.as_ref().is_some_and(|value| !value.is_empty());
    let reg_set = reg_file.is_some() || reg_env.as_ref().is_some_and(|value| !value.is_empty());
    if fleet_set && reg_set {
        return Err(GatewayError::message(
            "set either the fleet token or the registration token",
        ));
    }
    if fleet_set {
        let token = if let Some(path) = fleet_file {
            std::fs::read_to_string(&path)
                .map_err(|_| GatewayError::message("fleet token file could not be read"))?
        } else {
            fleet_env.unwrap_or_default()
        };
        let token = token.trim().to_string();
        if !fleet_token_ok(&token) {
            return Err(GatewayError::message("fleet token was rejected"));
        }
        return Ok((token, true));
    }
    let token = if let Some(path) = reg_file {
        std::fs::read_to_string(&path)
            .map_err(|_| GatewayError::message("registration token file could not be read"))?
    } else {
        required("FIZZ_REGISTRATION_TOKEN")?
    };
    let token = token.trim().to_string();
    if !registration_token_ok(&token) {
        return Err(GatewayError::message("registration token was rejected"));
    }
    Ok((token, false))
}

fn poll_secs() -> GatewayResult<u64> {
    let value = env::var("FIZZ_POLL_SECS")
        .ok()
        .and_then(|text| text.parse().ok())
        .unwrap_or(5);
    if (1..=300).contains(&value) {
        Ok(value)
    } else {
        Err(GatewayError::message(
            "FIZZ_POLL_SECS must be between 1 and 300",
        ))
    }
}

fn required(name: &str) -> GatewayResult<String> {
    env::var(name).map_err(|_| GatewayError::message(format!("missing {name}")))
}

async fn shutdown() {
    let ctrl_c = tokio::signal::ctrl_c();
    #[cfg(unix)]
    {
        let mut term =
            match tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()) {
                Ok(signal) => signal,
                Err(_) => {
                    let _ = ctrl_c.await;
                    return;
                }
            };
        tokio::select! {
            _ = ctrl_c => {}
            _ = term.recv() => {}
        }
    }
    #[cfg(not(unix))]
    {
        let _ = ctrl_c.await;
    }
}
