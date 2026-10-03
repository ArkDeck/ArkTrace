//! CoreFoundation/Security boundary, declarations checked against Xcode 27.
use super::{HeldFile, process::ProcessError};
use std::{ffi::c_void, os::unix::ffi::OsStrExt, path::Path, ptr};

type Ref = *const c_void;
const NO_NETWORK: u32 = 1 << 29;
const STRICT_ALL_ARCHITECTURES: u32 = (1 << 0) | (1 << 4) | NO_NETWORK;

#[derive(Clone, Debug, Eq, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub enum CodeTrustPolicy {
    /// Development artifact pin, still requiring a valid Mach-O code signature.
    DevelopmentPinned,
    DeveloperId {
        team_identifier: String,
        code_identifier: String,
    },
}

#[derive(Clone, Debug, Eq, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TrustVerdict {
    pub code_directory_hash: Vec<u8>,
    pub hardened_runtime: bool,
    pub developer_id: bool,
}

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    fn CFRelease(value: Ref);
    fn CFURLCreateFromFileSystemRepresentation(
        allocator: Ref,
        bytes: *const u8,
        length: isize,
        directory: u8,
    ) -> Ref;
    fn CFStringCreateWithBytes(
        allocator: Ref,
        bytes: *const u8,
        length: isize,
        encoding: u32,
        external: u8,
    ) -> Ref;
    fn CFNumberCreate(allocator: Ref, kind: isize, value: *const c_void) -> Ref;
    fn CFNumberGetValue(number: Ref, kind: isize, value: *mut c_void) -> u8;
    fn CFDictionaryCreate(
        allocator: Ref,
        keys: *const Ref,
        values: *const Ref,
        count: isize,
        key_callbacks: Ref,
        value_callbacks: Ref,
    ) -> Ref;
    fn CFDictionaryGetValue(dictionary: Ref, key: Ref) -> Ref;
    fn CFDataGetLength(data: Ref) -> isize;
    fn CFDataGetBytePtr(data: Ref) -> *const u8;
    fn CFGetTypeID(value: Ref) -> usize;
    fn CFDataGetTypeID() -> usize;
    fn CFNumberGetTypeID() -> usize;
}
#[link(name = "Security", kind = "framework")]
unsafe extern "C" {
    fn SecStaticCodeCreateWithPath(path: Ref, flags: u32, code: *mut Ref) -> i32;
    fn SecStaticCodeCheckValidity(code: Ref, flags: u32, requirement: Ref) -> i32;
    fn SecRequirementCreateWithString(text: Ref, flags: u32, requirement: *mut Ref) -> i32;
    fn SecCodeCopySigningInformation(code: Ref, flags: u32, information: *mut Ref) -> i32;
    fn SecCodeCopyGuestWithAttributes(
        host: Ref,
        attributes: Ref,
        flags: u32,
        guest: *mut Ref,
    ) -> i32;
    fn SecCodeCheckValidity(code: Ref, flags: u32, requirement: Ref) -> i32;
    static kSecCodeInfoUnique: Ref;
    static kSecCodeInfoFlags: Ref;
    static kSecGuestAttributePid: Ref;
}

struct Owned(Ref);
impl Owned {
    fn new(value: Ref) -> Result<Self, ProcessError> {
        if value.is_null() {
            Err(ProcessError::TrustUnavailable)
        } else {
            Ok(Self(value))
        }
    }
}
impl Drop for Owned {
    fn drop(&mut self) {
        // SAFETY: every Owned came from a CF/Security create/copy rule, released once.
        unsafe { CFRelease(self.0) };
    }
}

fn requirement(policy: &CodeTrustPolicy) -> Result<Option<Owned>, ProcessError> {
    let CodeTrustPolicy::DeveloperId {
        team_identifier,
        code_identifier,
    } = policy
    else {
        return Ok(None);
    };
    if team_identifier.len() != 10
        || !team_identifier
            .bytes()
            .all(|b| b.is_ascii_uppercase() || b.is_ascii_digit())
        || code_identifier.is_empty()
        || code_identifier.len() > 256
        || !code_identifier
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b".-_".contains(&b))
    {
        return Err(ProcessError::InvalidPolicy);
    }
    let text = format!(
        "anchor apple generic and identifier \"{code_identifier}\" and certificate leaf[subject.OU] = \"{team_identifier}\" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
    );
    // SAFETY: valid UTF-8 bytes and explicit length, CF copies the text.
    let string = Owned::new(unsafe {
        CFStringCreateWithBytes(
            ptr::null(),
            text.as_ptr(),
            text.len() as isize,
            0x08000100,
            0,
        )
    })?;
    let mut result = ptr::null();
    // SAFETY: live CF string and writable out-pointer, returns retained requirement.
    if unsafe { SecRequirementCreateWithString(string.0, 0, &mut result) } != 0 {
        return Err(ProcessError::InvalidPolicy);
    }
    Ok(Some(Owned::new(result)?))
}

fn information(code: Ref) -> Result<TrustVerdict, ProcessError> {
    let mut info = ptr::null();
    // SAFETY: live SecCode/SecStaticCode, signing information flag, retained out-pointer.
    if unsafe { SecCodeCopySigningInformation(code, 1 << 1, &mut info) } != 0 {
        return Err(ProcessError::SignatureInvalid);
    }
    let info = Owned::new(info)?;
    // SAFETY: dictionary is live and exported keys are CFString constants.
    let (hash, flags) = unsafe {
        (
            CFDictionaryGetValue(info.0, kSecCodeInfoUnique),
            CFDictionaryGetValue(info.0, kSecCodeInfoFlags),
        )
    };
    // SAFETY: non-null values are checked against their CF runtime types before access.
    if hash.is_null()
        || flags.is_null()
        || unsafe {
            CFGetTypeID(hash) != CFDataGetTypeID() || CFGetTypeID(flags) != CFNumberGetTypeID()
        }
    {
        return Err(ProcessError::SignatureInvalid);
    }
    // SAFETY: hash is verified CFData; length bounded before copying its bytes.
    let length = unsafe { CFDataGetLength(hash) };
    if !(20..=64).contains(&length) {
        return Err(ProcessError::SignatureInvalid);
    }
    let mut bits = 0_i64;
    // SAFETY: verified CFNumber and an i64 out-pointer (kCFNumberSInt64Type = 4).
    if unsafe { CFNumberGetValue(flags, 4, (&mut bits as *mut i64).cast()) } == 0 {
        return Err(ProcessError::SignatureInvalid);
    }
    // SAFETY: live CFData, bounded nonzero length, data remains live during the copy.
    let code_directory_hash =
        unsafe { std::slice::from_raw_parts(CFDataGetBytePtr(hash), length as usize) }.to_vec();
    Ok(TrustVerdict {
        code_directory_hash,
        hardened_runtime: bits & 0x10000 != 0,
        developer_id: false,
    })
}

pub(super) fn verify_path(
    path: &Path,
    policy: &CodeTrustPolicy,
) -> Result<TrustVerdict, ProcessError> {
    let bytes = path.as_os_str().as_bytes();
    // SAFETY: explicit filesystem bytes and length; CF copies them into a URL.
    let url = Owned::new(unsafe {
        CFURLCreateFromFileSystemRepresentation(
            ptr::null(),
            bytes.as_ptr(),
            bytes.len() as isize,
            0,
        )
    })?;
    let mut code = ptr::null();
    // SAFETY: live CFURL and retained output pointer.
    if unsafe { SecStaticCodeCreateWithPath(url.0, 0, &mut code) } != 0 {
        return Err(ProcessError::SignatureInvalid);
    }
    let code = Owned::new(code)?;
    let requirement = requirement(policy)?;
    // SAFETY: live code/optional requirement, strict static validation with network forbidden.
    if unsafe {
        SecStaticCodeCheckValidity(
            code.0,
            STRICT_ALL_ARCHITECTURES,
            requirement.as_ref().map_or(ptr::null(), |r| r.0),
        )
    } != 0
    {
        return Err(if requirement.is_some() {
            ProcessError::TrustRejected
        } else {
            ProcessError::SignatureInvalid
        });
    }
    let mut verdict = information(code.0)?;
    if requirement.is_some() {
        if !verdict.hardened_runtime {
            return Err(ProcessError::TrustRejected);
        }
        verdict.developer_id = true;
    }
    Ok(verdict)
}

pub(super) fn verify_loaded(
    pid: i32,
    executable: &HeldFile,
    expected: &TrustVerdict,
    policy: &CodeTrustPolicy,
) -> Result<(), ProcessError> {
    executable.verify()?;
    // SAFETY: pid is a live owned child; NSNumber copies the 32-bit PID.
    let number =
        Owned::new(unsafe { CFNumberCreate(ptr::null(), 3, (&pid as *const i32).cast()) })?;
    // Borrowed dictionary keys/values remain live until the Security call finishes.
    // SAFETY: one exported CFString key and one live NSNumber, explicit count.
    let attributes = Owned::new(unsafe {
        CFDictionaryCreate(
            ptr::null(),
            &kSecGuestAttributePid,
            &number.0,
            1,
            ptr::null(),
            ptr::null(),
        )
    })?;
    let mut code = ptr::null();
    // SAFETY: asks the kernel code host for this PID, retained output pointer.
    if unsafe { SecCodeCopyGuestWithAttributes(ptr::null(), attributes.0, 0, &mut code) } != 0 {
        return Err(ProcessError::TrustUnavailable);
    }
    let code = Owned::new(code)?;
    let requirement = requirement(policy)?;
    // SAFETY: live dynamic code and requirement; validation does not use the network.
    if unsafe {
        SecCodeCheckValidity(
            code.0,
            NO_NETWORK,
            requirement.as_ref().map_or(ptr::null(), |r| r.0),
        )
    } != 0
    {
        return Err(ProcessError::TrustRejected);
    }
    let actual = information(code.0)?;
    if actual.code_directory_hash != expected.code_directory_hash {
        return Err(ProcessError::DigestMismatch);
    }
    executable.verify()?;
    Ok(())
}
