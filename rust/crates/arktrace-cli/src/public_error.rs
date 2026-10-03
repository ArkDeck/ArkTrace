#[cfg(target_os = "macos")]
use crate::CommandError;
pub use arktrace_contract::{Code, PublicError, Stage};
#[cfg(target_os = "macos")]
use arktrace_platform::HostError;

#[cfg(target_os = "macos")]
pub(crate) fn host_error(error: HostError, fallback: PublicError) -> PublicError {
    match error {
        HostError::Cancelled => PublicError::new(Code::Cancelled, fallback.stage()),
        HostError::DeadlineExceeded => PublicError::new(Code::QueryTimeout, fallback.stage()),
        HostError::CleanupFailed => PublicError::cleanup(fallback.stage(), false),
        _ => fallback,
    }
}
#[cfg(target_os = "macos")]
pub(crate) fn command_error(error: CommandError) -> PublicError {
    match error {
        CommandError::InvalidArguments => PublicError::new(Code::InvalidArgument, Stage::Request),
        CommandError::InvalidMachineValue => PublicError::new(Code::InternalError, Stage::Encoding),
        CommandError::OutputLimitExceeded => {
            PublicError::new(Code::OutputLimitExceeded, Stage::Encoding)
        }
        CommandError::Cancelled => PublicError::new(Code::Cancelled, Stage::Encoding),
        CommandError::DeadlineExceeded => PublicError::new(Code::QueryTimeout, Stage::Encoding),
        #[cfg(target_os = "macos")]
        CommandError::Engine(error) => error.public_error(),
    }
}
