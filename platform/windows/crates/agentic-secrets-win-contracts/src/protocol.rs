use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use time::OffsetDateTime;
use uuid::Uuid;

pub const PROTOCOL_VERSION: u16 = 1;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum IpcOperation {
    Health,
    CreateDeliveryPlan,
    DeliveryOutcome,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct IpcEnvelope<T> {
    pub protocol_version: u16,
    pub request_id: Uuid,
    pub operation: IpcOperation,
    pub nonce: String,
    #[serde(with = "time::serde::rfc3339")]
    pub timestamp: OffsetDateTime,
    pub payload: T,
}

impl<T> IpcEnvelope<T> {
    pub fn new(operation: IpcOperation, nonce: String, payload: T) -> Self {
        Self {
            protocol_version: PROTOCOL_VERSION,
            request_id: Uuid::new_v4(),
            operation,
            nonce,
            timestamp: OffsetDateTime::now_utc(),
            payload,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct RunnerIdentity {
    pub executable_path: String,
    pub sha256: String,
    pub process_id: Option<u32>,
    pub user_sid: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct TargetIdentity {
    pub executable_path: String,
    pub sha256: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum DeliverySinkKind {
    Environment,
    Stdin,
    NamedPipe,
    TemporaryFile,
    LocalProxyToken,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct SecretBinding {
    pub alias: String,
    pub environment_name: String,
    pub value_digest: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct DeliveryPlanRequest {
    pub profile: String,
    pub target_executable: String,
    pub arguments: Vec<String>,
    pub workspace: String,
    pub action_class: String,
    pub origin_hint: String,
    pub parent_environment_keys: Vec<String>,
    pub runner_identity: RunnerIdentity,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct DeliveryPlan {
    pub plan_id: Uuid,
    pub profile: String,
    pub target: TargetIdentity,
    pub argv: Vec<String>,
    pub sink: DeliverySinkKind,
    pub expires_at_epoch_seconds: i64,
    pub max_uses: u8,
    pub policy_epoch: u64,
    pub decision_digest: String,
    pub action_class: String,
    pub environment: BTreeMap<String, String>,
    pub secret_bindings: Vec<SecretBinding>,
}

impl DeliveryPlan {
    pub fn redacted_for_audit(&self) -> DeliveryPlanAuditView {
        DeliveryPlanAuditView {
            plan_id: self.plan_id,
            profile: self.profile.clone(),
            target_sha256: self.target.sha256.clone(),
            sink: self.sink.clone(),
            policy_epoch: self.policy_epoch,
            decision_digest: self.decision_digest.clone(),
            action_class: self.action_class.clone(),
            aliases: self
                .secret_bindings
                .iter()
                .map(|binding| binding.alias.clone())
                .collect(),
            environment_names: self
                .secret_bindings
                .iter()
                .map(|binding| binding.environment_name.clone())
                .collect(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct DeliveryPlanAuditView {
    pub plan_id: Uuid,
    pub profile: String,
    pub target_sha256: String,
    pub sink: DeliverySinkKind,
    pub policy_epoch: u64,
    pub decision_digest: String,
    pub action_class: String,
    pub aliases: Vec<String>,
    pub environment_names: Vec<String>,
}
