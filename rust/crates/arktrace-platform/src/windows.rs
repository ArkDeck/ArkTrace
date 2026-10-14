//! Windows handle boundary. Every path mutation is relative to held parents:
//! `NtCreateFile` with a root directory handle is the `openat` of Windows, a
//! reparse point is opened as itself and refused (the `O_NOFOLLOW`), and every
//! handle shares read, write and delete so POSIX-semantics rename/delete keep
//! the macOS model (a holder keeps its bytes; identity rechecks detect a swap).
//! "Private" is the Windows reading of mode 0700/0600: the owner is the token
//! user and the DACL grants nobody else anything, except the principals that
//! hold root's place (SYSTEM, Administrators, TrustedInstaller). Leases are
//! `LockFileEx` on one byte at offset 2^64-2 of the lease file, the lock byte
//! shared with the ArkDeck purger (docs/RUST_CORE_MIGRATION_DESIGN.md).
//! Primitives adapted from ArkDeck `arkdeck-platform/src/windows/host_fs.rs`
//! and `identity.rs` (MIT, same organization).
use crate::{HostError, HostOperation, IoBudget};
use sha2::{Digest, Sha256};
use std::{
    ffi::{CString, OsStr, OsString},
    fs::File,
    io,
    mem::{offset_of, size_of},
    os::windows::{
        ffi::{OsStrExt, OsStringExt},
        fs::FileExt,
        io::{AsRawHandle, FromRawHandle},
    },
    path::{Component, Path, PathBuf, Prefix},
    ptr::{null, null_mut},
    sync::{Arc, OnceLock},
    thread,
    time::{Duration, Instant},
};
use windows_sys::Wdk::Foundation::OBJECT_ATTRIBUTES;
use windows_sys::Wdk::Storage::FileSystem::{
    FILE_CREATE, FILE_DIRECTORY_FILE, FILE_NON_DIRECTORY_FILE, FILE_OPEN, FILE_OPEN_REPARSE_POINT,
    FILE_RENAME_INFORMATION, FILE_RENAME_POSIX_SEMANTICS, FILE_SYNCHRONOUS_IO_NONALERT,
    FileRenameInformationEx, NtCreateFile, NtSetInformationFile,
};
use windows_sys::Win32::Foundation::{
    ERROR_ALREADY_EXISTS, ERROR_DIRECTORY, ERROR_FILE_EXISTS, ERROR_FILE_NOT_FOUND,
    ERROR_FILENAME_EXCED_RANGE, ERROR_INVALID_NAME, ERROR_LOCK_VIOLATION, ERROR_NO_MORE_FILES,
    ERROR_NOT_SAME_DEVICE, ERROR_NOT_SUPPORTED, ERROR_PATH_NOT_FOUND, ERROR_STOPPED_ON_SYMLINK,
    GENERIC_ALL, GENERIC_EXECUTE, GENERIC_READ, GENERIC_WRITE, HANDLE, LocalFree,
    OBJ_CASE_INSENSITIVE, RtlNtStatusToDosError, STATUS_FILE_IS_A_DIRECTORY,
    STATUS_NOT_A_DIRECTORY, UNICODE_STRING,
};
use windows_sys::Win32::Security::Authorization::{
    ConvertSidToStringSidW, ConvertStringSecurityDescriptorToSecurityDescriptorW, GetSecurityInfo,
    SDDL_REVISION_1, SE_FILE_OBJECT, SetSecurityInfo,
};
use windows_sys::Win32::Security::Cryptography::{
    BCRYPT_USE_SYSTEM_PREFERRED_RNG, BCryptGenRandom,
};
use windows_sys::Win32::Security::{
    ACCESS_ALLOWED_ACE, ACE_HEADER, ACL, CopySid, DACL_SECURITY_INFORMATION, EqualSid, GetAce,
    GetLengthSid, GetSecurityDescriptorDacl, GetSecurityDescriptorLength, GetTokenInformation,
    INHERIT_ONLY_ACE, IsValidSid, OWNER_SECURITY_INFORMATION, PROTECTED_DACL_SECURITY_INFORMATION,
    PSECURITY_DESCRIPTOR, PSID, SECURITY_DESCRIPTOR, TOKEN_QUERY, TOKEN_USER, TokenUser,
};
use windows_sys::Win32::Storage::FileSystem::{
    DELETE, FILE_ADD_FILE, FILE_ADD_SUBDIRECTORY, FILE_ALL_ACCESS, FILE_APPEND_DATA,
    FILE_ATTRIBUTE_DIRECTORY, FILE_ATTRIBUTE_REPARSE_POINT, FILE_BASIC_INFO, FILE_DELETE_CHILD,
    FILE_DISPOSITION_FLAG_DELETE, FILE_DISPOSITION_FLAG_POSIX_SEMANTICS, FILE_DISPOSITION_INFO_EX,
    FILE_FLAG_BACKUP_SEMANTICS, FILE_FLAG_OPEN_REPARSE_POINT, FILE_FULL_DIR_INFO,
    FILE_GENERIC_EXECUTE, FILE_GENERIC_READ, FILE_GENERIC_WRITE, FILE_ID_INFO, FILE_LIST_DIRECTORY,
    FILE_READ_ATTRIBUTES, FILE_READ_DATA, FILE_SHARE_DELETE, FILE_SHARE_READ, FILE_SHARE_WRITE,
    FILE_STANDARD_INFO, FILE_TRAVERSE, FILE_WRITE_ATTRIBUTES, FILE_WRITE_DATA, FILE_WRITE_EA,
    FileBasicInfo, FileDispositionInfoEx, FileFullDirectoryInfo, FileFullDirectoryRestartInfo,
    FileIdInfo, FileStandardInfo, FlushFileBuffers, GetFileInformationByHandleEx,
    LOCKFILE_EXCLUSIVE_LOCK, LOCKFILE_FAIL_IMMEDIATELY, LockFileEx, READ_CONTROL, SYNCHRONIZE,
    SetFileInformationByHandle, UnlockFileEx, WRITE_DAC, WRITE_OWNER,
};
use windows_sys::Win32::System::Com::CoTaskMemFree;
use windows_sys::Win32::System::IO::OVERLAPPED;
use windows_sys::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};
use windows_sys::Win32::System::WindowsProgramming::QueryInterruptTimePrecise;
use windows_sys::Win32::UI::Shell::{FOLDERID_LocalAppData, KF_FLAG_DEFAULT, SHGetKnownFolderPath};

#[path = "windows_directory.rs"]
mod directory;
#[path = "windows_file_transaction.rs"]
mod file_transaction;
#[path = "windows_owner.rs"]
mod owner;
pub use owner::{
    OwnedDirectory, OwnerKind, OwnerRecoveryOutcome, OwnerStore, PublishedOwnerEvidence,
    SidecarRecovery, SidecarStore,
};
#[path = "windows_writable.rs"]
mod writable;
pub use directory::SealedDirectory;
pub use writable::WritableFile;
#[path = "windows_process.rs"]
mod process;
pub use process::{
    ProcessBudget, ProcessError, ProcessOutcome, ProcessOutputFileBudget, VerifiedExecutable,
    run_supervised, supervisor_main,
};
#[path = "windows_trust.rs"]
mod trust;
pub use trust::{CodeTrustPolicy, TrustVerdict};
#[path = "windows_cli.rs"]
mod cli;
pub use cli::{CliSignalGuard, CliWriteFailure, MappedExecutable};

/// The interrupt-time count keeps counting through sleep and hibernation,
/// like Darwin's `CLOCK_MONOTONIC_RAW` that Swift's ContinuousClock uses;
/// `QueryUnbiasedInterruptTime*` and `Instant` exclude suspension.
pub(crate) fn continuous_time() -> Result<(i64, u32), HostError> {
    let mut ticks = 0_u64;
    // SAFETY: valid uniquely borrowed output; the call has no failure mode.
    unsafe { QueryInterruptTimePrecise(&mut ticks) };
    let seconds = i64::try_from(ticks / 10_000_000).map_err(|_| HostError::InvalidEvidence)?;
    Ok((seconds, ((ticks % 10_000_000) * 100) as u32))
}

const CHUNK_BYTES: usize = 1024 * 1024;
/// The one byte every lease locks: beyond the end of any lease file (they are
/// empty), so the mandatory NTFS range lock never refuses a reader of data.
const LOCK_OFFSET: u64 = u64::MAX - 1;
const SHARE_ALL: u32 = FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE;
const INSPECT: u32 = FILE_READ_ATTRIBUTES | READ_CONTROL | SYNCHRONIZE;
const READ: u32 = FILE_READ_DATA | INSPECT;
const DIRECTORY: u32 = FILE_LIST_DIRECTORY | FILE_TRAVERSE | INSPECT;
/// Directories this process writes in: a directory flush needs add rights.
const DIRECTORY_WRITE: u32 = DIRECTORY | FILE_ADD_FILE | FILE_ADD_SUBDIRECTORY;
const CREATE_FILE: u32 = READ | FILE_WRITE_DATA | FILE_APPEND_DATA | WRITE_DAC;
/// What an entry for anyone but the owner may not grant under "no group or
/// other write" (Unix `0o022`).
const WRITE_RIGHTS: u32 = FILE_WRITE_DATA
    | FILE_APPEND_DATA
    | FILE_WRITE_EA
    | FILE_WRITE_ATTRIBUTES
    | FILE_DELETE_CHILD
    | DELETE
    | WRITE_DAC
    | WRITE_OWNER;
/// SYSTEM, Administrators and TrustedInstaller hold root's place.
const TRUSTED_PRINCIPALS: [&str; 3] = [
    "S-1-5-18",
    "S-1-5-32-544",
    "S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464",
];

#[derive(Clone, Copy, Debug, Eq, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FileIdentity {
    /// Volume serial number.
    pub device: u64,
    /// The 64-bit NTFS file reference. A file id that needs the upper half of
    /// the 128-bit `FileIdInfo` (ReFS) is refused, never folded.
    pub inode: u64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FileSnapshot {
    pub identity: FileIdentity,
    pub byte_count: u64,
    attributes: u32,
    links: u32,
    /// Digest of the owner and DACL: the mode/uid/gid of a Windows entry.
    security: [u8; 32],
    modification: i64,
    change: i64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SourceFacts {
    pub sha256: String,
    pub byte_count: u64,
}

fn fail_closed() -> HostError {
    HostError::InvalidEvidence
}

pub(crate) fn not_supported(operation: HostOperation) -> HostError {
    HostError::SystemIo {
        operation,
        code: ERROR_NOT_SUPPORTED as i32,
    }
}

fn from_io(error: io::Error, operation: HostOperation) -> HostError {
    let code = error.raw_os_error().unwrap_or(ERROR_NOT_SUPPORTED as i32);
    match code as u32 {
        ERROR_FILE_NOT_FOUND | ERROR_PATH_NOT_FOUND => HostError::NotFound,
        ERROR_STOPPED_ON_SYMLINK => HostError::LinkedObject,
        ERROR_ALREADY_EXISTS | ERROR_FILE_EXISTS => HostError::AlreadyExists,
        ERROR_NOT_SAME_DEVICE => HostError::CrossVolume,
        ERROR_FILENAME_EXCED_RANGE | ERROR_INVALID_NAME => HostError::InvalidPath,
        ERROR_DIRECTORY => HostError::NotDirectory,
        _ => HostError::SystemIo { operation, code },
    }
}

fn os_error(operation: HostOperation) -> HostError {
    from_io(io::Error::last_os_error(), operation)
}

fn bool_result(result: i32, operation: HostOperation) -> Result<(), HostError> {
    if result == 0 {
        return Err(os_error(operation));
    }
    Ok(())
}

const RESERVED_NAMES: [&str; 22] = [
    "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8",
    "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
];

/// One component inside a held directory, kept as UTF-8 like the Darwin
/// port. Beyond the Unix rule every character NTFS or Win32 reserves is
/// refused (`:` would name an alternate data stream), as are trailing dots
/// and spaces and DOS device names that other Win32 tools cannot open.
fn component(name: &OsStr) -> Result<CString, HostError> {
    let text = name.to_str().ok_or(HostError::InvalidPath)?;
    let units = text.encode_utf16().count();
    let stem = text
        .split('.')
        .next()
        .unwrap_or_default()
        .to_ascii_uppercase();
    if text.is_empty()
        || units > 255
        || text == "."
        || text == ".."
        || text.ends_with('.')
        || text.ends_with(' ')
        || RESERVED_NAMES.contains(&stem.as_str())
        || text
            .chars()
            .any(|c| matches!(c, '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|') || c < ' ')
    {
        return Err(HostError::InvalidPath);
    }
    CString::new(text).map_err(|_| HostError::InvalidPath)
}

fn utf16(name: &CString) -> Result<Vec<u16>, HostError> {
    Ok(name
        .to_str()
        .map_err(|_| HostError::InvalidPath)?
        .encode_utf16()
        .collect())
}

fn wide_terminated(value: &OsStr) -> Result<Vec<u16>, HostError> {
    let mut value: Vec<u16> = value.encode_wide().collect();
    if value.contains(&0) {
        return Err(HostError::InvalidPath);
    }
    value.push(0);
    Ok(value)
}

struct LocalAllocation(*mut std::ffi::c_void);
impl Drop for LocalAllocation {
    fn drop(&mut self) {
        if !self.0.is_null() {
            // SAFETY: exclusively owned result of a LocalAlloc-family API.
            unsafe { LocalFree(self.0) };
        }
    }
}

struct Sid(Vec<u32>);
impl Sid {
    fn copy(pointer: PSID) -> Result<Self, HostError> {
        // SAFETY: called only with pointers from a live token/descriptor.
        if pointer.is_null() || unsafe { IsValidSid(pointer) } == 0 {
            return Err(fail_closed());
        }
        // SAFETY: the SID was validated above.
        let length = unsafe { GetLengthSid(pointer) };
        let mut storage = vec![0_u32; (length as usize).div_ceil(size_of::<u32>())];
        // SAFETY: storage is aligned and at least `length` bytes.
        bool_result(
            unsafe { CopySid(length, storage.as_mut_ptr().cast(), pointer) },
            HostOperation::Stat,
        )?;
        Ok(Self(storage))
    }
    fn pointer(&self) -> PSID {
        self.0.as_ptr().cast_mut().cast()
    }
    fn equals(&self, other: &Self) -> bool {
        // SAFETY: both buffers hold validated copied SIDs.
        unsafe { EqualSid(self.pointer(), other.pointer()) != 0 }
    }
    fn text(&self) -> Result<String, HostError> {
        let mut result = null_mut();
        // SAFETY: valid SID; the output allocation is released below.
        bool_result(
            unsafe { ConvertSidToStringSidW(self.pointer(), &mut result) },
            HostOperation::Stat,
        )?;
        let _allocation = LocalAllocation(result.cast());
        let mut length = 0;
        // SAFETY: successful API output is a NUL-terminated UTF-16 string.
        unsafe {
            while *result.add(length) != 0 {
                length += 1;
            }
        }
        // SAFETY: the measured length lies inside the API-owned string.
        String::from_utf16(unsafe { std::slice::from_raw_parts(result, length) })
            .map_err(|_| fail_closed())
    }
}

/// The token user of this process, read once.
fn user() -> Result<&'static Sid, HostError> {
    static USER: OnceLock<Option<Sid>> = OnceLock::new();
    USER.get_or_init(|| token_user().ok())
        .as_ref()
        .ok_or(HostError::NotPrivate)
}

fn token_user() -> Result<Sid, HostError> {
    let mut token: HANDLE = null_mut();
    // SAFETY: GetCurrentProcess is a pseudo-handle; the token is owned below.
    bool_result(
        unsafe { OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) },
        HostOperation::Stat,
    )?;
    // SAFETY: a successful call returned a new owned token handle.
    let token = unsafe { File::from_raw_handle(token) };
    let mut length = 0_u32;
    // SAFETY: the documented size query with no output buffer.
    unsafe { GetTokenInformation(token.as_raw_handle(), TokenUser, null_mut(), 0, &mut length) };
    if length == 0 || length > 64 * 1024 {
        return Err(os_error(HostOperation::Stat));
    }
    let mut storage = vec![0_usize; (length as usize).div_ceil(size_of::<usize>())];
    // SAFETY: pointer-aligned storage of at least `length` bytes.
    bool_result(
        unsafe {
            GetTokenInformation(
                token.as_raw_handle(),
                TokenUser,
                storage.as_mut_ptr().cast(),
                length,
                &mut length,
            )
        },
        HostOperation::Stat,
    )?;
    // SAFETY: the returned buffer begins with a TOKEN_USER header.
    let header = unsafe { storage.as_ptr().cast::<TOKEN_USER>().read_unaligned() };
    Sid::copy(header.User.Sid)
}

/// A self-relative security descriptor built from SDDL.
struct Descriptor(LocalAllocation);
impl Descriptor {
    /// Owner the token user; a protected DACL granting that user alone `rights`
    /// (inherited by children when it is a directory's).
    fn owner_only(rights: &str, inherit: bool) -> Result<Self, HostError> {
        let user = user()?.text()?;
        let inherit = if inherit { "OICI" } else { "" };
        let sddl = wide_terminated(OsStr::new(&format!(
            "O:{user}D:P(A;{inherit};{rights};;;{user})"
        )))?;
        let mut descriptor = null_mut();
        // SAFETY: NUL-terminated SDDL; the allocation is owned by the result.
        bool_result(
            unsafe {
                ConvertStringSecurityDescriptorToSecurityDescriptorW(
                    sddl.as_ptr(),
                    SDDL_REVISION_1,
                    &mut descriptor,
                    null_mut(),
                )
            },
            HostOperation::SetPermissions,
        )?;
        Ok(Self(LocalAllocation(descriptor)))
    }
    fn raw(&self) -> PSECURITY_DESCRIPTOR {
        self.0.0
    }
}

fn trusted_principal(sid: &Sid) -> bool {
    sid.text()
        .is_ok_and(|text| TRUSTED_PRINCIPALS.contains(&text.as_str()))
}

fn generic(mask: u32) -> u32 {
    let mut mapped = mask & !(GENERIC_ALL | GENERIC_READ | GENERIC_WRITE | GENERIC_EXECUTE);
    if mask & GENERIC_ALL != 0 {
        mapped |= FILE_ALL_ACCESS;
    }
    if mask & GENERIC_READ != 0 {
        mapped |= FILE_GENERIC_READ;
    }
    if mask & GENERIC_WRITE != 0 {
        mapped |= FILE_GENERIC_WRITE;
    }
    if mask & GENERIC_EXECUTE != 0 {
        mapped |= FILE_GENERIC_EXECUTE;
    }
    mapped
}

/// Who may do what to an entry, read from its owner and DACL.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct Access {
    owner_is_user: bool,
    owner_trusted: bool,
    /// Rights granted to the token user (allowed minus earlier denies).
    user: u32,
    /// Rights granted to anyone but the token user and trusted principals.
    untrusted: u32,
    /// Rights granted to anyone but the token user.
    others: u32,
    digest: [u8; 32],
}

impl Access {
    fn of(file: &File) -> Result<Self, HostError> {
        let mut owner = null_mut();
        let mut dacl: *mut ACL = null_mut();
        let mut descriptor = null_mut();
        // SAFETY: a live handle opened with READ_CONTROL; the returned pointers
        // point into `descriptor`, which is released below.
        let status = unsafe {
            GetSecurityInfo(
                file.as_raw_handle(),
                SE_FILE_OBJECT,
                OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
                &mut owner,
                null_mut(),
                &mut dacl,
                null_mut(),
                &mut descriptor,
            )
        };
        let _descriptor = LocalAllocation(descriptor);
        if status != 0 {
            return Err(HostError::SystemIo {
                operation: HostOperation::Stat,
                code: status as i32,
            });
        }
        // SAFETY: a valid self-relative descriptor allocated by the call.
        let length = unsafe { GetSecurityDescriptorLength(descriptor) } as usize;
        // SAFETY: the descriptor spans exactly `length` readable bytes.
        let digest: [u8; 32] =
            Sha256::digest(unsafe { std::slice::from_raw_parts(descriptor.cast::<u8>(), length) })
                .into();
        let user = user()?;
        let owner = Sid::copy(owner)?;
        let owner_is_user = owner.equals(user);
        let owner_trusted = owner_is_user || trusted_principal(&owner);
        if dacl.is_null() {
            // A NULL DACL (FAT volumes, explicit grants) grants everything.
            return Ok(Self {
                owner_is_user,
                owner_trusted,
                user: FILE_ALL_ACCESS,
                untrusted: FILE_ALL_ACCESS,
                others: FILE_ALL_ACCESS,
                digest,
            });
        }
        let (mut allowed, mut denied, mut others, mut untrusted) = (0, 0, 0, 0);
        // SAFETY: a valid ACL returned by GetSecurityInfo.
        let count = unsafe { (*dacl).AceCount };
        for index in 0..u32::from(count) {
            let mut ace = null_mut();
            // SAFETY: index is below the ACL's own count.
            bool_result(
                unsafe { GetAce(dacl, index, &mut ace) },
                HostOperation::Stat,
            )?;
            // SAFETY: every ACE begins with its header.
            let header = unsafe { *ace.cast::<ACE_HEADER>() };
            if u32::from(header.AceFlags) & INHERIT_ONLY_ACE != 0 {
                continue;
            }
            // Object and callback entries cannot be read as plain grants.
            if header.AceType > 1 {
                return Ok(Self {
                    owner_is_user,
                    owner_trusted,
                    user: 0,
                    untrusted: FILE_ALL_ACCESS,
                    others: FILE_ALL_ACCESS,
                    digest,
                });
            }
            // SAFETY: allowed and denied ACEs share this layout; the SID
            // starts at SidStart inside the ACE.
            let (mask, sid) = unsafe {
                let entry = ace.cast::<ACCESS_ALLOWED_ACE>();
                (
                    (*entry).Mask,
                    ace.cast::<u8>()
                        .add(offset_of!(ACCESS_ALLOWED_ACE, SidStart)),
                )
            };
            let mask = generic(mask);
            // SAFETY: a SID inside a valid ACE and the cached user SID.
            let is_user = unsafe { EqualSid(sid.cast(), user.pointer()) } != 0;
            match (header.AceType, is_user) {
                (0, true) => allowed |= mask & !denied,
                (0, false) => {
                    others |= mask;
                    if !trusted_principal(&Sid::copy(sid.cast())?) {
                        untrusted |= mask;
                    }
                }
                (_, true) => denied |= mask,
                (_, false) => {}
            }
        }
        Ok(Self {
            owner_is_user,
            owner_trusted,
            user: allowed,
            untrusted,
            others,
            digest,
        })
    }
    /// Unix "owned by this user, `mode & 0o077 == 0`" where root still reads.
    fn owner_private(&self) -> bool {
        self.owner_is_user && self.untrusted == 0
    }
    /// Unix "owned by this user or root; nobody else may change it, except
    /// that others may add entries" (the sticky `/tmp`).
    fn trusted_ancestor(&self) -> bool {
        self.owner_trusted
            && self.untrusted & WRITE_RIGHTS & !(FILE_ADD_FILE | FILE_ADD_SUBDIRECTORY) == 0
    }
    /// Unix `mode & 0o222 == 0`: nobody, the owner included, may write data.
    fn readonly(&self) -> bool {
        (self.user | self.others) & (FILE_WRITE_DATA | FILE_APPEND_DATA) == 0
    }
    /// Unix `0400` on a private sealed file.
    fn sealed(&self) -> bool {
        self.owner_private()
            && self.others == 0
            && self.user & FILE_READ_DATA != 0
            && self.readonly()
    }
    /// Unix `0600` on a private writable file.
    fn owner_read_write(&self) -> bool {
        self.owner_private()
            && self.others == 0
            && self.user & (FILE_READ_DATA | FILE_WRITE_DATA) == FILE_READ_DATA | FILE_WRITE_DATA
    }
}

/// Replace an entry's DACL with a protected owner-only one (`chmod`).
fn set_owner_only(file: &File, rights: &str) -> Result<(), HostError> {
    let descriptor = Descriptor::owner_only(rights, false)?;
    let mut present = 0;
    let mut dacl = null_mut();
    let mut defaulted = 0;
    // SAFETY: a valid self-relative descriptor built from SDDL.
    bool_result(
        unsafe {
            GetSecurityDescriptorDacl(descriptor.raw(), &mut present, &mut dacl, &mut defaulted)
        },
        HostOperation::SetPermissions,
    )?;
    if present == 0 || dacl.is_null() {
        return Err(fail_closed());
    }
    // SAFETY: a live handle opened with WRITE_DAC and a valid ACL.
    let status = unsafe {
        SetSecurityInfo(
            file.as_raw_handle(),
            SE_FILE_OBJECT,
            DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
            null_mut(),
            null_mut(),
            dacl,
            null(),
        )
    };
    if status != 0 {
        return Err(HostError::SystemIo {
            operation: HostOperation::SetPermissions,
            code: status as i32,
        });
    }
    Ok(())
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Kind {
    Directory,
    NonDirectory,
    Any,
}

/// `openat(parent, name, O_NOFOLLOW)`: never through a reparse point, every
/// share mode. `security` applies only when `disposition` creates the entry.
fn nt_open(
    parent: &File,
    name: &[u16],
    access: u32,
    disposition: u32,
    kind: Kind,
    security: Option<&Descriptor>,
    operation: HostOperation,
) -> Result<File, HostError> {
    let bytes = u16::try_from(name.len() * 2).map_err(|_| HostError::InvalidPath)?;
    let object = UNICODE_STRING {
        Length: bytes,
        MaximumLength: bytes,
        Buffer: name.as_ptr().cast_mut(),
    };
    let attributes = OBJECT_ATTRIBUTES {
        Length: size_of::<OBJECT_ATTRIBUTES>() as u32,
        RootDirectory: parent.as_raw_handle(),
        ObjectName: &object,
        Attributes: OBJ_CASE_INSENSITIVE,
        SecurityDescriptor: security.map_or(null(), |d| d.raw().cast::<SECURITY_DESCRIPTOR>()),
        SecurityQualityOfService: null(),
    };
    let options = FILE_OPEN_REPARSE_POINT
        | FILE_SYNCHRONOUS_IO_NONALERT
        | match kind {
            Kind::Directory => FILE_DIRECTORY_FILE,
            Kind::NonDirectory => FILE_NON_DIRECTORY_FILE,
            Kind::Any => 0,
        };
    let mut handle: HANDLE = null_mut();
    // SAFETY: zeroed storage is a valid IO_STATUS_BLOCK output.
    let mut status_block = unsafe { std::mem::zeroed() };
    // SAFETY: every pointer names a live local for the duration of the call;
    // a successful call returns a new handle owned below.
    let status = unsafe {
        NtCreateFile(
            &mut handle,
            access | SYNCHRONIZE,
            &attributes,
            &mut status_block,
            null(),
            0,
            SHARE_ALL,
            disposition,
            options,
            null(),
            0,
        )
    };
    if status < 0 {
        return Err(match status {
            STATUS_NOT_A_DIRECTORY => HostError::NotDirectory,
            STATUS_FILE_IS_A_DIRECTORY => HostError::NotRegular,
            // SAFETY: a pure status-code translation.
            _ => from_io(
                io::Error::from_raw_os_error(unsafe { RtlNtStatusToDosError(status) } as i32),
                operation,
            ),
        });
    }
    // SAFETY: NtCreateFile succeeded, so `handle` is a new owned handle.
    let file = unsafe { File::from_raw_handle(handle) };
    if Stat::of(&file)?.reparse() {
        return Err(HostError::LinkedObject);
    }
    Ok(file)
}

fn information<T: Default>(file: &File, class: i32) -> Result<T, HostError> {
    let mut value = T::default();
    // SAFETY: a live handle and an output of exactly the class's size.
    bool_result(
        unsafe {
            GetFileInformationByHandleEx(
                file.as_raw_handle(),
                class,
                std::ptr::from_mut(&mut value).cast(),
                size_of::<T>() as u32,
            )
        },
        HostOperation::Stat,
    )?;
    Ok(value)
}

/// What `fstat` answers from one handle.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct Stat {
    volume: u64,
    id: [u8; 16],
    size: u64,
    links: u32,
    attributes: u32,
    written: i64,
    changed: i64,
    delete_pending: bool,
}

impl Stat {
    fn of(file: &File) -> Result<Self, HostError> {
        let id: FILE_ID_INFO = information(file, FileIdInfo)?;
        let basic: FILE_BASIC_INFO = information(file, FileBasicInfo)?;
        let standard: FILE_STANDARD_INFO = information(file, FileStandardInfo)?;
        Ok(Self {
            volume: id.VolumeSerialNumber,
            id: id.FileId.Identifier,
            size: u64::try_from(standard.EndOfFile).map_err(|_| fail_closed())?,
            links: standard.NumberOfLinks,
            attributes: basic.FileAttributes,
            written: basic.LastWriteTime,
            changed: basic.ChangeTime,
            delete_pending: standard.DeletePending,
        })
    }
    fn reparse(&self) -> bool {
        self.attributes & FILE_ATTRIBUTE_REPARSE_POINT != 0
    }
    fn is_dir(&self) -> bool {
        self.attributes & FILE_ATTRIBUTE_DIRECTORY != 0 && !self.reparse()
    }
    fn is_file(&self) -> bool {
        self.attributes & FILE_ATTRIBUTE_DIRECTORY == 0 && !self.reparse()
    }
    fn identity(&self) -> Result<FileIdentity, HostError> {
        if self.id[8..] != [0; 8] {
            return Err(HostError::IdentityMismatch);
        }
        Ok(FileIdentity {
            device: self.volume,
            inode: u64::from_le_bytes(self.id[..8].try_into().map_err(|_| fail_closed())?),
        })
    }
}

impl FileSnapshot {
    fn of(file: &File) -> Result<Self, HostError> {
        let stat = Stat::of(file)?;
        Ok(Self {
            identity: stat.identity()?,
            byte_count: stat.size,
            attributes: stat.attributes,
            links: stat.links,
            security: Access::of(file)?.digest,
            modification: stat.written,
            change: stat.changed,
        })
    }
}

/// `fstatat(parent, name, AT_SYMLINK_NOFOLLOW)`.
fn stat_child(parent: &File, name: &CString) -> Result<Stat, HostError> {
    let handle = nt_open(
        parent,
        &utf16(name)?,
        INSPECT,
        FILE_OPEN,
        Kind::Any,
        None,
        HostOperation::Stat,
    )
    .or_else(|error| match error {
        // A link is inspected as itself, like lstat; callers refuse it.
        HostError::LinkedObject => {
            nt_open_unchecked(parent, &utf16(name)?, INSPECT, HostOperation::Stat)
        }
        error => Err(error),
    })?;
    Stat::of(&handle)
}

fn nt_open_unchecked(
    parent: &File,
    name: &[u16],
    access: u32,
    operation: HostOperation,
) -> Result<File, HostError> {
    let bytes = u16::try_from(name.len() * 2).map_err(|_| HostError::InvalidPath)?;
    let object = UNICODE_STRING {
        Length: bytes,
        MaximumLength: bytes,
        Buffer: name.as_ptr().cast_mut(),
    };
    let attributes = OBJECT_ATTRIBUTES {
        Length: size_of::<OBJECT_ATTRIBUTES>() as u32,
        RootDirectory: parent.as_raw_handle(),
        ObjectName: &object,
        Attributes: OBJ_CASE_INSENSITIVE,
        SecurityDescriptor: null(),
        SecurityQualityOfService: null(),
    };
    let mut handle: HANDLE = null_mut();
    // SAFETY: zeroed storage is a valid IO_STATUS_BLOCK output.
    let mut status_block = unsafe { std::mem::zeroed() };
    // SAFETY: live locals; the new handle is owned below.
    let status = unsafe {
        NtCreateFile(
            &mut handle,
            access | SYNCHRONIZE,
            &attributes,
            &mut status_block,
            null(),
            0,
            SHARE_ALL,
            FILE_OPEN,
            FILE_OPEN_REPARSE_POINT | FILE_SYNCHRONOUS_IO_NONALERT,
            null(),
            0,
        )
    };
    if status < 0 {
        return Err(from_io(
            // SAFETY: a pure status-code translation.
            io::Error::from_raw_os_error(unsafe { RtlNtStatusToDosError(status) } as i32),
            operation,
        ));
    }
    // SAFETY: NtCreateFile succeeded and returned a new owned handle.
    Ok(unsafe { File::from_raw_handle(handle) })
}

/// `renameat`/`renameatx_np(RENAME_EXCL)` of the entry `source` names inside
/// `parent`, into `destination`, with POSIX semantics. Windows has no atomic
/// exchange; callers that need `RENAME_SWAP` use a verified replace instead.
fn rename_entry(
    parent: &File,
    source: &CString,
    destination: &File,
    name: &CString,
    replace: bool,
) -> Result<(), HostError> {
    let entry = nt_open(
        parent,
        &utf16(source)?,
        DELETE | FILE_READ_ATTRIBUTES | READ_CONTROL,
        FILE_OPEN,
        Kind::Any,
        None,
        HostOperation::Rename,
    )?;
    rename_handle(&entry, destination, &utf16(name)?, replace)
}

fn rename_handle(
    source: &File,
    destination: &File,
    name: &[u16],
    replace: bool,
) -> Result<(), HostError> {
    const FILE_RENAME_REPLACE_IF_EXISTS: u32 = 0x1;
    let header = offset_of!(FILE_RENAME_INFORMATION, FileName);
    let size = header + name.len() * 2 + 2;
    let mut buffer = vec![0_u64; size.div_ceil(8)];
    let info = buffer.as_mut_ptr().cast::<FILE_RENAME_INFORMATION>();
    // SAFETY: the u64 buffer is aligned for and at least as large as the
    // header plus the name and its terminator.
    unsafe {
        (*info).Anonymous.Flags = FILE_RENAME_POSIX_SEMANTICS
            | if replace {
                FILE_RENAME_REPLACE_IF_EXISTS
            } else {
                0
            };
        (*info).RootDirectory = destination.as_raw_handle();
        (*info).FileNameLength = (name.len() * 2) as u32;
        std::ptr::copy_nonoverlapping(name.as_ptr(), (*info).FileName.as_mut_ptr(), name.len());
    }
    // SAFETY: zeroed storage is a valid IO_STATUS_BLOCK output.
    let mut status_block = unsafe { std::mem::zeroed() };
    // SAFETY: a live source handle (DELETE access) and the information above.
    let status = unsafe {
        NtSetInformationFile(
            source.as_raw_handle(),
            &mut status_block,
            info.cast(),
            size as u32,
            FileRenameInformationEx,
        )
    };
    if status < 0 {
        return Err(from_io(
            // SAFETY: a pure status-code translation.
            io::Error::from_raw_os_error(unsafe { RtlNtStatusToDosError(status) } as i32),
            HostOperation::Rename,
        ));
    }
    Ok(())
}

/// `unlinkat` of the exact entry `file` is open on (DELETE access), with POSIX
/// semantics: the name is gone at once while other holders keep their bytes.
fn delete_handle(file: &File) -> Result<(), HostError> {
    let info = FILE_DISPOSITION_INFO_EX {
        Flags: FILE_DISPOSITION_FLAG_DELETE | FILE_DISPOSITION_FLAG_POSIX_SEMANTICS,
    };
    // SAFETY: a live handle and a correctly sized disposition.
    bool_result(
        unsafe {
            SetFileInformationByHandle(
                file.as_raw_handle(),
                FileDispositionInfoEx,
                std::ptr::from_ref(&info).cast(),
                size_of::<FILE_DISPOSITION_INFO_EX>() as u32,
            )
        },
        HostOperation::Remove,
    )
}

/// Remove the exact identity-checked child: the check and the deletion use the
/// same handle, so a raced replacement is never removed.
fn remove_child(
    parent: &File,
    name: &CString,
    expected: FileIdentity,
    directory: bool,
) -> Result<(), HostError> {
    let entry = nt_open(
        parent,
        &utf16(name)?,
        DELETE | FILE_READ_ATTRIBUTES | READ_CONTROL,
        FILE_OPEN,
        if directory {
            Kind::Directory
        } else {
            Kind::NonDirectory
        },
        None,
        HostOperation::Remove,
    )?;
    let stat = Stat::of(&entry)?;
    if (directory && !stat.is_dir()) || (!directory && !stat.is_file()) {
        return Err(HostError::IdentityMismatch);
    }
    if stat.identity()? != expected {
        return Err(HostError::IdentityMismatch);
    }
    delete_handle(&entry)
}

fn lock_byte(file: &File, exclusive: bool) -> Result<bool, HostError> {
    let mut overlapped = overlapped(LOCK_OFFSET);
    let flags = LOCKFILE_FAIL_IMMEDIATELY
        | if exclusive {
            LOCKFILE_EXCLUSIVE_LOCK
        } else {
            0
        };
    // SAFETY: a live synchronous handle and a live OVERLAPPED naming the
    // offset; a synchronous handle completes before the call returns.
    if unsafe { LockFileEx(file.as_raw_handle(), flags, 0, 1, 0, &mut overlapped) } != 0 {
        return Ok(true);
    }
    let error = io::Error::last_os_error();
    if error.raw_os_error() == Some(ERROR_LOCK_VIOLATION as i32) {
        return Ok(false);
    }
    Err(from_io(error, HostOperation::Lock))
}

fn unlock_byte(file: &File) -> Result<(), HostError> {
    let mut overlapped = overlapped(LOCK_OFFSET);
    // SAFETY: a live handle; unlocking the byte this handle holds.
    bool_result(
        unsafe { UnlockFileEx(file.as_raw_handle(), 0, 1, 0, &mut overlapped) },
        HostOperation::Lock,
    )
}

fn overlapped(offset: u64) -> OVERLAPPED {
    let mut value = OVERLAPPED::default();
    value.Anonymous.Anonymous.Offset = offset as u32;
    value.Anonymous.Anonymous.OffsetHigh = (offset >> 32) as u32;
    value
}

/// Names in a held directory (without `.`/`..`), read through a fresh handle
/// so each enumeration starts at its own beginning.
fn list_names(directory: &File, maximum: usize) -> Result<Vec<CString>, HostError> {
    let listing = nt_open(
        directory,
        &[],
        DIRECTORY,
        FILE_OPEN,
        Kind::Directory,
        None,
        HostOperation::Read,
    )?;
    if Stat::of(&listing)?.identity()? != Stat::of(directory)?.identity()? {
        return Err(HostError::IdentityMismatch);
    }
    let mut names = Vec::new();
    let mut buffer = vec![0_u64; 8192];
    let mut class = FileFullDirectoryRestartInfo;
    loop {
        // SAFETY: a live directory handle and a writable, aligned buffer.
        let listed = unsafe {
            GetFileInformationByHandleEx(
                listing.as_raw_handle(),
                class,
                buffer.as_mut_ptr().cast(),
                (buffer.len() * 8) as u32,
            )
        };
        if listed == 0 {
            let error = io::Error::last_os_error();
            if error.raw_os_error() == Some(ERROR_NO_MORE_FILES as i32) {
                break;
            }
            return Err(from_io(error, HostOperation::Read));
        }
        class = FileFullDirectoryInfo;
        let mut offset = 0_usize;
        loop {
            let base = buffer.as_ptr().cast::<u8>();
            // SAFETY: the system wrote a chain of entries inside `buffer`;
            // each name length stays within it.
            let (next, name) = unsafe {
                let entry = base.add(offset).cast::<FILE_FULL_DIR_INFO>();
                let length = (*entry).FileNameLength as usize / 2;
                let name = std::slice::from_raw_parts(
                    base.add(offset + offset_of!(FILE_FULL_DIR_INFO, FileName))
                        .cast::<u16>(),
                    length,
                );
                ((*entry).NextEntryOffset as usize, name)
            };
            let name = String::from_utf16(name).map_err(|_| HostError::InvalidPath)?;
            if name != "." && name != ".." {
                if names.len() == maximum {
                    return Err(HostError::LimitExceeded);
                }
                names.push(component(OsStr::new(&name))?);
            }
            if next == 0 {
                break;
            }
            offset += next;
        }
    }
    Ok(names)
}

fn random_bytes<const N: usize>() -> Result<[u8; N], HostError> {
    let mut bytes = [0_u8; N];
    // SAFETY: the system-preferred RNG fills the full fixed buffer.
    let status = unsafe {
        BCryptGenRandom(
            null_mut(),
            bytes.as_mut_ptr(),
            N as u32,
            BCRYPT_USE_SYSTEM_PREFERRED_RNG,
        )
    };
    if status < 0 {
        return Err(HostError::SystemIo {
            operation: HostOperation::Read,
            code: status,
        });
    }
    Ok(bytes)
}

/// A version-4 UUID text from the system RNG.
fn uuid() -> String {
    // The system RNG has no documented failure for this flag. A failure yields
    // a fixed name: every exclusive create then collides and fails closed.
    let mut bytes = random_bytes::<16>().unwrap_or([0; 16]);
    bytes[6] = (bytes[6] & 15) | 0x40;
    bytes[8] = (bytes[8] & 63) | 0x80;
    let h = bytes.iter().map(|b| format!("{b:02x}")).collect::<String>();
    format!(
        "{}-{}-{}-{}-{}",
        &h[..8],
        &h[8..12],
        &h[12..16],
        &h[16..20],
        &h[20..]
    )
}

struct DirectoryNode {
    file: File,
    identity: FileIdentity,
    parent: Option<Arc<DirectoryNode>>,
    name: CString,
    path: PathBuf,
    private: bool,
    trusted_ancestors: bool,
    writable: bool,
}

#[derive(Clone)]
pub struct HeldDirectory(Arc<DirectoryNode>);

/// Immutable metadata and handle of the exact file bound at open time.
/// No public constructor accepts an arbitrary identity or a foreign handle.
pub struct HeldFile {
    file: File,
    initial: FileSnapshot,
    parent: HeldDirectory,
    name: CString,
    private: bool,
}

fn require_private_security(file: &File) -> Result<(), HostError> {
    if !Access::of(file)?.owner_private() {
        return Err(HostError::NotPrivate);
    }
    Ok(())
}

fn require_trusted_ancestor(file: &File) -> Result<(), HostError> {
    if !Access::of(file)?.trusted_ancestor() {
        return Err(HostError::NotPrivate);
    }
    Ok(())
}

fn local_drive(path: &Path) -> bool {
    matches!(
        path.components().next(),
        Some(Component::Prefix(prefix))
            if matches!(prefix.kind(), Prefix::Disk(_) | Prefix::VerbatimDisk(_))
    )
}

impl HeldDirectory {
    /// Caller supplies a canonical absolute storage root on a local drive.
    /// Every component is opened without following a reparse point; existing
    /// owners and DACLs are validated, never repaired.
    pub fn open_private(path: &Path) -> Result<Self, HostError> {
        Self::open(path, true)
    }

    /// Read-only authority for fixed code in an installed product directory.
    /// Every parent is held with trusted ownership; no storage authority.
    pub fn open_code_directory(path: &Path) -> Result<Self, HostError> {
        Self::open_security(path, false, true)
    }

    fn open(path: &Path, private: bool) -> Result<Self, HostError> {
        Self::open_security(path, private, private)
    }

    fn open_trusted_temporary_parent(path: &Path) -> Result<Self, HostError> {
        Self::open_security(path, false, true)
    }

    fn open_security(
        path: &Path,
        private: bool,
        trusted_ancestors: bool,
    ) -> Result<Self, HostError> {
        if !path.is_absolute() || !local_drive(path) {
            return Err(HostError::InvalidPath);
        }
        let mut components = path.components();
        let prefix = match components.next() {
            Some(Component::Prefix(prefix)) => prefix,
            _ => return Err(HostError::InvalidPath),
        };
        if components.next() != Some(Component::RootDir) {
            return Err(HostError::InvalidPath);
        }
        let names: Vec<_> = components
            .map(|part| match part {
                Component::Normal(name) => component(name),
                _ => Err(HostError::InvalidPath),
            })
            .collect::<Result<_, _>>()?;
        if private && names.is_empty() {
            return Err(HostError::InvalidPath);
        }
        let mut root_path = PathBuf::from(prefix.as_os_str());
        root_path.push("\\");
        let file = {
            use std::os::windows::fs::OpenOptionsExt;
            std::fs::OpenOptions::new()
                .access_mode(DIRECTORY)
                .share_mode(SHARE_ALL)
                .custom_flags(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT)
                .open(&root_path)
                .map_err(|e| from_io(e, HostOperation::Open))?
        };
        let stat = Stat::of(&file)?;
        if !stat.is_dir() {
            return Err(HostError::NotDirectory);
        }
        let mut current = Self(Arc::new(DirectoryNode {
            identity: stat.identity()?,
            file,
            parent: None,
            name: CString::new("\\").map_err(|_| HostError::InvalidPath)?,
            path: root_path,
            private: false,
            trusted_ancestors,
            writable: false,
        }));
        for (index, name) in names.iter().enumerate() {
            let final_component = index + 1 == names.len();
            current = current.open_child(name, private && final_component, trusted_ancestors)?;
        }
        current.revalidate()?;
        Ok(current)
    }

    fn open_child(
        &self,
        name: &CString,
        private: bool,
        trusted_ancestors: bool,
    ) -> Result<Self, HostError> {
        let file = nt_open(
            &self.0.file,
            &utf16(name)?,
            if private { DIRECTORY_WRITE } else { DIRECTORY },
            FILE_OPEN,
            Kind::Directory,
            None,
            HostOperation::Open,
        )?;
        let stat = Stat::of(&file)?;
        if !stat.is_dir() {
            return Err(HostError::NotDirectory);
        }
        if private {
            require_private_security(&file)?;
        }
        if trusted_ancestors {
            require_trusted_ancestor(&file)?;
        }
        Ok(Self(Arc::new(DirectoryNode {
            identity: stat.identity()?,
            file,
            parent: Some(self.0.clone()),
            name: name.clone(),
            path: self
                .0
                .path
                .join(name.to_str().map_err(|_| HostError::InvalidPath)?),
            private,
            trusted_ancestors,
            writable: private,
        })))
    }

    pub fn identity(&self) -> FileIdentity {
        self.0.identity
    }
    pub fn path(&self) -> &Path {
        &self.0.path
    }

    /// Sorted component names from an independent enumeration handle.
    pub fn child_names(
        &self,
        budget: &IoBudget,
        maximum_children: usize,
    ) -> Result<Vec<OsString>, HostError> {
        if maximum_children > 196_608 {
            return Err(HostError::LimitExceeded);
        }
        directory::names_bounded(self, budget, maximum_children).map(|names| {
            names
                .into_iter()
                .map(|name| OsString::from(name.to_string_lossy().into_owned()))
                .collect()
        })
    }

    pub fn revalidate(&self) -> Result<(), HostError> {
        let stat = Stat::of(&self.0.file)?;
        if !stat.is_dir() || stat.delete_pending || stat.identity()? != self.0.identity {
            return Err(HostError::IdentityMismatch);
        }
        if self.0.private {
            require_private_security(&self.0.file)?;
        }
        if self.0.trusted_ancestors {
            require_trusted_ancestor(&self.0.file)?;
        }
        if let Some(parent) = &self.0.parent {
            Self(parent.clone()).revalidate()?;
            let linked = stat_child(&parent.file, &self.0.name)?;
            if !linked.is_dir() || linked.identity()? != self.0.identity {
                return Err(HostError::IdentityMismatch);
            }
        }
        Ok(())
    }

    /// `mkdirat(parent, name, 0700)`: a fresh owner-only directory.
    fn make_private_directory(&self, name: &CString) -> Result<(), HostError> {
        let descriptor = Descriptor::owner_only("FA", true)?;
        nt_open(
            &self.0.file,
            &utf16(name)?,
            DIRECTORY_WRITE,
            FILE_CREATE,
            Kind::Directory,
            Some(&descriptor),
            HostOperation::CreateDirectory,
        )
        .map(drop)
    }

    pub fn create_private_child(&self, name: &str) -> Result<Self, HostError> {
        if !self.0.private {
            return Err(HostError::NotPrivate);
        }
        let name = component(OsStr::new(name))?;
        self.revalidate()?;
        self.make_private_directory(&name)?;
        let child = self.open_child(&name, true, true)?;
        child.revalidate()?;
        self.sync()?;
        Ok(child)
    }

    pub fn open_private_child(&self, name: &str) -> Result<Self, HostError> {
        self.revalidate()?;
        if !self.0.private {
            return Err(HostError::NotPrivate);
        }
        self.open_child(&component(OsStr::new(name))?, true, true)
    }

    /// Ignore non-directory components without following them. A selected
    /// directory must retain the inspected identity when it is opened.
    pub fn find_private_child(&self, name: &str) -> Result<Option<Self>, HostError> {
        self.revalidate()?;
        let component = component(OsStr::new(name))?;
        let info = match stat_child(&self.0.file, &component) {
            Ok(info) => info,
            Err(HostError::NotFound) => return Ok(None),
            Err(e) => return Err(e),
        };
        if !info.is_dir() {
            return Ok(None);
        }
        let directory = self.open_private_child(name)?;
        if directory.identity() != info.identity()? {
            return Err(HostError::IdentityMismatch);
        }
        directory.revalidate()?;
        Ok(Some(directory))
    }

    pub fn ensure_private_child(&self, name: &str) -> Result<Self, HostError> {
        match self.create_private_child(name) {
            Ok(child) => Ok(child),
            Err(HostError::AlreadyExists) => self.open_private_child(name),
            Err(error) => Err(error),
        }
    }

    /// Exact membership in a disposable private directory.
    pub fn require_file_membership(
        &self,
        expected: &[&str],
        budget: &IoBudget,
    ) -> Result<(), HostError> {
        self.require_private_membership(expected, &[], budget)
    }

    pub fn require_private_membership(
        &self,
        files: &[&str],
        directories: &[&str],
        budget: &IoBudget,
    ) -> Result<(), HostError> {
        if !self.0.private {
            return Err(HostError::NotPrivate);
        }
        let expected = files.iter().chain(directories).copied().collect::<Vec<_>>();
        if expected.is_empty() || expected.len() > 64 {
            return Err(HostError::InvalidLimit);
        }
        let mut expected = expected
            .iter()
            .map(|name| component(OsStr::new(name)))
            .collect::<Result<Vec<_>, _>>()?;
        expected.sort_unstable_by(|a, b| a.as_bytes().cmp(b.as_bytes()));
        if expected.windows(2).any(|pair| pair[0] == pair[1]) {
            return Err(HostError::InvalidEvidence);
        }
        if directory::names_bounded(self, budget, 64)? != expected {
            return Err(HostError::InvalidEvidence);
        }
        for name in files {
            let name = component(OsStr::new(name))?;
            self.open_file_component(name, true)?.verify()?;
        }
        for name in directories {
            self.open_private_child(name)?.revalidate()?;
        }
        self.revalidate()
    }

    pub fn open_file(&self, name: &str) -> Result<HeldFile, HostError> {
        self.open_file_component(component(OsStr::new(name))?, self.0.private)
    }

    fn open_file_component(&self, name: CString, private: bool) -> Result<HeldFile, HostError> {
        self.revalidate()?;
        let file = nt_open(
            &self.0.file,
            &utf16(&name)?,
            READ,
            FILE_OPEN,
            Kind::NonDirectory,
            None,
            HostOperation::Open,
        )?;
        HeldFile::bound(file, self.clone(), name, private)
    }

    /// `openat(O_RDWR|O_CREAT|O_EXCL, 0600)`: a fresh owner-only file.
    fn create_file(&self, name: &CString) -> Result<File, HostError> {
        if !self.0.private {
            return Err(HostError::NotPrivate);
        }
        self.revalidate()?;
        let descriptor = Descriptor::owner_only("FA", false)?;
        nt_open(
            &self.0.file,
            &utf16(name)?,
            CREATE_FILE,
            FILE_CREATE,
            Kind::NonDirectory,
            Some(&descriptor),
            HostOperation::Open,
        )
    }

    pub fn write_new_readonly(
        &self,
        name: &str,
        bytes: &[u8],
        budget: &IoBudget,
    ) -> Result<HeldFile, HostError> {
        if bytes.len() as u64 > budget.maximum_bytes {
            return Err(HostError::LimitExceeded);
        }
        budget.check()?;
        let name = component(OsStr::new(name))?;
        let file = self.create_file(&name)?;
        let identity = Stat::of(&file)?.identity()?;
        let result = (|| {
            for (index, chunk) in bytes.chunks(CHUNK_BYTES).enumerate() {
                budget.check()?;
                write_all_at(&file, chunk, (index * CHUNK_BYTES) as u64)?;
            }
            self.seal(&file, &name, false, budget)
        })();
        match result {
            Ok(value) => Ok(value),
            Err(error) => {
                drop(file);
                self.remove_owned_component(&name, identity)
                    .map_err(|_| HostError::CleanupFailed)?;
                Err(error)
            }
        }
    }

    /// `fchmod(0400|0500)`, flush, then rebind by name to the same identity.
    fn seal(
        &self,
        file: &File,
        name: &CString,
        executable: bool,
        budget: &IoBudget,
    ) -> Result<HeldFile, HostError> {
        budget.check()?;
        flush(file)?;
        set_owner_only(file, if executable { "FRFX" } else { "FR" })?;
        self.sync()?;
        let identity = Stat::of(file)?.identity()?;
        let sealed = self.open_file_component(name.clone(), true)?;
        if sealed.initial.identity != identity {
            return Err(HostError::IdentityMismatch);
        }
        budget.check()?;
        Ok(sealed)
    }

    pub fn copy_snapshot(
        &self,
        source: &HeldFile,
        name: &str,
        executable: bool,
        budget: &IoBudget,
    ) -> Result<(HeldFile, SourceFacts), HostError> {
        source.verify()?;
        if source.initial.byte_count > budget.maximum_bytes {
            return Err(HostError::LimitExceeded);
        }
        budget.check()?;
        let name = component(OsStr::new(name))?;
        let output = self.create_file(&name)?;
        let identity = Stat::of(&output)?.identity()?;
        let result = (|| {
            let facts =
                source.scan(budget, |offset, chunk| write_all_at(&output, chunk, offset))?;
            let sealed = self.seal(&output, &name, executable, budget)?;
            if sealed.initial.byte_count != facts.byte_count {
                return Err(HostError::Changed);
            }
            Ok((sealed, facts))
        })();
        drop(output);
        let result = result.and_then(|(sealed, facts)| {
            // Verify the exact output independently, after closing writable access.
            if sealed.facts(budget)? != facts {
                return Err(HostError::Changed);
            }
            Ok((sealed, facts))
        });
        match result {
            Ok(value) => Ok(value),
            Err(error) => {
                self.remove_owned_component(&name, identity)
                    .map_err(|_| HostError::CleanupFailed)?;
                Err(error)
            }
        }
    }

    pub fn promote_noreplace(
        &self,
        file: &HeldFile,
        destination: &Self,
        name: &str,
        budget: &IoBudget,
    ) -> Result<HeldFile, HostError> {
        if file.parent.identity() != self.identity() || !file.private || !destination.0.private {
            return Err(HostError::NotPrivate);
        }
        if self.identity().device != destination.identity().device {
            return Err(HostError::CrossVolume);
        }
        if file.initial.byte_count > budget.maximum_bytes {
            return Err(HostError::LimitExceeded);
        }
        let name = component(OsStr::new(name))?;
        budget.check()?;
        file.verify()?;
        destination.revalidate()?;
        budget.cancellation.publication(|| {
            budget.check_deadline()?;
            file.verify()?;
            destination.revalidate()?;
            rename_entry(&self.0.file, &file.name, &destination.0.file, &name, false)
        })?;
        let result = (|| {
            self.sync()?;
            destination.sync()?;
            let ready = destination.open_file_component(name.clone(), true)?;
            if ready.initial.identity != file.initial.identity {
                return Err(HostError::IdentityMismatch);
            }
            // A rename legitimately moves the change time; everything else,
            // including the security digest, must match the sealed candidate.
            let mut expected = file.initial;
            expected.change = ready.initial.change;
            if ready.initial != expected {
                return Err(HostError::Changed);
            }
            budget.check()?;
            Ok(ready)
        })();
        match result {
            Ok(ready) => Ok(ready),
            Err(error) => {
                destination
                    .remove_owned_component(&name, file.initial.identity)
                    .map_err(|_| HostError::CleanupFailed)?;
                Err(error)
            }
        }
    }

    pub fn remove_owned_file(&self, name: &str, expected: FileIdentity) -> Result<(), HostError> {
        self.remove_owned_component(&component(OsStr::new(name))?, expected)
    }

    fn remove_owned_component(
        &self,
        name: &CString,
        expected: FileIdentity,
    ) -> Result<(), HostError> {
        if !self.0.private {
            return Err(HostError::NotPrivate);
        }
        self.revalidate()?;
        remove_child(&self.0.file, name, expected, false)?;
        self.sync()
    }

    /// Directory metadata flush. A directory held without write access (a
    /// trusted public ancestor) cannot be flushed; NTFS journals its metadata.
    pub fn sync(&self) -> Result<(), HostError> {
        self.revalidate()?;
        if self.0.writable {
            flush(&self.0.file)?;
        }
        Ok(())
    }
}

fn flush(file: &File) -> Result<(), HostError> {
    // SAFETY: a live handle opened with write (or add-entry) access.
    bool_result(
        unsafe { FlushFileBuffers(file.as_raw_handle()) },
        HostOperation::Sync,
    )
}

fn write_all_at(file: &File, mut bytes: &[u8], mut offset: u64) -> Result<(), HostError> {
    while !bytes.is_empty() {
        let count = file
            .seek_write(bytes, offset)
            .map_err(|e| from_io(e, HostOperation::Write))?;
        if count == 0 {
            return Err(HostError::SystemIo {
                operation: HostOperation::Write,
                code: 0,
            });
        }
        bytes = &bytes[count..];
        offset += count as u64;
    }
    Ok(())
}

#[cfg(test)]
#[path = "windows_tests.rs"]
mod tests;

impl HeldFile {
    /// Explicit raw inputs may resolve links once. The canonical parents and
    /// final file are then opened without following links and held.
    pub fn open_explicit_source(path: &Path) -> Result<Self, HostError> {
        if !path.is_absolute() {
            return Err(HostError::InvalidPath);
        }
        let canonical = std::fs::canonicalize(path).map_err(|e| from_io(e, HostOperation::Open))?;
        let parent = HeldDirectory::open(canonical.parent().ok_or(HostError::InvalidPath)?, false)?;
        parent.open_file_component(
            component(canonical.file_name().ok_or(HostError::InvalidPath)?)?,
            false,
        )
    }

    fn bound(
        file: File,
        parent: HeldDirectory,
        name: CString,
        private: bool,
    ) -> Result<Self, HostError> {
        let stat = Stat::of(&file)?;
        if !stat.is_file() {
            return Err(HostError::NotRegular);
        }
        if private {
            require_private_security(&file)?;
            if stat.links != 1 {
                return Err(HostError::LinkedObject);
            }
        }
        let value = Self {
            initial: FileSnapshot::of(&file)?,
            file,
            parent,
            name,
            private,
        };
        value.verify()?;
        Ok(value)
    }

    pub fn snapshot(&self) -> FileSnapshot {
        self.initial
    }

    /// Immutable backup/publication inputs must grant nobody write access.
    pub fn require_readonly(&self) -> Result<(), HostError> {
        self.verify()?;
        if !Access::of(&self.file)?.readonly() {
            return Err(HostError::NotPrivate);
        }
        Ok(())
    }

    pub fn path(&self) -> PathBuf {
        self.parent
            .path()
            .join(self.name.to_str().unwrap_or_default())
    }

    /// SQLite reopening path for this exact private sealed file. Windows has no
    /// `/dev/fd`: the caller must keep this HeldFile for the connection's whole
    /// lifetime and bind SQLite's own handle with
    /// [`HeldFile::verify_sqlite_readonly_connection`].
    pub fn readonly_database_path(&self) -> Result<PathBuf, HostError> {
        self.verify()?;
        if !self.private || !Access::of(&self.file)?.sealed() {
            return Err(HostError::NotPrivate);
        }
        for suffix in ["-journal", "-wal", "-shm"] {
            let name = component(OsStr::new(&format!(
                "{}{suffix}",
                self.name.to_str().map_err(|_| HostError::InvalidPath)?
            )))?;
            match stat_child(&self.parent.0.file, &name) {
                Err(HostError::NotFound) => {}
                Ok(_) => return Err(HostError::InvalidEvidence),
                Err(error) => return Err(error),
            }
        }
        Ok(self.path())
    }

    /// Bind a read-only SQLite connection's actual main-file handle (from its
    /// FILESTAT) to this held file's identity.
    pub fn verify_sqlite_readonly_connection(
        &self,
        connection: &rusqlite::Connection,
    ) -> Result<(), HostError> {
        self.verify()?;
        if writable::sqlite_handle_identity(connection)? != self.initial.identity {
            return Err(HostError::IdentityMismatch);
        }
        self.verify()
    }

    /// Inspect a small header without materializing the whole source.
    pub fn read_prefix(
        &self,
        prefix_bytes: usize,
        budget: &IoBudget,
    ) -> Result<Vec<u8>, HostError> {
        if prefix_bytes == 0 || prefix_bytes > CHUNK_BYTES {
            return Err(HostError::InvalidLimit);
        }
        budget.check()?;
        if self.initial.byte_count > budget.maximum_bytes {
            return Err(HostError::LimitExceeded);
        }
        self.verify()?;
        let mut bytes = vec![0; prefix_bytes.min(self.initial.byte_count as usize)];
        let mut offset = 0;
        while offset < bytes.len() {
            budget.check()?;
            let count = match self.file.seek_read(&mut bytes[offset..], offset as u64) {
                Ok(count) => count,
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(error) => return Err(from_io(error, HostOperation::Read)),
            };
            if count == 0 {
                return Err(HostError::Changed);
            }
            offset += count;
        }
        budget.check()?;
        self.verify()?;
        Ok(bytes)
    }

    pub fn verify(&self) -> Result<(), HostError> {
        self.parent.revalidate()?;
        let linked = stat_child(&self.parent.0.file, &self.name)?;
        if !linked.is_file() || linked.identity()? != self.initial.identity {
            return Err(HostError::IdentityMismatch);
        }
        if FileSnapshot::of(&self.file)? != self.initial {
            return Err(HostError::Changed);
        }
        if self.private {
            require_private_security(&self.file)?;
        }
        Ok(())
    }

    fn scan(
        &self,
        budget: &IoBudget,
        mut consume: impl FnMut(u64, &[u8]) -> Result<(), HostError>,
    ) -> Result<SourceFacts, HostError> {
        if budget.maximum_bytes == 0 {
            return Err(HostError::InvalidLimit);
        }
        if self.initial.byte_count > budget.maximum_bytes
            || self.initial.byte_count > i64::MAX as u64
        {
            return Err(HostError::LimitExceeded);
        }
        budget.check()?;
        self.verify()?;
        let mut buffer = vec![0; CHUNK_BYTES];
        let mut offset = 0_u64;
        let mut hash = Sha256::new();
        loop {
            budget.check()?;
            let count = match self.file.seek_read(&mut buffer, offset) {
                Ok(value) => value,
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(error) => return Err(from_io(error, HostOperation::Read)),
            };
            if count == 0 {
                break;
            }
            let next = offset
                .checked_add(count as u64)
                .ok_or(HostError::LimitExceeded)?;
            if next > budget.maximum_bytes || next > self.initial.byte_count {
                return Err(HostError::Changed);
            }
            hash.update(&buffer[..count]);
            consume(offset, &buffer[..count])?;
            offset = next;
        }
        budget.check()?;
        self.verify()?;
        if offset != self.initial.byte_count {
            return Err(HostError::Changed);
        }
        Ok(SourceFacts {
            sha256: format!("{:x}", hash.finalize()),
            byte_count: offset,
        })
    }

    pub fn facts(&self, budget: &IoBudget) -> Result<SourceFacts, HostError> {
        self.scan(budget, |_, _| Ok(()))
    }

    pub fn read_bounded(&self, budget: &IoBudget) -> Result<Vec<u8>, HostError> {
        if self.initial.byte_count > budget.maximum_bytes {
            return Err(HostError::LimitExceeded);
        }
        let capacity =
            usize::try_from(self.initial.byte_count).map_err(|_| HostError::LimitExceeded)?;
        let mut bytes = Vec::new();
        bytes
            .try_reserve_exact(capacity)
            .map_err(|_| HostError::LimitExceeded)?;
        self.scan(budget, |_, chunk| {
            bytes.extend_from_slice(chunk);
            Ok(())
        })?;
        Ok(bytes)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LeaseMode {
    Shared,
    Exclusive,
}

pub struct Lease {
    file: File,
    parent: HeldDirectory,
    name: CString,
    identity: FileIdentity,
    mode: LeaseMode,
    newly_created: bool,
    /// A failed non-atomic downgrade released the byte; no authority remains.
    lost: bool,
}

/// Fresh per-session lease. Unlike stable cache locks, its name may be removed
/// after the owned ephemeral entry is gone. Existing names are never admitted.
pub struct EphemeralLease(Lease);
impl EphemeralLease {
    pub fn acquire(
        parent: &HeldDirectory,
        name: &str,
        budget: &IoBudget,
    ) -> Result<Self, HostError> {
        budget.check()?;
        Lease::try_acquire_impl(parent, name, LeaseMode::Exclusive, true, true, false)?
            .map(Self)
            .ok_or(HostError::Busy)
    }
    pub fn revalidate(&self) -> Result<(), HostError> {
        self.0.revalidate()
    }
    pub fn remove(self) -> Result<(), HostError> {
        self.0.revalidate()?;
        if !self.0.newly_created || self.0.mode != LeaseMode::Exclusive {
            return Err(HostError::InvalidEvidence);
        }
        self.0
            .parent
            .remove_owned_component(&self.0.name, self.0.identity)?;
        self.0.parent.sync()
    }
}

impl Lease {
    /// The empty-file lease protocol shared with the ArkDeck purger: one
    /// `LockFileEx` byte at 2^64-2. Existing lease files are validated unchanged.
    pub fn try_acquire(
        parent: &HeldDirectory,
        name: &str,
        mode: LeaseMode,
        create: bool,
    ) -> Result<Option<Self>, HostError> {
        Self::try_acquire_impl(parent, name, mode, create, false, false)
    }

    /// Read-only migration authority. Missing locks are never created; an
    /// existing file is opened for reading and keeps its security and bytes.
    pub fn try_acquire_existing_readonly(
        parent: &HeldDirectory,
        name: &str,
        mode: LeaseMode,
    ) -> Result<Option<Self>, HostError> {
        Self::try_acquire_impl(parent, name, mode, false, false, true)
    }

    pub fn acquire_existing_readonly(
        parent: &HeldDirectory,
        name: &str,
        mode: LeaseMode,
        budget: &IoBudget,
    ) -> Result<Self, HostError> {
        loop {
            budget.check()?;
            if let Some(lease) = Self::try_acquire_existing_readonly(parent, name, mode)? {
                return Ok(lease);
            }
            thread::sleep(
                Duration::from_millis(5)
                    .min(budget.deadline.saturating_duration_since(Instant::now())),
            );
        }
    }

    fn try_acquire_impl(
        parent: &HeldDirectory,
        name: &str,
        mode: LeaseMode,
        create: bool,
        require_fresh: bool,
        readonly_existing: bool,
    ) -> Result<Option<Self>, HostError> {
        if !parent.0.private {
            return Err(HostError::NotPrivate);
        }
        parent.revalidate()?;
        let name = component(OsStr::new(name))?;
        let wide = utf16(&name)?;
        let access = if readonly_existing {
            READ
        } else {
            READ | FILE_WRITE_DATA
        };
        let mut created = None;
        if create {
            let descriptor = Descriptor::owner_only("FA", false)?;
            match nt_open(
                &parent.0.file,
                &wide,
                access,
                FILE_CREATE,
                Kind::NonDirectory,
                Some(&descriptor),
                HostOperation::Open,
            ) {
                Ok(file) => created = Some(file),
                Err(HostError::AlreadyExists) if !require_fresh => {}
                Err(error) => return Err(error),
            }
        }
        let newly_created = created.is_some();
        if require_fresh && !newly_created {
            return Err(HostError::AlreadyExists);
        }
        let file = match created {
            Some(file) => file,
            None => nt_open(
                &parent.0.file,
                &wide,
                access,
                FILE_OPEN,
                Kind::NonDirectory,
                None,
                HostOperation::Open,
            )?,
        };
        let stat = Stat::of(&file)?;
        if !stat.is_file() {
            return Err(HostError::NotRegular);
        }
        require_private_security(&file)?;
        if stat.links != 1 {
            return Err(HostError::LinkedObject);
        }
        if readonly_existing && stat.size != 0 {
            return Err(HostError::InvalidEvidence);
        }
        let identity = stat.identity()?;
        match lock_byte(&file, mode == LeaseMode::Exclusive) {
            Ok(true) => {}
            Ok(false) if !require_fresh => return Ok(None),
            result => {
                if require_fresh {
                    drop(file);
                    remove_child(&parent.0.file, &name, identity, false)
                        .map_err(|_| HostError::CleanupFailed)?;
                    parent.sync().map_err(|_| HostError::CleanupFailed)?;
                }
                return Err(match result {
                    Err(error) => error,
                    _ => HostError::Busy,
                });
            }
        }
        let lease = Self {
            file,
            parent: parent.clone(),
            name,
            identity,
            mode,
            newly_created,
            lost: false,
        };
        lease.revalidate()?;
        Ok(Some(lease))
    }

    pub fn acquire(
        parent: &HeldDirectory,
        name: &str,
        mode: LeaseMode,
        budget: &IoBudget,
    ) -> Result<Self, HostError> {
        loop {
            budget.check()?;
            if let Some(lease) = Self::try_acquire(parent, name, mode, true)? {
                return Ok(lease);
            }
            thread::sleep(
                Duration::from_millis(5)
                    .min(budget.deadline.saturating_duration_since(Instant::now())),
            );
        }
    }

    pub fn mode(&self) -> LeaseMode {
        self.mode
    }

    /// `LockFileEx` cannot convert an exclusive range lock in place: the byte
    /// is released and immediately retaken shared without waiting. If another
    /// locker wins that window the lease is lost and every later use fails.
    pub fn downgrade_shared(&mut self) -> Result<(), HostError> {
        self.revalidate()?;
        if self.mode == LeaseMode::Shared {
            return Ok(());
        }
        unlock_byte(&self.file)?;
        match lock_byte(&self.file, false) {
            Ok(true) => {}
            Ok(false) => {
                self.lost = true;
                return Err(HostError::Busy);
            }
            Err(error) => {
                self.lost = true;
                return Err(error);
            }
        }
        self.mode = LeaseMode::Shared;
        self.revalidate()
    }

    pub fn revalidate(&self) -> Result<(), HostError> {
        if self.lost {
            return Err(HostError::Busy);
        }
        self.parent.revalidate()?;
        let linked = stat_child(&self.parent.0.file, &self.name)?;
        let stat = Stat::of(&self.file)?;
        if !linked.is_file()
            || linked.identity()? != self.identity
            || stat.identity()? != self.identity
            || stat.links != 1
            || stat.delete_pending
        {
            return Err(HostError::IdentityMismatch);
        }
        require_private_security(&self.file)
    }
}

/// The known-folder `LocalAppData\<name>` workspace (the product-scoped name
/// plays the role of Darwin's `/private/tmp/<name>-u<uid>`). The shared
/// `LocalAppData\Temp` is not used: it commonly carries write grants for other
/// principals (sandbox accounts, AppContainer capabilities) that fail the
/// trusted-ancestor rule. No environment variable (`TEMP`, `TMP`,
/// `LOCALAPPDATA`) is consulted; existing owners and DACLs are validated,
/// never repaired.
pub fn user_temporary_workspace(name: &str) -> Result<HeldDirectory, HostError> {
    let name = component(OsStr::new(name))?;
    let parent = HeldDirectory::open_trusted_temporary_parent(&known_local_app_data()?)?;
    parent.revalidate()?;
    match parent.make_private_directory(&name) {
        Ok(()) | Err(HostError::AlreadyExists) => {}
        Err(error) => return Err(error),
    }
    let child = parent.open_child(&name, true, true)?;
    child.revalidate()?;
    parent.sync()?;
    Ok(child)
}

fn known_local_app_data() -> Result<PathBuf, HostError> {
    let mut path = null_mut();
    // SAFETY: a fixed known-folder id; the returned string is freed below.
    let status = unsafe {
        SHGetKnownFolderPath(
            &FOLDERID_LocalAppData,
            KF_FLAG_DEFAULT as u32,
            null_mut(),
            &mut path,
        )
    };
    struct TaskMemory(*mut u16);
    impl Drop for TaskMemory {
        fn drop(&mut self) {
            // SAFETY: CoTaskMemFree accepts the API allocation or null.
            unsafe { CoTaskMemFree(self.0.cast()) };
        }
    }
    let path = TaskMemory(path);
    if status < 0 || path.0.is_null() {
        return Err(HostError::NotFound);
    }
    let mut length = 0;
    // SAFETY: a successful result is a NUL-terminated UTF-16 string.
    unsafe {
        while *path.0.add(length) != 0 {
            length += 1;
        }
    }
    // SAFETY: the measured length lies inside the API-owned string.
    let text = OsString::from_wide(unsafe { std::slice::from_raw_parts(path.0, length) });
    Ok(PathBuf::from(text))
}
