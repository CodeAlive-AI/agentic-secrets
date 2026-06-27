use agentic_secrets_win_contracts::{
    IpcEnvelope, NonceReplayCache, NonceReplayError, PROTOCOL_VERSION,
};
use serde::{Deserialize, Serialize};
use thiserror::Error;
use time::OffsetDateTime;

#[cfg(windows)]
pub mod named_pipe;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct CallerIdentity {
    pub user_sid: String,
    pub process_id: u32,
    pub executable_path: String,
    pub executable_sha256: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ExpectedRunnerIdentity {
    pub user_sid: String,
    pub executable_sha256: String,
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum IpcAuthorizationError {
    #[error("unsupported protocol version {0}")]
    UnsupportedVersion(u16),
    #[error("request nonce rejected: {0}")]
    Nonce(#[from] NonceReplayError),
    #[error("caller user SID mismatch")]
    UserSidMismatch,
    #[error("runner executable identity mismatch")]
    RunnerIdentityMismatch,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PipeEndpoint {
    pub path: String,
    pub user_sid: String,
}

impl PipeEndpoint {
    pub fn for_user_sid(user_sid: impl Into<String>) -> Self {
        let user_sid = user_sid.into();
        Self {
            path: format!(
                r"\\.\pipe\agentic-secrets\{}\broker",
                sanitize_sid(&user_sid)
            ),
            user_sid,
        }
    }

    pub fn security_descriptor_sddl(&self) -> String {
        // Current user and LocalSystem only. The SDDL intentionally omits Everyone,
        // Anonymous, and Administrators; elevation is not an authorization bypass.
        format!("D:P(A;;0x12019f;;;SY)(A;;0x12019f;;;{})", self.user_sid)
    }
}

pub fn authorize_envelope<T>(
    envelope: &IpcEnvelope<T>,
    caller: &CallerIdentity,
    expected: &ExpectedRunnerIdentity,
    replay_cache: &mut NonceReplayCache,
    now: OffsetDateTime,
) -> Result<(), IpcAuthorizationError> {
    if envelope.protocol_version != PROTOCOL_VERSION {
        return Err(IpcAuthorizationError::UnsupportedVersion(
            envelope.protocol_version,
        ));
    }
    replay_cache.accept(&envelope.nonce, envelope.timestamp, now)?;
    if caller.user_sid != expected.user_sid {
        return Err(IpcAuthorizationError::UserSidMismatch);
    }
    if caller.executable_sha256 != expected.executable_sha256 {
        return Err(IpcAuthorizationError::RunnerIdentityMismatch);
    }
    Ok(())
}

fn sanitize_sid(sid: &str) -> String {
    sid.chars()
        .filter(|ch| ch.is_ascii_alphanumeric() || *ch == '-')
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use agentic_secrets_win_contracts::{IpcOperation, NonceReplayCache};
    use time::Duration;

    #[test]
    fn pipe_acl_excludes_broad_principals() {
        let endpoint = PipeEndpoint::for_user_sid("S-1-5-21-1000");
        let sddl = endpoint.security_descriptor_sddl();
        assert!(sddl.contains("S-1-5-21-1000"));
        assert!(sddl.contains("SY"));
        assert!(!sddl.contains("WD"));
        assert!(!sddl.contains("AN"));
        assert!(!sddl.contains("BA"));
    }

    #[test]
    fn authorization_rejects_replay_and_identity_mismatch() {
        let now = OffsetDateTime::from_unix_timestamp(1_700_000_000).expect("time");
        let mut envelope = agentic_secrets_win_contracts::IpcEnvelope::new(
            IpcOperation::Health,
            "n1".to_string(),
            (),
        );
        envelope.timestamp = now;
        let caller = CallerIdentity {
            user_sid: "S-1-5-21-1000".to_string(),
            process_id: 42,
            executable_path: "runner.exe".to_string(),
            executable_sha256: "abc".to_string(),
        };
        let expected = ExpectedRunnerIdentity {
            user_sid: "S-1-5-21-1000".to_string(),
            executable_sha256: "abc".to_string(),
        };
        let mut cache = NonceReplayCache::new(Duration::seconds(30));

        authorize_envelope(&envelope, &caller, &expected, &mut cache, now).expect("authorized");
        assert!(matches!(
            authorize_envelope(&envelope, &caller, &expected, &mut cache, now),
            Err(IpcAuthorizationError::Nonce(_))
        ));

        let mut second = envelope.clone();
        second.nonce = "n2".to_string();
        let other_user = CallerIdentity {
            user_sid: "S-1-5-21-9999".to_string(),
            ..caller
        };
        assert_eq!(
            authorize_envelope(&second, &other_user, &expected, &mut cache, now),
            Err(IpcAuthorizationError::UserSidMismatch)
        );
    }
}
