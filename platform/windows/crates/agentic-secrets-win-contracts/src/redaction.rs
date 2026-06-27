use thiserror::Error;

const TOKEN_MARKERS: &[&str] = &[
    "sk-",
    "sk-proj-",
    "xoxb-",
    "xoxp-",
    "ghp_",
    "github_pat_",
    "AKIA",
];

#[derive(Debug, Error, PartialEq, Eq)]
pub enum RedactionError {
    #[error("raw secret material detected in audit payload")]
    RawSecretDetected,
}

#[derive(Debug, Default, Clone)]
pub struct Redactor;

impl Redactor {
    pub fn reject_known_secrets(
        &self,
        payload: &str,
        known_secrets: &[&str],
    ) -> Result<(), RedactionError> {
        if known_secrets
            .iter()
            .any(|secret| !secret.is_empty() && payload.contains(secret))
        {
            return Err(RedactionError::RawSecretDetected);
        }
        if TOKEN_MARKERS.iter().any(|marker| payload.contains(marker)) {
            return Err(RedactionError::RawSecretDetected);
        }
        Ok(())
    }
}
