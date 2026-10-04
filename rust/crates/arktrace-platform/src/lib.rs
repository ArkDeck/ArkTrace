//! Native host ports. Domain contracts and GUI/Capture are intentionally absent.
mod budget;
mod continuous_time;
mod error;

pub use budget::{CancellationToken, IoBudget};
pub use continuous_time::ContinuousDeadline;
pub use error::{HostError, HostOperation};

#[cfg(target_os = "macos")]
#[allow(unsafe_code)]
mod macos;
#[cfg(all(target_os = "macos", feature = "process-fixtures"))]
#[doc(hidden)]
pub use macos::process_fixture;
#[cfg(target_os = "macos")]
pub use macos::{
    CliSignalGuard, CliWriteFailure, CodeTrustPolicy, EphemeralLease, FileIdentity, FileSnapshot,
    HeldDirectory, HeldFile, Lease, LeaseMode, MappedExecutable, ProcessBudget, ProcessError,
    ProcessOutcome, ProcessOutputFileBudget, SealedDirectory, SourceFacts, TrustVerdict,
    VerifiedExecutable, run_supervised, supervisor_main, user_temporary_workspace,
};
#[cfg(target_os = "macos")]
pub use macos::{
    OwnedDirectory, OwnerKind, OwnerRecoveryOutcome, OwnerStore, PublishedOwnerEvidence,
    WritableFile,
};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum NativeHost {
    MacOSArm64,
    WindowsX64,
}

pub fn native_host() -> Option<NativeHost> {
    if cfg!(all(target_os = "macos", target_arch = "aarch64")) {
        Some(NativeHost::MacOSArm64)
    } else if cfg!(all(target_os = "windows", target_arch = "x86_64")) {
        Some(NativeHost::WindowsX64)
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn native_runner_matches_the_requested_host() {
        let expected = std::env::var("ARKTRACE_EXPECT_NATIVE_HOST").expect("use run-cargo.py");
        let actual = match native_host() {
            Some(NativeHost::MacOSArm64) => "macos-arm64",
            Some(NativeHost::WindowsX64) => "windows-x64",
            None => "unsupported",
        };
        assert_eq!(actual, expected);
    }
}
