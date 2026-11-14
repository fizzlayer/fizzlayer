//! Postgres for compose and hosted gateways. `memory://` keeps pins and
//! approvals in the process only.

use uuid::Uuid;

use crate::db::{AuditWrite, Db, NewApproval, PendingApproval, PinAlert, ToolSight};
use crate::error::GatewayResult;
use crate::memory::MemoryDb;
use crate::notify::PhoneBudget;
use crate::policy::{ApprovalHit, PolicyRule};
use crate::toolpin::PinRecord;

pub enum Backend {
    Postgres(Db),
    Memory(MemoryDb),
}

impl Backend {
    pub async fn connect(url: &str) -> GatewayResult<Self> {
        if url == "memory://" || url.starts_with("memory://") {
            Ok(Self::Memory(MemoryDb::new()))
        } else {
            Ok(Self::Postgres(Db::connect(url).await?))
        }
    }

    pub async fn gateway_workspace(&self, gateway_id: Uuid) -> GatewayResult<Option<Uuid>> {
        match self {
            Self::Postgres(db) => db.gateway_workspace(gateway_id).await,
            Self::Memory(db) => db.gateway_workspace(gateway_id).await,
        }
    }

    pub async fn token_active(&self, gateway_id: Uuid, jti: &str) -> GatewayResult<bool> {
        match self {
            Self::Postgres(db) => db.token_active(gateway_id, jti).await,
            Self::Memory(db) => db.token_active(gateway_id, jti).await,
        }
    }

    pub async fn policies(&self, gateway_id: Uuid) -> GatewayResult<Vec<PolicyRule>> {
        match self {
            Self::Postgres(db) => db.policies(gateway_id).await,
            Self::Memory(db) => db.policies(gateway_id).await,
        }
    }

    pub async fn approval_hit(
        &self,
        gateway_id: Uuid,
        server: &str,
        tool: &str,
        args_hash: &str,
    ) -> GatewayResult<ApprovalHit> {
        match self {
            Self::Postgres(db) => db.approval_hit(gateway_id, server, tool, args_hash).await,
            Self::Memory(db) => db.approval_hit(gateway_id, server, tool, args_hash).await,
        }
    }

    pub async fn open_approval(&self, approval: &NewApproval<'_>) -> GatewayResult<Uuid> {
        match self {
            Self::Postgres(db) => db.open_approval(approval).await,
            Self::Memory(db) => db.open_approval(approval).await,
        }
    }

    pub async fn consume_approval(&self, id: Uuid) -> GatewayResult<bool> {
        match self {
            Self::Postgres(db) => db.consume_approval(id).await,
            Self::Memory(db) => db.consume_approval(id).await,
        }
    }

    pub async fn record_audit(&self, audit: &AuditWrite) -> GatewayResult<()> {
        match self {
            Self::Postgres(db) => db.record_audit(audit).await,
            Self::Memory(db) => db.record_audit(audit).await,
        }
    }

    pub async fn observe_tools(
        &self,
        gateway_id: Uuid,
        workspace_id: Uuid,
        sights: &[ToolSight],
    ) -> GatewayResult<Vec<bool>> {
        match self {
            Self::Postgres(db) => db.observe_tools(gateway_id, workspace_id, sights).await,
            Self::Memory(db) => db.observe_tools(gateway_id, workspace_id, sights).await,
        }
    }

    pub async fn pin_record(
        &self,
        gateway_id: Uuid,
        server: &str,
        tool: &str,
    ) -> GatewayResult<Option<PinRecord>> {
        match self {
            Self::Postgres(db) => db.pin_record(gateway_id, server, tool).await,
            Self::Memory(db) => db.pin_record(gateway_id, server, tool).await,
        }
    }

    pub async fn phone_budget(&self, workspace_id: Uuid) -> PhoneBudget {
        match self {
            Self::Postgres(db) => db.phone_budget(workspace_id).await,
            Self::Memory(db) => db.phone_budget(workspace_id).await,
        }
    }

    pub async fn record_phone_attempt(
        &self,
        workspace_id: Uuid,
        approval_id: Uuid,
        status: &str,
    ) -> GatewayResult<()> {
        match self {
            Self::Postgres(db) => {
                db.record_phone_attempt(workspace_id, approval_id, status)
                    .await
            }
            Self::Memory(db) => {
                db.record_phone_attempt(workspace_id, approval_id, status)
                    .await
            }
        }
    }

    pub async fn list_pending(&self) -> GatewayResult<Vec<PendingApproval>> {
        match self {
            Self::Postgres(db) => db.list_pending().await,
            Self::Memory(db) => db.list_pending().await,
        }
    }

    pub async fn decide_approval(&self, id: Uuid, status: &str) -> GatewayResult<bool> {
        match self {
            Self::Postgres(db) => db.decide_approval(id, status).await,
            Self::Memory(db) => db.decide_approval(id, status).await,
        }
    }

    pub async fn list_alerts(&self) -> GatewayResult<Vec<PinAlert>> {
        match self {
            Self::Postgres(db) => db.list_alerts().await,
            Self::Memory(db) => db.list_alerts().await,
        }
    }

    pub async fn reapprove_pin(
        &self,
        gateway_id: Uuid,
        server: &str,
        tool: &str,
    ) -> GatewayResult<bool> {
        match self {
            Self::Postgres(db) => db.reapprove_pin(gateway_id, server, tool).await,
            Self::Memory(db) => db.reapprove_pin(gateway_id, server, tool).await,
        }
    }
}
