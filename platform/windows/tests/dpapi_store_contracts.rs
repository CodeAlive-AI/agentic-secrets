use agentic_secrets_win_store::{FileSecretStore, SecretProtector, StoreError};
use std::fs;
use zeroize::Zeroizing;

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
fn integrity_tamper_and_epoch_rollback_fail_closed() {
    let dir = std::env::temp_dir().join(format!("agentic-secrets-dpapi-{}", std::process::id()));
    let path = dir.join("store.json");
    let _ = fs::remove_file(&path);
    let store = FileSecretStore::new(&path, b"integrity-key".to_vec(), TestProtector);

    store
        .put("openai-dev", "OPENAI_API_KEY", b"synthetic-secret", 2)
        .expect("put");
    assert!(store.resolve("openai-dev").is_ok());
    assert!(matches!(
        store.put("openai-dev", "OPENAI_API_KEY", b"synthetic-secret", 1),
        Err(StoreError::Rollback)
    ));

    let mut json = fs::read_to_string(&path).expect("read");
    json = json.replace("openai-dev", "tampered-alias");
    fs::write(&path, json).expect("tamper");
    assert!(matches!(
        store.resolve("openai-dev"),
        Err(StoreError::Integrity)
    ));

    let _ = fs::remove_dir_all(dir);
}
