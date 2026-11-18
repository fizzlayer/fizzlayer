//! Server-side queries. fizz-guard and fizz-config connect as `gateway_runtime`
//! (or the Supabase service role). Browser roles are not used here.

use std::time::Duration;

use tokio::sync::Mutex;
use tokio_postgres::Client;
use uuid::Uuid;

use crate::config::{GatewaySpec, Mode, ServerSpec, Transport};
use crate::error::{GatewayError, GatewayResult};
use crate::notify::{self, PhoneBudget};
use crate::policy::{ApprovalHit, Effect, NotifyChannel, PolicyRule};
use crate::toolpin::{self, PinRecord, PinStatus};

pub struct Db {
    client: Mutex<Client>,
}

impl Db {
    pub async fn connect(url: &str) -> GatewayResult<Self> {
        let mut config = url
            .parse::<tokio_postgres::Config>()
            .map_err(|_| GatewayError::message("database connection failed"))?;
        config.connect_timeout(Duration::from_secs(5));
        let mut last = GatewayError::message("database connection failed");
        for attempt in 0..30 {
            match config.connect(tokio_postgres::NoTls).await {
                Ok((client, connection)) => {
                    tokio::spawn(async move {
                        let _ = connection.await;
                    });
                    return Ok(Self {
                        client: Mutex::new(client),
                    });
                }
                Err(err) => {
                    last = GatewayError::database(err);
                    if attempt < 29 {
                        tokio::time::sleep(Duration::from_secs(1)).await;
                    }
                }
            }
        }
        Err(last)
    }

    pub async fn load_gateway(
        &self,
        gateway_id: Option<Uuid>,
        guard_host: &str,
        jwks_file: &str,
    ) -> GatewayResult<GatewaySpec> {
        let client = self.client.lock().await;
        let rows = match gateway_id {
            Some(id) => {
                client
                    .query(
                        "select id, workspace_id, mode, public_url, listen_port, config_revision, ag_version
                         from gateway.gateways where id = $1 and status = 'active'",
                        &[&id],
                    )
                    .await
            }
            None => {
                client
                    .query(
                        "select id, workspace_id, mode, public_url, listen_port, config_revision, ag_version
                         from gateway.gateways where status = 'active' order by created_at",
                        &[],
                    )
                    .await
            }
        }
        .map_err(GatewayError::database)?;
        if rows.len() != 1 {
            return Err(GatewayError::message(
                "expected exactly one active gateway; pass --gateway when there are several",
            ));
        }
        let row = &rows[0];
        let id: Uuid = row.get("id");
        let mode = Mode::parse(row.get("mode"))
            .ok_or_else(|| GatewayError::message("gateway mode is not usable"))?;
        let listen_port: i32 = row.get("listen_port");
        let listen_port = u16::try_from(listen_port)
            .map_err(|_| GatewayError::message("gateway listen port is not usable"))?;
        let server_rows = client
            .query(
                "select name, transport, url_or_cmd, command_args, auth_kind
                 from gateway.servers where gateway_id = $1 and enabled order by name",
                &[&id],
            )
            .await
            .map_err(GatewayError::database)?;
        let mut servers = Vec::with_capacity(server_rows.len());
        for server in server_rows {
            let transport = Transport::parse(server.get("transport"))
                .ok_or_else(|| GatewayError::message("server transport is not usable"))?;
            servers.push(ServerSpec {
                name: server.get("name"),
                transport,
                url_or_cmd: server.get("url_or_cmd"),
                command_args: server.get("command_args"),
                auth_kind: server.get("auth_kind"),
                credential: None,
            });
        }
        Ok(GatewaySpec {
            gateway_id: id,
            workspace_id: row.get("workspace_id"),
            mode,
            public_url: row.get("public_url"),
            listen_port,
            config_revision: row.get("config_revision"),
            ag_version: row.get("ag_version"),
            guard_host: guard_host.to_string(),
            jwks_file: jwks_file.to_string(),
            jwks_url: None,
            credential_mode: crate::config::CredentialMode::Refuse,
            servers,
        })
    }

    pub async fn gateway_workspace(&self, gateway_id: Uuid) -> GatewayResult<Option<Uuid>> {
        let client = self.client.lock().await;
        let row = client
            .query_opt(
                "select workspace_id from gateway.gateways where id = $1 and status = 'active'",
                &[&gateway_id],
            )
            .await
            .map_err(GatewayError::database)?;
        Ok(row.map(|row| row.get("workspace_id")))
    }

    pub async fn token_active(&self, gateway_id: Uuid, jti: &str) -> GatewayResult<bool> {
        let client = self.client.lock().await;
        let row = client
            .query_opt(
                "select (revoked_at is null and expires_at > now()) as active
                 from gateway.client_tokens where gateway_id = $1 and jti = $2",
                &[&gateway_id, &jti],
            )
            .await
            .map_err(GatewayError::database)?;
        Ok(row.and_then(|row| row.get("active")).unwrap_or(false))
    }

    pub async fn policies(&self, gateway_id: Uuid) -> GatewayResult<Vec<PolicyRule>> {
        let client = self.client.lock().await;
        let rows = client
            .query(
                "select s.name as server_name, p.tool_name, p.effect, p.notify_channel
                 from gateway.policies p
                 left join gateway.servers s on s.id = p.server_id
                 where p.gateway_id = $1",
                &[&gateway_id],
            )
            .await
            .map_err(GatewayError::database)?;
        let mut rules = Vec::with_capacity(rows.len());
        for row in rows {
            let effect = Effect::parse(row.get("effect"))
                .ok_or_else(|| GatewayError::message("policy effect is not usable"))?;
            let notify_channel = NotifyChannel::parse(row.get("notify_channel"))
                .ok_or_else(|| GatewayError::message("policy channel is not usable"))?;
            rules.push(PolicyRule {
                server_name: row.get("server_name"),
                tool_name: row.get("tool_name"),
                effect,
                notify_channel,
            });
        }
        Ok(rules)
    }

    pub async fn approval_hit(
        &self,
        gateway_id: Uuid,
        server: &str,
        tool: &str,
        args_hash: &str,
    ) -> GatewayResult<ApprovalHit> {
        let client = self.client.lock().await;
        let approved = client
            .query_opt(
                "select id from gateway.approvals
                 where gateway_id = $1 and server_name = $2 and tool_name = $3 and args_hash = $4
                   and status = 'approved' and expires_at > now()
                 order by created_at limit 1",
                &[&gateway_id, &server, &tool, &args_hash],
            )
            .await
            .map_err(GatewayError::database)?;
        if let Some(row) = approved {
            return Ok(ApprovalHit::Approved { id: row.get("id") });
        }
        let pending = client
            .query_opt(
                "select id from gateway.approvals
                 where gateway_id = $1 and server_name = $2 and tool_name = $3 and args_hash = $4
                   and status = 'pending' and expires_at > now()
                 order by created_at limit 1",
                &[&gateway_id, &server, &tool, &args_hash],
            )
            .await
            .map_err(GatewayError::database)?;
        Ok(match pending {
            Some(row) => ApprovalHit::Pending { id: row.get("id") },
            None => ApprovalHit::None,
        })
    }

    pub async fn open_approval(&self, approval: &NewApproval<'_>) -> GatewayResult<Uuid> {
        let client = self.client.lock().await;
        let ttl = approval.ttl_secs.clamp(60, 24 * 60 * 60) as f64;
        let row = client
            .query_one(
                "insert into gateway.approvals
                   (gateway_id, workspace_id, server_name, tool_name, args_hash, args_preview,
                    notify_channel, status, expires_at)
                 values ($1, $2, $3, $4, $5, $6, $7, 'pending', now() + ($8 * interval '1 second'))
                 returning id",
                &[
                    &approval.gateway_id,
                    &approval.workspace_id,
                    &approval.server,
                    &approval.tool,
                    &approval.args_hash,
                    &approval.args_preview,
                    &approval.notify_channel,
                    &ttl,
                ],
            )
            .await
            .map_err(GatewayError::database)?;
        Ok(row.get("id"))
    }

    pub async fn consume_approval(&self, id: Uuid) -> GatewayResult<bool> {
        let client = self.client.lock().await;
        let updated = client
            .execute(
                "update gateway.approvals set status = 'consumed'
                 where id = $1 and status = 'approved' and expires_at > now()",
                &[&id],
            )
            .await
            .map_err(GatewayError::database)?;
        Ok(updated == 1)
    }

    pub async fn record_audit(&self, audit: &AuditWrite) -> GatewayResult<()> {
        let mut client = self.client.lock().await;
        let transaction = client.transaction().await.map_err(GatewayError::database)?;
        transaction
            .execute(
                "insert into gateway.audit_log
                   (gateway_id, workspace_id, server_name, tool_name, subject, jti, args_hash, args_preview, decision, reason)
                 values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)",
                &[
                    &audit.gateway_id,
                    &audit.workspace_id,
                    &audit.server_name,
                    &audit.tool_name,
                    &audit.subject,
                    &audit.jti,
                    &audit.args_hash,
                    &audit.args_preview,
                    &audit.decision,
                    &audit.reason,
                ],
            )
            .await
            .map_err(GatewayError::database)?;
        let approvals: i32 = if audit.decision == "approval_required" {
            1
        } else {
            0
        };
        transaction
            .execute(
                "insert into gateway.usage_daily (gateway_id, usage_date, tool_calls, approvals)
                 values ($1, (timezone('utc', now()))::date, 1, $2)
                 on conflict (gateway_id, usage_date) do update
                 set tool_calls = gateway.usage_daily.tool_calls + 1,
                     approvals = gateway.usage_daily.approvals + excluded.approvals",
                &[&audit.gateway_id, &approvals],
            )
            .await
            .map_err(GatewayError::database)?;
        transaction.commit().await.map_err(GatewayError::database)?;
        Ok(())
    }

    pub async fn insert_token(
        &self,
        gateway_id: Uuid,
        user_id: Uuid,
        name: &str,
        jti: Uuid,
        ttl_secs: u64,
    ) -> GatewayResult<()> {
        let client = self.client.lock().await;
        let ttl = ttl_secs.min(60 * 60 * 24 * 30) as f64;
        client
            .execute(
                "insert into gateway.client_tokens (gateway_id, user_id, name, jti, expires_at)
                 values ($1, $2, $3, $4, now() + ($5 * interval '1 second'))",
                &[&gateway_id, &user_id, &name, &jti.to_string(), &ttl],
            )
            .await
            .map_err(GatewayError::database)?;
        Ok(())
    }

    pub async fn user_for_gateway(&self, gateway_id: Uuid) -> GatewayResult<(Uuid, Uuid, String)> {
        let client = self.client.lock().await;
        let row = client
            .query_one(
                "select workspace_id, user_id, public_url from gateway.client_subject($1)",
                &[&gateway_id],
            )
            .await
            .map_err(GatewayError::database)?;
        Ok((
            row.get("workspace_id"),
            row.get("user_id"),
            row.get("public_url"),
        ))
    }

    pub async fn audit_decisions(&self, gateway_id: Uuid) -> GatewayResult<Vec<(String, String)>> {
        let client = self.client.lock().await;
        let rows = client
            .query(
                "select tool_name, decision from gateway.audit_log
                 where gateway_id = $1 order by created_at",
                &[&gateway_id],
            )
            .await
            .map_err(GatewayError::database)?;
        Ok(rows
            .into_iter()
            .map(|row| (row.get("tool_name"), row.get("decision")))
            .collect())
    }

    pub async fn approval_status(
        &self,
        gateway_id: Uuid,
        tool: &str,
    ) -> GatewayResult<Option<String>> {
        let client = self.client.lock().await;
        let row = client
            .query_opt(
                "select status from gateway.approvals
                 where gateway_id = $1 and tool_name = $2
                 order by created_at desc limit 1",
                &[&gateway_id, &tool],
            )
            .await
            .map_err(GatewayError::database)?;
        Ok(row.map(|row| row.get("status")))
    }

    pub async fn latest_approval(
        &self,
        gateway_id: Uuid,
        tool: &str,
    ) -> GatewayResult<Option<(Uuid, String)>> {
        let client = self.client.lock().await;
        let row = client
            .query_opt(
                "select id, status from gateway.approvals
                 where gateway_id = $1 and tool_name = $2
                 order by created_at desc limit 1",
                &[&gateway_id, &tool],
            )
            .await
            .map_err(GatewayError::database)?;
        Ok(row.map(|row| (row.get("id"), row.get("status"))))
    }

    pub async fn observe_tools(
        &self,
        gateway_id: Uuid,
        workspace_id: Uuid,
        sights: &[ToolSight],
    ) -> GatewayResult<Vec<bool>> {
        let mut client = self.client.lock().await;
        let transaction = client.transaction().await.map_err(GatewayError::database)?;
        let show_unreviewed = transaction
            .query_one(
                "select unreviewed_tools = 'show' as show
                 from gateway.gateways where id = $1",
                &[&gateway_id],
            )
            .await
            .map_err(GatewayError::database)?
            .get("show");
        let mut keep = Vec::with_capacity(sights.len());
        for sight in sights {
            keep.push(
                apply_sight(
                    &transaction,
                    gateway_id,
                    workspace_id,
                    sight,
                    show_unreviewed,
                )
                .await?,
            );
        }
        transaction.commit().await.map_err(GatewayError::database)?;
        Ok(keep)
    }

    pub async fn pin_record(
        &self,
        gateway_id: Uuid,
        server: &str,
        tool: &str,
    ) -> GatewayResult<Option<PinRecord>> {
        let client = self.client.lock().await;
        let row = client
            .query_opt(
                "select p.pin_sha256, p.observed_sha256, p.status
                 from gateway.tool_pins p
                 join gateway.servers s on s.id = p.server_id
                 where s.gateway_id = $1 and s.name = $2 and p.tool_name = $3",
                &[&gateway_id, &server, &tool],
            )
            .await
            .map_err(GatewayError::database)?;
        match row {
            None => Ok(None),
            Some(row) => Ok(Some(pin_from_row(&row)?)),
        }
    }

    pub async fn phone_budget(&self, workspace_id: Uuid) -> PhoneBudget {
        let client = self.client.lock().await;
        let row = match client
            .query_one(
                "select gateway.phone_approval_budget($1)::text as budget",
                &[&workspace_id],
            )
            .await
        {
            Ok(row) => row,
            Err(err) => {
                eprintln!(
                    "fizz-guard: phone budget unavailable: {}",
                    GatewayError::database(err)
                );
                return PhoneBudget::unreachable();
            }
        };
        let text: String = row.get("budget");
        match serde_json::from_str(&text) {
            Ok(value) => notify::budget_from_json(&value),
            Err(_) => PhoneBudget::unreachable(),
        }
    }

    pub async fn record_phone_attempt(
        &self,
        workspace_id: Uuid,
        approval_id: Uuid,
        status: &str,
    ) -> GatewayResult<()> {
        if !matches!(status, "stubbed" | "skipped") {
            return Err(GatewayError::message("phone attempt was rejected"));
        }
        let client = self.client.lock().await;
        client
            .execute(
                "insert into gateway.phone_calls (workspace_id, approval_id, status)
                 values ($1, $2, $3)",
                &[&workspace_id, &approval_id, &status],
            )
            .await
            .map_err(GatewayError::database)?;
        Ok(())
    }

    pub async fn list_pending(&self) -> GatewayResult<Vec<PendingApproval>> {
        let client = self.client.lock().await;
        let rows = client
            .query(
                "select id, gateway_id, server_name, tool_name, args_preview,
                        extract(epoch from expires_at)::bigint as expires_at
                 from gateway.approvals
                 where status = 'pending' and expires_at > now()
                 order by created_at",
                &[],
            )
            .await
            .map_err(GatewayError::database)?;
        Ok(rows
            .into_iter()
            .map(|row| PendingApproval {
                id: row.get("id"),
                gateway_id: row.get("gateway_id"),
                server: row.get("server_name"),
                tool: row.get("tool_name"),
                args_preview: row.get("args_preview"),
                expires_at: row.get("expires_at"),
            })
            .collect())
    }

    pub async fn decide_approval(&self, id: Uuid, status: &str) -> GatewayResult<bool> {
        if !matches!(status, "approved" | "denied") {
            return Err(GatewayError::message("approval decision was rejected"));
        }
        let client = self.client.lock().await;
        let updated = client
            .execute(
                "update gateway.approvals set status = $2
                 where id = $1 and status = 'pending' and expires_at > now()",
                &[&id, &status],
            )
            .await
            .map_err(GatewayError::database)?;
        Ok(updated == 1)
    }

    pub async fn list_alerts(&self) -> GatewayResult<Vec<PinAlert>> {
        let client = self.client.lock().await;
        let rows = client
            .query(
                "select s.gateway_id, s.name as server_name, a.tool_name, a.description_preview,
                        a.observed_sha256
                 from gateway.pin_alerts a
                 join gateway.servers s on s.id = a.server_id
                 where a.acknowledged_at is null
                 order by a.created_at",
                &[],
            )
            .await
            .map_err(GatewayError::database)?;
        Ok(rows
            .into_iter()
            .map(|row| PinAlert {
                gateway_id: row.get("gateway_id"),
                server: row.get("server_name"),
                tool: row.get("tool_name"),
                description_preview: row.get("description_preview"),
                observed_sha256: row.get("observed_sha256"),
            })
            .collect())
    }

    pub async fn reapprove_pin(
        &self,
        gateway_id: Uuid,
        server: &str,
        tool: &str,
    ) -> GatewayResult<bool> {
        if !toolpin::tool_name_ok(tool) {
            return Err(GatewayError::message("pin was rejected"));
        }
        let mut client = self.client.lock().await;
        let transaction = client.transaction().await.map_err(GatewayError::database)?;
        let updated = transaction
            .execute(
                "update gateway.tool_pins p
                 set pin_sha256 = p.observed_sha256,
                     status = 'approved',
                     approved_at = now()
                 from gateway.servers s
                 where p.server_id = s.id and s.gateway_id = $1 and s.name = $2
                   and p.tool_name = $3 and p.status in ('changed', 'unreviewed')",
                &[&gateway_id, &server, &tool],
            )
            .await
            .map_err(GatewayError::database)?;
        if updated != 1 {
            return Ok(false);
        }
        transaction
            .execute(
                "update gateway.pin_alerts a
                 set acknowledged_at = now()
                 from gateway.servers s
                 where a.server_id = s.id and s.gateway_id = $1 and s.name = $2
                   and a.tool_name = $3 and a.acknowledged_at is null",
                &[&gateway_id, &server, &tool],
            )
            .await
            .map_err(GatewayError::database)?;
        transaction.commit().await.map_err(GatewayError::database)?;
        Ok(true)
    }

    pub async fn open_pin_alert(
        &self,
        gateway_id: Uuid,
        tool: &str,
    ) -> GatewayResult<Option<String>> {
        let client = self.client.lock().await;
        let row = client
            .query_opt(
                "select a.kind
                 from gateway.pin_alerts a
                 join gateway.servers s on s.id = a.server_id
                 where s.gateway_id = $1 and a.tool_name = $2 and a.acknowledged_at is null
                 order by a.created_at desc limit 1",
                &[&gateway_id, &tool],
            )
            .await
            .map_err(GatewayError::database)?;
        Ok(row.map(|row| row.get("kind")))
    }

    pub async fn phone_status_for_tool(
        &self,
        gateway_id: Uuid,
        tool: &str,
    ) -> GatewayResult<Option<String>> {
        let client = self.client.lock().await;
        let row = client
            .query_opt(
                "select c.status
                 from gateway.phone_calls c
                 join gateway.approvals a on a.id = c.approval_id
                 where a.gateway_id = $1 and a.tool_name = $2
                 order by c.created_at desc limit 1",
                &[&gateway_id, &tool],
            )
            .await
            .map_err(GatewayError::database)?;
        Ok(row.map(|row| row.get("status")))
    }
}

async fn apply_sight(
    transaction: &tokio_postgres::Transaction<'_>,
    gateway_id: Uuid,
    workspace_id: Uuid,
    sight: &ToolSight,
    show_unreviewed: bool,
) -> GatewayResult<bool> {
    if !toolpin::tool_name_ok(&sight.tool) || !hash_ok(&sight.hash) {
        return Ok(false);
    }
    if sight.server.is_empty() {
        return Ok(show_unreviewed);
    }
    let row = transaction
        .query_opt(
            "select p.pin_sha256, p.observed_sha256, p.status
             from gateway.tool_pins p
             join gateway.servers s on s.id = p.server_id
             where s.gateway_id = $1 and s.name = $2 and p.tool_name = $3",
            &[&gateway_id, &sight.server, &sight.tool],
        )
        .await
        .map_err(GatewayError::database)?;
    let existing = match &row {
        None => None,
        Some(row) => Some(pin_from_row(row)?),
    };
    let decision = toolpin::review_pin(existing.as_ref(), &sight.hash, show_unreviewed);
    let status = decision.status.as_str();
    if existing.is_none() {
        let inserted = transaction
            .execute(
                "insert into gateway.tool_pins
                   (server_id, tool_name, pin_sha256, observed_sha256, status, approved_at)
                 select s.id, $3, $4, $5, $6, null
                 from gateway.servers s
                 where s.gateway_id = $1 and s.name = $2",
                &[
                    &gateway_id,
                    &sight.server,
                    &sight.tool,
                    &decision.pin_sha256,
                    &decision.observed_sha256,
                    &status,
                ],
            )
            .await
            .map_err(GatewayError::database)?;
        if inserted != 1 {
            return Ok(false);
        }
    } else {
        let updated = transaction
            .execute(
                "update gateway.tool_pins p
                 set pin_sha256 = $4,
                     observed_sha256 = $5,
                     status = $6,
                     approved_at = case
                       when $6 = 'unreviewed' then null
                       when p.approved_at is null then now()
                       else p.approved_at
                     end
                 from gateway.servers s
                 where p.server_id = s.id and s.gateway_id = $1 and s.name = $2
                   and p.tool_name = $3",
                &[
                    &gateway_id,
                    &sight.server,
                    &sight.tool,
                    &decision.pin_sha256,
                    &decision.observed_sha256,
                    &status,
                ],
            )
            .await
            .map_err(GatewayError::database)?;
        if updated != 1 {
            return Ok(false);
        }
    }
    if decision.alert {
        transaction
            .execute(
                "insert into gateway.pin_alerts
                   (gateway_id, workspace_id, server_id, tool_name, approved_sha256,
                    observed_sha256, description_preview, kind)
                 select $1, $2, s.id, $3, $4, $5, $6, 'changed'
                 from gateway.servers s
                 where s.gateway_id = $1 and s.name = $7
                   and not exists (
                     select 1 from gateway.pin_alerts a
                     where a.server_id = s.id and a.tool_name = $3
                       and a.observed_sha256 = $5 and a.acknowledged_at is null
                   )",
                &[
                    &gateway_id,
                    &workspace_id,
                    &sight.tool,
                    &decision.pin_sha256,
                    &decision.observed_sha256,
                    &sight.description_preview,
                    &sight.server,
                ],
            )
            .await
            .map_err(GatewayError::database)?;
    }
    Ok(decision.show)
}

fn pin_from_row(row: &tokio_postgres::Row) -> GatewayResult<PinRecord> {
    let status = PinStatus::parse(row.get("status"))
        .ok_or_else(|| GatewayError::message("pin status is not usable"))?;
    Ok(PinRecord {
        pin_sha256: row.get("pin_sha256"),
        observed_sha256: row.get("observed_sha256"),
        status,
    })
}

fn hash_ok(value: &str) -> bool {
    value.len() == 64
        && value
            .chars()
            .all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase())
}

pub struct NewApproval<'a> {
    pub gateway_id: Uuid,
    pub workspace_id: Uuid,
    pub server: &'a str,
    pub tool: &'a str,
    pub args_hash: &'a str,
    pub args_preview: &'a str,
    pub notify_channel: &'a str,
    pub ttl_secs: i64,
}

pub struct ToolSight {
    pub server: String,
    pub tool: String,
    pub hash: String,
    pub description_preview: String,
}

pub struct PendingApproval {
    pub id: Uuid,
    pub gateway_id: Uuid,
    pub server: String,
    pub tool: String,
    pub args_preview: String,
    pub expires_at: i64,
}

pub struct PinAlert {
    pub gateway_id: Uuid,
    pub server: String,
    pub tool: String,
    pub description_preview: String,
    pub observed_sha256: String,
}

pub struct AuditWrite {
    pub gateway_id: Uuid,
    pub workspace_id: Uuid,
    pub server_name: String,
    pub tool_name: String,
    pub subject: String,
    pub jti: String,
    pub args_hash: String,
    pub args_preview: String,
    pub decision: &'static str,
    pub reason: String,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::toolpin::{pin_blocks_call, pin_hash};
    use serde_json::json;

    /// Runs only when FIZZ_TEST_DATABASE_URL points at a database that already
    /// has the local compose seed. CI covers the same path through compose.
    #[tokio::test]
    async fn postgres_round_trip_when_configured() {
        let Ok(url) = std::env::var("FIZZ_TEST_DATABASE_URL") else {
            return;
        };
        let db = Db::connect(&url).await.expect("connect");
        let gateway = Uuid::parse_str("22222222-2222-4222-8222-222222222222").unwrap();
        let workspace = Uuid::parse_str("11111111-1111-4111-8111-111111111111").unwrap();
        let schema = json!({"type": "object", "properties": {}});
        let tool = format!("t{}", &Uuid::new_v4().simple().to_string()[..12]);
        let shown = db
            .observe_tools(
                gateway,
                workspace,
                &[ToolSight {
                    server: "sample".into(),
                    tool: tool.clone(),
                    hash: pin_hash("extra", "First.", &schema),
                    description_preview: "First.".into(),
                }],
            )
            .await
            .unwrap();
        assert_eq!(shown, vec![true]);
        assert!(db.reapprove_pin(gateway, "sample", &tool).await.unwrap());
        let hidden = db
            .observe_tools(
                gateway,
                workspace,
                &[ToolSight {
                    server: "sample".into(),
                    tool: tool.clone(),
                    hash: pin_hash("extra", "Changed.", &schema),
                    description_preview: "Changed.".into(),
                }],
            )
            .await
            .unwrap();
        assert_eq!(hidden, vec![false]);
        assert!(pin_blocks_call(
            db.pin_record(gateway, "sample", &tool)
                .await
                .unwrap()
                .as_ref()
        ));
        assert_eq!(
            db.open_pin_alert(gateway, &tool).await.unwrap().as_deref(),
            Some("changed")
        );
        let approval = db
            .open_approval(&NewApproval {
                gateway_id: gateway,
                workspace_id: workspace,
                server: "sample",
                tool: "move_funds",
                args_hash: &"ab".repeat(32),
                args_preview: "keys:",
                notify_channel: "phone",
                ttl_secs: 600,
            })
            .await
            .unwrap();
        assert!(db.decide_approval(approval, "approved").await.unwrap());
        assert!(db.consume_approval(approval).await.unwrap());
        assert!(!db.consume_approval(approval).await.unwrap());
        let budget = db.phone_budget(workspace).await;
        assert!(!budget.allowed);
        assert!(!budget.reachable);
        db.record_phone_attempt(workspace, approval, "skipped")
            .await
            .unwrap();
        assert!(
            db.record_phone_attempt(workspace, approval, "reserved")
                .await
                .is_err()
        );
        assert_eq!(
            db.phone_status_for_tool(gateway, "move_funds")
                .await
                .unwrap()
                .as_deref(),
            Some("skipped")
        );
    }
}
