#!/usr/bin/env python3
"""Compute a deterministic SHA-256 identity for the current Git worktree bytes."""

from __future__ import annotations

import hashlib
import os
import stat
import subprocess
import sys
from pathlib import Path


MAX_SOURCE_FILE_BYTES = 128 * 1024 * 1024
MAX_SOURCE_TOTAL_BYTES = 512 * 1024 * 1024


def fail(message: str) -> "NoReturn":
    raise SystemExit(f"source tree identity failed: {message}")


def field(digest: "hashlib._Hash", value: bytes) -> None:
    digest.update(len(value).to_bytes(8, "big"))
    digest.update(value)


def open_regular_beneath(root_descriptor: int, raw_path: bytes) -> int:
    components = raw_path.split(b"/")
    if not components or any(component in (b"", b".", b"..") for component in components):
        fail("source path is invalid")
    current = os.dup(root_descriptor)
    try:
        for component in components[:-1]:
            next_descriptor = os.open(
                component,
                os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_CLOEXEC", 0)
                | getattr(os, "O_NOFOLLOW", 0),
                dir_fd=current,
            )
            os.close(current)
            current = next_descriptor
        descriptor = os.open(
            components[-1],
            os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=current,
        )
        return descriptor
    finally:
        os.close(current)


def hash_regular_file(
    candidate: Path | None = None,
    after_open=None,
    *,
    root_descriptor: int | None = None,
    raw_path: bytes | None = None,
) -> tuple[int, int, bytes]:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    if root_descriptor is not None and raw_path is not None:
        descriptor = open_regular_beneath(root_descriptor, raw_path)
    elif candidate is not None:
        descriptor = os.open(candidate, flags)
    else:
        fail("source file request is invalid")
    with os.fdopen(descriptor, "rb", closefd=True) as handle:
        initial = os.fstat(handle.fileno())
        if not stat.S_ISREG(initial.st_mode):
            fail("source projection contains a non-regular file")
        if initial.st_size < 0 or initial.st_size > MAX_SOURCE_FILE_BYTES:
            fail("source file exceeds its byte bound")
        if after_open is not None:
            after_open()
        file_digest = hashlib.sha256()
        remaining = initial.st_size
        while remaining:
            chunk = handle.read(min(1024 * 1024, remaining))
            if not chunk:
                fail("source file shrank while hashing")
            file_digest.update(chunk)
            remaining -= len(chunk)
        if handle.read(1):
            fail("source file grew while hashing")
        final = os.fstat(handle.fileno())
        if (
            initial.st_dev != final.st_dev
            or initial.st_ino != final.st_ino
            or initial.st_mode != final.st_mode
            or initial.st_size != final.st_size
            or initial.st_mtime_ns != final.st_mtime_ns
            or initial.st_ctime_ns != final.st_ctime_ns
        ):
            fail("source file changed while hashing")
        return initial.st_mode, initial.st_size, file_digest.digest()


def add_total_bytes(current: int, byte_count: int) -> int:
    total = current + byte_count
    if total > MAX_SOURCE_TOTAL_BYTES:
        fail("source projection exceeds its total byte bound")
    return total


def main() -> None:
    if len(sys.argv) != 2:
        fail("expected repository root")
    root = Path(sys.argv[1]).resolve(strict=True)
    if not (root / ".git").exists():
        fail("repository metadata is unavailable")
    result = subprocess.run(
        [
            "git", "-C", str(root), "ls-files", "--cached", "--others",
            "--exclude-standard", "-z",
        ],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    paths = result.stdout.split(b"\0")
    if paths and paths[-1] == b"":
        paths.pop()
    if not paths:
        fail("source projection is empty")
    if len(paths) != len(set(paths)):
        fail("source projection contains duplicate paths")
    # `git ls-files --cached --others` groups paths by index classification.
    # Sort the combined byte paths so staging or committing an unchanged file
    # cannot change the identity of the source projection.
    paths.sort()

    digest = hashlib.sha256()
    digest.update(b"arktrace-source-tree-v1\0")
    total_bytes = 0
    root_descriptor = os.open(
        root, os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0),
    )
    try:
        for raw_path in paths:
            if not raw_path or len(raw_path) > 4096 or b"\n" in raw_path or b"\r" in raw_path:
                fail("source path is invalid")
            relative = os.fsdecode(raw_path)
            if relative.startswith(".build/") or "/__pycache__/" in f"/{relative}":
                continue
            # This audited output is generated from the projection itself. Keeping
            # it outside the projection avoids a self-referential hash while all
            # source, scripts, locks and tests remain covered.
            if relative in {
                "Fixtures/release-evidence/phase3-medium-performance.json",
                "Fixtures/release-evidence/phase4-medium-agent-performance.json",
                "Fixtures/release-evidence/phase5-cli-distribution.json",
            }:
                continue
            if relative.endswith(".pyc"):
                continue
            mode, byte_count, file_digest = hash_regular_file(
                root_descriptor=root_descriptor, raw_path=raw_path
            )
            total_bytes = add_total_bytes(total_bytes, byte_count)
            field(digest, raw_path)
            field(digest, b"x" if mode & stat.S_IXUSR else b"-")
            field(digest, str(byte_count).encode("ascii"))
            field(digest, file_digest)
    finally:
        os.close(root_descriptor)
    print(digest.hexdigest())


if __name__ == "__main__":
    try:
        main()
    except (OSError, subprocess.SubprocessError):
        fail("source projection is unreadable")
