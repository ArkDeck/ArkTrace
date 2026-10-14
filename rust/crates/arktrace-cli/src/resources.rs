use crate::public_error::{Code, PublicError, Stage, host_error};
use arktrace_contract::TraceParserIdentity;
use arktrace_platform::{
    CodeTrustPolicy, HeldFile, IoBudget, MappedExecutable, OwnedDirectory, ProcessError,
    VerifiedExecutable,
};
use serde::Deserialize;
use std::path::{Path, PathBuf};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RuntimeManifest {
    format_version: u32,
    product_version: String,
    architecture: String,
    development: bool,
    #[serde(rename = "helperSHA256")]
    helper_sha256: String,
    #[serde(rename = "unsignedParserSHA256")]
    unsigned_parser_sha256: String,
    parser: TraceParserIdentity,
    maximum_source_bytes: u64,
    maximum_database_bytes: u64,
    storage_namespace: String,
}
pub(crate) struct Resources {
    pub helper: VerifiedExecutable,
    pub parser: VerifiedExecutable,
    pub identity: TraceParserIdentity,
    pub maximum_source_bytes: u64,
    pub maximum_database_bytes: u64,
    pub storage_namespace: String,
}
fn unavailable() -> PublicError {
    PublicError::new(Code::InternalError, Stage::Preparing)
}
fn mismatch() -> PublicError {
    PublicError::new(Code::TraceStreamerIdentityMismatch, Stage::Preparing)
}
fn process_error(error: ProcessError, fallback: PublicError) -> PublicError {
    match error {
        ProcessError::Host(error) => host_error(error, fallback),
        ProcessError::Cancelled => PublicError::new(Code::Cancelled, fallback.stage()),
        ProcessError::DeadlineExceeded => PublicError::new(Code::QueryTimeout, fallback.stage()),
        ProcessError::CleanupFailed => PublicError::cleanup(fallback.stage(), false),
        _ => fallback,
    }
}
#[cfg(target_os = "macos")]
fn policy(identifier: &str) -> Result<CodeTrustPolicy, PublicError> {
    Ok(if cfg!(feature = "development-resources") {
        CodeTrustPolicy::DevelopmentPinned
    } else {
        CodeTrustPolicy::DeveloperId {
            team_identifier: "8AQTYW5FKR".to_owned(),
            code_identifier: identifier.to_owned(),
        }
    })
}
/// Windows: every image is pinned by its whole SHA-256 (manifest), and a
/// release build additionally requires an Authenticode signature by the
/// publisher fixed at build time (`ARKTRACE_WINDOWS_PUBLISHER`; user ruling
/// (b), never a rotating leaf hash). A release build without one refuses.
#[cfg(windows)]
fn policy(_identifier: &str) -> Result<CodeTrustPolicy, PublicError> {
    if cfg!(feature = "development-resources") {
        return Ok(CodeTrustPolicy::DevelopmentPinned);
    }
    option_env!("ARKTRACE_WINDOWS_PUBLISHER")
        .filter(|publisher| !publisher.is_empty())
        .map(|publisher| CodeTrustPolicy::AuthenticodePublisher {
            publisher: publisher.to_owned(),
        })
        .ok_or_else(unavailable)
}
#[cfg(target_os = "macos")]
mod layout {
    pub const ARCHITECTURE: &str = "arm64";
    pub const RUNTIME_MANIFEST: &str = "Resources/ArkTraceRust/runtime.json";
    pub const HELPER: &str = "Helpers/arktrace-host-process";
    pub const PARSER: &str = "Helpers/trace_streamer";
    pub const HELPER_SNAPSHOT: &str = "host-process";
    pub const PARSER_SNAPSHOT: &str = "trace-streamer";
    pub const PARSER_MANIFEST: &[u8] =
        include_bytes!("../../../../ThirdParty/TraceStreamer/macx/manifest.json");
}
/// Closed Windows installation layout, relative to the directory holding
/// `arktrace.exe` (docs/CLI.md "Windows installation layout"). Images keep
/// `.exe` names: `CreateProcessW` would otherwise append one.
#[cfg(windows)]
mod layout {
    pub const ARCHITECTURE: &str = "x86_64";
    pub const RUNTIME_MANIFEST: &str = "resources/ArkTraceRust/runtime.json";
    pub const HELPER: &str = "resources/Helpers/arktrace-host-process.exe";
    pub const PARSER: &str = "resources/Helpers/trace_streamer.exe";
    pub const HELPER_SNAPSHOT: &str = "host-process.exe";
    pub const PARSER_SNAPSHOT: &str = "trace-streamer.exe";
    pub const PARSER_MANIFEST: &[u8] =
        include_bytes!("../../../../ThirdParty/TraceStreamer/windows-x86_64/manifest.json");
}
fn fixed_identity() -> Result<TraceParserIdentity, PublicError> {
    let value: serde_json::Value =
        serde_json::from_slice(layout::PARSER_MANIFEST).map_err(|_| unavailable())?;
    let mut fields = serde_json::Map::new();
    for key in [
        "name",
        "reportedVersion",
        "binarySHA256",
        "upstreamRepository",
        "upstreamRevision",
        "architecture",
        "adapterVersion",
        "buildRecipeVersion",
    ] {
        fields.insert(
            key.to_owned(),
            value.get(key).ok_or_else(unavailable)?.clone(),
        );
    }
    // The manifest names the file; the identity carries the parser's logical
    // name (`trace_streamer` on both platforms, as every envelope reports it).
    if cfg!(windows) && value.get("name") == Some(&serde_json::json!("trace_streamer.exe")) {
        fields.insert("name".to_owned(), serde_json::json!("trace_streamer"));
    }
    serde_json::from_value(serde_json::Value::Object(fields)).map_err(|_| unavailable())
}
/// The sealed `.app` bundle holding `Contents/MacOS/arktrace`; its contents
/// are the resource root.
#[cfg(target_os = "macos")]
fn bundle(image: &MappedExecutable) -> Result<(PathBuf, PathBuf), PublicError> {
    let executable = image.path();
    let macos = executable.parent().ok_or_else(unavailable)?;
    let contents = macos.parent().ok_or_else(unavailable)?;
    let bundle = contents.parent().ok_or_else(unavailable)?;
    if executable.file_name() != Some(std::ffi::OsStr::new("arktrace"))
        || macos.file_name() != Some(std::ffi::OsStr::new("MacOS"))
        || contents.file_name() != Some(std::ffi::OsStr::new("Contents"))
        || bundle.extension() != Some(std::ffi::OsStr::new("app"))
    {
        return Err(unavailable());
    }
    image
        .verify_bundle(bundle, &policy("com.arktrace.ArkTrace.CLI")?)
        .map_err(|_| unavailable())?;
    Ok((bundle.to_owned(), contents.to_owned()))
}
/// The installation directory holding `arktrace.exe`; it is also the
/// resource root.
#[cfg(windows)]
fn bundle(image: &MappedExecutable) -> Result<(PathBuf, PathBuf), PublicError> {
    let executable = image.path();
    let root = executable.parent().ok_or_else(unavailable)?;
    if !executable
        .file_name()
        .is_some_and(|name| name.eq_ignore_ascii_case("arktrace.exe"))
    {
        return Err(unavailable());
    }
    image
        .verify_bundle(root, &policy("arktrace")?)
        .map_err(|_| unavailable())?;
    Ok((root.to_owned(), root.to_owned()))
}
pub(crate) fn load(
    image: &MappedExecutable,
    owner: &OwnedDirectory,
    override_path: Option<&Path>,
    budget: &IoBudget,
) -> Result<Resources, PublicError> {
    let (app, contents) = bundle(image)?;
    let manifest_file = HeldFile::open_explicit_source(&contents.join(layout::RUNTIME_MANIFEST))
        .map_err(|_| unavailable())?;
    let manifest_budget = IoBudget {
        maximum_bytes: 16384,
        ..budget.clone()
    };
    let manifest: RuntimeManifest = serde_json::from_slice(
        &manifest_file
            .read_bounded(&manifest_budget)
            .map_err(|e| host_error(e, unavailable()))?,
    )
    .map_err(|_| unavailable())?;
    let mut fixed = fixed_identity()?;
    let expected_unsigned = fixed.binary_sha256.clone();
    fixed.binary_sha256 = manifest.parser.binary_sha256.clone();
    if manifest.format_version != 1
        || manifest.product_version != env!("CARGO_PKG_VERSION")
        || manifest.architecture != layout::ARCHITECTURE
        || manifest.development != cfg!(feature = "development-resources")
        || manifest.unsigned_parser_sha256 != expected_unsigned
        || manifest.parser != fixed
        || manifest.parser.validate().is_err()
        || manifest.maximum_source_bytes == 0
        || manifest.maximum_source_bytes > i64::MAX as u64
        || manifest.maximum_database_bytes == 0
        || manifest.maximum_database_bytes > i64::MAX as u64
        || !manifest.storage_namespace.starts_with("com.arktrace.")
        || manifest.storage_namespace.len() > 128
        || !manifest
            .storage_namespace
            .bytes()
            .all(|v| v.is_ascii_alphanumeric() || b".-_".contains(&v))
    {
        return Err(mismatch());
    }
    let helper_source = HeldFile::open_explicit_source(&contents.join(layout::HELPER))
        .map_err(|_| unavailable())?;
    let parser_path = override_path
        .map(Path::to_owned)
        .unwrap_or_else(|| contents.join(layout::PARSER));
    let parser_source = HeldFile::open_explicit_source(&parser_path)
        .map_err(|_| PublicError::new(Code::TraceStreamerUnavailable, Stage::Preparing))?;
    let parser_sha = parser_source
        .facts(budget)
        .map_err(|e| host_error(e, mismatch()))?
        .sha256;
    let explicit_development = override_path.is_some() && parser_sha == expected_unsigned;
    let mut identity = manifest.parser;
    if explicit_development {
        identity.binary_sha256 = expected_unsigned;
    }
    if parser_sha != identity.binary_sha256 {
        return Err(mismatch());
    }
    let (helper_snapshot, _) = owner
        .directory()
        .copy_snapshot(&helper_source, layout::HELPER_SNAPSHOT, true, budget)
        .map_err(|e| host_error(e, unavailable()))?;
    let (parser_snapshot, _) = owner
        .directory()
        .copy_snapshot(&parser_source, layout::PARSER_SNAPSHOT, true, budget)
        .map_err(|e| host_error(e, mismatch()))?;
    let helper = VerifiedExecutable::verify(
        helper_snapshot,
        &manifest.helper_sha256,
        policy("com.arktrace.ArkTrace.host-process")?,
        budget,
    )
    .map_err(|e| process_error(e, unavailable()))?;
    let parser = VerifiedExecutable::verify(
        parser_snapshot,
        &identity.binary_sha256,
        if explicit_development {
            CodeTrustPolicy::DevelopmentPinned
        } else {
            policy("trace_streamer")?
        },
        budget,
    )
    .map_err(|e| process_error(e, mismatch()))?;
    manifest_file.verify().map_err(|_| unavailable())?;
    image
        .verify_bundle(&app, &policy("com.arktrace.ArkTrace.CLI")?)
        .map_err(|_| unavailable())?;
    budget.check().map_err(|e| host_error(e, unavailable()))?;
    Ok(Resources {
        helper,
        parser,
        identity,
        maximum_source_bytes: manifest.maximum_source_bytes,
        maximum_database_bytes: manifest.maximum_database_bytes,
        storage_namespace: manifest.storage_namespace,
    })
}
