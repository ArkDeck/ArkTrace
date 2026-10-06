"""Bounded admission for the disposable Swift input-guard fixtures.

These deliberate invalid inputs belong only to --protocol-guard. Normal SDK
operations continue to require an empty ephemeral namespace.
"""
import hashlib
import errno
import os
import socket
import stat

from ownership import OwnershipError, digest

CONTENTS = {"valid": b"{}", "cap": b"x" * 65536, "empty": b"",
            "oversize": b"x" * 65537, "nul-content": b"\0",
            **{name: b"x" for name in
               ("growth", "shrink", "mutation", "replacement", "raced-fifo", "raced-symlink")}}
SPECIAL = {"directory", "fifo", "symlink", "socket"}


def populate(namespace, path, budget):
    """Create one disposable set; the local socket is never listened to."""
    namespace.require_empty()
    for name, data in CONTENTS.items():
        budget.checkpoint()
        fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                     0o600, dir_fd=namespace.descriptor)
        try:
            offset = 0
            while offset < len(data):
                budget.checkpoint()
                written = os.write(fd, data[offset:offset + 65536])
                if written <= 0:
                    raise OwnershipError("guard fixture write failed")
                offset += written
        finally:
            os.close(fd)
    os.mkdir("directory", 0o700, dir_fd=namespace.descriptor)
    os.mkfifo("fifo", 0o600, dir_fd=namespace.descriptor)
    os.symlink("valid", "symlink", dir_fd=namespace.descriptor)
    previous = os.open(".", os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    fixture = None
    try:
        fixture = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        fd = fixture.fileno()
        budget.checkpoint()
        os.fchdir(namespace.descriptor)
        fixture.bind("socket")
    except OSError as error:
        raise OwnershipError("guard local socket bind unavailable") from error
    finally:
        if fixture is not None:
            fixture.close()
        os.fchdir(previous)
        os.close(previous)
    try:
        os.fstat(fd)
    except OSError as error:
        if error.errno != errno.EBADF:
            raise
    else:
        raise OwnershipError("guard socket descriptor retained")
    namespace.revalidate()
    return {"localSocketBound": True, "socketClosedEBADF": True,
            "listenCalls": 0, "connectCalls": 0, "EngineCalls": 0}


def admit(namespace, path, budget):
    """Inspect only the exact 15 caller-owned fixtures; never follow specials."""
    namespace.revalidate()
    names = set()
    with os.scandir(namespace.descriptor) as entries:
        for entry in entries:
            budget.checkpoint()
            if len(names) >= 15 or entry.name not in CONTENTS.keys() | SPECIAL:
                raise OwnershipError("guard fixture set invalid")
            names.add(entry.name)
    if names != CONTENTS.keys() | SPECIAL:
        raise OwnershipError("guard fixtures missing")
    for name in sorted(names):
        budget.checkpoint()
        info = os.stat(name, dir_fd=namespace.descriptor, follow_symlinks=False)
        if info.st_uid != os.getuid():
            raise OwnershipError("guard fixture owner invalid")
        if name in CONTENTS:
            content = CONTENTS[name]
            if (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or
                    stat.S_IMODE(info.st_mode) != 0o600 or info.st_size != len(content)):
                raise OwnershipError("guard regular fixture invalid")
            if content:
                actual, _ = digest(path + "/" + name, hash_budget=budget,
                                   expected_identity=(info.st_dev, info.st_ino, info.st_size,
                                                      info.st_mode, info.st_mtime_ns, info.st_ctime_ns),
                                   max_extent_bytes=len(content))
                if actual != hashlib.sha256(content).hexdigest():
                    raise OwnershipError("guard fixture content invalid")
        elif name == "symlink":
            if not stat.S_ISLNK(info.st_mode) or os.readlink(name, dir_fd=namespace.descriptor) != "valid":
                raise OwnershipError("guard symlink fixture invalid")
        elif name == "directory":
            if not stat.S_ISDIR(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o700:
                raise OwnershipError("guard directory fixture invalid")
            descriptor = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                                 dir_fd=namespace.descriptor)
            try:
                with os.scandir(descriptor) as entries:
                    if next(entries, None) is not None:
                        raise OwnershipError("guard directory fixture not empty")
            finally:
                os.close(descriptor)
        elif name == "fifo" and not stat.S_ISFIFO(info.st_mode):
            raise OwnershipError("guard fifo fixture invalid")
        elif name == "socket" and not stat.S_ISSOCK(info.st_mode):
            raise OwnershipError("guard socket fixture invalid")
    namespace.revalidate()
    return {"fixtureCount": len(names), "regularInputBytes": sum(map(len, CONTENTS.values())),
            "followedSpecialObjects": False, "EngineCalls": 0, "TaskCancelCalls": 0}
