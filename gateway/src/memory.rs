//! Process-local store. `DATABASE_URL=memory://` selects it. Nothing is written
//! to disk, and it starts empty, so tool calls are denied until pins and
//! policies exist. Compose and hosted gateways use Postgres instead.

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, SystemTime};

use uuid::Uuid;

use crate::db::{AuditWrite, NewApproval, PendingApproval, PinAlert, ToolSight};
use crate::error::{GatewayError, GatewayResult};
use crate::notify::PhoneBudget;
use crate::policy::{ApprovalHit, PolicyRule};
use crate::toolpin::{self, PinRecord};

struct GatewayRow {
    workspace_id: Uuid,
    active: bool,
    show_unreviewed: bool,
}

struct ApprovalRow {
    id: Uuid,
    gateway_id: Uuid,
    server: String,
    tool: String,
    args_hash: String,
    args_preview: String,
    status: String,
    expires_at: SystemTime,
}

struct AlertRow {
    gateway_id: Uuid,
    server: String,
    tool: String,
    observed_sha256: String,
    description_preview: String,
    acknowledged: bool,
}

struct PhoneRow {
    status: String,
}

struct State {
    gateways: HashMap<Uuid, GatewayRow>,
    servers: HashMap<(Uuid, String), Uuid>,
    tokens: HashMap<(Uuid, String), SystemTime>,
    policies: HashMap<Uuid, Vec<PolicyRule>>,
    pins: HashMap<(Uuid, String), PinRecord>,
    approvals: Vec<ApprovalRow>,
    alerts: Vec<AlertRow>,
    phones: Vec<PhoneRow>,
    audits: Vec<(String, String)>,
}

pub struct MemoryDb {
    inner: Mutex<State>,
}

impl Default for MemoryDb {
    fn default() -> Self {
        Self::new()
    }
}

impl MemoryDb {
    pub fn new() -> Self {
        Self {
            inner: Mutex::new(State {
                gateways: HashMap::new(),
                servers: HashMap::new(),
                tokens: HashMap::new(),
                policies: HashMap::new(),
                pins: HashMap::new(),
                approvals: Vec::new(),
                alerts: Vec::new(),
                phones: Vec::new(),
                audits: Vec::new(),
            }),
        }
    }

    fn lock(&self) -> GatewayResult<std::sync::MutexGuard<'_, State>> {
        self.inner
            .lock()
            .map_err(|_| GatewayError::message("policy store is unavailable"))
    }

    pub fn insert_gateway(&self, id: Uuid, workspace_id: Uuid, show_unreviewed: bool) {
        if let Ok(mut state) = self.lock() {
            state.gateways.insert(
                id,
                GatewayRow {
                    workspace_id,
                    active: true,
                    show_unreviewed,
                },
            );
        }
    }

    pub fn insert_server(&self, gateway_id: Uuid, name: &str) {
        if let Ok(mut state) = self.lock() {
            state
                .servers
                .insert((gateway_id, name.to_string()), Uuid::new_v4());
        }
    }

    pub fn insert_token(&self, gateway_id: Uuid, jti: &str) {
        if let Ok(mut state) = self.lock() {
            state.tokens.insert(
                (gateway_id, jti.to_string()),
                SystemTime::now() + Duration::from_secs(3600),
            );
        }
    }

    pub fn insert_policy(&self, gateway_id: Uuid, rule: PolicyRule) {
        if let Ok(mut state) = self.lock() {
            state.policies.entry(gateway_id).or_default().push(rule);
        }
    }

    pub async fn gateway_workspace(&self, gateway_id: Uuid) -> GatewayResult<Option<Uuid>> {
        let state = self.lock()?;
        Ok(state
            .gateways
            .get(&gateway_id)
            .filter(|row| row.active)
            .map(|row| row.workspace_id))
    }

    pub async fn token_active(&self, gateway_id: Uuid, jti: &str) -> GatewayResult<bool> {
        let state = self.lock()?;
        Ok(state
            .tokens
            .get(&(gateway_id, jti.to_string()))
            .is_some_and(|expires| *expires > SystemTime::now()))
    }

    pub async fn policies(&self, gateway_id: Uuid) -> GatewayResult<Vec<PolicyRule>> {
        let state = self.lock()?;
        Ok(state.policies.get(&gateway_id).cloned().unwrap_or_default())
    }

    pub async fn approval_hit(
        &self,
        gateway_id: Uuid,
        server: &str,
        tool: &str,
        args_hash: &str,
    ) -> GatewayResult<ApprovalHit> {
        let state = self.lock()?;
        let mut matches = state.approvals.iter().filter(|row| {
            row.gateway_id == gateway_id
                && row.server == server
                && row.tool == tool
                && row.args_hash == args_hash
                && row.expires_at > SystemTime::now()
        });
        if let Some(row) = matches.clone().find(|row| row.status == "approved") {
            return Ok(ApprovalHit::Approved { id: row.id });
        }
        Ok(match matches.find(|row| row.status == "pending") {
            Some(row) => ApprovalHit::Pending { id: row.id },
            None => ApprovalHit::None,
        })
    }

    pub async fn open_approval(&self, approval: &NewApproval<'_>) -> GatewayResult<Uuid> {
        let mut state = self.lock()?;
        let id = Uuid::new_v4();
        let ttl = approval.ttl_secs.clamp(60, 24 * 60 * 60) as u64;
        state.approvals.push(ApprovalRow {
            id,
            gateway_id: approval.gateway_id,
            server: approval.server.to_string(),
            tool: approval.tool.to_string(),
            args_hash: approval.args_hash.to_string(),
            args_preview: approval.args_preview.to_string(),
            status: "pending".to_string(),
            expires_at: SystemTime::now() + Duration::from_secs(ttl),
        });
        Ok(id)
    }

    pub async fn consume_approval(&self, id: Uuid) -> GatewayResult<bool> {
        let mut state = self.lock()?;
        let Some(row) = state.approvals.iter_mut().find(|row| row.id == id) else {
            return Ok(false);
        };
        if row.status == "approved" && row.expires_at > SystemTime::now() {
            row.status = "consumed".to_string();
            Ok(true)
        } else {
            Ok(false)
        }
    }

    pub async fn record_audit(&self, audit: &AuditWrite) -> GatewayResult<()> {
        let mut state = self.lock()?;
        state
            .audits
            .push((audit.tool_name.clone(), audit.decision.to_string()));
        Ok(())
    }

    pub async fn observe_tools(
        &self,
        gateway_id: Uuid,
        _workspace_id: Uuid,
        sights: &[ToolSight],
    ) -> GatewayResult<Vec<bool>> {
        let mut state = self.lock()?;
        let show_unreviewed = state
            .gateways
            .get(&gateway_id)
            .map(|row| row.show_unreviewed)
            .unwrap_or(false);
        let mut keep = Vec::with_capacity(sights.len());
        for sight in sights {
            if !toolpin::tool_name_ok(&sight.tool) {
                keep.push(false);
                continue;
            }
            let Some(server_id) = state
                .servers
                .get(&(gateway_id, sight.server.clone()))
                .copied()
            else {
                keep.push(sight.server.is_empty() && show_unreviewed);
                continue;
            };
            let key = (server_id, sight.tool.clone());
            let existing = state.pins.get(&key).cloned();
            let decision = toolpin::review_pin(existing.as_ref(), &sight.hash, show_unreviewed);
            if decision.alert {
                let open = state.alerts.iter().any(|alert| {
                    !alert.acknowledged
                        && alert.server == sight.server
                        && alert.tool == sight.tool
                        && alert.observed_sha256 == decision.observed_sha256
                });
                if !open {
                    state.alerts.push(AlertRow {
                        gateway_id,
                        server: sight.server.clone(),
                        tool: sight.tool.clone(),
                        observed_sha256: decision.observed_sha256.clone(),
                        description_preview: sight.description_preview.clone(),
                        acknowledged: false,
                    });
                }
            }
            state.pins.insert(
                key,
                PinRecord {
                    pin_sha256: decision.pin_sha256,
                    observed_sha256: decision.observed_sha256,
                    status: decision.status,
                },
            );
            keep.push(decision.show);
        }
        Ok(keep)
    }

    pub async fn pin_record(
        &self,
        gateway_id: Uuid,
        server: &str,
        tool: &str,
    ) -> GatewayResult<Option<PinRecord>> {
        let state = self.lock()?;
        let Some(server_id) = state
            .servers
            .get(&(gateway_id, server.to_string()))
            .copied()
        else {
            return Ok(None);
        };
        Ok(state.pins.get(&(server_id, tool.to_string())).cloned())
    }

    pub async fn phone_budget(&self, _workspace_id: Uuid) -> PhoneBudget {
        // No billing tables live in this process. Callers treat this as the
        // unreachable hook and do not place a call.
        PhoneBudget::unreachable()
    }

    pub async fn record_phone_attempt(
        &self,
        _workspace_id: Uuid,
        approval_id: Uuid,
        status: &str,
    ) -> GatewayResult<()> {
        if !matches!(status, "stubbed" | "skipped") {
            return Err(GatewayError::message("phone attempt was rejected"));
        }
        let mut state = self.lock()?;
        let _ = approval_id;
        state.phones.push(PhoneRow {
            status: status.to_string(),
        });
        Ok(())
    }

    pub async fn list_pending(&self) -> GatewayResult<Vec<PendingApproval>> {
        let state = self.lock()?;
        Ok(state
            .approvals
            .iter()
            .filter(|row| row.status == "pending" && row.expires_at > SystemTime::now())
            .map(|row| PendingApproval {
                id: row.id,
                gateway_id: row.gateway_id,
                server: row.server.clone(),
                tool: row.tool.clone(),
                args_preview: row.args_preview.clone(),
                expires_at: row
                    .expires_at
                    .duration_since(SystemTime::UNIX_EPOCH)
                    .map(|duration| duration.as_secs() as i64)
                    .unwrap_or(0),
            })
            .collect())
    }

    pub async fn decide_approval(&self, id: Uuid, status: &str) -> GatewayResult<bool> {
        if !matches!(status, "approved" | "denied") {
            return Err(GatewayError::message("approval decision was rejected"));
        }
        let mut state = self.lock()?;
        let Some(row) = state.approvals.iter_mut().find(|row| row.id == id) else {
            return Ok(false);
        };
        if row.status == "pending" && row.expires_at > SystemTime::now() {
            row.status = status.to_string();
            Ok(true)
        } else {
            Ok(false)
        }
    }

    pub async fn list_alerts(&self) -> GatewayResult<Vec<PinAlert>> {
        let state = self.lock()?;
        Ok(state
            .alerts
            .iter()
            .filter(|alert| !alert.acknowledged)
            .map(|alert| PinAlert {
                gateway_id: alert.gateway_id,
                server: alert.server.clone(),
                tool: alert.tool.clone(),
                description_preview: alert.description_preview.clone(),
                observed_sha256: alert.observed_sha256.clone(),
            })
            .collect())
    }

    pub async fn reapprove_pin(
        &self,
        gateway_id: Uuid,
        server: &str,
        tool: &str,
    ) -> GatewayResult<bool> {
        let mut state = self.lock()?;
        let Some(server_id) = state
            .servers
            .get(&(gateway_id, server.to_string()))
            .copied()
        else {
            return Ok(false);
        };
        let Some(pin) = state.pins.get_mut(&(server_id, tool.to_string())) else {
            return Ok(false);
        };
        if pin.status == toolpin::PinStatus::Approved {
            return Ok(false);
        }
        pin.pin_sha256 = pin.observed_sha256.clone();
        pin.status = toolpin::PinStatus::Approved;
        for alert in &mut state.alerts {
            if alert.gateway_id == gateway_id && alert.server == server && alert.tool == tool {
                alert.acknowledged = true;
            }
        }
        Ok(true)
    }

    pub fn phone_statuses(&self) -> Vec<String> {
        self.lock()
            .map(|state| state.phones.iter().map(|row| row.status.clone()).collect())
            .unwrap_or_default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::policy::{Effect, NotifyChannel};
    use crate::toolpin::{pin_blocks_call, pin_hash};
    use serde_json::json;

    #[tokio::test]
    async fn approval_is_single_use_and_a_changed_pin_is_hidden() {
        let db = MemoryDb::new();
        let gateway = Uuid::new_v4();
        let workspace = Uuid::new_v4();
        db.insert_gateway(gateway, workspace, false);
        db.insert_server(gateway, "sample");
        db.insert_policy(
            gateway,
            PolicyRule {
                server_name: Some("sample".into()),
                tool_name: "move_funds".into(),
                effect: Effect::Approve,
                notify_channel: NotifyChannel::Phone,
            },
        );
        let schema = json!({"type": "object"});
        let hash = pin_hash("note", "Leave a note.", &schema);
        db.observe_tools(
            gateway,
            workspace,
            &[ToolSight {
                server: "sample".into(),
                tool: "note".into(),
                hash,
                description_preview: "Leave a note.".into(),
            }],
        )
        .await
        .unwrap();
        assert!(db.reapprove_pin(gateway, "sample", "note").await.unwrap());
        let hidden = db
            .observe_tools(
                gateway,
                workspace,
                &[ToolSight {
                    server: "sample".into(),
                    tool: "note".into(),
                    hash: pin_hash("note", "Changed.", &schema),
                    description_preview: "Changed.".into(),
                }],
            )
            .await
            .unwrap();
        assert_eq!(hidden, vec![false]);
        assert!(pin_blocks_call(
            db.pin_record(gateway, "sample", "note")
                .await
                .unwrap()
                .as_ref()
        ));
        assert_eq!(db.list_alerts().await.unwrap().len(), 1);
        assert!(db.reapprove_pin(gateway, "sample", "note").await.unwrap());
        assert!(!pin_blocks_call(
            db.pin_record(gateway, "sample", "note")
                .await
                .unwrap()
                .as_ref()
        ));

        let args = "cd".repeat(32);
        let pending = db
            .open_approval(&NewApproval {
                gateway_id: gateway,
                workspace_id: workspace,
                server: "sample",
                tool: "move_funds",
                args_hash: &args,
                args_preview: "keys:",
                notify_channel: "phone",
                ttl_secs: 600,
            })
            .await
            .unwrap();
        assert!(matches!(
            db.approval_hit(gateway, "sample", "move_funds", &args)
                .await
                .unwrap(),
            ApprovalHit::Pending { id } if id == pending
        ));
        assert!(db.decide_approval(pending, "approved").await.unwrap());
        assert!(db.consume_approval(pending).await.unwrap());
        assert!(!db.consume_approval(pending).await.unwrap());
        assert!(matches!(
            db.approval_hit(gateway, "sample", "move_funds", &args)
                .await
                .unwrap(),
            ApprovalHit::None
        ));
        let budget = db.phone_budget(workspace).await;
        assert!(!budget.reachable);
        assert!(!budget.allowed);
        db.record_phone_attempt(workspace, pending, "skipped")
            .await
            .unwrap();
        assert!(
            db.record_phone_attempt(workspace, pending, "reserved")
                .await
                .is_err()
        );
        assert_eq!(db.phone_statuses(), vec!["skipped".to_string()]);
    }
}
