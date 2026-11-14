//! Tiny Streamable HTTP MCP server used by the local compose test.
//! It is not a product surface. ping, admin_reset, and move_funds are the
//! three tools the probe calls; the gateway is what allows or denies them.

use std::env;
use std::net::SocketAddr;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;

use axum::extract::State;
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use serde_json::{json, Value};
use tokio::net::TcpListener;

#[derive(Default)]
struct Counts {
    ping: AtomicU64,
    admin_reset: AtomicU64,
    move_funds: AtomicU64,
}

#[tokio::main]
async fn main() {
    let mut args = env::args().skip(1);
    let port: u16 = env::var("SAMPLE_PORT")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(8080);
    match args.next().as_deref() {
        Some("ready") => {
            let addr = format!("127.0.0.1:{port}");
            match std::net::TcpStream::connect_timeout(
                &addr
                    .parse()
                    .unwrap_or_else(|_| SocketAddr::from(([127, 0, 0, 1], 1))),
                Duration::from_secs(2),
            ) {
                Ok(_) => std::process::exit(0),
                Err(_) => {
                    eprintln!("sample-mcp: not ready");
                    std::process::exit(1);
                }
            }
        }
        Some("serve") | None => {}
        Some(_) => {
            eprintln!("usage: sample-mcp serve | sample-mcp ready");
            std::process::exit(2);
        }
    }
    let app = Router::new()
        .route("/health", get(|| async { "ok" }))
        .route("/calls", get(calls))
        .route("/mcp", post(mcp).delete(|| async { StatusCode::OK }))
        .with_state(Arc::new(Counts::default()));
    let listener = TcpListener::bind(("0.0.0.0", port)).await.expect("bind");
    eprintln!("sample-mcp: listening");
    axum::serve(listener, app).await.expect("serve");
}

async fn calls(State(counts): State<Arc<Counts>>) -> Json<Value> {
    Json(json!({
        "ping": counts.ping.load(Ordering::Relaxed),
        "admin_reset": counts.admin_reset.load(Ordering::Relaxed),
        "move_funds": counts.move_funds.load(Ordering::Relaxed),
    }))
}

async fn mcp(
    State(counts): State<Arc<Counts>>,
    headers: HeaderMap,
    Json(body): Json<Value>,
) -> Response {
    let id = body.get("id").cloned().unwrap_or(Value::Null);
    if id.is_null() {
        return StatusCode::ACCEPTED.into_response();
    }
    let method = body.get("method").and_then(Value::as_str).unwrap_or("");
    let result = match method {
        "initialize" => {
            let version = body
                .pointer("/params/protocolVersion")
                .and_then(Value::as_str)
                .unwrap_or("2025-03-26");
            json!({
                "protocolVersion": version,
                "capabilities": {"tools": {"listChanged": false}},
                "serverInfo": {"name": "fizzlayer-sample", "version": "0.1.0"}
            })
        }
        "tools/list" => json!({
            "tools": [
                tool("ping", "Return pong."),
                tool("admin_reset", "Reset the sample server. Denied by the local policy."),
                tool("move_funds", "Move funds. Requires approval.")
            ]
        }),
        "tools/call" => {
            let name = body
                .pointer("/params/name")
                .and_then(Value::as_str)
                .unwrap_or("");
            match name {
                "ping" => counts.ping.fetch_add(1, Ordering::Relaxed),
                "admin_reset" => counts.admin_reset.fetch_add(1, Ordering::Relaxed),
                "move_funds" => counts.move_funds.fetch_add(1, Ordering::Relaxed),
                _ => {
                    return rpc_error(id, -32602, "unknown tool");
                }
            };
            json!({
                "content": [{"type": "text", "text": match name {
                    "ping" => "pong",
                    "admin_reset" => "reset",
                    _ => "moved",
                }}],
                "isError": false
            })
        }
        _ => return rpc_error(id, -32601, "method not found"),
    };
    let mut response = Json(json!({"jsonrpc": "2.0", "id": id, "result": result})).into_response();
    if method == "initialize" {
        let session = headers
            .get("mcp-session-id")
            .and_then(|value| value.to_str().ok())
            .unwrap_or("fizzlayer-sample");
        response.headers_mut().insert(
            "mcp-session-id",
            session
                .parse()
                .unwrap_or_else(|_| axum::http::HeaderValue::from_static("fizzlayer-sample")),
        );
    }
    response
}

fn tool(name: &str, description: &str) -> Value {
    json!({
        "name": name,
        "description": description,
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": false}
    })
}

fn rpc_error(id: Value, code: i32, message: &str) -> Response {
    Json(json!({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}}))
        .into_response()
}
