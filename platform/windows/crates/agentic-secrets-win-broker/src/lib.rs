use agentic_secrets_win_contracts::{
    AuditEvent, AuditLog, AuditOutcome, DeliveryPlan, DeliveryPlanRequest, DeliverySinkKind,
    EnvironmentBuilder, SecretBinding, TargetIdentity,
};
use agentic_secrets_win_store::digest_hex;
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, HashMap};
use std::fs;
use std::path::Path;
use thiserror::Error;
use time::{Duration, OffsetDateTime};
use uuid::Uuid;
use zeroize::Zeroizing;

const GENERIC_RUNNERS: &[&str] = &[
    "cmd.exe",
    "node.exe",
    "powershell.exe",
    "pwsh.exe",
    "python.exe",
    "python3.exe",
];

#[derive(Debug, Error)]
pub enum BrokerError {
    #[error("unknown profile {0}")]
    UnknownProfile(String),
    #[error("generic runner {0} requires an explicit policy pack before env delivery")]
    GenericRunnerRequiresPolicy(String),
    #[error("target executable identity changed")]
    TargetIdentityChanged,
    #[error("environment contract failed: {0}")]
    Environment(#[from] agentic_secrets_win_contracts::EnvironmentBlockError),
    #[error("audit redaction rejected the event")]
    AuditRedaction,
    #[error("I/O failed: {0}")]
    Io(#[from] std::io::Error),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SecretProfile {
    pub name: String,
    pub alias: String,
    pub environment_name: String,
    pub policy_pack_id: Option<String>,
    pub synthetic_value: Zeroizing<String>,
}

#[derive(Debug, Clone)]
pub struct BrokerPolicy {
    pub policy_epoch: u64,
    pub profiles: HashMap<String, SecretProfile>,
}

impl BrokerPolicy {
    pub fn synthetic_default() -> Self {
        let profile = SecretProfile {
            name: "synthetic".to_string(),
            alias: "synthetic-openai-dev".to_string(),
            environment_name: "AGENTIC_SECRETS_SYNTHETIC_TOKEN".to_string(),
            policy_pack_id: Some("agentic-secrets-synthetic".to_string()),
            synthetic_value: Zeroizing::new("synthetic-secret-for-contract-tests".to_string()),
        };
        Self {
            policy_epoch: 1,
            profiles: HashMap::from([(profile.name.clone(), profile)]),
        }
    }
}

#[derive(Debug)]
pub struct Broker {
    pub policy: BrokerPolicy,
    pub audit: AuditLog,
}

impl Broker {
    pub fn new(policy: BrokerPolicy) -> Self {
        Self {
            policy,
            audit: AuditLog::default(),
        }
    }

    pub fn create_delivery_plan(
        &mut self,
        request: DeliveryPlanRequest,
        parent_environment: &HashMap<String, String>,
        now: OffsetDateTime,
    ) -> Result<DeliveryPlan, BrokerError> {
        let profile = self
            .policy
            .profiles
            .get(&request.profile)
            .ok_or_else(|| BrokerError::UnknownProfile(request.profile.clone()))?;
        let target = assess_target(&request.target_executable)?;
        self.authorize_target(&target, profile)?;

        let injected = BTreeMap::from([(
            profile.environment_name.clone(),
            profile.synthetic_value.to_string(),
        )]);
        let env_block = EnvironmentBuilder::default().build(parent_environment, injected)?;
        let plan = DeliveryPlan {
            plan_id: Uuid::new_v4(),
            profile: profile.name.clone(),
            target,
            argv: build_argv(&request.target_executable, &request.arguments),
            sink: DeliverySinkKind::Environment,
            expires_at_epoch_seconds: (now + Duration::seconds(30)).unix_timestamp(),
            max_uses: 1,
            policy_epoch: self.policy.policy_epoch,
            decision_digest: decision_digest(&request, profile),
            action_class: request.action_class,
            environment: env_block.into_variables(),
            secret_bindings: vec![SecretBinding {
                alias: profile.alias.clone(),
                environment_name: profile.environment_name.clone(),
                value_digest: digest_hex(profile.synthetic_value.as_bytes()),
            }],
        };

        self.audit
            .append(
                AuditEvent::delivery(&plan, "agentic-secrets-win-run", AuditOutcome::Allow),
                &[profile.synthetic_value.as_str()],
            )
            .map_err(|_| BrokerError::AuditRedaction)?;
        Ok(plan)
    }

    pub fn verify_target_identity(&self, plan: &DeliveryPlan) -> Result<(), BrokerError> {
        let observed = assess_target(&plan.target.executable_path)?;
        if observed.sha256 == plan.target.sha256 {
            Ok(())
        } else {
            Err(BrokerError::TargetIdentityChanged)
        }
    }

    fn authorize_target(
        &self,
        target: &TargetIdentity,
        profile: &SecretProfile,
    ) -> Result<(), BrokerError> {
        let name = Path::new(&target.executable_path)
            .file_name()
            .and_then(|value| value.to_str())
            .unwrap_or_default()
            .to_ascii_lowercase();
        if GENERIC_RUNNERS.contains(&name.as_str()) && profile.policy_pack_id.is_none() {
            return Err(BrokerError::GenericRunnerRequiresPolicy(name));
        }
        Ok(())
    }
}

pub fn assess_target(path: &str) -> Result<TargetIdentity, BrokerError> {
    let bytes = fs::read(path)?;
    Ok(TargetIdentity {
        executable_path: path.to_string(),
        sha256: hex::encode(Sha256::digest(bytes)),
    })
}

fn build_argv(target: &str, arguments: &[String]) -> Vec<String> {
    let argv_zero = Path::new(target)
        .file_name()
        .and_then(|value| value.to_str())
        .unwrap_or(target)
        .to_string();
    std::iter::once(argv_zero)
        .chain(arguments.iter().cloned())
        .collect()
}

fn decision_digest(request: &DeliveryPlanRequest, profile: &SecretProfile) -> String {
    let mut hasher = Sha256::new();
    hasher.update(request.profile.as_bytes());
    hasher.update(request.target_executable.as_bytes());
    hasher.update(request.arguments.join("\0").as_bytes());
    hasher.update(request.workspace.as_bytes());
    hasher.update(request.action_class.as_bytes());
    hasher.update(profile.alias.as_bytes());
    hasher.update(profile.environment_name.as_bytes());
    hex::encode(hasher.finalize())
}

#[cfg(test)]
mod tests {
    use super::*;
    use agentic_secrets_win_contracts::RunnerIdentity;

    fn temp_target(name: &str) -> String {
        let path = std::env::temp_dir().join(format!("{name}-{}", std::process::id()));
        fs::write(&path, b"synthetic executable").expect("write");
        path.to_string_lossy().to_string()
    }

    fn request(target: String) -> DeliveryPlanRequest {
        DeliveryPlanRequest {
            profile: "synthetic".to_string(),
            target_executable: target,
            arguments: vec!["--version".to_string()],
            workspace: "workspace".to_string(),
            action_class: "read-only".to_string(),
            origin_hint: "contract-test".to_string(),
            parent_environment_keys: vec!["PATH".to_string()],
            runner_identity: RunnerIdentity {
                executable_path: "agentic-secrets-win-run.exe".to_string(),
                sha256: "runner".to_string(),
                process_id: None,
                user_sid: None,
            },
        }
    }

    #[test]
    fn creates_redacted_one_use_synthetic_delivery_plan() {
        let target = temp_target("agentic-secrets-target");
        let mut broker = Broker::new(BrokerPolicy::synthetic_default());
        let parent = HashMap::from([("PATH".to_string(), "C:\\Windows\\System32".to_string())]);
        let plan = broker
            .create_delivery_plan(request(target.clone()), &parent, OffsetDateTime::UNIX_EPOCH)
            .expect("plan");

        assert_eq!(plan.max_uses, 1);
        assert!(plan
            .environment
            .contains_key("AGENTIC_SECRETS_SYNTHETIC_TOKEN"));
        assert_eq!(broker.audit.events().len(), 1);
        let audit = serde_json::to_string(broker.audit.events()).expect("audit");
        assert!(!audit.contains("synthetic-secret-for-contract-tests"));
        let _ = fs::remove_file(target);
    }

    #[test]
    fn generic_runner_requires_policy_pack() {
        let dir = std::env::temp_dir().join(format!("agentic-secrets-cmd-{}", std::process::id()));
        fs::create_dir_all(&dir).expect("mkdir");
        let target = dir.join("cmd.exe");
        fs::write(&target, b"cmd").expect("write");
        let mut policy = BrokerPolicy::synthetic_default();
        policy
            .profiles
            .get_mut("synthetic")
            .expect("profile")
            .policy_pack_id = None;
        let mut broker = Broker::new(policy);
        let parent = HashMap::new();

        let request = request(target.to_string_lossy().to_string());
        let error = broker
            .create_delivery_plan(request, &parent, OffsetDateTime::UNIX_EPOCH)
            .expect_err("denied");
        assert!(matches!(error, BrokerError::GenericRunnerRequiresPolicy(_)));
        let _ = fs::remove_file(&target);
        let _ = fs::remove_dir(dir);
    }
}
