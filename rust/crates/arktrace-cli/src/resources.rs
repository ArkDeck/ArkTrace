use crate::public_error::{Code, PublicError, Stage, host_error};
use arktrace_contract::TraceParserIdentity;
#[cfg(windows)]
use arktrace_platform::HeldDirectory;
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
    /// The bundled `doctor --self-test` trace; read only by the self-test,
    /// which verifies its pinned whole SHA-256 first.
    pub self_test_trace: PathBuf,
}
/// Fixtures/traces/zlib.htrace, the reviewed bundled self-test trace.
pub(crate) const SELF_TEST_TRACE_SHA256: &str =
    "eb196eeb30c6b959c23d5e18d159ec946ba664ee8d9bc6f1acc32947b4ff5cfe";
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
    pub const SELF_TEST_TRACE: &str = "Resources/zlib.htrace";
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
    pub const SELF_TEST_TRACE: &str = "resources/zlib.htrace";
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
/// One verified attribution file of the installed `licenses` set.
#[cfg(windows)]
#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct LicenseFile {
    pub owner: String,
    pub license_expression: String,
    pub resource: String,
    pub sha256: String,
    pub byte_count: u64,
}
/// The installed, verified Windows license set: the shared TraceStreamer
/// inventory (as the Swift CLI reports it) plus the Windows-only build tools
/// and statically linked runtime (`windows-license-inventory.json`).
#[cfg(windows)]
pub(crate) struct Licenses {
    pub product_license_bytes: u64,
    pub component_count: usize,
    pub build_tool_count: usize,
    pub files: Vec<LicenseFile>,
    pub windows_build_tool_count: usize,
    pub windows_static_runtime_count: usize,
    pub windows_files: Vec<LicenseFile>,
}
/// Reviewed attribution bytes, embedded at build time; the installed copies
/// under `resources/licenses` must equal them exactly.
#[cfg(windows)]
mod attribution {
    pub const DIRECTORY: &str = "resources/licenses";
    pub const PRODUCT_LICENSE: &[u8] = include_bytes!("../../../../LICENSE");
    pub const NOTICE: &[u8] = include_bytes!("../../../../THIRD_PARTY_NOTICES.md");
    pub const INVENTORY: &[u8] =
        include_bytes!("../../../../ThirdParty/TraceStreamer/license-inventory.json");
    pub const WINDOWS_INVENTORY: &[u8] =
        include_bytes!("../../../../ThirdParty/TraceStreamer/windows-license-inventory.json");
    pub const TOP_LEVEL: [&str; 6] = [
        "LICENSE",
        "LICENSES",
        "LICENSES-windows",
        "THIRD_PARTY_NOTICES.md",
        "license-inventory.json",
        "windows-license-inventory.json",
    ];
}
/// Every `(owner, expression, path, sha, bytes)` an inventory section names,
/// including additional files. Paths must be flat names under `prefix/`.
#[cfg(windows)]
fn inventory_records(
    entries: &[serde_json::Value],
    prefix: &str,
) -> Result<Vec<LicenseFile>, PublicError> {
    let text = |value: &serde_json::Value, key: &str| {
        value
            .get(key)
            .and_then(serde_json::Value::as_str)
            .map(str::to_owned)
            .ok_or_else(unavailable)
    };
    let count = |value: &serde_json::Value, key: &str| {
        value
            .get(key)
            .and_then(serde_json::Value::as_u64)
            .filter(|n| *n > 0)
            .ok_or_else(unavailable)
    };
    let mut records = Vec::new();
    for entry in entries {
        let owner = text(entry, "name")?;
        let license_expression = text(entry, "licenseExpression")?;
        records.push(LicenseFile {
            owner: owner.clone(),
            license_expression: license_expression.clone(),
            resource: text(entry, "licenseFile")?,
            sha256: text(entry, "licenseSHA256")?,
            byte_count: count(entry, "licenseByteCount")?,
        });
        for extra in entry
            .get("additionalLicenseFiles")
            .and_then(serde_json::Value::as_array)
            .map(Vec::as_slice)
            .unwrap_or_default()
        {
            records.push(LicenseFile {
                owner: owner.clone(),
                license_expression: license_expression.clone(),
                resource: text(extra, "path")?,
                sha256: text(extra, "sha256")?,
                byte_count: count(extra, "byteCount")?,
            });
        }
    }
    let flat = |resource: &str| {
        resource
            .strip_prefix(prefix)
            .and_then(|rest| rest.strip_prefix('/'))
            .is_some_and(|name| {
                !name.is_empty()
                    && name != "."
                    && name != ".."
                    && name
                        .bytes()
                        .all(|b| b.is_ascii_alphanumeric() || b"_.+-".contains(&b))
            })
    };
    // One entry per (owner, file): a text may serve several owners (the GPL
    // text of both the GCC build tool and its runtime), but then with one identity.
    let mut owners = std::collections::BTreeSet::new();
    let mut identities = std::collections::BTreeMap::new();
    for record in &records {
        let key = record.resource.to_ascii_lowercase();
        let identity = (record.sha256.clone(), record.byte_count);
        if !flat(&record.resource)
            || !owners.insert((record.owner.clone(), key.clone()))
            || identities
                .insert(key, identity.clone())
                .is_some_and(|known| known != identity)
        {
            return Err(unavailable());
        }
    }
    records.sort_by(|a, b| {
        (a.resource.as_bytes(), a.owner.as_bytes())
            .cmp(&(b.resource.as_bytes(), b.owner.as_bytes()))
    });
    Ok(records)
}
/// Exact membership from the held directory's independent enumeration handle.
/// File and directory opens below also enforce their required native type.
#[cfg(windows)]
fn exact_names(
    directory: &HeldDirectory,
    expected: &[&str],
    budget: &IoBudget,
) -> Result<(), PublicError> {
    let mut actual = Vec::new();
    for name in directory
        .child_names(budget, 256)
        .map_err(|e| host_error(e, unavailable()))?
    {
        actual.push(name.to_str().ok_or_else(unavailable)?.to_ascii_lowercase());
    }
    let mut wanted: Vec<_> = expected.iter().map(|v| v.to_ascii_lowercase()).collect();
    actual.sort();
    wanted.sort();
    if actual == wanted {
        Ok(())
    } else {
        Err(unavailable())
    }
}
#[cfg(windows)]
fn verified_file(
    directory: &HeldDirectory,
    name: &str,
    record: &LicenseFile,
    budget: &IoBudget,
) -> Result<(), PublicError> {
    let file = directory.open_file(name).map_err(|_| unavailable())?;
    let facts = file
        .facts(&IoBudget {
            maximum_bytes: 1024 * 1024,
            ..budget.clone()
        })
        .map_err(|e| host_error(e, unavailable()))?;
    if facts.sha256 != record.sha256 || facts.byte_count != record.byte_count {
        return Err(unavailable());
    }
    file.verify().map_err(|_| unavailable())
}
#[cfg(windows)]
fn exact_bytes(
    directory: &HeldDirectory,
    name: &str,
    expected: &[u8],
    budget: &IoBudget,
) -> Result<(), PublicError> {
    let file = directory.open_file(name).map_err(|_| unavailable())?;
    let bytes = file
        .read_bounded(&IoBudget {
            maximum_bytes: 1024 * 1024,
            ..budget.clone()
        })
        .map_err(|e| host_error(e, unavailable()))?;
    if bytes != expected {
        return Err(unavailable());
    }
    file.verify().map_err(|_| unavailable())
}
/// `licenses`: the installed attribution set beside `arktrace.exe`, each file
/// equal to the reviewed bytes or inventory identity, in an exact closure.
#[cfg(windows)]
pub(crate) fn licenses(
    image: &MappedExecutable,
    budget: &IoBudget,
) -> Result<Licenses, PublicError> {
    let (root, _) = bundle(image)?;
    let base = root.join(attribution::DIRECTORY);
    let held_base = HeldDirectory::open_code_directory(&base).map_err(|_| unavailable())?;
    exact_names(&held_base, &attribution::TOP_LEVEL, budget)?;
    for (name, bytes) in [
        ("LICENSE", attribution::PRODUCT_LICENSE),
        ("THIRD_PARTY_NOTICES.md", attribution::NOTICE),
        ("license-inventory.json", attribution::INVENTORY),
        (
            "windows-license-inventory.json",
            attribution::WINDOWS_INVENTORY,
        ),
    ] {
        exact_bytes(&held_base, name, bytes, budget)?;
    }
    let inventory: serde_json::Value =
        serde_json::from_slice(attribution::INVENTORY).map_err(|_| unavailable())?;
    let windows: serde_json::Value =
        serde_json::from_slice(attribution::WINDOWS_INVENTORY).map_err(|_| unavailable())?;
    let array = |value: &serde_json::Value, key: &str| {
        value
            .get(key)
            .and_then(serde_json::Value::as_array)
            .cloned()
            .ok_or_else(unavailable)
    };
    let components = array(&inventory, "components")?;
    let build_tools = array(&inventory, "buildTools")?;
    let windows_tools = array(&windows, "buildTools")?;
    let static_runtime = array(&windows, "staticRuntime")?;
    let files = inventory_records(
        &[components.clone(), build_tools.clone()].concat(),
        "LICENSES",
    )?;
    let windows_files = inventory_records(
        &[windows_tools.clone(), static_runtime.clone()].concat(),
        "LICENSES-windows",
    )?;
    for (directory, records) in [("LICENSES", &files), ("LICENSES-windows", &windows_files)] {
        let mut names: Vec<&str> = records
            .iter()
            .map(|r| &r.resource[directory.len() + 1..])
            .collect();
        names.dedup();
        let held_directory =
            HeldDirectory::open_code_directory(&base.join(directory)).map_err(|_| unavailable())?;
        exact_names(&held_directory, &names, budget)?;
        let mut verified = std::collections::BTreeSet::new();
        for record in records.iter() {
            if verified.insert(record.resource.as_str()) {
                verified_file(
                    &held_directory,
                    &record.resource[directory.len() + 1..],
                    record,
                    budget,
                )?;
            }
        }
        held_directory.revalidate().map_err(|_| unavailable())?;
    }
    held_base.revalidate().map_err(|_| unavailable())?;
    image
        .verify_bundle(&root, &policy("arktrace")?)
        .map_err(|_| unavailable())?;
    budget.check().map_err(|e| host_error(e, unavailable()))?;
    Ok(Licenses {
        product_license_bytes: attribution::PRODUCT_LICENSE.len() as u64,
        component_count: components.len(),
        build_tool_count: build_tools.len(),
        files,
        windows_build_tool_count: windows_tools.len(),
        windows_static_runtime_count: static_runtime.len(),
        windows_files,
    })
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
        self_test_trace: contents.join(layout::SELF_TEST_TRACE),
    })
}
