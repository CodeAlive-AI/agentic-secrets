use windows::core::PWSTR;
use windows::Win32::Foundation::{CloseHandle, LocalFree, HANDLE, HLOCAL};
use windows::Win32::Security::Authorization::ConvertSidToStringSidW;
use windows::Win32::Security::{GetTokenInformation, TokenUser, TOKEN_QUERY, TOKEN_USER};
use windows::Win32::System::Pipes::GetNamedPipeClientProcessId;
use windows::Win32::System::Threading::{
    OpenProcess, OpenProcessToken, PROCESS_QUERY_LIMITED_INFORMATION,
};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ObservedPipeClient {
    pub process_id: u32,
    pub user_sid: String,
}

pub fn observe_client(_pipe: HANDLE) -> windows::core::Result<ObservedPipeClient> {
    let mut process_id = 0u32;
    unsafe {
        GetNamedPipeClientProcessId(_pipe, &mut process_id)?;
        let process = OwnedHandle::new(OpenProcess(
            PROCESS_QUERY_LIMITED_INFORMATION,
            false,
            process_id,
        )?);
        let mut token = HANDLE::default();
        OpenProcessToken(process.raw(), TOKEN_QUERY, &mut token)?;
        let token = OwnedHandle::new(token);
        let user_sid = token_user_sid(token.raw())?;
        Ok(ObservedPipeClient {
            process_id,
            user_sid,
        })
    }
}

unsafe fn token_user_sid(token: HANDLE) -> windows::core::Result<String> {
    let mut required_len = 0u32;
    let _ = GetTokenInformation(token, TokenUser, None, 0, &mut required_len);
    let mut buffer = vec![0u8; required_len as usize];
    GetTokenInformation(
        token,
        TokenUser,
        Some(buffer.as_mut_ptr().cast()),
        buffer.len() as u32,
        &mut required_len,
    )?;
    let token_user = &*(buffer.as_ptr() as *const TOKEN_USER);
    let mut sid_string = PWSTR::null();
    ConvertSidToStringSidW(token_user.User.Sid, &mut sid_string)?;
    let sid = sid_string
        .to_string()
        .map_err(|_| windows::core::Error::from_win32())?;
    let _ = LocalFree(HLOCAL(sid_string.as_ptr().cast()));
    Ok(sid)
}

#[derive(Debug)]
struct OwnedHandle(HANDLE);

impl OwnedHandle {
    fn new(handle: HANDLE) -> Self {
        Self(handle)
    }

    fn raw(&self) -> HANDLE {
        self.0
    }
}

impl Drop for OwnedHandle {
    fn drop(&mut self) {
        unsafe {
            CloseHandle(self.0).ok();
        }
    }
}
