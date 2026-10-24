#[cfg(any(target_os = "macos", windows, test))]
use arktrace_platform::CancellationToken;
use serde::Serialize;
#[cfg(any(target_os = "macos", windows, test))]
use std::{
    io::{self, Write},
    time::Instant,
};

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
pub enum CommandError {
    InvalidArguments,
    InvalidMachineValue,
    OutputLimitExceeded,
    Cancelled,
    DeadlineExceeded,
    #[cfg(any(target_os = "macos", windows))]
    Engine(arktrace_engine::EngineError),
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum OutputFormat {
    Machine { pretty: bool },
    Human,
}
impl std::fmt::Display for CommandError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for CommandError {}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CommandLimits {
    pub timeout_ms: u64,
    pub max_rows: usize,
    pub max_events: usize,
    pub max_output_bytes: usize,
}
impl CommandLimits {
    pub fn validate(&self) -> Result<(), CommandError> {
        if !(100..=120_000).contains(&self.timeout_ms)
            || !(1..=100_000).contains(&self.max_rows)
            || !(1..=100_000).contains(&self.max_events)
            || !(1024..=67_108_864).contains(&self.max_output_bytes)
        {
            return Err(CommandError::InvalidArguments);
        }
        Ok(())
    }
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ToolIdentity {
    name: &'static str,
    version: &'static str,
    build_revision: String,
}
fn digest(value: &str, length: usize) -> bool {
    value.len() == length
        && value
            .bytes()
            .all(|v| v.is_ascii_digit() || (b'a'..=b'f').contains(&v))
}
impl ToolIdentity {
    /// The composition caller must obtain this digest from its verified
    /// executable. Git revision and the old Swift artifact are not substitutes.
    pub fn from_executable_sha256(build_revision: String) -> Result<Self, CommandError> {
        if !digest(&build_revision, 64) {
            return Err(CommandError::InvalidMachineValue);
        }
        Ok(Self {
            name: "arktrace",
            version: env!("CARGO_PKG_VERSION"),
            build_revision,
        })
    }
}
#[cfg(any(target_os = "macos", windows, test))]
struct BoundedWriter<'a> {
    bytes: Vec<u8>,
    maximum: usize,
    deadline: Instant,
    cancellation: &'a CancellationToken,
    failure: Option<CommandError>,
}
#[cfg(any(target_os = "macos", windows, test))]
impl Write for BoundedWriter<'_> {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        let error = if self.cancellation.is_cancelled() {
            Some(CommandError::Cancelled)
        } else if Instant::now() >= self.deadline {
            Some(CommandError::DeadlineExceeded)
        } else if bytes.len() > self.maximum.saturating_sub(self.bytes.len()) {
            Some(CommandError::OutputLimitExceeded)
        } else {
            None
        };
        if let Some(error) = error {
            self.failure = Some(error);
            return Err(io::Error::other("bounded machine output"));
        }
        self.bytes.extend_from_slice(bytes);
        Ok(bytes.len())
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}
#[cfg(test)]
fn encode(
    value: &impl Serialize,
    maximum: usize,
    deadline: Instant,
    cancellation: &CancellationToken,
) -> Result<Vec<u8>, CommandError> {
    encode_formatted(value, maximum, deadline, cancellation, false)
}
#[cfg(any(target_os = "macos", windows, test))]
pub(crate) fn encode_formatted(
    value: &impl Serialize,
    maximum: usize,
    deadline: Instant,
    cancellation: &CancellationToken,
    pretty: bool,
) -> Result<Vec<u8>, CommandError> {
    let mut writer = BoundedWriter {
        bytes: Vec::new(),
        maximum,
        deadline,
        cancellation,
        failure: None,
    };
    let outcome = if pretty {
        serde_json::to_writer_pretty(&mut writer, value)
    } else {
        serde_json::to_writer(&mut writer, value)
    };
    if outcome.is_err() {
        return Err(writer.failure.unwrap_or(CommandError::InvalidMachineValue));
    }
    writer
        .write_all(b"\n")
        .map_err(|_| writer.failure.unwrap_or(CommandError::InvalidMachineValue))?;
    Ok(writer.bytes)
}

#[cfg(any(target_os = "macos", windows))]
mod macos;
#[cfg(any(target_os = "macos", windows))]
pub use macos::{
    DOCTOR_CHECKS, DirectoryCommand, DoctorStatus, LicenseFileValue, LicensesValue,
    RustLicenseValue, WindowsLicenseValue, doctor_document, execute_no_cache,
    execute_no_cache_formatted, licenses_document,
};

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;
    #[test]
    fn pretty_whitespace_and_newline_share_the_same_complete_output_budget() {
        let token = CancellationToken::default();
        let deadline = Instant::now() + Duration::from_secs(1);
        let value = serde_json::json!({"nested":{"value":"\u{2028}\n"}});
        let pretty = encode_formatted(&value, 1024, deadline, &token, true).unwrap();
        let compact = encode(&value, 1024, deadline, &token).unwrap();
        assert_eq!(
            serde_json::from_slice::<serde_json::Value>(&pretty).unwrap(),
            value
        );
        assert!(pretty.len() > compact.len());
        assert_eq!(
            encode_formatted(&value, pretty.len() - 1, deadline, &token, true),
            Err(CommandError::OutputLimitExceeded)
        );
        assert!(pretty.ends_with(b"\n"));
    }
    #[test]
    fn whole_output_budget_includes_json_escaping_and_newline() {
        let token = CancellationToken::default();
        let deadline = Instant::now() + Duration::from_secs(1);
        let value = "\"\n".repeat(100);
        let bytes = encode(&value, 1000, deadline, &token).unwrap();
        assert!(bytes.len() > value.len());
        assert_eq!(
            encode(&value, bytes.len() - 1, deadline, &token),
            Err(CommandError::OutputLimitExceeded)
        );
        assert_eq!(
            encode(&value, bytes.len(), deadline, &token).unwrap(),
            bytes
        );
        token.cancel();
        assert_eq!(
            encode(&value, 1000, deadline, &token),
            Err(CommandError::Cancelled)
        );
        assert_eq!(
            encode(
                &value,
                1000,
                Instant::now() - Duration::from_secs(1),
                &CancellationToken::default()
            ),
            Err(CommandError::DeadlineExceeded)
        );
    }
    #[test]
    fn identity_and_limits_reject_path_or_oversized_echo() {
        assert!(ToolIdentity::from_executable_sha256("/private/raw.trace".to_owned()).is_err());
        let valid = CommandLimits {
            timeout_ms: 30000,
            max_rows: 128,
            max_events: 128,
            max_output_bytes: 8388608,
        };
        assert!(valid.validate().is_ok());
        for invalid in [
            CommandLimits {
                timeout_ms: 99,
                ..valid
            },
            CommandLimits {
                max_rows: 100001,
                ..valid
            },
            CommandLimits {
                max_output_bytes: 1023,
                ..valid
            },
            CommandLimits {
                max_events: 0,
                ..valid
            },
        ] {
            assert_eq!(invalid.validate(), Err(CommandError::InvalidArguments));
        }
    }
}
