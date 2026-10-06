"""Hold a physical, owner-only source without reading trace bytes.

This preflight supplements the consumer's source guard. Revalidation is a
bounded snapshot, not a guarantee against later changes by the same owner.
"""
from contextlib import contextmanager
import os
import stat

from hash_budget import HashBudget
from ownership import OwnershipError


def source_identity(info):
    return (info.st_dev, info.st_ino, info.st_size, info.st_mode,
            info.st_mtime_ns, info.st_ctime_ns, info.st_uid, info.st_nlink)


def directory_identity(info):
    return (info.st_dev, info.st_ino, info.st_mode)


class HeldSource:
    def __init__(self, path, descriptor, identity, directories, budget):
        self.path = path
        self.descriptor = descriptor
        self.identity = identity
        self.directories = directories
        self.budget = budget
        self.closed = False

    def revalidate(self):
        self.budget.checkpoint()
        if self.closed:
            raise OwnershipError("source descriptor closed")
        for path, descriptor, expected in self.directories:
            self.budget.checkpoint()
            if (directory_identity(os.fstat(descriptor)) != expected or
                    directory_identity(os.lstat(path)) != expected):
                raise OwnershipError("physical source parent changed")
        if (source_identity(os.fstat(self.descriptor)) != self.identity or
                source_identity(os.lstat(self.path)) != self.identity):
            raise OwnershipError("source changed after admission")
        self.budget.checkpoint()


@contextmanager
def open_owned_source(path, expected_byte_count, expected_device,
                      expected_inode, *, hash_budget):
    if type(hash_budget) is not HashBudget:
        raise OwnershipError("source budget required")
    hash_budget.checkpoint()
    if (type(path) is not str or not path.startswith("/") or
            len(os.fsencode(path)) > 4096 or "\x00" in path):
        raise OwnershipError("bounded absolute source path required")
    parts = path.split("/")[1:]
    if not 1 <= len(parts) <= 64 or any(part in ("", ".", "..") for part in parts):
        raise OwnershipError("canonical physical source path required")
    if any(type(value) is not int or value <= 0 for value in
           (expected_byte_count, expected_device, expected_inode)):
        raise OwnershipError("positive source identity required")
    descriptors = []
    held = None
    try:
        descriptor = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
        descriptors.append(descriptor)
        directories = [("/", descriptor, directory_identity(os.fstat(descriptor)))]
        prefix = ""
        for part in parts[:-1]:
            hash_budget.checkpoint()
            descriptor = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW |
                                 os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=descriptor)
            descriptors.append(descriptor)
            prefix += "/" + part
            directories.append((prefix, descriptor, directory_identity(os.fstat(descriptor))))
        hash_budget.checkpoint()
        descriptor = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK |
                             os.O_CLOEXEC, dir_fd=descriptor)
        descriptors.append(descriptor)
        info = os.fstat(descriptor)
        if (not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o400 or
                info.st_uid != os.getuid() or info.st_nlink != 1 or
                (info.st_size, info.st_dev, info.st_ino) !=
                (expected_byte_count, expected_device, expected_inode)):
            raise OwnershipError("owner-only source identity mismatch")
        held = HeldSource(path, descriptor, source_identity(info), directories, hash_budget)
        held.revalidate()
        yield held
        held.revalidate()
    except OSError:
        raise OwnershipError("source admission unavailable") from None
    finally:
        if held is not None:
            held.closed = True
        for descriptor in reversed(descriptors):
            os.close(descriptor)
