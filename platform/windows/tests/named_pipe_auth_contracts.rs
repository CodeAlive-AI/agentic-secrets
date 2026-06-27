use agentic_secrets_win_contracts::{
    IpcEnvelope, IpcOperation, NonceReplayCache, PROTOCOL_VERSION,
};
use agentic_secrets_win_ipc::{
    authorize_envelope, CallerIdentity, ExpectedRunnerIdentity, IpcAuthorizationError, PipeEndpoint,
};
use time::{Duration, OffsetDateTime};

#[test]
fn pipe_endpoint_is_user_scoped_and_not_world_acl() {
    let endpoint = PipeEndpoint::for_user_sid("S-1-5-21-1000");
    assert_eq!(
        endpoint.path,
        r"\\.\pipe\agentic-secrets\S-1-5-21-1000\broker"
    );
    let sddl = endpoint.security_descriptor_sddl();
    assert!(sddl.contains("S-1-5-21-1000"));
    assert!(!sddl.contains("WD"));
    assert!(!sddl.contains("AN"));
}

#[test]
fn stale_nonce_wrong_sid_and_wrong_runner_identity_fail_closed() {
    let now = OffsetDateTime::from_unix_timestamp(1_800_000_000).expect("time");
    let caller = CallerIdentity {
        user_sid: "S-1-5-21-1000".to_string(),
        process_id: 100,
        executable_path: "agentic-secrets-win-run.exe".to_string(),
        executable_sha256: "runner-digest".to_string(),
    };
    let expected = ExpectedRunnerIdentity {
        user_sid: "S-1-5-21-1000".to_string(),
        executable_sha256: "runner-digest".to_string(),
    };

    let mut cache = NonceReplayCache::new(Duration::seconds(30));
    let mut envelope = IpcEnvelope::new(IpcOperation::CreateDeliveryPlan, "n1".to_string(), ());
    envelope.timestamp = now - Duration::seconds(60);
    assert!(matches!(
        authorize_envelope(&envelope, &caller, &expected, &mut cache, now),
        Err(IpcAuthorizationError::Nonce(_))
    ));

    let mut cache = NonceReplayCache::new(Duration::seconds(30));
    envelope.timestamp = now;
    envelope.protocol_version = PROTOCOL_VERSION + 1;
    assert!(matches!(
        authorize_envelope(&envelope, &caller, &expected, &mut cache, now),
        Err(IpcAuthorizationError::UnsupportedVersion(_))
    ));

    envelope.protocol_version = PROTOCOL_VERSION;
    let wrong_runner = ExpectedRunnerIdentity {
        executable_sha256: "other".to_string(),
        ..expected
    };
    assert_eq!(
        authorize_envelope(&envelope, &caller, &wrong_runner, &mut cache, now),
        Err(IpcAuthorizationError::RunnerIdentityMismatch)
    );
}
