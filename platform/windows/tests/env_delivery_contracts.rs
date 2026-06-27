use agentic_secrets_win_broker::{Broker, BrokerPolicy};
use agentic_secrets_win_contracts::{DeliveryPlanRequest, RunnerIdentity};
use agentic_secrets_win_run::build_child_environment;
use std::collections::HashMap;
use std::fs;
use time::OffsetDateTime;

fn target_fixture(name: &str) -> String {
    let dir =
        std::env::temp_dir().join(format!("agentic-secrets-env-{name}-{}", std::process::id()));
    fs::create_dir_all(&dir).expect("mkdir");
    let path = dir.join(name);
    fs::write(&path, b"synthetic executable").expect("write");
    path.to_string_lossy().to_string()
}

fn request(target: String) -> DeliveryPlanRequest {
    DeliveryPlanRequest {
        profile: "synthetic".to_string(),
        target_executable: target,
        arguments: vec!["--synthetic".to_string()],
        workspace: "contract-workspace".to_string(),
        action_class: "read-only".to_string(),
        origin_hint: "contract-test".to_string(),
        parent_environment_keys: vec!["PATH".to_string()],
        runner_identity: RunnerIdentity {
            executable_path: "agentic-secrets-win-run.exe".to_string(),
            sha256: "runner-digest".to_string(),
            process_id: Some(100),
            user_sid: Some("S-1-5-21-1000".to_string()),
        },
    }
}

#[test]
fn happy_path_delivers_one_synthetic_secret_and_minimal_environment() {
    let target = target_fixture("tool.exe");
    let mut broker = Broker::new(BrokerPolicy::synthetic_default());
    let parent = HashMap::from([
        ("PATH".to_string(), "C:\\Windows\\System32".to_string()),
        ("SystemRoot".to_string(), "C:\\Windows".to_string()),
        ("UNRELATED".to_string(), "drop".to_string()),
        ("GITHUB_TOKEN".to_string(), "drop-secret-shaped".to_string()),
    ]);

    let plan = broker
        .create_delivery_plan(request(target.clone()), &parent, OffsetDateTime::UNIX_EPOCH)
        .expect("plan");
    let child_env = build_child_environment(&plan, &parent).expect("child env");

    assert_eq!(plan.secret_bindings.len(), 1);
    assert!(child_env
        .variables()
        .contains_key("AGENTIC_SECRETS_SYNTHETIC_TOKEN"));
    assert!(child_env.variables().contains_key("PATH"));
    assert!(child_env.variables().contains_key("SystemRoot"));
    assert!(!child_env.variables().contains_key("GITHUB_TOKEN"));
    assert!(!child_env.variables().contains_key("UNRELATED"));

    let audit = serde_json::to_string(broker.audit.events()).expect("audit");
    assert!(audit.contains("synthetic-openai-dev"));
    assert!(!audit.contains("synthetic-secret-for-contract-tests"));
    let _ = fs::remove_file(target);
}

#[test]
fn secret_collision_blocks_before_launch() {
    let target = target_fixture("tool-collision.exe");
    let mut broker = Broker::new(BrokerPolicy::synthetic_default());
    let parent = HashMap::from([(
        "AGENTIC_SECRETS_SYNTHETIC_TOKEN".to_string(),
        "ambient".to_string(),
    )]);

    let error = broker
        .create_delivery_plan(request(target.clone()), &parent, OffsetDateTime::UNIX_EPOCH)
        .expect_err("collision");
    assert!(error.to_string().contains("overwrite ambient"));
    let _ = fs::remove_file(target);
}
