//! ExtMcp policy server.
//!
//! `tools/call` is allow, deny, or approve. Approve stores a pending row and
//! rejects immediately. A later identical call is allowed once after that row
//! is marked approved. The handler never waits for a person: agentgateway
//! aborts this RPC after 10 seconds.
//!
//! `tools/list` hashes each tool's name, description, and input schema. A new
//! tool is stored as unreviewed. A changed approved hash is removed from the
//! list and recorded as an alert. `tools/call` is denied unless the pin is
//! approved. Response replacement uses `McpResponseResult.mutated`, which
//! agentgateway accepts as a new JSON-RPC result. See gateway/UPSTREAM.md.

use std::env;
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use fizz_gateway::db::{AuditWrite, NewApproval, ToolSight};
use fizz_gateway::error::{GatewayError, GatewayResult};
use fizz_gateway::ext_mcp::ext_mcp_server::{ExtMcp, ExtMcpServer};
use fizz_gateway::ext_mcp::{
    AuthorizationError, McpRequest, McpRequestResult, McpResponse, McpResponseResult, Pass,
    authorization_error, mcp_request_result, mcp_response_result,
};
use fizz_gateway::notify::{self, ApprovalNotice, Notifiers, phone_attempt};
use fizz_gateway::policy::{self, ApprovalHit, NotifyChannel, Step};
use fizz_gateway::store::Backend;
use fizz_gateway::toolpin;
use prost_types::value::Kind;
use serde_json::Value;
use tonic::{Request, Response, Status};
use uuid::Uuid;

struct Guard {
    backend: Arc<Backend>,
    notifiers: Notifiers,
    ttl_secs: i64,
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
        request: Request<McpResponse>,
    ) -> Result<Response<McpResponseResult>, Status> {
        let message = request.into_inner();
        match self.review_list(&message).await {
            Ok(result) => Ok(Response::new(result)),
            Err(err) => {
                eprintln!("fizz-guard: {err}");
                Ok(Response::new(reject_response("guardrail check failed")))
            }
        }
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
        let Some(identity) = identity(message.metadata_context.as_ref()) else {
            return Ok(reject("tool call was rejected"));
        };
        if !self
            .workspace_ok(&identity, server_label, &tool, &arguments)
            .await?
        {
            return Ok(reject("tool call was rejected"));
        }
        let record = if server.is_empty() {
            None
        } else {
            self.backend
                .pin_record(identity.gateway_id, server, &tool)
                .await?
        };
        if toolpin::pin_blocks_call(record.as_ref()) {
            let reason = toolpin::pin_block_message(&tool, record.as_ref());
            self.audit(&identity, server_label, &tool, &arguments, "deny", &reason)
                .await?;
            eprintln!("fizz-guard: decision=deny tool={tool} server={server_label}");
            return Ok(reject(&reason));
        }
        let rules = self.backend.policies(identity.gateway_id).await?;
        let effect = policy::match_effect(&rules, server, &tool);
        let channel = policy::match_channel(&rules, server, &tool);
        let (hash, preview) = policy::fingerprint(&arguments);
        let hit = if matches!(effect, fizz_gateway::policy::Effect::Approve) {
            self.backend
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
                if !self.backend.consume_approval(id).await? {
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
                let (id, created) = match hit {
                    ApprovalHit::Pending { id } => (id, false),
                    _ => (
                        self.backend
                            .open_approval(&NewApproval {
                                gateway_id: identity.gateway_id,
                                workspace_id: identity.workspace_id,
                                server: server_label,
                                tool: &tool,
                                args_hash: &hash,
                                args_preview: &preview,
                                notify_channel: channel.as_str(),
                                ttl_secs: self.ttl_secs,
                            })
                            .await?,
                        true,
                    ),
                };
                if created {
                    self.notify(
                        channel,
                        identity.workspace_id,
                        &ApprovalNotice {
                            id,
                            gateway_id: identity.gateway_id,
                            server: server_label.to_string(),
                            tool: tool.clone(),
                            args_hash: hash.clone(),
                            args_preview: preview.clone(),
                            ttl_secs: self.ttl_secs,
                        },
                    )
                    .await;
                }
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

    async fn review_list(&self, message: &McpResponse) -> GatewayResult<McpResponseResult> {
        if message.method != "tools/list" {
            return Ok(pass_response());
        }
        let Some(identity) = identity(message.metadata_context.as_ref()) else {
            return Ok(reject_response("guardrail check failed"));
        };
        let Some(workspace) = self.backend.gateway_workspace(identity.gateway_id).await? else {
            return Ok(reject_response("guardrail check failed"));
        };
        if workspace != identity.workspace_id
            || !self
                .backend
                .token_active(identity.gateway_id, &identity.jti)
                .await?
        {
            return Ok(reject_response("guardrail check failed"));
        }
        let parsed = toolpin::parse_tool_list(&message.mcp_response)
            .ok_or_else(|| GatewayError::message("tool list was rejected"))?;
        let mut sights = Vec::with_capacity(parsed.len());
        for tool in &parsed {
            let attributed = toolpin::attribute_tool(&message.service_names, &tool.name);
            sights.push(ToolSight {
                server: attributed.server,
                tool: attributed.tool.clone(),
                hash: toolpin::pin_hash(&attributed.tool, &tool.description, &tool.input_schema),
                description_preview: toolpin::description_preview(&tool.description),
            });
        }
        let keep = self
            .backend
            .observe_tools(identity.gateway_id, identity.workspace_id, &sights)
            .await?;
        match toolpin::filter_tool_list(&message.mcp_response, &keep)
            .ok_or_else(|| GatewayError::message("tool list was rejected"))?
        {
            toolpin::ToolListFilter::Unchanged => Ok(pass_response()),
            toolpin::ToolListFilter::Replaced(bytes) => Ok(mutated(bytes)),
        }
    }

    async fn workspace_ok(
        &self,
        identity: &Identity,
        server: &str,
        tool: &str,
        arguments: &Value,
    ) -> GatewayResult<bool> {
        let Some(workspace) = self.backend.gateway_workspace(identity.gateway_id).await? else {
            return Ok(false);
        };
        if workspace != identity.workspace_id {
            self.audit(
                identity,
                server,
                tool,
                arguments,
                "deny",
                "workspace did not match",
            )
            .await?;
            eprintln!("fizz-guard: decision=deny tool={tool} server={server}");
            return Ok(false);
        }
        if !self
            .backend
            .token_active(identity.gateway_id, &identity.jti)
            .await?
        {
            self.audit(
                identity,
                server,
                tool,
                arguments,
                "deny",
                "token is not active",
            )
            .await?;
            eprintln!("fizz-guard: decision=deny tool={tool} server={server}");
            return Ok(false);
        }
        Ok(true)
    }

    async fn notify(&self, channel: NotifyChannel, workspace_id: Uuid, notice: &ApprovalNotice) {
        if channel == NotifyChannel::Phone {
            // Stub only. Do not call AgentPhone and do not reserve monthly quota.
            let budget = self.backend.phone_budget(workspace_id).await;
            let attempt = phone_attempt(&budget);
            if let Err(err) = self
                .backend
                .record_phone_attempt(workspace_id, notice.id, attempt.as_str())
                .await
            {
                eprintln!("fizz-guard: phone attempt was not recorded: {err}");
            }
            notify::log_notice(channel, notice, attempt.as_str());
            return;
        }
        let _ = tokio::time::timeout(
            notify::NOTIFY_BUDGET,
            self.notifiers.notify(channel, notice),
        )
        .await;
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
        self.backend
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

fn identity(meta: Option<&prost_types::Struct>) -> Option<Identity> {
    let meta = meta?;
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
    if !toolpin::tool_name_ok(&name) {
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

fn pass_response() -> McpResponseResult {
    McpResponseResult {
        result: Some(mcp_response_result::Result::Pass(Pass {})),
    }
}

fn mutated(bytes: Vec<u8>) -> McpResponseResult {
    McpResponseResult {
        result: Some(mcp_response_result::Result::Mutated(bytes)),
    }
}

fn reject_response(reason: &str) -> McpResponseResult {
    McpResponseResult {
        result: Some(mcp_response_result::Result::Error(AuthorizationError {
            code: authorization_error::Code::PermissionDenied as i32,
            reason: reason.to_string(),
            mcp_error: None,
        })),
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
    let backend = Arc::new(Backend::connect(&url).await?);
    let token = env::var("FIZZ_GUARD_ADMIN_TOKEN").unwrap_or_default();
    if token.is_empty() {
        eprintln!("fizz-guard: admin API disabled");
    } else {
        let admin_listen =
            env::var("FIZZ_GUARD_ADMIN_LISTEN").unwrap_or_else(|_| "127.0.0.1:9002".to_string());
        let admin_addr: SocketAddr = admin_listen
            .parse()
            .map_err(|_| GatewayError::message("admin listen address is not usable"))?;
        let admin_backend = Arc::clone(&backend);
        tokio::spawn(async move {
            if let Err(err) = fizz_gateway::admin::serve(admin_addr, token, admin_backend).await {
                eprintln!("fizz-guard: {err}");
            }
        });
    }
    let service = ExtMcpServer::new(Guard {
        backend,
        notifiers: Notifiers::from_env(),
        ttl_secs: approval_ttl(),
    });
    eprintln!("fizz-guard: listening");
    tonic::transport::Server::builder()
        .add_service(service)
        .serve(addr)
        .await
        .map_err(|_| GatewayError::message("policy server stopped"))?;
    Ok(())
}

fn approval_ttl() -> i64 {
    env::var("FIZZ_APPROVAL_TTL_SECS")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(600)
        .clamp(60, 24 * 60 * 60)
}
