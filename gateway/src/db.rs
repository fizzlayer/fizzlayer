//! Server-side queries. fizz-guard and fizz-config connect as `gateway_runtime`
//! (or the Supabase service role). Browser roles are not used here.

use std::time::Duration;

use tokio::sync::Mutex;
use tokio_postgres::Client;
use uuid::Uuid;

use crate::config::{GatewaySpec, Mode, ServerSpec, Transport};
use crate::error::{GatewayError, GatewayResult};
use crate::policy::{ApprovalHit, Effect, PolicyRule};

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
                "select s.name as server_name, p.tool_name, p.effect
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
            rules.push(PolicyRule {
                server_name: row.get("server_name"),
                tool_name: row.get("tool_name"),
                effect,
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

    pub async fn open_approval(
        &self,
        gateway_id: Uuid,
        workspace_id: Uuid,
        server: &str,
        tool: &str,
        args_hash: &str,
    ) -> GatewayResult<Uuid> {
        let client = self.client.lock().await;
        let row = client
            .query_one(
                "insert into gateway.approvals
                   (gateway_id, workspace_id, server_name, tool_name, args_hash, status, expires_at)
                 values ($1, $2, $3, $4, $5, 'pending', now() + interval '10 minutes')
                 returning id",
                &[&gateway_id, &workspace_id, &server, &tool, &args_hash],
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
