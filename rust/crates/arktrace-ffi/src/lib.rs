//! Reviewed C ABI. Engine threads retain all parser/SQLite/cleanup work.
mod abi_records;
#[allow(unsafe_code)]
mod exports;
mod model;
mod registry;
pub use abi_records::*;
pub use exports::*;
#[cfg(feature = "fuzzing")]
pub use model::{fuzz_admit_session_source, fuzz_decode_engine_config, fuzz_decode_request};
