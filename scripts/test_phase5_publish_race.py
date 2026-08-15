#!/usr/bin/env python3
"""Deterministic race seams for descriptor-bound Phase 5 publication."""

from __future__ import annotations

import hashlib
import importlib.util
import os
from pathlib import Path
import tempfile


SCRIPT_DIRECTORY = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "phase5_distribution_verifier",
    SCRIPT_DIRECTORY / "verify_phase5_cli_distribution.py",
)
if SPEC is None or SPEC.loader is None:
    raise SystemExit("publish race contract failed")
VERIFIER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFIER)


def require_failure(operation) -> None:
    try:
        operation()
    except (OSError, VERIFIER.VerificationError) as error:
        return error
    raise AssertionError("replacement race was accepted")


def install_after_rename(callback):
    original = VERIFIER.rename_exclusive

    def wrapped(source_fd, source_name, destination_fd, destination_name):
        original(source_fd, source_name, destination_fd, destination_name)
        callback(source_fd, source_name, destination_fd, destination_name)

    VERIFIER.rename_exclusive = wrapped
    return original


def regular_replacement(root: Path) -> None:
    staging = root / "regular-staging"
    staging.mkdir()
    source = staging / "regular.partial"
    destination = root / "regular.final"
    hidden = root / "regular.held"
    source.write_bytes(b"reviewed")
    expected = hashlib.sha256(b"reviewed").hexdigest()

    def replace(_source_fd, _source_name, destination_fd, destination_name):
        os.rename(
            destination_name,
            hidden.name,
            src_dir_fd=destination_fd,
            dst_dir_fd=destination_fd,
        )
        descriptor = os.open(
            destination_name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC,
            0o600,
            dir_fd=destination_fd,
        )
        try:
            os.write(descriptor, b"attacker")
        finally:
            os.close(descriptor)

    original = install_after_rename(replace)
    try:
        require_failure(lambda: VERIFIER.publish_file(source, destination, expected, 8))
    finally:
        VERIFIER.rename_exclusive = original
    assert destination.read_bytes() == b"attacker"
    assert hidden.read_bytes() == b"reviewed"
    assert not source.exists()


def symlink_replacement(root: Path) -> None:
    source = root / "symlink.partial"
    destination = root / "symlink.final"
    hidden = root / "symlink.held"
    sentinel = root / "sentinel"
    source.write_bytes(b"reviewed")
    sentinel.write_bytes(b"sentinel")
    expected = hashlib.sha256(b"reviewed").hexdigest()

    def replace(_source_fd, _source_name, destination_fd, destination_name):
        os.rename(
            destination_name,
            hidden.name,
            src_dir_fd=destination_fd,
            dst_dir_fd=destination_fd,
        )
        os.symlink(sentinel.name, destination_name, dir_fd=destination_fd)

    original = install_after_rename(replace)
    try:
        require_failure(lambda: VERIFIER.publish_file(source, destination, expected, 8))
    finally:
        VERIFIER.rename_exclusive = original
    assert destination.is_symlink()
    assert sentinel.read_bytes() == b"sentinel"
    assert hidden.read_bytes() == b"reviewed"


def source_recreation(root: Path) -> None:
    staging = root / "recreated-staging"
    staging.mkdir()
    source = staging / "recreated.partial"
    destination = root / "recreated.final"
    source.write_bytes(b"reviewed")
    expected = hashlib.sha256(b"reviewed").hexdigest()

    def recreate(source_fd, source_name, _destination_fd, _destination_name):
        descriptor = os.open(
            source_name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC,
            0o600,
            dir_fd=source_fd,
        )
        try:
            os.write(descriptor, b"later")
        finally:
            os.close(descriptor)

    original = install_after_rename(recreate)
    try:
        VERIFIER.publish_file(source, destination, expected, 8)
    finally:
        VERIFIER.rename_exclusive = original
    assert destination.read_bytes() == b"reviewed"
    assert source.read_bytes() == b"later"


def tree_snapshot_root_replacement(root: Path) -> None:
    source = root / "snapshot-source.app"
    held = root / "snapshot-source-held.app"
    destination = root / "snapshot-private.app"
    source.mkdir()
    (source / "reviewed").write_bytes(b"reviewed")
    original = VERIFIER.tree_projection_descriptor
    call_count = 0

    def replace_after_initial(descriptor):
        nonlocal call_count
        result = original(descriptor)
        call_count += 1
        if call_count == 1:
            source.rename(held)
            source.mkdir()
            (source / "attacker").write_bytes(b"attacker")
        return result

    VERIFIER.tree_projection_descriptor = replace_after_initial
    try:
        require_failure(lambda: VERIFIER.snapshot_tree(source, destination))
    finally:
        VERIFIER.tree_projection_descriptor = original
    assert (destination / "reviewed").read_bytes() == b"reviewed"
    assert not (destination / "attacker").exists()
    assert (held / "reviewed").read_bytes() == b"reviewed"
    assert (source / "attacker").read_bytes() == b"attacker"


def directory_replacement(root: Path) -> None:
    source = root / "directory.partial"
    destination = root / "directory.final"
    hidden = root / "directory.held"
    source.mkdir()
    (source / "file").write_bytes(b"reviewed")
    expected = VERIFIER.tree_sha(source)

    def replace(_source_fd, _source_name, destination_fd, destination_name):
        os.rename(
            destination_name,
            hidden.name,
            src_dir_fd=destination_fd,
            dst_dir_fd=destination_fd,
        )
        os.mkdir(destination_name, mode=0o700, dir_fd=destination_fd)
        replacement_fd = os.open(
            destination_name,
            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
            dir_fd=destination_fd,
        )
        try:
            descriptor = os.open(
                "file",
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC,
                0o600,
                dir_fd=replacement_fd,
            )
            try:
                os.write(descriptor, b"reviewed")
            finally:
                os.close(descriptor)
        finally:
            os.close(replacement_fd)

    original = install_after_rename(replace)
    try:
        error = require_failure(
            lambda: VERIFIER.publish_directory(source, destination, expected)
        )
    finally:
        VERIFIER.rename_exclusive = original
    assert (destination / "file").exists(), repr(error)
    assert (destination / "file").read_bytes() == b"reviewed"
    assert (hidden / "file").read_bytes() == b"reviewed"


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="arktrace-phase5-publish-race-") as raw:
        root = Path(raw).resolve()
        regular_replacement(root)
        symlink_replacement(root)
        source_recreation(root)
        tree_snapshot_root_replacement(root)
        directory_replacement(root)
    print("Phase 5 publication race contract passed")


if __name__ == "__main__":
    main()
