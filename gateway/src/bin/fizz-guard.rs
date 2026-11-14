//! ExtMcp policy server. agentgateway calls CheckRequest before tools/call.
//! Allow and deny are final. Approve stores a pending row and rejects; a later
//! identical call is allowed once after that row is marked approved. Nothing
//! here places a phone call or sends chat. That notifier is a later piece.

use std::env;
use std::net::SocketAddr;
use std::time::Duration;

use fizz_gateway::db::{AuditWrite, Db};
use fizz_gateway::error::{GatewayError, GatewayResult};
use fizz_gateway::ext_mcp::ext_mcp_server::{ExtMcp, ExtMcpServer};
use fizz_gateway::ext_mcp::{
    authorization_error, mcp_request_result, mcp_response_result, AuthorizationError, McpRequest,
    McpRequestResult, McpResponse, McpResponseResult, Pass,
};
use fizz_gateway::policy::{self, ApprovalHit, Step};
use prost_types::value::Kind;
use serde_json::Value;
use tonic::{Request, Response, Status};
use uuid::Uuid;

struct Guard {
    db: Db,
}

#[tonic::async_trait]
impl ExtMcp for Guard {
    async fn check_request(
        &self,
        request: Request<McpRequest>,
    ) -> Result<Response<McpRequestResult>, Status> {
        let message = request.into_inner();
        match self.decide(&message).await {
            Ok(result) => Ok(Response::new(result)),
            Err(err) => {
                eprintln!("fizz-guard: {err}");
                Ok(Response::new(reject("guardrail check failed")))
            }
        }
    }

    async fn check_response(
        &self,
        _request: Request<McpResponse>,
    ) -> Result<Response<McpResponseResult>, Status> {
        Ok(Response::new(McpResponseResult {
            result: Some(mcp_response_result::Result::Pass(Pass {})),
        }))
    }
}

impl Guard {
    async fn decide(&self, message: &McpRequest) -> GatewayResult<McpRequestResult> {
        if message.method != "tools/call" {
            return Ok(pass());
        }
        let server = message
            .service_names
            .first()
            .map(String::as_str)
            .unwrap_or("");
        let server_label = if server.is_empty() { "unknown" } else { server };
        let bytes = message.mcp_request.as_deref().unwrap_or(b"{}");
        let (tool, arguments) = match tool_call(bytes) {
            Some(parsed) => parsed,
            None => return Ok(reject("tool call was rejected")),
        };
        let Some(identity) = identity(message) else {
            return Ok(reject("tool call was rejected"));
        };
        let Some(workspace) = self.db.gateway_workspace(identity.gateway_id).await? else {
            return Ok(reject("tool call was rejected"));
        };
        if workspace != identity.workspace_id {
            self.audit(
                &identity,
                server_label,
                &tool,
                &arguments,
                "deny",
                "workspace did not match",
            )
            .await?;
            eprintln!("fizz-guard: decision=deny tool={tool} server={server_label}");
            return Ok(reject("tool call was rejected"));
        }
        if !self
            .db
            .token_active(identity.gateway_id, &identity.jti)
            .await?
        {
            self.audit(
                &identity,
                server_label,
                &tool,
                &arguments,
                "deny",
                "token is not active",
            )
            .await?;
            eprintln!("fizz-guard: decision=deny tool={tool} server={server_label}");
            return Ok(reject("tool call was rejected"));
        }
        let rules = self.db.policies(identity.gateway_id).await?;
        let effect = policy::match_effect(&rules, server, &tool);
        let (hash, _) = policy::fingerprint(&arguments);
        let hit = if matches!(effect, fizz_gateway::policy::Effect::Approve) {
            self.db
                .approval_hit(identity.gateway_id, server, &tool, &hash)
                .await?
        } else {
            ApprovalHit::None
        };
        match policy::decide(effect, hit, &tool) {
            Step::Allow { decision } => {
                self.audit(&identity, server_label, &tool, &arguments, decision, "")
                    .await?;
                eprintln!("fizz-guard: decision={decision} tool={tool} server={server_label}");
                Ok(pass())
            }
            Step::Reject { decision, reason } => {
                self.audit(
                    &identity,
                    server_label,
                    &tool,
                    &arguments,
                    decision,
                    &reason,
                )
                .await?;
                eprintln!("fizz-guard: decision={decision} tool={tool} server={server_label}");
                Ok(reject(&reason))
            }
            Step::Consume { id } => {
                if !self.db.consume_approval(id).await? {
                    self.audit(
                        &identity,
                        server_label,
                        &tool,
                        &arguments,
                        "deny",
                        "approval was no longer usable",
                    )
                    .await?;
                    eprintln!("fizz-guard: decision=deny tool={tool} server={server_label}");
                    return Ok(reject("tool call was rejected"));
                }
                self.audit(
                    &identity,
                    server_label,
                    &tool,
                    &arguments,
                    "approval_consumed",
                    "",
                )
                .await?;
                eprintln!(
                    "fizz-guard: decision=approval_consumed tool={tool} server={server_label}"
                );
                Ok(pass())
            }
            Step::OpenApproval => {
                let id = match hit {
                    ApprovalHit::Pending { id } => id,
                    _ => {
                        self.db
                            .open_approval(
                                identity.gateway_id,
                                identity.workspace_id,
                                server_label,
                                &tool,
                                &hash,
                            )
                            .await?
                    }
                };
                let reason = policy::approval_message(id);
                self.audit(
                    &identity,
                    server_label,
                    &tool,
                    &arguments,
                    "approval_required",
                    &reason,
                )
                .await?;
                eprintln!(
                    "fizz-guard: decision=approval_required tool={tool} server={server_label}"
                );
                Ok(reject(&reason))
            }
        }
    }

    async fn audit(
        &self,
        identity: &Identity,
        server: &str,
        tool: &str,
        arguments: &Value,
        decision: &'static str,
        reason: &str,
    ) -> GatewayResult<()> {
        let (hash, preview) = policy::fingerprint(arguments);
        let reason = {
            let mut text = reason.to_string();
            if text.len() > 400 {
                text.truncate(400);
            }
            text
        };
        self.db
            .record_audit(&AuditWrite {
                gateway_id: identity.gateway_id,
                workspace_id: identity.workspace_id,
                server_name: bound(server, 80),
                tool_name: bound(tool, 128),
                subject: identity.subject.clone(),
                jti: identity.jti.clone(),
                args_hash: hash,
                args_preview: preview,
                decision,
                reason,
            })
            .await
    }
}

struct Identity {
    gateway_id: Uuid,
    workspace_id: Uuid,
    subject: String,
    jti: String,
}

fn identity(message: &McpRequest) -> Option<Identity> {
    let meta = message.metadata_context.as_ref()?;
    let gateway_raw = meta_str(meta, "gateway")?;
    let gateway_id = Uuid::parse_str(gateway_raw.trim_matches('\'')).ok()?;
    let workspace_raw = meta_str(meta, "ws")?;
    let workspace_id = Uuid::parse_str(&workspace_raw).ok()?;
    let subject = meta_str(meta, "sub")?;
    let jti = meta_str(meta, "jti")?;
    if subject.len() > 80 || jti.len() > 80 {
        return None;
    }
    Some(Identity {
        gateway_id,
        workspace_id,
        subject,
        jti,
    })
}

fn meta_str(meta: &prost_types::Struct, key: &str) -> Option<String> {
    match meta.fields.get(key).and_then(|value| value.kind.as_ref()) {
        Some(Kind::StringValue(text)) if !text.is_empty() => Some(text.clone()),
        _ => None,
    }
}

fn tool_call(bytes: &[u8]) -> Option<(String, Value)> {
    let value: Value = serde_json::from_slice(bytes).ok()?;
    let name = value.get("name").and_then(Value::as_str)?.to_string();
    if name.is_empty() || name.len() > 128 {
        return None;
    }
    let arguments = value
        .get("arguments")
        .cloned()
        .unwrap_or_else(|| Value::Object(Default::default()));
    Some((name, arguments))
}

fn bound(value: &str, max: usize) -> String {
    let mut text = value.to_string();
    if text.len() > max {
        text.truncate(max);
    }
    text
}

fn pass() -> McpRequestResult {
    McpRequestResult {
        result: Some(mcp_request_result::Result::Pass(Pass {})),
        header_mutation: None,
        metadata: None,
    }
}

fn reject(reason: &str) -> McpRequestResult {
    McpRequestResult {
        result: Some(mcp_request_result::Result::Error(AuthorizationError {
            code: authorization_error::Code::PermissionDenied as i32,
            reason: reason.to_string(),
            mcp_error: None,
        })),
        header_mutation: None,
        metadata: None,
    }
}

#[tokio::main]
async fn main() {
    let mut args = env::args().skip(1);
    match args.next().as_deref() {
        Some("ready") => {
            let listen =
                env::var("FIZZ_GUARD_LISTEN").unwrap_or_else(|_| "0.0.0.0:9001".to_string());
            let port = listen.rsplit(':').next().unwrap_or("9001");
            let addr = format!("127.0.0.1:{port}");
            match std::net::TcpStream::connect_timeout(
                &addr
                    .parse()
                    .unwrap_or_else(|_| SocketAddr::from(([127, 0, 0, 1], 1))),
                Duration::from_secs(2),
            ) {
                Ok(_) => std::process::exit(0),
                Err(_) => {
                    eprintln!("fizz-guard: not ready");
                    std::process::exit(1);
                }
            }
        }
        Some("serve") | None => {
            if let Err(err) = serve().await {
                eprintln!("fizz-guard: {err}");
                std::process::exit(1);
            }
        }
        Some(_) => {
            eprintln!("usage: fizz-guard serve | fizz-guard ready");
            std::process::exit(2);
        }
    }
}

async fn serve() -> GatewayResult<()> {
    let url =
        env::var("DATABASE_URL").map_err(|_| GatewayError::message("missing DATABASE_URL"))?;
    let listen = env::var("FIZZ_GUARD_LISTEN").unwrap_or_else(|_| "0.0.0.0:9001".to_string());
    let addr: SocketAddr = listen
        .parse()
        .map_err(|_| GatewayError::message("listen address is not usable"))?;
    let db = Db::connect(&url).await?;
    let service = ExtMcpServer::new(Guard { db });
    eprintln!("fizz-guard: listening");
    tonic::transport::Server::builder()
        .add_service(service)
        .serve(addr)
        .await
        .map_err(|_| GatewayError::message("policy server stopped"))?;
    Ok(())
}
