#![no_main]

use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let _ = arktrace_ffi::fuzz_decode_engine_config(data);
});
