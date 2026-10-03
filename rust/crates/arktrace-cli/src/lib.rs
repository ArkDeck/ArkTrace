//! Shared command composition and the migration executable adapter.
pub mod arguments;
mod driver;
mod event_query;
mod machine;
mod public_error;
#[cfg(target_os = "macos")]
mod resources;
pub use driver::run;
pub use event_query::EventQuery;
pub use machine::{CommandError, CommandLimits, OutputFormat, ToolIdentity};
#[cfg(target_os = "macos")]
pub use machine::{DirectoryCommand, execute_no_cache, execute_no_cache_formatted};
