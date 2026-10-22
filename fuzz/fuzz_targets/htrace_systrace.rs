#![no_main]

use libfuzzer_sys::fuzz_target;

// Byte 0 selects the session format (1 = htrace, 2 = systrace). The rest is
// the source path. File-byte parsing stays in the pinned TraceStreamer process.
fuzz_target!(|data: &[u8]| {
    let _ = arktrace_ffi::fuzz_admit_session_source(data);
});
