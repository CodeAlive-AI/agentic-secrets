use base64::{engine::general_purpose::STANDARD as BASE64, Engine as _};
use hmac::{Hmac, Mac};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use thiserror::Error;
use zeroize::Zeroizing;

#[cfg(windows)]
pub mod dpapi;

type HmacSha256 = Hmac<Sha256>;

#[derive(Debug, Error)]
pub enum StoreError {
    #[error("secret alias not found")]
    MissingAlias,
    #[error("store integrity verification failed")]
    Integrity,
    #[error("store rollback detected")]
    Rollback,
    #[error("store I/O failed: {0}")]
    Io(#[from] std::io::Error),
    #[error("store JSON failed: {0}")]
    Json(#[from] serde_json::Error),
    #[error("protector failed: {0}")]
    Protector(String),
}

pub trait SecretProtector {
    fn protect(&self, plaintext: &[u8], entropy: &[u8]) -> Result<Vec<u8>, StoreError>;
    fn unprotect(
        &self,
        ciphertext: &[u8],
        entropy: &[u8],
    ) -> Result<Zeroizing<Vec<u8>>, StoreError>;
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ProtectedSecretRecord {
    pub alias: String,
    pub environment_name: String,
    pub ciphertext_b64: String,
    pub value_digest: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct StoreFile {
    pub schema_version: u16,
    pub epoch: u64,
    pub records: BTreeMap<String, ProtectedSecretRecord>,
    pub integrity: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct StoreRollbackAnchor {
    pub schema_version: u16,
    pub highest_epoch: u64,
    pub latest_store_digest: String,
    pub integrity: String,
}

#[derive(Debug, Clone)]
pub struct FileSecretStore<P> {
    path: PathBuf,
    rollback_anchor_path: PathBuf,
    integrity_key: Vec<u8>,
    protector: P,
}

impl<P: SecretProtector> FileSecretStore<P> {
    pub fn new(path: impl Into<PathBuf>, integrity_key: Vec<u8>, protector: P) -> Self {
        let path = path.into();
        let rollback_anchor_path = rollback_anchor_path_for(&path);
        Self {
            path,
            rollback_anchor_path,
            integrity_key,
            protector,
        }
    }

    pub fn put(
        &self,
        alias: &str,
        environment_name: &str,
        plaintext: &[u8],
        epoch: u64,
    ) -> Result<(), StoreError> {
        let mut file = self.load_verified()?;
        if epoch < file.epoch {
            return Err(StoreError::Rollback);
        }
        file.epoch = epoch;
        let entropy = entropy_for(alias);
        let ciphertext = self.protector.protect(plaintext, &entropy)?;
        file.records.insert(
            alias.to_string(),
            ProtectedSecretRecord {
                alias: alias.to_string(),
                environment_name: environment_name.to_string(),
                ciphertext_b64: BASE64.encode(ciphertext),
                value_digest: digest_hex(plaintext),
            },
        );
        self.write(&mut file)
    }

    pub fn resolve(
        &self,
        alias: &str,
    ) -> Result<(ProtectedSecretRecord, Zeroizing<Vec<u8>>), StoreError> {
        let file = self.load_verified()?;
        let record = file
            .records
            .get(alias)
            .ok_or(StoreError::MissingAlias)?
            .clone();
        let ciphertext = BASE64
            .decode(record.ciphertext_b64.as_bytes())
            .map_err(|error| StoreError::Protector(error.to_string()))?;
        let plaintext = self.protector.unprotect(&ciphertext, &entropy_for(alias))?;
        Ok((record, plaintext))
    }

    pub fn load_verified(&self) -> Result<StoreFile, StoreError> {
        let file = self.load_or_empty()?;
        self.verify(&file)?;
        self.verify_rollback_anchor(&file)?;
        Ok(file)
    }

    fn load_or_empty(&self) -> Result<StoreFile, StoreError> {
        if !self.path.exists() {
            let mut empty = StoreFile {
                schema_version: 1,
                epoch: 0,
                records: BTreeMap::new(),
                integrity: String::new(),
            };
            empty.integrity = self.sign(&empty)?;
            return Ok(empty);
        }
        Ok(serde_json::from_slice(&fs::read(&self.path)?)?)
    }

    fn write(&self, file: &mut StoreFile) -> Result<(), StoreError> {
        file.integrity = self.sign(file)?;
        if let Some(parent) = self.path.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::write(&self.path, serde_json::to_vec_pretty(file)?)?;
        self.write_rollback_anchor(file)?;
        Ok(())
    }

    fn verify(&self, file: &StoreFile) -> Result<(), StoreError> {
        let expected = self.sign(file)?;
        if expected == file.integrity {
            Ok(())
        } else {
            Err(StoreError::Integrity)
        }
    }

    fn sign(&self, file: &StoreFile) -> Result<String, StoreError> {
        let mut copy = file.clone();
        copy.integrity.clear();
        let payload = serde_json::to_vec(&copy)?;
        let mut mac = HmacSha256::new_from_slice(&self.integrity_key)
            .map_err(|error| StoreError::Protector(error.to_string()))?;
        mac.update(&payload);
        Ok(hex::encode(mac.finalize().into_bytes()))
    }

    fn verify_rollback_anchor(&self, file: &StoreFile) -> Result<(), StoreError> {
        if !self.rollback_anchor_path.exists() {
            if file.epoch == 0 && file.records.is_empty() {
                return Ok(());
            }
            return Err(StoreError::Rollback);
        }
        let anchor = self.load_anchor()?;
        if file.epoch < anchor.highest_epoch {
            return Err(StoreError::Rollback);
        }
        if file.epoch == anchor.highest_epoch && store_digest(file)? != anchor.latest_store_digest {
            return Err(StoreError::Rollback);
        }
        Ok(())
    }

    fn write_rollback_anchor(&self, file: &StoreFile) -> Result<(), StoreError> {
        let digest = store_digest(file)?;
        let mut anchor = StoreRollbackAnchor {
            schema_version: 1,
            highest_epoch: file.epoch,
            latest_store_digest: digest,
            integrity: String::new(),
        };
        anchor.integrity = self.sign_anchor(&anchor)?;
        if let Some(parent) = self.rollback_anchor_path.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::write(
            &self.rollback_anchor_path,
            serde_json::to_vec_pretty(&anchor)?,
        )?;
        Ok(())
    }

    fn load_anchor(&self) -> Result<StoreRollbackAnchor, StoreError> {
        let anchor: StoreRollbackAnchor =
            serde_json::from_slice(&fs::read(&self.rollback_anchor_path)?)?;
        let expected = self.sign_anchor(&anchor)?;
        if expected == anchor.integrity {
            Ok(anchor)
        } else {
            Err(StoreError::Integrity)
        }
    }

    fn sign_anchor(&self, anchor: &StoreRollbackAnchor) -> Result<String, StoreError> {
        let mut copy = anchor.clone();
        copy.integrity.clear();
        let payload = serde_json::to_vec(&copy)?;
        let mut mac = HmacSha256::new_from_slice(&self.integrity_key)
            .map_err(|error| StoreError::Protector(error.to_string()))?;
        mac.update(&payload);
        Ok(hex::encode(mac.finalize().into_bytes()))
    }
}

pub fn digest_hex(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}

fn entropy_for(alias: &str) -> Vec<u8> {
    format!("agentic-secrets-win-store:initial:{alias}").into_bytes()
}

fn store_digest(file: &StoreFile) -> Result<String, StoreError> {
    let mut copy = file.clone();
    copy.integrity.clear();
    Ok(digest_hex(&serde_json::to_vec(&copy)?))
}

fn rollback_anchor_path_for(path: &Path) -> PathBuf {
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("store.json");
    path.with_file_name(format!("{file_name}.rollback-anchor.json"))
}

pub fn default_store_path() -> PathBuf {
    std::env::var_os("LOCALAPPDATA")
        .map(PathBuf::from)
        .unwrap_or_else(|| Path::new(".").to_path_buf())
        .join("AgenticSecrets")
        .join("store.json")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Debug, Clone)]
    struct TestProtector;

    impl SecretProtector for TestProtector {
        fn protect(&self, plaintext: &[u8], entropy: &[u8]) -> Result<Vec<u8>, StoreError> {
            let mut out = entropy.to_vec();
            out.extend_from_slice(plaintext);
            Ok(out)
        }

        fn unprotect(
            &self,
            ciphertext: &[u8],
            entropy: &[u8],
        ) -> Result<Zeroizing<Vec<u8>>, StoreError> {
            Ok(Zeroizing::new(ciphertext[entropy.len()..].to_vec()))
        }
    }

    #[test]
    fn tamper_blocks_resolution() {
        let dir =
            std::env::temp_dir().join(format!("agentic-secrets-win-store-{}", std::process::id()));
        let path = dir.join("store.json");
        let _ = fs::remove_file(&path);
        let store = FileSecretStore::new(&path, b"integrity-key".to_vec(), TestProtector);
        store
            .put("openai-dev", "OPENAI_API_KEY", b"synthetic-secret", 1)
            .expect("put");

        let mut json = fs::read_to_string(&path).expect("read");
        json = json.replace("OPENAI_API_KEY", "OTHER_NAME");
        fs::write(&path, json).expect("write");

        assert!(matches!(
            store.resolve("openai-dev"),
            Err(StoreError::Integrity)
        ));
        let _ = fs::remove_file(&path);
        let _ = fs::remove_file(rollback_anchor_path_for(&path));
    }

    #[test]
    fn older_valid_store_replay_blocks_resolution() {
        let dir = std::env::temp_dir().join(format!(
            "agentic-secrets-win-store-replay-{}",
            std::process::id()
        ));
        let path = dir.join("store.json");
        let _ = fs::remove_file(&path);
        let _ = fs::remove_file(rollback_anchor_path_for(&path));
        let store = FileSecretStore::new(&path, b"integrity-key".to_vec(), TestProtector);
        store
            .put("openai-dev", "OPENAI_API_KEY", b"old-secret", 1)
            .expect("put old");
        let older_valid = fs::read(&path).expect("snapshot old");
        store
            .put("openai-dev", "OPENAI_API_KEY", b"new-secret", 2)
            .expect("put new");
        fs::write(&path, older_valid).expect("restore old");

        assert!(matches!(
            store.resolve("openai-dev"),
            Err(StoreError::Rollback)
        ));
        let _ = fs::remove_file(&path);
        let _ = fs::remove_file(rollback_anchor_path_for(&path));
    }
}
