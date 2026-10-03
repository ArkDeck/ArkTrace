//! Native APFS acceptance probe. The Python harness owns both temporary roots.
#[cfg(target_os = "macos")]
mod native {
    use arktrace_platform::{
        CancellationToken, HeldDirectory, HeldFile, HostError, HostOperation, IoBudget,
    };
    use std::{
        fs::{self, File},
        io::Write,
        path::PathBuf,
        time::{Duration, Instant},
    };

    fn budget() -> IoBudget {
        IoBudget {
            maximum_bytes: 96 * 1024 * 1024,
            deadline: Instant::now() + Duration::from_secs(60),
            cancellation: CancellationToken::default(),
        }
    }

    pub fn run() {
        let args: Vec<_> = std::env::args_os().skip(1).collect();
        assert!(
            args.len() == 2 || args.len() == 3,
            "two owned private roots required"
        );
        let host_path = PathBuf::from(&args[0]);
        let volume_path = PathBuf::from(&args[1]);
        let host = HeldDirectory::open_private(&host_path).unwrap();
        if args.len() == 3 {
            assert_eq!(args[2], "reject-ignored-ownership");
            assert!(matches!(
                HeldDirectory::open_private(&volume_path),
                Err(HostError::NotPrivate)
            ));
            println!("ownership-disabled private root refused");
            return;
        }
        let volume = HeldDirectory::open_private(&volume_path).unwrap();
        assert_ne!(host.identity().device, volume.identity().device);
        let candidate = host
            .write_new_readonly("candidate", b"db", &budget())
            .unwrap();
        let cross_volume =
            host.promote_noreplace(&candidate, &volume, "cross-volume.db", &budget());
        assert!(matches!(cross_volume, Err(HostError::CrossVolume)));
        candidate.verify().unwrap();
        assert_eq!(fs::read_dir(&volume_path).unwrap().count(), 0);

        let entry = host.create_private_child("entry-stage").unwrap();
        entry.write_new_readonly("db", b"db", &budget()).unwrap();
        entry
            .write_new_readonly("metadata", b"metadata", &budget())
            .unwrap();
        let sealed = entry.seal_readonly_directory(&budget()).unwrap();
        assert!(matches!(
            host.promote_sealed_directory_noreplace(&sealed, &volume, "entry", &budget()),
            Err(HostError::CrossVolume)
        ));
        sealed.verify(&budget()).unwrap();
        assert_eq!(fs::read_dir(&volume_path).unwrap().count(), 0);

        let source_path = host_path.join("large-source");
        let mut writer = File::options()
            .write(true)
            .create_new(true)
            .open(&source_path)
            .unwrap();
        let chunk = vec![123; 1024 * 1024];
        for _ in 0..80 {
            writer.write_all(&chunk).unwrap();
        }
        writer.sync_all().unwrap();
        drop(writer);
        let source = HeldFile::open_explicit_source(&source_path).unwrap();
        let facts = source.facts(&budget()).unwrap();
        let result = volume.copy_snapshot(&source, "full-disk-partial", false, &budget());
        let failure = match result {
            Ok(_) => panic!("64 MiB image unexpectedly accepted 80 MiB"),
            Err(error) => error,
        };
        let residue_count = fs::read_dir(&volume_path).unwrap().count();
        let unchanged = source.facts(&budget()).unwrap() == facts;
        let expected = failure
            == HostError::SystemIo {
                operation: HostOperation::Write,
                code: libc::ENOSPC,
            };
        let report = serde_json::json!({
            "schemaVersion": "arktrace.native-file-volumes/1", "hostDevice":host.identity().device,
            "probeSHA256":HeldFile::open_explicit_source(&std::env::current_exe().unwrap()).unwrap().facts(&budget()).unwrap().sha256,
            "imageDevice":volume.identity().device, "crossVolume":"refused_without_mutation",
            "crossVolumeDirectory":"refused_without_mutation", "directoryCandidateRetained":true,
            "diskFullFailure":format!("{failure:?}"), "diskFullErrno":libc::ENOSPC,
            "cleanupResidueCount":residue_count, "rawBytesUnchanged":unchanged,
            "sourceByteCount":facts.byte_count, "sourceSHA256":facts.sha256,
            "passed":expected && residue_count == 0 && unchanged
        });
        println!("{report}");
        assert!(
            expected && residue_count == 0 && unchanged,
            "native volume acceptance failed"
        );
        let retry = volume
            .write_new_readonly("retry", b"ok", &budget())
            .unwrap();
        assert_eq!(retry.read_bounded(&budget()).unwrap(), b"ok");
        volume
            .remove_owned_file("retry", retry.snapshot().identity)
            .unwrap();
    }
}

fn main() {
    #[cfg(target_os = "macos")]
    native::run();
    #[cfg(not(target_os = "macos"))]
    panic!("this native acceptance probe requires macOS APFS");
}
