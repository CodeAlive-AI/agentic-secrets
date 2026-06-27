use crate::protocol::{DeliveryPlan, DeliverySinkKind};
use crate::redaction::{RedactionError, Redactor};
use serde::{Deserialize, Serialize};
use time::OffsetDateTime;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum AuditOutcome {
    Allow,
    Deny,
    Error,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct AuditEvent {
    pub event: String,
    pub decision_digest: String,
    pub subject_id: String,
    pub target_identity: String,
    pub action_class: String,
    pub sink: DeliverySinkKind,
    pub policy_epoch: u64,
    pub approval: String,
    pub outcome: AuditOutcome,
    #[serde(with = "time::serde::rfc3339")]
    pub time: OffsetDateTime,
    pub aliases: Vec<String>,
    pub environment_names: Vec<String>,
}

impl AuditEvent {
    pub fn delivery(
        plan: &DeliveryPlan,
        subject_id: impl Into<String>,
        outcome: AuditOutcome,
    ) -> Self {
        let view = plan.redacted_for_audit();
        Self {
            event: "secret_delivery".to_string(),
            decision_digest: view.decision_digest,
            subject_id: subject_id.into(),
            target_identity: view.target_sha256,
            action_class: view.action_class,
            sink: view.sink,
            policy_epoch: view.policy_epoch,
            approval: "synthetic".to_string(),
            outcome,
            time: OffsetDateTime::now_utc(),
            aliases: view.aliases,
            environment_names: view.environment_names,
        }
    }
}

#[derive(Debug, Default)]
pub struct AuditLog {
    events: Vec<AuditEvent>,
    redactor: Redactor,
}

impl AuditLog {
    pub fn append(
        &mut self,
        event: AuditEvent,
        known_secrets: &[&str],
    ) -> Result<(), RedactionError> {
        let payload =
            serde_json::to_string(&event).map_err(|_| RedactionError::RawSecretDetected)?;
        self.redactor
            .reject_known_secrets(&payload, known_secrets)?;
        self.events.push(event);
        Ok(())
    }

    pub fn events(&self) -> &[AuditEvent] {
        &self.events
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::{DeliveryPlan, SecretBinding, TargetIdentity};
    use std::collections::BTreeMap;
    use uuid::Uuid;

    #[test]
    fn audit_records_aliases_not_values() {
        let plan = DeliveryPlan {
            plan_id: Uuid::nil(),
            profile: "openai".to_string(),
            target: TargetIdentity {
                executable_path: "node.exe".to_string(),
                sha256: "abc".to_string(),
            },
            argv: vec!["node.exe".to_string()],
            sink: DeliverySinkKind::Environment,
            expires_at_epoch_seconds: 1,
            max_uses: 1,
            policy_epoch: 1,
            decision_digest: "digest".to_string(),
            action_class: "read-only".to_string(),
            environment: BTreeMap::from([(
                "OPENAI_API_KEY".to_string(),
                "synthetic-secret-value".to_string(),
            )]),
            secret_bindings: vec![SecretBinding {
                alias: "openai-dev".to_string(),
                environment_name: "OPENAI_API_KEY".to_string(),
                value_digest: "value-digest".to_string(),
            }],
        };

        let event = AuditEvent::delivery(&plan, "runner", AuditOutcome::Allow);
        let encoded = serde_json::to_string(&event).expect("json");
        assert!(encoded.contains("openai-dev"));
        assert!(!encoded.contains("synthetic-secret-value"));
    }
}
