use crate::{SecretProtector, StoreError};
use windows::Win32::Foundation::{LocalFree, HLOCAL};
use windows::Win32::Security::Cryptography::{
    CryptProtectData, CryptUnprotectData, CRYPTPROTECT_UI_FORBIDDEN, CRYPT_INTEGER_BLOB,
};
use zeroize::Zeroizing;

#[derive(Debug, Clone, Copy)]
pub struct DpapiCurrentUserProtector;

impl SecretProtector for DpapiCurrentUserProtector {
    fn protect(&self, plaintext: &[u8], entropy: &[u8]) -> Result<Vec<u8>, StoreError> {
        let input = blob_from_slice(plaintext);
        let entropy_blob = blob_from_slice(entropy);
        let mut output = CRYPT_INTEGER_BLOB::default();
        let ok = unsafe {
            CryptProtectData(
                &input,
                None,
                Some(&entropy_blob),
                None,
                None,
                CRYPTPROTECT_UI_FORBIDDEN,
                &mut output,
            )
        };
        if ok.is_err() {
            return Err(StoreError::Protector("CryptProtectData failed".to_string()));
        }
        unsafe { take_blob(output, false) }
    }

    fn unprotect(
        &self,
        ciphertext: &[u8],
        entropy: &[u8],
    ) -> Result<Zeroizing<Vec<u8>>, StoreError> {
        let input = blob_from_slice(ciphertext);
        let entropy_blob = blob_from_slice(entropy);
        let mut output = CRYPT_INTEGER_BLOB::default();
        let ok = unsafe {
            CryptUnprotectData(
                &input,
                None,
                Some(&entropy_blob),
                None,
                None,
                CRYPTPROTECT_UI_FORBIDDEN,
                &mut output,
            )
        };
        if ok.is_err() {
            return Err(StoreError::Protector(
                "CryptUnprotectData failed".to_string(),
            ));
        }
        unsafe { take_blob(output, true).map(Zeroizing::new) }
    }
}

fn blob_from_slice(slice: &[u8]) -> CRYPT_INTEGER_BLOB {
    CRYPT_INTEGER_BLOB {
        cbData: slice.len() as u32,
        pbData: slice.as_ptr() as *mut u8,
    }
}

unsafe fn take_blob(
    blob: CRYPT_INTEGER_BLOB,
    zero_before_free: bool,
) -> Result<Vec<u8>, StoreError> {
    if blob.pbData.is_null() {
        return Ok(Vec::new());
    }
    let bytes = std::slice::from_raw_parts(blob.pbData, blob.cbData as usize).to_vec();
    if zero_before_free {
        secure_zero_memory(blob.pbData, blob.cbData as usize);
    }
    let _ = LocalFree(HLOCAL(blob.pbData as *mut _));
    Ok(bytes)
}

unsafe fn secure_zero_memory(ptr: *mut u8, len: usize) {
    for offset in 0..len {
        std::ptr::write_volatile(ptr.add(offset), 0);
    }
}
