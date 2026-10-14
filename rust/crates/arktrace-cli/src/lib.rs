//! Shared command composition and the migration executable adapter.
pub mod arguments;
mod driver;
mod event_query;
mod machine;
mod public_error;
#[cfg(any(target_os = "macos", windows))]
mod resources;
pub use driver::run;
pub use event_query::EventQuery;
pub use machine::{CommandError, CommandLimits, OutputFormat, ToolIdentity};
#[cfg(any(target_os = "macos", windows))]
pub use machine::{DirectoryCommand, execute_no_cache, execute_no_cache_formatted};
