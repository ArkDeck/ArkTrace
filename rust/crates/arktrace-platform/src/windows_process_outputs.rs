//! Mutable process outputs stay relative to one held private CWD. No bytes are
//! read, no existing output is admitted, and no path enters an error/outcome.
//! The Windows reading of `macos_process_outputs.rs`: entries are opened
//! relative to held parents without following a reparse point, and "private"
//! is the owner-only DACL the parser inherits from the private CWD.
use super::super::{
    FileIdentity, HeldDirectory, INSPECT, Kind, Stat, component, nt_open, require_private_security,
    stat_child, utf16,
};
use super::{ProcessError, ProcessOutputFileBudget};
use crate::{HostError, HostOperation};
use std::{
    ffi::{CString, OsStr},
    fs::File,
};
use windows_sys::Wdk::Storage::FileSystem::FILE_OPEN;

const MAXIMUM_OUTPUTS: usize = 16;

fn relative_path(name: &OsStr) -> Result<Vec<CString>, ProcessError> {
    let text = name.to_str().ok_or(ProcessError::InvalidArguments)?;
    if text.is_empty() || text.len() > 1024 {
        return Err(ProcessError::InvalidArguments);
    }
    let path = text
        .split('/')
        .map(|part| component(OsStr::new(part)).map_err(|_| ProcessError::InvalidArguments))
        .collect::<Result<Vec<_>, _>>()?;
    if path.len() > 8 {
        return Err(ProcessError::InvalidArguments);
    }
    // NTFS names compare case-insensitively: refuse prefixes that differ only
    // by case through `validate`, which compares the upper-cased forms.
    Ok(path)
}

fn folded(path: &[CString]) -> Vec<String> {
    path.iter()
        .map(|part| part.to_string_lossy().to_uppercase())
        .collect()
}

pub(super) fn validate(files: &[ProcessOutputFileBudget]) -> Result<(), ProcessError> {
    if files.len() > MAXIMUM_OUTPUTS {
        return Err(ProcessError::InvalidArguments);
    }
    let mut names: Vec<Vec<String>> = Vec::with_capacity(files.len());
    for file in files {
        if file.maximum_bytes == 0 || file.maximum_bytes > i64::MAX as u64 {
            return Err(ProcessError::InvalidArguments);
        }
        let name = folded(&relative_path(&file.name)?);
        if names
            .iter()
            .any(|other| other.starts_with(&name) || name.starts_with(other))
        {
            return Err(ProcessError::InvalidArguments);
        }
        names.push(name);
    }
    Ok(())
}

struct Output {
    name: CString,
    ancestors: Vec<CString>,
    parents: Vec<HeldDirectory>,
    maximum_bytes: u64,
    /// The original handle and identity; later checks allow writes but
    /// require this identity at the name.
    file: Option<(File, FileIdentity)>,
}

pub(super) struct Watch {
    directory: HeldDirectory,
    files: Vec<Output>,
}
impl Watch {
    pub(super) fn new(
        directory: &HeldDirectory,
        files: &[ProcessOutputFileBudget],
    ) -> Result<Self, ProcessError> {
        validate(files)?;
        directory.revalidate()?;
        let mut outputs = Vec::with_capacity(files.len());
        for file in files {
            let mut path = relative_path(&file.name)?;
            // The topmost output object must not exist before launch.
            match stat_child(&directory.0.file, &path[0]) {
                Err(HostError::NotFound) => {}
                Ok(_) => return Err(ProcessError::Host(HostError::AlreadyExists)),
                Err(error) => return Err(error.into()),
            }
            let name = path.pop().ok_or(ProcessError::InvalidArguments)?;
            outputs.push(Output {
                name,
                ancestors: path,
                parents: Vec::new(),
                maximum_bytes: file.maximum_bytes,
                file: None,
            });
        }
        directory.revalidate()?;
        Ok(Self {
            directory: directory.clone(),
            files: outputs,
        })
    }

    pub(super) fn check(&mut self) -> Result<Vec<Option<u64>>, ProcessError> {
        self.directory.revalidate()?;
        let mut sizes = Vec::with_capacity(self.files.len());
        let mut identities = Vec::with_capacity(self.files.len());
        for (index, output) in self.files.iter_mut().enumerate() {
            for parent in &output.parents {
                parent.revalidate()?;
            }
            while output.parents.len() < output.ancestors.len() {
                let parent = output.parents.last().unwrap_or(&self.directory);
                let name = &output.ancestors[output.parents.len()];
                match stat_child(&parent.0.file, name) {
                    Err(HostError::NotFound) => break,
                    Err(error) => return Err(error.into()),
                    Ok(_) => output.parents.push(parent.open_child(name, true, true)?),
                }
            }
            if output.parents.len() != output.ancestors.len() {
                sizes.push(None);
                continue;
            }
            let parent = output.parents.last().unwrap_or(&self.directory);
            parent.revalidate()?;
            let linked = match stat_child(&parent.0.file, &output.name) {
                Err(HostError::NotFound) if output.file.is_none() => {
                    sizes.push(None);
                    continue;
                }
                Err(HostError::NotFound) => return Err(HostError::IdentityMismatch.into()),
                Err(error) => return Err(error.into()),
                Ok(info) => info,
            };
            if !linked.is_file() {
                return Err(if linked.reparse() {
                    HostError::LinkedObject
                } else {
                    HostError::NotRegular
                }
                .into());
            }
            if output.file.is_none() {
                let file = nt_open(
                    &parent.0.file,
                    &utf16(&output.name)?,
                    INSPECT,
                    FILE_OPEN,
                    Kind::NonDirectory,
                    None,
                    HostOperation::Open,
                )?;
                let identity = Stat::of(&file)?.identity()?;
                if identity != linked.identity()? {
                    return Err(HostError::IdentityMismatch.into());
                }
                output.file = Some((file, identity));
            }
            let (file, identity) = output.file.as_ref().expect("opened above");
            let held = Stat::of(file)?;
            if !held.is_file()
                || held.delete_pending
                || held.identity()? != *identity
                || linked.identity()? != *identity
            {
                return Err(HostError::IdentityMismatch.into());
            }
            if held.links != 1 || identities.contains(identity) {
                return Err(HostError::LinkedObject.into());
            }
            require_private_security(file)?;
            let after = stat_child(&parent.0.file, &output.name)?;
            if after.identity()? != *identity || !after.is_file() {
                return Err(HostError::IdentityMismatch.into());
            }
            if after.links != 1 {
                return Err(HostError::LinkedObject.into());
            }
            // Both the handle and the no-follow name samples must fit. A
            // fresh final poll after cleanup covers fast exit.
            let size = held.size.max(after.size);
            if size > output.maximum_bytes {
                return Err(ProcessError::OutputFileLimitExceeded { index: index as u8 });
            }
            identities.push(*identity);
            sizes.push(Some(size));
            parent.revalidate()?;
        }
        self.directory.revalidate()?;
        Ok(sizes)
    }
}
