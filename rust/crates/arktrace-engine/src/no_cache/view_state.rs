//! Session-held read authority for the one user sidecar. No caller path, root
//! discovery, write, deletion or fallback. Active leases protect the Ready.
use super::*;
use crate::{MAXIMUM_VIEW_STATE_BYTES, ViewStateDocument, ViewStateRead};

const FILE_NAME: &str = "view-state.json";

fn read_directory(
    directory: &HeldDirectory,
    trace_sha256: &str,
    io: &IoBudget,
) -> Result<ViewStateRead, HostError> {
    io.check()?;
    let file = match directory.open_file(FILE_NAME) {
        Ok(file) => file,
        Err(HostError::NotFound) => {
            directory.revalidate()?;
            io.check()?;
            return Ok(ViewStateRead::Missing);
        }
        Err(error) => return Err(error),
    };
    let result = match file.read_bounded(io) {
        Ok(bytes) => ViewStateDocument::decode(&bytes, trace_sha256),
        Err(HostError::LimitExceeded) => ViewStateRead::Preserved,
        Err(error) => return Err(error),
    };
    file.verify()?;
    directory.revalidate()?;
    io.check()?;
    Ok(result)
}

impl EngineSession {
    /// Worker-only bounded read. Both directory and key-lock parent come from
    /// this opening's native authority; no URL is reopened by the host. File
    /// format failures preserve bytes and do not indict the Ready database.
    pub fn read_view_state(&self, budget: &EngineBudget) -> Result<ViewStateRead, EngineError> {
        self.query_reader(budget)?;
        let SessionStorage::Cached {
            directory, locks, ..
        } = &self.storage
        else {
            return Ok(ViewStateRead::SessionScoped);
        };
        let io = budget.io(MAXIMUM_VIEW_STATE_BYTES as u64);
        let key = Lease::acquire(
            locks,
            &format!("{}.lock", self.metadata.cache_key.entry_identifier()),
            LeaseMode::Exclusive,
            &io,
        )
        .map_err(|e| host(EngineStage::Querying, e))?;
        self.query_reader(budget)?;
        let result = read_directory(directory, &self.metadata.trace_sha256, &io)
            .map_err(|e| host(EngineStage::Querying, e));
        self.query_reader(budget)?;
        key.revalidate()
            .map_err(|e| host(EngineStage::Querying, e))?;
        io.check().map_err(|e| host(EngineStage::Querying, e))?;
        result
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        fs,
        os::unix::fs::{DirBuilderExt, symlink},
        sync::atomic::{AtomicU64, Ordering},
    };
    static NEXT: AtomicU64 = AtomicU64::new(0);
    struct Fixture(std::path::PathBuf, HeldDirectory);
    impl Fixture {
        fn new() -> Self {
            let path = std::env::temp_dir().canonicalize().unwrap().join(format!(
                "arktrace-view-state-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            fs::DirBuilder::new().mode(0o700).create(&path).unwrap();
            let directory = HeldDirectory::open_private(&path).unwrap();
            Self(path, directory)
        }
        fn io(&self) -> IoBudget {
            IoBudget {
                maximum_bytes: MAXIMUM_VIEW_STATE_BYTES as u64,
                deadline: Instant::now() + Duration::from_secs(10),
                cancellation: CancellationToken::default(),
            }
        }
        fn read(&self, io: &IoBudget) -> Result<ViewStateRead, HostError> {
            read_directory(&self.1, &"a".repeat(64), io)
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            fs::remove_dir_all(&self.0).unwrap();
        }
    }
    #[test]
    fn missing_corrupt_future_and_oversized_files_are_preserved() {
        let f = Fixture::new();
        assert_eq!(f.read(&f.io()).unwrap(), ViewStateRead::Missing);
        for bytes in [
            b"{".to_vec(),
            br#"{"formatVersion":999,"traceSHA256":"future","flags":[],"marks":[]}"#.to_vec(),
            vec![b' '; MAXIMUM_VIEW_STATE_BYTES + 1],
        ] {
            let file =
                f.1.write_new_readonly(
                    FILE_NAME,
                    &bytes,
                    &IoBudget {
                        maximum_bytes: bytes.len() as u64,
                        ..f.io()
                    },
                )
                .unwrap();
            let before = file
                .facts(&IoBudget {
                    maximum_bytes: bytes.len() as u64,
                    ..f.io()
                })
                .unwrap();
            assert_eq!(f.read(&f.io()).unwrap(), ViewStateRead::Preserved);
            assert_eq!(
                file.facts(&IoBudget {
                    maximum_bytes: bytes.len() as u64,
                    ..f.io()
                })
                .unwrap(),
                before
            );
            f.1.remove_owned_file(FILE_NAME, file.snapshot().identity)
                .unwrap();
        }
    }
    #[test]
    fn cancellation_and_expiry_do_not_publish_or_mutate() {
        let f = Fixture::new();
        let file = f.1.write_new_readonly(FILE_NAME, b"{", &f.io()).unwrap();
        let io = f.io();
        io.cancellation.cancel();
        assert_eq!(f.read(&io).unwrap_err(), HostError::Cancelled);
        let io = IoBudget {
            deadline: Instant::now(),
            ..f.io()
        };
        assert_eq!(f.read(&io).unwrap_err(), HostError::DeadlineExceeded);
        assert_eq!(file.read_bounded(&f.io()).unwrap(), b"{");
    }
    #[test]
    fn symlink_and_replaced_parent_never_select_foreign_authority() {
        let f = Fixture::new();
        fs::write(f.0.join("foreign"), b"preserve").unwrap();
        symlink("foreign", f.0.join(FILE_NAME)).unwrap();
        assert!(f.read(&f.io()).is_err());
        assert_eq!(fs::read(f.0.join("foreign")).unwrap(), b"preserve");
        fs::remove_file(f.0.join(FILE_NAME)).unwrap();
        let moved = f.0.with_extension("moved");
        fs::rename(&f.0, &moved).unwrap();
        fs::DirBuilder::new().mode(0o700).create(&f.0).unwrap();
        fs::write(f.0.join(FILE_NAME), b"foreign replacement").unwrap();
        assert!(f.read(&f.io()).is_err());
        assert_eq!(
            fs::read(f.0.join(FILE_NAME)).unwrap(),
            b"foreign replacement"
        );
        fs::remove_dir_all(moved).unwrap();
    }
}
