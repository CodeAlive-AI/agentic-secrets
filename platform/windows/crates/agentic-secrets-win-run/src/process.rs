use agentic_secrets_win_contracts::zeroize_environment_values;
use agentic_secrets_win_contracts::DeliveryPlan;
use std::collections::HashMap;
use std::mem::size_of;
use windows::core::{PCWSTR, PWSTR};
use windows::Win32::Foundation::{CloseHandle, HANDLE};
use windows::Win32::System::JobObjects::{
    AssignProcessToJobObject, CreateJobObjectW, JobObjectExtendedLimitInformation,
    SetInformationJobObject, JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
    JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
};
use windows::Win32::System::Threading::{
    CreateProcessW, GetExitCodeProcess, ResumeThread, TerminateProcess, WaitForSingleObject,
    CREATE_SUSPENDED, CREATE_UNICODE_ENVIRONMENT, INFINITE, PROCESS_INFORMATION, STARTUPINFOW,
};

use crate::{build_child_environment, RunnerError};

pub fn launch_with_create_process(plan: &DeliveryPlan) -> Result<i32, RunnerError> {
    let parent = std::env::vars().collect::<HashMap<_, _>>();
    let job = create_kill_on_close_job()?;
    let mut env = build_child_environment(plan, &parent)?;
    let env_block = SensitiveWideBuffer::from_vec(env.to_windows_unicode_block()?);
    let mut command_line = command_line(&plan.target.executable_path, &plan.argv[1..]);
    let mut command_line_wide = SensitiveWideBuffer::from_vec(wide_null(&command_line));
    let application = wide_null(&plan.target.executable_path);
    let startup_info = STARTUPINFOW {
        cb: size_of::<STARTUPINFOW>() as u32,
        ..Default::default()
    };
    let mut process_info = PROCESS_INFORMATION::default();

    let ok = unsafe {
        CreateProcessW(
            PCWSTR(application.as_ptr()),
            PWSTR(command_line_wide.as_mut_ptr()),
            None,
            None,
            false,
            CREATE_UNICODE_ENVIRONMENT | CREATE_SUSPENDED,
            Some(env_block.as_ptr().cast()),
            PCWSTR::null(),
            &startup_info,
            &mut process_info,
        )
    };
    zeroize_environment_values(&mut env);
    command_line.clear();

    ok.map_err(|error| RunnerError::Process(error.to_string()))?;
    let process_handle = OwnedHandle::new(process_info.hProcess);
    let thread_handle = OwnedHandle::new(process_info.hThread);
    unsafe {
        if let Err(error) = AssignProcessToJobObject(job.raw(), process_handle.raw()) {
            terminate_process(process_handle.raw());
            return Err(RunnerError::Process(error.to_string()));
        }
        if ResumeThread(thread_handle.raw()) == u32::MAX {
            terminate_process(process_handle.raw());
            return Err(RunnerError::Process("ResumeThread failed".to_string()));
        }
        WaitForSingleObject(process_handle.raw(), INFINITE);
        let mut exit_code = 1u32;
        GetExitCodeProcess(process_handle.raw(), &mut exit_code)
            .map_err(|error| RunnerError::Process(error.to_string()))?;
        drop(thread_handle);
        drop(process_handle);
        drop(job);
        Ok(exit_code as i32)
    }
}

unsafe fn terminate_process(process: HANDLE) {
    TerminateProcess(process, 1).ok();
    WaitForSingleObject(process, INFINITE);
}

fn create_kill_on_close_job() -> Result<OwnedHandle, RunnerError> {
    let job = unsafe { CreateJobObjectW(None, PCWSTR::null()) }
        .map_err(|error| RunnerError::Process(error.to_string()))?;
    let job = OwnedHandle::new(job);
    let mut info = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
    info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    unsafe {
        SetInformationJobObject(
            job.raw(),
            JobObjectExtendedLimitInformation,
            &mut info as *mut _ as *const _,
            size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
        )
        .map_err(|error| RunnerError::Process(error.to_string()))?;
    }
    Ok(job)
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

#[derive(Debug)]
struct SensitiveWideBuffer(Vec<u16>);

impl SensitiveWideBuffer {
    fn from_vec(buffer: Vec<u16>) -> Self {
        Self(buffer)
    }

    fn as_ptr(&self) -> *const u16 {
        self.0.as_ptr()
    }

    fn as_mut_ptr(&mut self) -> *mut u16 {
        self.0.as_mut_ptr()
    }
}

impl Drop for SensitiveWideBuffer {
    fn drop(&mut self) {
        self.0.fill(0);
    }
}

fn command_line(program: &str, args: &[String]) -> String {
    std::iter::once(program.to_string())
        .chain(args.iter().cloned())
        .map(|part| quote_arg(&part))
        .collect::<Vec<_>>()
        .join(" ")
}

fn quote_arg(arg: &str) -> String {
    if arg.is_empty() {
        return "\"\"".to_string();
    }
    if !arg
        .bytes()
        .any(|byte| matches!(byte, b' ' | b'\t' | b'"' | b'\\'))
    {
        return arg.to_string();
    }
    let mut quoted = String::from("\"");
    let mut backslashes = 0usize;
    for ch in arg.chars() {
        match ch {
            '\\' => backslashes += 1,
            '"' => {
                quoted.push_str(&"\\".repeat(backslashes * 2 + 1));
                quoted.push('"');
                backslashes = 0;
            }
            _ => {
                quoted.push_str(&"\\".repeat(backslashes));
                backslashes = 0;
                quoted.push(ch);
            }
        }
    }
    quoted.push_str(&"\\".repeat(backslashes * 2));
    quoted.push('"');
    quoted
}

fn wide_null(value: &str) -> Vec<u16> {
    value.encode_utf16().chain(std::iter::once(0)).collect()
}
