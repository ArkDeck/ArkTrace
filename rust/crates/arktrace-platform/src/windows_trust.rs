//! Authenticode boundary (user ruling (b) of 2026-10-14 for the Windows
//! ArkTrace distribution): a signer is pinned by publisher identity, never by
//! a leaf certificate hash that rotates, and every pinned file is also pinned
//! by its whole SHA-256. `WinVerifyTrust` runs on the held handle itself
//! (generic Authenticode policy, whole-chain revocation from the cache only,
//! root excluded, no network retrieval). The signer chain read and the
//! subject decode are adapted from ArkDeck
//! `arkdeck-platform/src/windows/{identity.rs,publisher.rs}` (MIT, same
//! organization).
use super::{HeldFile, process::ProcessError, wide_terminated};
use sha2::{Digest, Sha256};
use std::{
    ffi::OsString,
    mem::size_of,
    os::windows::{ffi::OsStringExt, io::AsRawHandle},
    path::PathBuf,
    ptr::{null, null_mut},
};
use windows_sys::Win32::Foundation::{
    HANDLE, INVALID_HANDLE_VALUE, LocalFree, TRUST_E_NOSIGNATURE,
};
use windows_sys::Win32::Security::Cryptography::{
    CERT_CONTEXT, CERT_NAME_INFO, CRYPT_DECODE_ALLOC_FLAG, CertCreateCertificateContext,
    CertFreeCertificateContext, CertRDNValueToStrW, CryptDecodeObjectEx, PKCS_7_ASN_ENCODING,
    X509_ASN_ENCODING, X509_NAME,
};
use windows_sys::Win32::Security::WinTrust::{
    WINTRUST_ACTION_GENERIC_VERIFY_V2, WINTRUST_DATA, WINTRUST_DATA_0, WINTRUST_FILE_INFO,
    WTD_CACHE_ONLY_URL_RETRIEVAL, WTD_CHOICE_FILE, WTD_REVOCATION_CHECK_CHAIN_EXCLUDE_ROOT,
    WTD_REVOKE_WHOLECHAIN, WTD_STATEACTION_CLOSE, WTD_STATEACTION_VERIFY, WTD_UI_NONE,
    WTHelperGetProvCertFromChain, WTHelperGetProvSignerFromChain, WTHelperProvDataFromStateData,
    WinVerifyTrust,
};
use windows_sys::Win32::System::Threading::QueryFullProcessImageNameW;

#[derive(Clone, Debug, Eq, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub enum CodeTrustPolicy {
    /// Development artifact pinned by its whole SHA-256 alone. An image that
    /// carries an Authenticode signature must still verify; an unsigned one
    /// is admitted (Windows has no ad-hoc signature to require).
    DevelopmentPinned,
    /// A valid Authenticode signature whose signer is `publisher`: the
    /// leaf's single subject `O=`, or its single `CN=` when it has no `O=`.
    AuthenticodePublisher { publisher: String },
}

#[derive(Clone, Debug, Eq, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TrustVerdict {
    /// The verified signer's name; `None` for an unsigned development image.
    pub signer: Option<String>,
    /// SHA-256 of the verified leaf certificate (recorded, never pinned).
    pub signer_certificate_sha256: Option<String>,
    /// The image satisfied an `AuthenticodePublisher` policy.
    pub authenticode_publisher: bool,
}

fn valid_publisher(publisher: &str) -> bool {
    !publisher.is_empty()
        && publisher.len() <= 256
        && publisher.trim() == publisher
        && !publisher.chars().any(char::is_control)
}

/// `WinVerifyTrust` on the exact held handle, then the policy's pin.
pub(super) fn verify_file(
    file: &HeldFile,
    policy: &CodeTrustPolicy,
) -> Result<TrustVerdict, ProcessError> {
    if let CodeTrustPolicy::AuthenticodePublisher { publisher } = policy
        && !valid_publisher(publisher)
    {
        return Err(ProcessError::InvalidPolicy);
    }
    file.verify()?;
    let chain = authenticode_chain(file)?;
    file.verify()?;
    let verdict = match chain {
        Err(status) if status == TRUST_E_NOSIGNATURE => {
            if matches!(policy, CodeTrustPolicy::AuthenticodePublisher { .. }) {
                return Err(ProcessError::TrustRejected);
            }
            TrustVerdict {
                signer: None,
                signer_certificate_sha256: None,
                authenticode_publisher: false,
            }
        }
        Err(_) => {
            return Err(
                if matches!(policy, CodeTrustPolicy::AuthenticodePublisher { .. }) {
                    ProcessError::TrustRejected
                } else {
                    ProcessError::SignatureInvalid
                },
            );
        }
        Ok(chain) => {
            let leaf = chain.first().ok_or(ProcessError::SignatureInvalid)?;
            let signer = signer_name(leaf)?;
            let authenticode_publisher = match policy {
                CodeTrustPolicy::AuthenticodePublisher { publisher } => {
                    if signer != *publisher {
                        return Err(ProcessError::TrustRejected);
                    }
                    true
                }
                CodeTrustPolicy::DevelopmentPinned => false,
            };
            TrustVerdict {
                signer: Some(signer),
                signer_certificate_sha256: Some(format!("{:x}", Sha256::digest(leaf))),
                authenticode_publisher,
            }
        }
    };
    Ok(verdict)
}

/// The suspended child's image is the held, verified file: its Win32 image
/// path names an entry whose file identity is the held one. A running image
/// cannot be written (its section maps it), so the identity also binds the
/// verified bytes; the held snapshot is rechecked on both sides.
pub(super) fn verify_loaded(process: HANDLE, executable: &HeldFile) -> Result<(), ProcessError> {
    executable.verify()?;
    let mut buffer = vec![0_u16; 32_768];
    let mut length = buffer.len() as u32;
    // SAFETY: a live process handle and a writable buffer of `length` units.
    if unsafe { QueryFullProcessImageNameW(process, 0, buffer.as_mut_ptr(), &mut length) } == 0 {
        return Err(ProcessError::TrustUnavailable);
    }
    let image = PathBuf::from(OsString::from_wide(&buffer[..length as usize]));
    let loaded = HeldFile::open_explicit_source(&image).map_err(ProcessError::Host)?;
    if loaded.snapshot().identity != executable.initial.identity {
        return Err(ProcessError::DigestMismatch);
    }
    executable.verify()?;
    Ok(())
}

/// The verified first signer's chain (leaf first), or `WinVerifyTrust`'s
/// status when it did not accept the image.
fn authenticode_chain(file: &HeldFile) -> Result<Result<Vec<Vec<u8>>, i32>, ProcessError> {
    let path = wide_terminated(file.path().as_os_str())?;
    let mut file_info = WINTRUST_FILE_INFO {
        cbStruct: size_of::<WINTRUST_FILE_INFO>() as u32,
        pcwszFilePath: path.as_ptr(),
        hFile: file.file.as_raw_handle(),
        pgKnownSubject: null_mut(),
    };
    let mut data = WINTRUST_DATA {
        cbStruct: size_of::<WINTRUST_DATA>() as u32,
        dwUIChoice: WTD_UI_NONE,
        fdwRevocationChecks: WTD_REVOKE_WHOLECHAIN,
        dwUnionChoice: WTD_CHOICE_FILE,
        Anonymous: WINTRUST_DATA_0 {
            pFile: &mut file_info,
        },
        dwStateAction: WTD_STATEACTION_VERIFY,
        dwProvFlags: WTD_CACHE_ONLY_URL_RETRIEVAL | WTD_REVOCATION_CHECK_CHAIN_EXCLUDE_ROOT,
        ..Default::default()
    };
    let mut action = WINTRUST_ACTION_GENERIC_VERIFY_V2;
    // SAFETY: `data` points at `file_info` and `path`, which outlive both
    // calls; certificates are copied out before the state is closed.
    let (status, chain) = unsafe {
        let status = WinVerifyTrust(
            INVALID_HANDLE_VALUE,
            &mut action,
            std::ptr::from_mut(&mut data).cast(),
        );
        let mut chain = Vec::new();
        if status == 0 {
            let provider = WTHelperProvDataFromStateData(data.hWVTStateData);
            let signer = if provider.is_null() {
                null_mut()
            } else {
                WTHelperGetProvSignerFromChain(provider, 0, 0, 0)
            };
            let count = if signer.is_null() {
                0
            } else {
                (*signer).csCertChain
            };
            for index in 0..count {
                let certificate = WTHelperGetProvCertFromChain(signer, index);
                if certificate.is_null() || (*certificate).pCert.is_null() {
                    chain.clear();
                    break;
                }
                let context = &*(*certificate).pCert;
                chain.push(
                    std::slice::from_raw_parts(
                        context.pbCertEncoded,
                        context.cbCertEncoded as usize,
                    )
                    .to_vec(),
                );
            }
        }
        data.dwStateAction = WTD_STATEACTION_CLOSE;
        WinVerifyTrust(
            INVALID_HANDLE_VALUE,
            &mut action,
            std::ptr::from_mut(&mut data).cast(),
        );
        (status, chain)
    };
    if status != 0 {
        return Ok(Err(status));
    }
    if chain.is_empty() {
        // An accepted image with no readable chain is not accepted.
        return Err(ProcessError::SignatureInvalid);
    }
    Ok(Ok(chain))
}

/// The leaf's single subject `O=`, or its single `CN=` without an `O=`.
fn signer_name(der: &[u8]) -> Result<String, ProcessError> {
    let certificate = Certificate::decode(der)?;
    let organizations = certificate.subject_values(b"2.5.4.10")?;
    match organizations.as_slice() {
        [only] => Ok(only.clone()),
        [] => match certificate.subject_values(b"2.5.4.3")?.as_slice() {
            [only] => Ok(only.clone()),
            _ => Err(ProcessError::SignatureInvalid),
        },
        _ => Err(ProcessError::SignatureInvalid),
    }
}

struct Certificate(*const CERT_CONTEXT);
impl Drop for Certificate {
    fn drop(&mut self) {
        // SAFETY: exclusively owned context from CertCreateCertificateContext.
        unsafe { CertFreeCertificateContext(self.0) };
    }
}

struct Decoded(*mut std::ffi::c_void);
impl Drop for Decoded {
    fn drop(&mut self) {
        if !self.0.is_null() {
            // SAFETY: allocated by CryptDecodeObjectEx with CRYPT_DECODE_ALLOC_FLAG.
            unsafe { LocalFree(self.0) };
        }
    }
}

impl Certificate {
    fn decode(der: &[u8]) -> Result<Self, ProcessError> {
        let length = u32::try_from(der.len()).map_err(|_| ProcessError::SignatureInvalid)?;
        // SAFETY: the DER slice outlives the call; the context copies it.
        let context = unsafe {
            CertCreateCertificateContext(
                X509_ASN_ENCODING | PKCS_7_ASN_ENCODING,
                der.as_ptr(),
                length,
            )
        };
        if context.is_null() {
            return Err(ProcessError::SignatureInvalid);
        }
        Ok(Self(context))
    }

    /// Every value of the subject attribute `oid` (dotted ASCII).
    fn subject_values(&self, oid: &[u8]) -> Result<Vec<String>, ProcessError> {
        // SAFETY: live context; its CERT_INFO and subject blob belong to it.
        let subject = unsafe { (*(*self.0).pCertInfo).Subject };
        let mut decoded = Decoded(null_mut());
        let mut length = 0_u32;
        // SAFETY: the subject blob is live; the API allocates the output,
        // which `decoded` releases.
        if unsafe {
            CryptDecodeObjectEx(
                X509_ASN_ENCODING,
                X509_NAME,
                subject.pbData,
                subject.cbData,
                CRYPT_DECODE_ALLOC_FLAG,
                null(),
                std::ptr::from_mut(&mut decoded.0).cast(),
                &mut length,
            )
        } == 0
        {
            return Err(ProcessError::SignatureInvalid);
        }
        let mut values = Vec::new();
        // SAFETY: a successful decode yields a CERT_NAME_INFO whose arrays
        // have the stated counts and live in the same allocation.
        unsafe {
            let name = &*decoded.0.cast::<CERT_NAME_INFO>();
            for rdn in slice(name.rgRDN, name.cRDN) {
                for attribute in slice(rdn.rgRDNAttr, rdn.cRDNAttr) {
                    if attribute.pszObjId.is_null()
                        || std::ffi::CStr::from_ptr(attribute.pszObjId.cast()).to_bytes() != oid
                    {
                        continue;
                    }
                    let size =
                        CertRDNValueToStrW(attribute.dwValueType, &attribute.Value, null_mut(), 0);
                    let mut text = vec![0_u16; size.max(1) as usize];
                    let written = CertRDNValueToStrW(
                        attribute.dwValueType,
                        &attribute.Value,
                        text.as_mut_ptr(),
                        text.len() as u32,
                    );
                    let end = (written as usize).saturating_sub(1).min(text.len());
                    values.push(
                        String::from_utf16(&text[..end])
                            .map_err(|_| ProcessError::SignatureInvalid)?,
                    );
                }
            }
        }
        Ok(values)
    }
}

/// # Safety
/// `pointer` must address `count` initialised elements, or `count` be zero.
unsafe fn slice<'a, T>(pointer: *const T, count: u32) -> &'a [T] {
    if count == 0 || pointer.is_null() {
        &[]
    } else {
        // SAFETY: guaranteed by the caller.
        unsafe { std::slice::from_raw_parts(pointer, count as usize) }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{CancellationToken, IoBudget};
    use std::path::Path;
    use std::time::{Duration, Instant};

    /// An embedded-Authenticode-signed Microsoft image present on Windows
    /// development hosts and GitHub Windows runners alike.
    fn signed_image() -> HeldFile {
        let candidates = [
            r"C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe",
            r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
        ];
        let path = candidates
            .iter()
            .map(Path::new)
            .find(|path| path.is_file())
            .expect("no embedded-signed Microsoft image on this host");
        HeldFile::open_explicit_source(path).unwrap()
    }

    #[test]
    fn a_publisher_pin_accepts_only_the_named_signer() {
        let image = signed_image();
        let microsoft = CodeTrustPolicy::AuthenticodePublisher {
            publisher: "Microsoft Corporation".to_owned(),
        };
        let verdict = verify_file(&image, &microsoft).unwrap();
        assert_eq!(verdict.signer.as_deref(), Some("Microsoft Corporation"));
        assert!(verdict.authenticode_publisher);
        assert_eq!(
            verdict.signer_certificate_sha256.as_ref().unwrap().len(),
            64
        );
        for other in [
            "Contoso Ltd",
            "microsoft corporation",
            "Microsoft Corporation.",
        ] {
            let policy = CodeTrustPolicy::AuthenticodePublisher {
                publisher: other.to_owned(),
            };
            assert_eq!(
                verify_file(&image, &policy),
                Err(ProcessError::TrustRejected),
                "{other}"
            );
        }
        for invalid in ["", " Microsoft Corporation", "a\u{1}b"] {
            let policy = CodeTrustPolicy::AuthenticodePublisher {
                publisher: invalid.to_owned(),
            };
            assert_eq!(
                verify_file(&image, &policy),
                Err(ProcessError::InvalidPolicy)
            );
        }
        // A development pin records the signer without requiring one.
        let development = verify_file(&image, &CodeTrustPolicy::DevelopmentPinned).unwrap();
        assert_eq!(development.signer.as_deref(), Some("Microsoft Corporation"));
        assert!(!development.authenticode_publisher);
    }

    #[test]
    fn an_unsigned_image_passes_only_a_development_pin() {
        let image = HeldFile::open_explicit_source(&std::env::current_exe().unwrap()).unwrap();
        let verdict = verify_file(&image, &CodeTrustPolicy::DevelopmentPinned).unwrap();
        assert_eq!(verdict.signer, None);
        assert_eq!(
            verify_file(
                &image,
                &CodeTrustPolicy::AuthenticodePublisher {
                    publisher: "Microsoft Corporation".to_owned()
                }
            ),
            Err(ProcessError::TrustRejected)
        );
    }

    #[test]
    fn a_tampered_signed_image_is_refused_not_reported_unsigned() {
        let fixture = super::super::tests::Fixture::new();
        let budget = IoBudget {
            maximum_bytes: 1 << 30,
            deadline: Instant::now() + Duration::from_secs(60),
            cancellation: CancellationToken::default(),
        };
        let source = signed_image();
        let mut bytes = source.read_bounded(&budget).unwrap();
        // Flip one byte inside the signed region (the DOS stub text).
        bytes[0x60] ^= 0x01;
        let tampered = fixture
            .1
            .write_new_readonly("tampered.exe", &bytes, &budget)
            .unwrap();
        assert_eq!(
            verify_file(&tampered, &CodeTrustPolicy::DevelopmentPinned),
            Err(ProcessError::SignatureInvalid)
        );
        assert_eq!(
            verify_file(
                &tampered,
                &CodeTrustPolicy::AuthenticodePublisher {
                    publisher: "Microsoft Corporation".to_owned()
                }
            ),
            Err(ProcessError::TrustRejected)
        );
    }
}
