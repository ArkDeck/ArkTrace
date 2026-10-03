//! Mutable process outputs stay relative to one held private CWD. No bytes are
//! read, no existing output is admitted, and no path enters an error/outcome.
use super::super::{
    FileIdentity, FileSnapshot, HeldDirectory, component, descriptor, from_io,
    require_private_security, stat_child, stat_identity,
};
use super::{ProcessError, ProcessOutputFileBudget};
use crate::{HostError, HostOperation};
use std::{
    ffi::CString,
    ffi::OsStr,
    fs::File,
    os::{
        fd::AsRawFd,
        unix::{ffi::OsStrExt, fs::MetadataExt},
    },
};

const MAXIMUM_OUTPUTS: usize = 16;

fn relative_path(name: &OsStr) -> Result<Vec<CString>, ProcessError> {
    let bytes = name.as_bytes();
    if bytes.is_empty() || bytes.len() > 1024 {
        return Err(ProcessError::InvalidArguments);
    }
    let path = bytes
        .split(|b| *b == b'/')
        .map(|part| component(OsStr::from_bytes(part)).map_err(|_| ProcessError::InvalidArguments))
        .collect::<Result<Vec<_>, _>>()?;
    if path.len() > 8 {
        return Err(ProcessError::InvalidArguments);
    }
    Ok(path)
}

pub(super) fn validate(files: &[ProcessOutputFileBudget]) -> Result<(), ProcessError> {
    if files.len() > MAXIMUM_OUTPUTS {
        return Err(ProcessError::InvalidArguments);
    }
    let mut names = Vec::with_capacity(files.len());
    for file in files {
        if file.maximum_bytes == 0 || file.maximum_bytes > i64::MAX as u64 {
            return Err(ProcessError::InvalidArguments);
        }
        let name = relative_path(&file.name)?;
        if names
            .iter()
            .any(|other: &Vec<CString>| other.starts_with(&name) || name.starts_with(other))
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
    /// Holding the original descriptor also prevents reuse of its inode after
    /// replacement. Subsequent checks allow writes, but require this identity.
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
            // The topmost output object must not exist before launch. Nested
            // directories are created only by this invocation, then held.
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
            if linked.st_mode & libc::S_IFMT != libc::S_IFREG {
                return Err(if linked.st_mode & libc::S_IFMT == libc::S_IFLNK {
                    HostError::LinkedObject
                } else {
                    HostError::NotRegular
                }
                .into());
            }
            if output.file.is_none() {
                // SAFETY: held private parent, single component, fresh owned
                // readonly descriptor. NONBLOCK prevents a racing FIFO hang.
                let file = descriptor(unsafe {
                    libc::openat(
                        parent.0.file.as_raw_fd(),
                        output.name.as_ptr(),
                        libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK,
                    )
                })?;
                let metadata = file
                    .metadata()
                    .map_err(|e| from_io(e, HostOperation::Stat))?;
                let identity = FileSnapshot::metadata(&metadata).identity;
                if identity != stat_identity(&linked) {
                    return Err(HostError::IdentityMismatch.into());
                }
                output.file = Some((file, identity));
            }
            let (file, identity) = output.file.as_ref().expect("opened above");
            let metadata = file
                .metadata()
                .map_err(|e| from_io(e, HostOperation::Stat))?;
            if !metadata.is_file()
                || FileSnapshot::metadata(&metadata).identity != *identity
                || stat_identity(&linked) != *identity
            {
                return Err(HostError::IdentityMismatch.into());
            }
            if metadata.nlink() != 1 || identities.contains(identity) {
                return Err(HostError::LinkedObject.into());
            }
            require_private_security(file, &metadata)?;
            let after = stat_child(&parent.0.file, &output.name)?;
            if stat_identity(&after) != *identity || after.st_mode & libc::S_IFMT != libc::S_IFREG {
                return Err(HostError::IdentityMismatch.into());
            }
            if after.st_nlink != 1 {
                return Err(HostError::LinkedObject.into());
            }
            if after.st_uid != metadata.uid() || after.st_mode & 0o077 != 0 {
                return Err(HostError::NotPrivate.into());
            }
            // Both descriptor and no-follow pathname samples must fit. A fresh
            // final poll after cleanup covers fast exit and descendant writes.
            let size = metadata
                .size()
                .max(u64::try_from(after.st_size).map_err(|_| HostError::Changed)?);
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        fs::{self, DirBuilder, OpenOptions},
        io::Write,
        os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt, symlink},
        path::PathBuf,
        sync::atomic::{AtomicU64, Ordering},
    };
    static NEXT: AtomicU64 = AtomicU64::new(0);
    struct Fixture(PathBuf, HeldDirectory);
    impl Fixture {
        fn new() -> Self {
            let path = std::env::temp_dir().canonicalize().unwrap().join(format!(
                "arktrace-output-watch-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            DirBuilder::new().mode(0o700).create(&path).unwrap();
            let root = HeldDirectory::open_private(&path).unwrap();
            Self(path, root)
        }
        fn watch(&self) -> Watch {
            Watch::new(
                &self.1,
                &[ProcessOutputFileBudget {
                    name: "output".into(),
                    maximum_bytes: 10,
                }],
            )
            .unwrap()
        }
        fn file(&self) -> File {
            OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(self.0.join("output"))
                .unwrap()
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            fs::remove_dir_all(&self.0).unwrap();
        }
    }

    #[test]
    fn live_watch_accepts_growth_but_rejects_excess_without_reading_bytes() {
        let fixture = Fixture::new();
        let mut watch = fixture.watch();
        assert_eq!(watch.check().unwrap(), [None]);
        let mut writer = fixture.file();
        writer.write_all(b"a").unwrap();
        assert_eq!(watch.check().unwrap(), [Some(1)]);
        writer.write_all(b"bcdefghij").unwrap();
        assert_eq!(watch.check().unwrap(), [Some(10)]);
        writer.write_all(b"k").unwrap();
        assert_eq!(
            watch.check(),
            Err(ProcessError::OutputFileLimitExceeded { index: 0 })
        );
    }

    #[test]
    fn nested_watch_holds_private_parents_and_caps_growth() {
        let fixture = Fixture::new();
        let mut watch = Watch::new(
            &fixture.1,
            &[ProcessOutputFileBudget {
                name: "ts_tmp/unzlib_file.txt".into(),
                maximum_bytes: 10,
            }],
        )
        .unwrap();
        assert_eq!(watch.check().unwrap(), [None]);
        DirBuilder::new()
            .mode(0o700)
            .create(fixture.0.join("ts_tmp"))
            .unwrap();
        assert_eq!(watch.check().unwrap(), [None]);
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(fixture.0.join("ts_tmp/unzlib_file.txt"))
            .unwrap();
        file.write_all(b"1234567890").unwrap();
        assert_eq!(watch.check().unwrap(), [Some(10)]);
        file.write_all(b"x").unwrap();
        assert_eq!(
            watch.check(),
            Err(ProcessError::OutputFileLimitExceeded { index: 0 })
        );
    }

    #[test]
    fn observed_nested_parent_cannot_disappear_or_be_replaced() {
        for replacement in [false, true] {
            let fixture = Fixture::new();
            let mut watch = Watch::new(
                &fixture.1,
                &[ProcessOutputFileBudget {
                    name: "scratch/output".into(),
                    maximum_bytes: 10,
                }],
            )
            .unwrap();
            DirBuilder::new()
                .mode(0o700)
                .create(fixture.0.join("scratch"))
                .unwrap();
            watch.check().unwrap();
            fs::rename(fixture.0.join("scratch"), fixture.0.join("moved")).unwrap();
            if replacement {
                DirBuilder::new()
                    .mode(0o700)
                    .create(fixture.0.join("scratch"))
                    .unwrap();
            }
            assert_eq!(
                watch.check(),
                Err(ProcessError::Host(if replacement {
                    HostError::IdentityMismatch
                } else {
                    HostError::NotFound
                }))
            );
        }
    }

    #[test]
    fn nested_watch_refuses_existing_parent_symlink_and_public_directory() {
        let fixture = Fixture::new();
        let declaration = [ProcessOutputFileBudget {
            name: "scratch/output".into(),
            maximum_bytes: 10,
        }];
        DirBuilder::new()
            .mode(0o700)
            .create(fixture.0.join("scratch"))
            .unwrap();
        assert!(matches!(
            Watch::new(&fixture.1, &declaration),
            Err(ProcessError::Host(HostError::AlreadyExists))
        ));
        fs::remove_dir(fixture.0.join("scratch")).unwrap();
        let mut watch = Watch::new(&fixture.1, &declaration).unwrap();
        symlink("target", fixture.0.join("scratch")).unwrap();
        assert!(watch.check().is_err());
        fs::remove_file(fixture.0.join("scratch")).unwrap();
        let mut watch = Watch::new(&fixture.1, &declaration).unwrap();
        DirBuilder::new()
            .mode(0o700)
            .create(fixture.0.join("scratch"))
            .unwrap();
        fs::set_permissions(fixture.0.join("scratch"), fs::Permissions::from_mode(0o755)).unwrap();
        assert_eq!(
            watch.check(),
            Err(ProcessError::Host(HostError::NotPrivate))
        );
    }

    #[test]
    fn observed_output_cannot_disappear_or_be_replaced_by_same_size_inode() {
        for replacement in [false, true] {
            let fixture = Fixture::new();
            let mut watch = fixture.watch();
            fixture.file().write_all(b"old").unwrap();
            assert_eq!(watch.check().unwrap(), [Some(3)]);
            fs::remove_file(fixture.0.join("output")).unwrap();
            if replacement {
                fixture.file().write_all(b"new").unwrap();
            }
            assert_eq!(
                watch.check(),
                Err(ProcessError::Host(HostError::IdentityMismatch))
            );
        }
    }

    #[test]
    fn rejects_links_directory_and_public_mode_without_changing_target() {
        for kind in ["symlink", "hardlink", "directory", "public"] {
            let fixture = Fixture::new();
            let mut watch = fixture.watch();
            let output = fixture.0.join("output");
            let target = fixture.0.join("target");
            OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(&target)
                .unwrap()
                .write_all(b"preserve")
                .unwrap();
            let expected = match kind {
                "symlink" => {
                    symlink("target", &output).unwrap();
                    HostError::LinkedObject
                }
                "hardlink" => {
                    fs::hard_link(&target, &output).unwrap();
                    HostError::LinkedObject
                }
                "directory" => {
                    fs::create_dir(&output).unwrap();
                    HostError::NotRegular
                }
                _ => {
                    fixture.file();
                    fs::set_permissions(&output, fs::Permissions::from_mode(0o644)).unwrap();
                    HostError::NotPrivate
                }
            };
            assert_eq!(watch.check(), Err(ProcessError::Host(expected)));
            assert_eq!(fs::read(target).unwrap(), b"preserve");
            if kind == "public" {
                assert_eq!(
                    fs::metadata(output).unwrap().permissions().mode() & 0o777,
                    0o644
                );
            }
        }
    }

    #[test]
    fn ancestor_replacement_cannot_redirect_the_output_watch() {
        let fixture = Fixture::new();
        let mut watch = fixture.watch();
        fixture.file().write_all(b"old").unwrap();
        watch.check().unwrap();
        let moved = fixture.0.with_extension("moved");
        fs::rename(&fixture.0, &moved).unwrap();
        DirBuilder::new().mode(0o700).create(&fixture.0).unwrap();
        fixture.file().write_all(b"new").unwrap();
        assert_eq!(
            watch.check(),
            Err(ProcessError::Host(HostError::IdentityMismatch))
        );
        assert_eq!(fs::read(fixture.0.join("output")).unwrap(), b"new");
        fs::remove_dir_all(moved).unwrap();
    }
}
