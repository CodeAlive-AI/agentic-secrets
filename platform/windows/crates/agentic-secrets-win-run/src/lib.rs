use agentic_secrets_win_contracts::{
    DeliveryPlan, DeliveryPlanRequest, DeliverySinkKind, EnvironmentBlock, EnvironmentBuilder,
    IpcEnvelope, IpcOperation,
};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, HashMap};
use std::fs;
use std::io::{Read, Write};
use thiserror::Error;
use time::OffsetDateTime;

#[cfg(windows)]
pub mod process;

#[derive(Debug, Error)]
pub enum RunnerError {
    #[error("delivery plan has expired")]
    ExpiredPlan,
    #[error("delivery plan is not one-use")]
    NotOneUse,
    #[error("delivery plan uses unsupported sink")]
    UnsupportedSink,
    #[error("delivery plan is missing a value for {0}")]
    MissingBindingValue(String),
    #[error("target executable identity changed before launch")]
    TargetIdentityChanged,
    #[error("target executable read failed: {0}")]
    TargetRead(String),
    #[error("environment failed: {0}")]
    Environment(#[from] agentic_secrets_win_contracts::EnvironmentBlockError),
    #[error("process launch is only supported on Windows")]
    UnsupportedPlatform,
    #[error("process launch failed: {0}")]
    Process(String),
    #[error("broker IPC failed: {0}")]
    BrokerIpc(String),
}

pub fn build_child_environment(
    plan: &DeliveryPlan,
    parent: &HashMap<String, String>,
) -> Result<EnvironmentBlock, RunnerError> {
    validate_delivery_plan_shape(plan)?;
    let injected = injected_environment(plan)?;
    Ok(EnvironmentBuilder::default().build(parent, injected)?)
}

pub fn validate_delivery_plan(plan: &DeliveryPlan, now: OffsetDateTime) -> Result<(), RunnerError> {
    validate_delivery_plan_shape(plan)?;
    if plan.expires_at_epoch_seconds <= now.unix_timestamp() {
        return Err(RunnerError::ExpiredPlan);
    }
    Ok(())
}

pub fn verify_target_identity(plan: &DeliveryPlan) -> Result<(), RunnerError> {
    let bytes = fs::read(&plan.target.executable_path)
        .map_err(|error| RunnerError::TargetRead(error.to_string()))?;
    let observed = hex::encode(Sha256::digest(bytes));
    if observed == plan.target.sha256 {
        Ok(())
    } else {
        Err(RunnerError::TargetIdentityChanged)
    }
}

pub fn request_plan_from_broker(
    broker_pipe: &str,
    request: DeliveryPlanRequest,
) -> Result<DeliveryPlan, RunnerError> {
    let envelope = IpcEnvelope::new(
        IpcOperation::CreateDeliveryPlan,
        uuid::Uuid::new_v4().to_string(),
        request,
    );
    let mut pipe = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(broker_pipe)
        .map_err(|error| RunnerError::BrokerIpc(error.to_string()))?;
    let payload =
        serde_json::to_vec(&envelope).map_err(|error| RunnerError::BrokerIpc(error.to_string()))?;
    pipe.write_all(&payload)
        .map_err(|error| RunnerError::BrokerIpc(error.to_string()))?;
    pipe.write_all(b"\n")
        .map_err(|error| RunnerError::BrokerIpc(error.to_string()))?;
    let mut response = Vec::new();
    pipe.read_to_end(&mut response)
        .map_err(|error| RunnerError::BrokerIpc(error.to_string()))?;
    serde_json::from_slice(&response).map_err(|error| RunnerError::BrokerIpc(error.to_string()))
}

fn validate_delivery_plan_shape(plan: &DeliveryPlan) -> Result<(), RunnerError> {
    if plan.max_uses != 1 {
        return Err(RunnerError::NotOneUse);
    }
    if plan.sink != DeliverySinkKind::Environment {
        return Err(RunnerError::UnsupportedSink);
    }
    for binding in &plan.secret_bindings {
        if !plan.environment.contains_key(&binding.environment_name) {
            return Err(RunnerError::MissingBindingValue(
                binding.environment_name.clone(),
            ));
        }
    }
    Ok(())
}

fn injected_environment(plan: &DeliveryPlan) -> Result<BTreeMap<String, String>, RunnerError> {
    plan.secret_bindings
        .iter()
        .map(|binding| {
            let value = plan
                .environment
                .get(&binding.environment_name)
                .cloned()
                .ok_or_else(|| {
                    RunnerError::MissingBindingValue(binding.environment_name.clone())
                })?;
            Ok((binding.environment_name.clone(), value))
        })
        .collect()
}

#[cfg(not(windows))]
pub fn launch_plan(_plan: &DeliveryPlan) -> Result<i32, RunnerError> {
    Err(RunnerError::UnsupportedPlatform)
}

#[cfg(windows)]
pub fn launch_plan(plan: &DeliveryPlan) -> Result<i32, RunnerError> {
    validate_delivery_plan(plan, OffsetDateTime::now_utc())?;
    verify_target_identity(plan)?;
    process::launch_with_create_process(plan)
        .map_err(|error| RunnerError::Process(error.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use agentic_secrets_win_contracts::{DeliverySinkKind, SecretBinding, TargetIdentity};
    use uuid::Uuid;

    #[test]
    fn runner_fails_closed_on_ambient_secret_collision() {
        let plan = DeliveryPlan {
            plan_id: Uuid::nil(),
            profile: "synthetic".to_string(),
            target: TargetIdentity {
                executable_path: "cmd.exe".to_string(),
                sha256: "abc".to_string(),
            },
            argv: vec!["cmd.exe".to_string()],
            sink: DeliverySinkKind::Environment,
            expires_at_epoch_seconds: 9_999_999_999,
            max_uses: 1,
            policy_epoch: 1,
            decision_digest: "digest".to_string(),
            action_class: "read-only".to_string(),
            environment: BTreeMap::from([("OPENAI_API_KEY".to_string(), "synthetic".to_string())]),
            secret_bindings: vec![SecretBinding {
                alias: "openai".to_string(),
                environment_name: "OPENAI_API_KEY".to_string(),
                value_digest: "digest".to_string(),
            }],
        };
        let parent = HashMap::from([("openai_api_key".to_string(), "ambient".to_string())]);

        assert!(matches!(
            build_child_environment(&plan, &parent),
            Err(RunnerError::Environment(
                agentic_secrets_win_contracts::EnvironmentBlockError::Collision(_)
            ))
        ));
    }

    #[test]
    fn expired_plan_fails_closed() {
        let mut plan = test_plan();
        plan.expires_at_epoch_seconds = 1;

        assert!(matches!(
            validate_delivery_plan(&plan, OffsetDateTime::from_unix_timestamp(2).expect("time")),
            Err(RunnerError::ExpiredPlan)
        ));
    }

    #[test]
    fn missing_binding_value_fails_closed() {
        let mut plan = test_plan();
        plan.environment.clear();
        let parent = HashMap::new();

        assert!(matches!(
            build_child_environment(&plan, &parent),
            Err(RunnerError::MissingBindingValue(_))
        ));
    }

    #[test]
    fn target_identity_change_fails_closed() {
        let path =
            std::env::temp_dir().join(format!("agentic-secrets-target-{}", std::process::id()));
        fs::write(&path, b"before").expect("write before");
        let mut plan = test_plan();
        plan.target.executable_path = path.to_string_lossy().to_string();
        plan.target.sha256 = hex::encode(Sha256::digest(b"before"));
        fs::write(&path, b"after").expect("write after");

        assert!(matches!(
            verify_target_identity(&plan),
            Err(RunnerError::TargetIdentityChanged)
        ));
        let _ = fs::remove_file(path);
    }

    fn test_plan() -> DeliveryPlan {
        DeliveryPlan {
            plan_id: Uuid::nil(),
            profile: "synthetic".to_string(),
            target: TargetIdentity {
                executable_path: "cmd.exe".to_string(),
                sha256: "abc".to_string(),
            },
            argv: vec!["cmd.exe".to_string()],
            sink: DeliverySinkKind::Environment,
            expires_at_epoch_seconds: 9_999_999_999,
            max_uses: 1,
            policy_epoch: 1,
            decision_digest: "digest".to_string(),
            action_class: "read-only".to_string(),
            environment: BTreeMap::from([("OPENAI_API_KEY".to_string(), "synthetic".to_string())]),
            secret_bindings: vec![SecretBinding {
                alias: "openai".to_string(),
                environment_name: "OPENAI_API_KEY".to_string(),
                value_digest: "digest".to_string(),
            }],
        }
    }
}
