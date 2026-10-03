//! The only unsafe ABI boundary. Valid caller allocations remain a precondition.
use crate::{abi_records::*, model, registry};
#[cfg(target_os = "macos")]
use arktrace_engine::{
    DrainStatus, EngineProgress, RequestState, RuntimeHandle, SessionState, SourceFormat,
};
use std::{
    mem::{align_of, size_of},
    panic::{AssertUnwindSafe, catch_unwind},
};
fn guard(engine: u64, body: impl FnOnce() -> Result<(), u32>) -> u32 {
    // Retain the panic context before entering the body. Containment must not
    // depend on acquiring the process registry again during an unwind.
    let context = if engine == 0 {
        None
    } else {
        match registry::host(engine) {
            Ok(host) => Some(host),
            Err(code) => return code,
        }
    };
    match catch_unwind(AssertUnwindSafe(body)) {
        Ok(Ok(())) => STATUS_OK,
        Ok(Err(code)) => code,
        Err(_) => {
            if let Some(host) = context {
                registry::poison(&host);
            }
            STATUS_INTERNAL
        }
    }
}
unsafe fn output<'a, T: Default>(pointer: *mut T, bytes: u64) -> Result<&'a mut T, u32> {
    if pointer.is_null()
        || bytes != size_of::<T>() as u64
        || !pointer.addr().is_multiple_of(align_of::<T>())
    {
        return Err(STATUS_INVALID_BUFFER);
    }
    // SAFETY: the documented caller precondition supplies this exact live,
    // aligned, writable, exclusive record for the duration of the call.
    unsafe {
        pointer.write(T::default());
        Ok(&mut *pointer)
    }
}
unsafe fn input(pointer: *const u8, bytes: u64, maximum: u32) -> Result<Vec<u8>, u32> {
    if pointer.is_null() || bytes == 0 || bytes > u64::from(maximum) || bytes > isize::MAX as u64 {
        return Err(STATUS_INVALID_BUFFER);
    }
    // SAFETY: caller guarantees the validated range is readable and live.
    // Copy before return; no worker retains caller memory.
    Ok(unsafe { std::slice::from_raw_parts(pointer, bytes as usize) }.to_vec())
}
macro_rules! simple {
    ($name:ident($engine:ident $(,$arg:ident:$type:ty)*),$body:expr)=>{
        #[unsafe(no_mangle)]
        pub extern "C" fn $name($engine:u64,$($arg:$type),*)->u32 {guard($engine,||$body)}
    }
}
/// # Safety
/// `output` must satisfy the generated header's live record preconditions.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn arktrace_abi_identity(out: *mut AbiIdentity, bytes: u64) -> u32 {
    guard(0, || {
        let output = unsafe { output(out, bytes) }?;
        *output = AbiIdentity {
            struct_size: size_of::<AbiIdentity>() as u32,
            abi_version: ABI_VERSION,
            capabilities: if cfg!(target_os = "macos") {
                u64::from(CAP_MACOS_ENGINE | CAP_COLD_JSON | CAP_VIEWPORT_RECORDS)
            } else {
                0
            } | if cfg!(feature = "process-fixtures") {
                u64::from(CAP_DEVELOPMENT_FIXTURES)
            } else {
                0
            },
            contract_digest: CONTRACT_DIGEST,
        };
        Ok(())
    })
}
unsafe fn create(
    in_ptr: *const u8,
    in_bytes: u64,
    out: *mut u64,
    out_bytes: u64,
    fixture: bool,
) -> u32 {
    guard(0, || {
        let out = unsafe { output(out, out_bytes) }?;
        let data = unsafe { input(in_ptr, in_bytes, MAXIMUM_CONFIG_BYTES) }?;
        *out = registry::create(model::decode(&data)?, fixture)?;
        Ok(())
    })
}
/// # Safety
/// Input/output storage must be valid, live, correctly sized and disjoint.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn arktrace_engine_create(
    p: *const u8,
    n: u64,
    out: *mut u64,
    bytes: u64,
) -> u32 {
    unsafe { create(p, n, out, bytes, false) }
}
/// # Safety
/// Same record/buffer preconditions as `arktrace_engine_create`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn arktrace_engine_create_fixture(
    p: *const u8,
    n: u64,
    out: *mut u64,
    bytes: u64,
) -> u32 {
    unsafe { create(p, n, out, bytes, true) }
}
simple!(arktrace_engine_drain(engine), {
    let host = registry::host(engine)?;
    #[cfg(target_os = "macos")]
    host.engine.start_drain();
    #[cfg(not(target_os = "macos"))]
    let _ = host;
    Ok(())
});
simple!(
    arktrace_engine_release(engine),
    registry::release_engine(engine)
);
/// # Safety
/// Output must be a live writable `uint32_t` record of exactly four bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn arktrace_engine_drain_status(
    engine: u64,
    out: *mut u32,
    bytes: u64,
) -> u32 {
    guard(engine, || {
        let out = unsafe { output(out, bytes) }?;
        let host = registry::host(engine)?;
        #[cfg(target_os = "macos")]
        {
            *out = match host.engine.drain_status() {
                DrainStatus::Running => DRAIN_RUNNING,
                DrainStatus::Draining => DRAIN_DRAINING,
                DrainStatus::Drained => DRAIN_DRAINED,
            };
            Ok(())
        }
        #[cfg(not(target_os = "macos"))]
        {
            let _ = (out, host);
            Err(STATUS_UNSUPPORTED_HOST)
        }
    })
}
fn timeout(ms: u32) -> Result<std::time::Duration, u32> {
    if !(1..=300_000).contains(&ms) {
        return Err(STATUS_INVALID_INPUT);
    }
    Ok(std::time::Duration::from_millis(u64::from(ms)))
}
/// # Safety
/// Output is a live, aligned writable uint64_t of exactly eight bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn arktrace_engine_retained_result_bytes(
    engine: u64,
    out: *mut u64,
    bytes: u64,
) -> u32 {
    guard(engine, || {
        let out = unsafe { output(out, bytes) }?;
        let host = registry::host(engine)?;
        #[cfg(target_os = "macos")]
        {
            *out = host.engine.retained_result_bytes() as u64;
            Ok(())
        }
        #[cfg(not(target_os = "macos"))]
        {
            let _ = (out, host);
            Err(STATUS_UNSUPPORTED_HOST)
        }
    })
}
/// # Safety
/// Source UTF-8 and output record satisfy the header buffer preconditions.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn arktrace_session_open(
    engine: u64,
    p: *const u8,
    n: u64,
    format: u32,
    ms: u32,
    out: *mut OpenTicket,
    bytes: u64,
) -> u32 {
    guard(engine, || {
        let out = unsafe { output(out, bytes) }?;
        let data = unsafe { input(p, n, MAXIMUM_PATH_BYTES) }?;
        let source = String::from_utf8(data).map_err(|_| STATUS_INVALID_INPUT)?;
        if source.contains('\0') || !(1..=2).contains(&format) {
            return Err(STATUS_INVALID_INPUT);
        }
        let timeout = timeout(ms)?;
        let host = registry::host(engine)?;
        host.active()?;
        #[cfg(target_os = "macos")]
        {
            let ticket = host
                .engine
                .open(
                    source.into(),
                    if format == 1 {
                        SourceFormat::Htrace
                    } else {
                        SourceFormat::Systrace
                    },
                    timeout,
                )
                .map_err(registry::failure)?;
            *out = OpenTicket {
                struct_size: size_of::<OpenTicket>() as u32,
                reserved: 0,
                session: ticket.session.raw(),
                request: ticket.request.raw(),
            };
            Ok(())
        }
        #[cfg(not(target_os = "macos"))]
        {
            let _ = (source, timeout, host, out);
            Err(STATUS_UNSUPPORTED_HOST)
        }
    })
}
/// # Safety
/// Output must satisfy the header's exact record size/alignment contract.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn arktrace_session_poll(
    engine: u64,
    session: u64,
    out: *mut SessionStatus,
    bytes: u64,
) -> u32 {
    guard(engine, || {
        let out = unsafe { output(out, bytes) }?;
        let host = registry::host(engine)?;
        #[cfg(target_os = "macos")]
        {
            let status = host
                .engine
                .session_status(RuntimeHandle::from_raw(session))
                .map_err(registry::failure)?;
            let (failure_present, code, stage, retryable) =
                registry::public_fields(status.close_failure);
            *out = SessionStatus {
                struct_size: size_of::<SessionStatus>() as u32,
                state: match status.state {
                    SessionState::Opening => SESSION_OPENING,
                    SessionState::Ready => SESSION_READY,
                    SessionState::Cancelling => SESSION_CANCELLING,
                    SessionState::Closing => SESSION_CLOSING,
                    SessionState::Failed => SESSION_FAILED,
                    SessionState::Closed => SESSION_CLOSED,
                },
                resources_closed: u32::from(status.resources_closed),
                failure_present,
                code,
                stage,
                retryable,
                reserved: 0,
            };
            Ok(())
        }
        #[cfg(not(target_os = "macos"))]
        {
            let _ = (out, host, session);
            Err(STATUS_UNSUPPORTED_HOST)
        }
    })
}
simple!(arktrace_session_close(engine, session: u64), {
    let host = registry::host(engine)?;
    #[cfg(target_os = "macos")]
    return host
        .engine
        .close(RuntimeHandle::from_raw(session))
        .map_err(registry::failure);
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (host, session);
        Err(STATUS_UNSUPPORTED_HOST)
    }
});
simple!(arktrace_session_release(engine, session: u64), {
    let host = registry::host(engine)?;
    #[cfg(target_os = "macos")]
    return host
        .engine
        .release_session(RuntimeHandle::from_raw(session))
        .map_err(registry::failure);
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (host, session);
        Err(STATUS_UNSUPPORTED_HOST)
    }
});
/// # Safety
/// Closed UTF-8 input/output record are live, aligned, sized and disjoint.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn arktrace_request_submit(
    engine: u64,
    session: u64,
    p: *const u8,
    n: u64,
    ms: u32,
    out: *mut u64,
    bytes: u64,
) -> u32 {
    guard(engine, || {
        let out = unsafe { output(out, bytes) }?;
        let data = unsafe { input(p, n, MAXIMUM_REQUEST_BYTES) }?;
        let operation: model::Operation = model::decode(&data)?;
        operation.validate()?;
        let timeout = timeout(ms)?;
        let host = registry::host(engine)?;
        host.active()?;
        #[cfg(target_os = "macos")]
        {
            *out = host
                .engine
                .submit(
                    RuntimeHandle::from_raw(session),
                    operation.native(),
                    timeout,
                )
                .map_err(registry::failure)?
                .raw();
            Ok(())
        }
        #[cfg(not(target_os = "macos"))]
        {
            let _ = (operation, timeout, host, out, session);
            Err(STATUS_UNSUPPORTED_HOST)
        }
    })
}
/// # Safety
/// Output record is live/writable and satisfies the generated header layout.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn arktrace_request_poll(
    engine: u64,
    request: u64,
    out: *mut PollStatus,
    bytes: u64,
) -> u32 {
    guard(engine, || {
        let out = unsafe { output(out, bytes) }?;
        let host = registry::host(engine)?;
        #[cfg(target_os = "macos")]
        {
            let status = host
                .engine
                .poll(RuntimeHandle::from_raw(request))
                .map_err(registry::failure)?;
            let progress = match status.progress {
                None => 0,
                Some(EngineProgress::SourceSnapshot) => PROGRESS_SOURCE_SNAPSHOT,
                Some(EngineProgress::ParserIdentity) => PROGRESS_PARSER_IDENTITY,
                Some(EngineProgress::Parsing) => PROGRESS_PARSING,
                Some(EngineProgress::Indexing(_)) => PROGRESS_INDEXING,
                Some(EngineProgress::Validating) => PROGRESS_VALIDATING,
                Some(EngineProgress::Publishing) => PROGRESS_PUBLISHING,
                Some(EngineProgress::OpeningDatabase) => PROGRESS_OPENING_DATABASE,
                Some(EngineProgress::Ready) => PROGRESS_READY,
            };
            let (failure_present, code, stage, retryable) = registry::public_fields(status.failure);
            *out = PollStatus {
                struct_size: size_of::<PollStatus>() as u32,
                state: match status.state {
                    RequestState::Queued => REQUEST_QUEUED,
                    RequestState::Running => REQUEST_RUNNING,
                    RequestState::Cancelling => REQUEST_CANCELLING,
                    RequestState::Succeeded => REQUEST_SUCCEEDED,
                    RequestState::Failed => REQUEST_FAILED,
                },
                session: status.session.raw(),
                progress,
                failure_present,
                code,
                stage,
                retryable,
                reserved: 0,
            };
            Ok(())
        }
        #[cfg(not(target_os = "macos"))]
        {
            let _ = (out, host, request);
            Err(STATUS_UNSUPPORTED_HOST)
        }
    })
}
simple!(arktrace_request_cancel(engine, request: u64), {
    let host = registry::host(engine)?;
    #[cfg(target_os = "macos")]
    return host
        .engine
        .cancel(RuntimeHandle::from_raw(request))
        .map_err(registry::failure);
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (host, request);
        Err(STATUS_UNSUPPORTED_HOST)
    }
});
simple!(arktrace_request_release(engine, request: u64), {
    let host = registry::host(engine)?;
    #[cfg(target_os = "macos")]
    return host
        .engine
        .release_request(RuntimeHandle::from_raw(request))
        .map_err(registry::failure);
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (host, request);
        Err(STATUS_UNSUPPORTED_HOST)
    }
});
#[cfg(target_os = "macos")]
fn view(owner: u64, r: &registry::ResultOwner) -> ResultView {
    ResultView {
        struct_size: size_of::<ResultView>() as u32,
        kind: r.kind,
        owner,
        data: r.data.bytes().as_ptr(),
        length: r.data.bytes().len() as u64,
        retained_bytes: r.data.retained_bytes() as u64,
    }
}
/// # Safety
/// Output is valid; returned view lives until its Rust owner is released.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn arktrace_result_acquire(
    engine: u64,
    request: u64,
    out: *mut ResultView,
    bytes: u64,
) -> u32 {
    guard(engine, || {
        let out = unsafe { output(out, bytes) }?;
        let host = registry::host(engine)?;
        #[cfg(target_os = "macos")]
        {
            let result = host.acquire(request)?;
            let id = registry::retain(result.clone())?;
            *out = view(id, &result);
            Ok(())
        }
        #[cfg(not(target_os = "macos"))]
        {
            let _ = (out, host, request);
            Err(STATUS_UNSUPPORTED_HOST)
        }
    })
}
/// # Safety
/// Keep owner live while reading the view; output is a valid exact record.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn arktrace_result_view(owner: u64, out: *mut ResultView, bytes: u64) -> u32 {
    guard(0, || {
        let out = unsafe { output(out, bytes) }?;
        let result = registry::owner(owner)?;
        #[cfg(target_os = "macos")]
        {
            *out = view(owner, &result);
            Ok(())
        }
        #[cfg(not(target_os = "macos"))]
        {
            let _ = (out, result.kind);
            Err(STATUS_UNSUPPORTED_HOST)
        }
    })
}
/// # Safety
/// Output is a valid writable uint64_t; cloned owner must later be released.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn arktrace_result_clone(owner: u64, out: *mut u64, bytes: u64) -> u32 {
    guard(0, || {
        let out = unsafe { output(out, bytes) }?;
        *out = registry::retain(registry::owner(owner)?)?;
        Ok(())
    })
}
#[unsafe(no_mangle)]
pub extern "C" fn arktrace_result_release(owner: u64) -> u32 {
    guard(0, || registry::release_owner(owner))
}
#[cfg(target_os = "macos")]
fn snapshot_view(owner: u64, r: &registry::ResultOwner) -> Result<SnapshotView, u32> {
    let scene = r.data.snapshot().ok_or(STATUS_UNSUPPORTED_OPERATION)?;
    Ok(SnapshotView {
        struct_size: size_of::<SnapshotView>() as u32,
        format_version: 1,
        owner,
        viewport: scene.viewport,
        tracks: scene.tracks.as_ptr(),
        track_count: scene.tracks.len() as u64,
        primitives: scene.primitives.as_ptr(),
        primitive_count: scene.primitives.len() as u64,
        quality: scene.quality.as_ptr(),
        quality_count: scene.quality.len() as u64,
        strings: scene.strings.as_ptr(),
        string_bytes: scene.strings.len() as u64,
        retained_bytes: r.data.retained_bytes() as u64,
        quality_status: scene.quality_status,
        reserved: 0,
    })
}
/// # Safety
/// All record arrays/string bytes are borrowed until `owner` is released.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn arktrace_snapshot_acquire(
    engine: u64,
    request: u64,
    out: *mut SnapshotView,
    bytes: u64,
) -> u32 {
    guard(engine, || {
        let out = unsafe { output(out, bytes) }?;
        let host = registry::host(engine)?;
        #[cfg(target_os = "macos")]
        {
            let result = host.acquire(request)?;
            let mut view = snapshot_view(0, &result)?;
            let id = registry::retain(result)?;
            view.owner = id;
            *out = view;
            Ok(())
        }
        #[cfg(not(target_os = "macos"))]
        {
            let _ = (out, host, request);
            Err(STATUS_UNSUPPORTED_HOST)
        }
    })
}
/// # Safety
/// Output/owner follow the same retained-memory preconditions as acquire.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn arktrace_snapshot_view(
    owner: u64,
    out: *mut SnapshotView,
    bytes: u64,
) -> u32 {
    guard(0, || {
        let out = unsafe { output(out, bytes) }?;
        let result = registry::owner(owner)?;
        #[cfg(target_os = "macos")]
        {
            *out = snapshot_view(owner, &result)?;
            Ok(())
        }
        #[cfg(not(target_os = "macos"))]
        {
            let _ = (out, result.kind);
            Err(STATUS_UNSUPPORTED_HOST)
        }
    })
}
simple!(arktrace_fixture_panic(engine), {
    let host = registry::host(engine)?;
    host.active()?;
    #[cfg(feature = "process-fixtures")]
    panic!("controlled FFI panic containment");
    #[cfg(not(feature = "process-fixtures"))]
    Err(STATUS_UNSUPPORTED_OPERATION)
});
