//! Local approve/deny page and JSON API. The bearer token is the deployment
//! secret. It can decide any pending approval in this database, so do not
//! publish the port on a shared multi-tenant host.

use std::net::SocketAddr;
use std::sync::Arc;

use axum::Json;
use axum::Router;
use axum::extract::State;
use axum::http::{HeaderMap, StatusCode, header::AUTHORIZATION};
use axum::response::{Html, IntoResponse};
use axum::routing::{get, post};
use serde::Deserialize;
use serde_json::json;
use tokio::net::TcpListener;
use uuid::Uuid;

use crate::error::{GatewayError, GatewayResult};
use crate::notify::{safe_label, token_matches};
use crate::policy::short_id;
use crate::store::Backend;

struct AppState {
    token: String,
    backend: Arc<Backend>,
}

pub async fn serve(addr: SocketAddr, token: String, backend: Arc<Backend>) -> GatewayResult<()> {
    if token.is_empty() {
        return Err(GatewayError::message("admin token is not set"));
    }
    let app = Router::new()
        .route("/", get(page))
        .route("/approvals", get(list_approvals))
        .route("/approvals/decision", post(decide))
        .route("/alerts", get(list_alerts))
        .route("/alerts/approve", post(reapprove))
        .with_state(Arc::new(AppState { token, backend }));
    let listener = TcpListener::bind(addr)
        .await
        .map_err(|_| GatewayError::message("admin listener did not bind"))?;
    eprintln!("fizz-guard: admin listening");
    axum::serve(listener, app)
        .await
        .map_err(|_| GatewayError::message("admin server stopped"))?;
    Ok(())
}

async fn page() -> Html<&'static str> {
    Html(PAGE)
}

async fn list_approvals(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> impl IntoResponse {
    if !authorized(&headers, &state.token) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    match state.backend.list_pending().await {
        Ok(rows) => Json(json!({
            "approvals": rows.into_iter().map(|row| json!({
                "id": row.id,
                "short_id": short_id(row.id),
                "gateway_id": row.gateway_id,
                "server": safe_label(&row.server),
                "tool": safe_label(&row.tool),
                "args_preview": row.args_preview,
                "expires_at": row.expires_at,
            })).collect::<Vec<_>>()
        }))
        .into_response(),
        Err(_) => StatusCode::INTERNAL_SERVER_ERROR.into_response(),
    }
}

async fn decide(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(body): Json<DecisionBody>,
) -> impl IntoResponse {
    if !authorized(&headers, &state.token) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    if !matches!(body.status.as_str(), "approved" | "denied") {
        return StatusCode::BAD_REQUEST.into_response();
    }
    match state.backend.decide_approval(body.id, &body.status).await {
        Ok(true) => Json(json!({"status": body.status})).into_response(),
        Ok(false) => StatusCode::CONFLICT.into_response(),
        Err(_) => StatusCode::BAD_REQUEST.into_response(),
    }
}

async fn list_alerts(State(state): State<Arc<AppState>>, headers: HeaderMap) -> impl IntoResponse {
    if !authorized(&headers, &state.token) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    match state.backend.list_alerts().await {
        Ok(rows) => Json(json!({
            "alerts": rows.into_iter().map(|row| json!({
                "gateway_id": row.gateway_id,
                "server": safe_label(&row.server),
                "tool": safe_label(&row.tool),
                "description_preview": row.description_preview,
                "observed_sha256": row.observed_sha256,
            })).collect::<Vec<_>>()
        }))
        .into_response(),
        Err(_) => StatusCode::INTERNAL_SERVER_ERROR.into_response(),
    }
}

async fn reapprove(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(body): Json<ReapproveBody>,
) -> impl IntoResponse {
    if !authorized(&headers, &state.token) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    match state
        .backend
        .reapprove_pin(body.gateway_id, &body.server, &body.tool)
        .await
    {
        Ok(true) => Json(json!({"status": "approved"})).into_response(),
        Ok(false) => StatusCode::CONFLICT.into_response(),
        Err(_) => StatusCode::BAD_REQUEST.into_response(),
    }
}

fn authorized(headers: &HeaderMap, expected: &str) -> bool {
    let Some(value) = headers
        .get(AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
    else {
        return false;
    };
    let Some(presented) = value.strip_prefix("Bearer ") else {
        return false;
    };
    token_matches(presented, expected)
}

#[derive(Deserialize)]
struct DecisionBody {
    id: Uuid,
    status: String,
}

#[derive(Deserialize)]
struct ReapproveBody {
    gateway_id: Uuid,
    server: String,
    tool: String,
}

const PAGE: &str = r##"<!doctype html>
<meta charset="utf-8">
<title>Fizzlayer approvals</title>
<style>
  body { font: 16px/1.4 system-ui, sans-serif; margin: 2rem; max-width: 42rem; }
  button { margin-right: 0.5rem; }
  li { margin: 0.75rem 0; }
  .note { color: #444; }
</style>
<h1>Approvals</h1>
<p class="note">Pending tool calls for this gateway. Approving allows one retry of the same arguments. This page does not place a phone call. Description text on an alert is untrusted text from the MCP server.</p>
<label>Admin token <input id="token" type="password" autocomplete="off"></label>
<button id="load" type="button">Load</button>
<h2>Pending</h2>
<ul id="approvals"></ul>
<h2>Description changes</h2>
<ul id="alerts"></ul>
<script>
const token = document.querySelector("#token");
const approvals = document.querySelector("#approvals");
const alerts = document.querySelector("#alerts");
document.querySelector("#load").addEventListener("click", load);
async function api(path, options) {
  const headers = Object.assign({authorization: "Bearer " + token.value}, options && options.headers);
  const response = await fetch(path, Object.assign({}, options, {headers}));
  if (!response.ok) throw new Error(String(response.status));
  return response.json();
}
function line(parent, text) {
  const item = document.createElement("li");
  item.textContent = text;
  parent.appendChild(item);
  return item;
}
async function load() {
  approvals.replaceChildren();
  alerts.replaceChildren();
  try {
    const pending = await api("/approvals");
    for (const row of pending.approvals) {
      const item = line(approvals, row.server + " / " + row.tool + " (" + row.short_id + ") " + row.args_preview);
      add(item, "Approve", () => decide(row, "approved"));
      add(item, "Deny", () => decide(row, "denied"));
    }
    if (pending.approvals.length === 0) line(approvals, "None.");
    const changed = await api("/alerts");
    for (const row of changed.alerts) {
      const item = line(alerts, row.server + " / " + row.tool + " - " + row.description_preview);
      add(item, "Approve description", () => reapprove(row));
    }
    if (changed.alerts.length === 0) line(alerts, "None.");
  } catch (err) {
    line(approvals, "Could not load.");
  }
}
function add(item, label, action) {
  const button = document.createElement("button");
  button.type = "button";
  button.textContent = label;
  button.addEventListener("click", action);
  item.appendChild(document.createTextNode(" "));
  item.appendChild(button);
}
async function decide(row, status) {
  await api("/approvals/decision", {method: "POST", headers: {"content-type": "application/json"}, body: JSON.stringify({id: row.id, status})});
  await load();
}
async function reapprove(row) {
  await api("/alerts/approve", {method: "POST", headers: {"content-type": "application/json"}, body: JSON.stringify({gateway_id: row.gateway_id, server: row.server, tool: row.tool})});
  await load();
}
</script>
"##;
