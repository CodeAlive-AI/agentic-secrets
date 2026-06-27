use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashMap, HashSet};
use thiserror::Error;
use zeroize::Zeroize;

const BLOCKED_EXACT_NAMES: &[&str] = &[
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_AUTH_TOKEN",
    "AWS_SECRET_ACCESS_KEY",
    "AWS_SESSION_TOKEN",
    "BW_SESSION",
    "BWS_ACCESS_TOKEN",
    "GEMINI_API_KEY",
    "GH_TOKEN",
    "GITHUB_TOKEN",
    "HCLOUD_TOKEN",
    "OPENAI_API_KEY",
    "STRIPE_API_KEY",
];

const SECRET_FRAGMENTS: &[&str] = &[
    "ACCESS_KEY",
    "API_KEY",
    "AUTHORIZATION",
    "PASSWORD",
    "PRIVATE_KEY",
    "SECRET",
    "TOKEN",
];

const DEFAULT_ALLOWLIST: &[&str] = &[
    "COMSPEC",
    "PATH",
    "PATHEXT",
    "SYSTEMROOT",
    "TEMP",
    "TMP",
    "USERPROFILE",
    "WINDIR",
];

#[derive(Debug, Error, PartialEq, Eq)]
pub enum EnvironmentBlockError {
    #[error("secret delivery would overwrite ambient environment variable {0}")]
    Collision(String),
    #[error("environment variable name is empty")]
    EmptyName,
    #[error("environment variable name contains an unsupported character: {0}")]
    InvalidName(String),
    #[error("environment variable {0} contains an embedded NUL")]
    EmbeddedNul(String),
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct EnvironmentBlock {
    variables: BTreeMap<String, String>,
}

impl EnvironmentBlock {
    pub fn variables(&self) -> &BTreeMap<String, String> {
        &self.variables
    }

    pub fn into_variables(self) -> BTreeMap<String, String> {
        self.variables
    }

    pub fn to_windows_unicode_block(&self) -> Result<Vec<u16>, EnvironmentBlockError> {
        let mut block = Vec::new();
        for (name, value) in &self.variables {
            validate_name(name)?;
            reject_nul(name, name)?;
            reject_nul(name, value)?;
            block.extend(format!("{name}={value}").encode_utf16());
            block.push(0);
        }
        block.push(0);
        Ok(block)
    }
}

#[derive(Debug, Clone)]
pub struct EnvironmentBuilder {
    allowlist: HashSet<String>,
}

impl Default for EnvironmentBuilder {
    fn default() -> Self {
        Self::new(DEFAULT_ALLOWLIST)
    }
}

impl EnvironmentBuilder {
    pub fn new<I, S>(allowlist: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: AsRef<str>,
    {
        let allowlist = allowlist
            .into_iter()
            .map(|item| normalize_key(item.as_ref()))
            .collect();
        Self { allowlist }
    }

    pub fn build(
        &self,
        parent: &HashMap<String, String>,
        injected: BTreeMap<String, String>,
    ) -> Result<EnvironmentBlock, EnvironmentBlockError> {
        let parent_index = case_insensitive_index(parent.keys());
        for name in injected.keys() {
            validate_name(name)?;
            if parent_index.contains_key(&normalize_key(name)) {
                return Err(EnvironmentBlockError::Collision(name.clone()));
            }
        }

        let mut clean = BTreeMap::new();
        for (name, value) in parent {
            validate_name(name)?;
            if !self.allowlist.contains(&normalize_key(name)) {
                continue;
            }
            if looks_secret_like(name) {
                continue;
            }
            reject_nul(name, value)?;
            clean.insert(name.clone(), value.clone());
        }

        for (name, value) in injected {
            reject_nul(&name, &value)?;
            clean.insert(name, value);
        }

        Ok(EnvironmentBlock { variables: clean })
    }
}

pub fn looks_secret_like(name: &str) -> bool {
    let upper = normalize_key(name);
    BLOCKED_EXACT_NAMES.contains(&upper.as_str())
        || SECRET_FRAGMENTS
            .iter()
            .any(|fragment| upper.contains(fragment))
}

pub fn zeroize_environment_values(block: &mut EnvironmentBlock) {
    for value in block.variables.values_mut() {
        value.zeroize();
    }
}

fn case_insensitive_index<'a, I>(keys: I) -> HashMap<String, &'a String>
where
    I: IntoIterator<Item = &'a String>,
{
    keys.into_iter()
        .map(|key| (normalize_key(key), key))
        .collect()
}

fn normalize_key(name: &str) -> String {
    name.to_ascii_uppercase()
}

fn validate_name(name: &str) -> Result<(), EnvironmentBlockError> {
    if name.is_empty() {
        return Err(EnvironmentBlockError::EmptyName);
    }
    if name.contains('=') {
        return Err(EnvironmentBlockError::InvalidName(name.to_string()));
    }
    Ok(())
}

fn reject_nul(name: &str, value: &str) -> Result<(), EnvironmentBlockError> {
    if value.contains('\0') {
        return Err(EnvironmentBlockError::EmbeddedNul(name.to_string()));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keeps_only_minimal_allowed_environment_and_injected_secret() {
        let parent = HashMap::from([
            ("SystemRoot".to_string(), "C:\\Windows".to_string()),
            ("PATH".to_string(), "C:\\Windows\\System32".to_string()),
            ("OPENAI_API_KEY".to_string(), "should-not-copy".to_string()),
            ("UNRELATED".to_string(), "drop-me".to_string()),
        ]);
        let injected = BTreeMap::from([(
            "AGENTIC_SYNTHETIC_TOKEN".to_string(),
            "synthetic-secret".to_string(),
        )]);

        let block = EnvironmentBuilder::default()
            .build(&parent, injected)
            .expect("env block");

        assert_eq!(
            block.variables().keys().cloned().collect::<Vec<_>>(),
            vec!["AGENTIC_SYNTHETIC_TOKEN", "PATH", "SystemRoot"]
        );
        assert_eq!(
            block.variables().get("AGENTIC_SYNTHETIC_TOKEN"),
            Some(&"synthetic-secret".to_string())
        );
    }

    #[test]
    fn collisions_fail_closed_before_launch() {
        let parent = HashMap::from([("OPENAI_API_KEY".to_string(), "ambient".to_string())]);
        let injected = BTreeMap::from([("openai_api_key".to_string(), "new".to_string())]);

        assert_eq!(
            EnvironmentBuilder::default().build(&parent, injected),
            Err(EnvironmentBlockError::Collision(
                "openai_api_key".to_string()
            ))
        );
    }

    #[test]
    fn emits_double_nul_terminated_unicode_environment_block() {
        let block = EnvironmentBlock {
            variables: BTreeMap::from([("SystemRoot".to_string(), "C:\\Windows".to_string())]),
        };
        let encoded = block.to_windows_unicode_block().expect("encoded");
        assert_eq!(encoded.last(), Some(&0));
        assert_eq!(
            encoded.iter().rev().take(2).collect::<Vec<_>>(),
            vec![&0, &0]
        );
    }
}
