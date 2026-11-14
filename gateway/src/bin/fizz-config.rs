//! Render agentgateway YAML from gateway.servers, and mint client JWTs.
//! `watch` rewrites the file only when the render changes, which is what the
//! proxy's hot reload watches for.

use std::env;
use std::path::PathBuf;
use std::time::Duration;

use fizz_gateway::config::{self, render_yaml};
use fizz_gateway::db::Db;
use fizz_gateway::error::GatewayResult;
use fizz_gateway::jwt;
use uuid::Uuid;

#[tokio::main]
async fn main() {
    let code = match run().await {
        Ok(()) => 0,
        Err(err) => {
            eprintln!("fizz-config: {err}");
            1
        }
    };
    std::process::exit(code);
}

async fn run() -> GatewayResult<()> {
    let mut args = env::args().skip(1);
    match args.next().as_deref() {
        Some("render") => render_once().await,
        Some("watch") => watch().await,
        Some("token") => {
            let rest: Vec<String> = args.collect();
            issue_token(&rest).await
        }
        Some("help") | None => {
            eprintln!(
                "usage: fizz-config render | fizz-config watch | fizz-config token --out <file> [--name <label>] [--ttl-secs <n>] [--gateway <uuid>]"
            );
            Ok(())
        }
        Some(other) => Err(fizz_gateway::error::GatewayError::message(format!(
            "unknown command {other}"
        ))),
    }
}

async fn render_once() -> GatewayResult<()> {
    let db = Db::connect(&required("DATABASE_URL")?).await?;
    let spec = db
        .load_gateway(
            gateway_flag(&env::args().skip(1).collect::<Vec<_>>())?,
            &required("FIZZ_GUARD_HOST")?,
            &required("FIZZ_JWKS_FILE")?,
        )
        .await?;
    let material = jwt::load_or_create(PathBuf::from(required("FIZZ_SIGNING_KEY")?).as_path())?;
    config::write_if_changed(
        PathBuf::from(required("FIZZ_JWKS_FILE")?).as_path(),
        &String::from_utf8_lossy(&material.jwks_json()?),
    )?;
    let yaml = render_yaml(&spec)?;
    let wrote =
        config::write_if_changed(PathBuf::from(required("FIZZ_CONFIG_OUT")?).as_path(), &yaml)?;
    eprintln!(
        "fizz-config: gateway {} revision {} {}",
        spec.gateway_id,
        spec.config_revision,
        if wrote {
            "wrote config"
        } else {
            "config unchanged"
        }
    );
    Ok(())
}

async fn watch() -> GatewayResult<()> {
    loop {
        if let Err(err) = render_once().await {
            eprintln!("fizz-config: {err}");
        }
        tokio::time::sleep(Duration::from_secs(2)).await;
    }
}

async fn issue_token(args: &[String]) -> GatewayResult<()> {
    let out = flag(args, "--out")
        .ok_or_else(|| fizz_gateway::error::GatewayError::message("token --out is required"))?;
    let name = flag(args, "--name").unwrap_or_else(|| "client".to_string());
    let ttl: u64 = flag(args, "--ttl-secs")
        .and_then(|value| value.parse().ok())
        .unwrap_or(30 * 24 * 60 * 60);
    if !(60..=30 * 24 * 60 * 60).contains(&ttl) || name.is_empty() || name.len() > 80 {
        return Err(fizz_gateway::error::GatewayError::message(
            "token options were rejected",
        ));
    }
    let db = Db::connect(&required("DATABASE_URL")?).await?;
    let spec = db
        .load_gateway(
            gateway_flag(args)?,
            &required("FIZZ_GUARD_HOST")?,
            &required("FIZZ_JWKS_FILE")?,
        )
        .await?;
    let (_workspace, user_id, audience) = db.user_for_gateway(spec.gateway_id).await?;
    let material = jwt::load_or_create(PathBuf::from(required("FIZZ_SIGNING_KEY")?).as_path())?;
    let jti = Uuid::new_v4();
    db.insert_token(spec.gateway_id, user_id, &name, jti, ttl)
        .await?;
    let token = material.issue(&user_id.to_string(), spec.workspace_id, &audience, jti, ttl)?;
    write_secret(&PathBuf::from(out), token.as_bytes())?;
    eprintln!("fizz-config: wrote token file");
    Ok(())
}

fn write_secret(path: &std::path::Path, bytes: &[u8]) -> GatewayResult<()> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|_| {
            fizz_gateway::error::GatewayError::message("token file could not be written")
        })?;
    }
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(path)
        .map_err(|_| {
            fizz_gateway::error::GatewayError::message("token file could not be written")
        })?;
    file.write_all(bytes).map_err(|_| {
        fizz_gateway::error::GatewayError::message("token file could not be written")
    })?;
    Ok(())
}

fn required(name: &str) -> GatewayResult<String> {
    env::var(name)
        .map_err(|_| fizz_gateway::error::GatewayError::message(format!("missing {name}")))
}

fn gateway_flag(args: &[String]) -> GatewayResult<Option<Uuid>> {
    match flag(args, "--gateway") {
        Some(value) => Uuid::parse_str(&value)
            .map(Some)
            .map_err(|_| fizz_gateway::error::GatewayError::message("gateway id is not usable")),
        None => Ok(None),
    }
}

fn flag(args: &[String], name: &str) -> Option<String> {
    args.iter()
        .position(|arg| arg == name)
        .and_then(|index| args.get(index + 1))
        .cloned()
}
