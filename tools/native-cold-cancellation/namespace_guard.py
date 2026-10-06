"""Read-only, bounded snapshots of the session-owned ephemeral namespace."""
from contextlib import contextmanager
import os
import stat

from hash_budget import HashBudget
from ownership import OwnershipError
from source_guard import directory_identity, source_identity


class HeldNamespace:
    def __init__(self, directories, hash_budget):
        self.directories = directories
        self.budget = hash_budget
        self.descriptor = directories[-1][1]

    def revalidate(self):
        self.budget.checkpoint()
        for path, descriptor, expected in self.directories:
            self.budget.checkpoint()
            if (directory_identity(os.fstat(descriptor)) != expected or
                    directory_identity(os.lstat(path)) != expected):
                raise OwnershipError("namespace physical parent changed")
        leaf = os.fstat(self.descriptor)
        if leaf.st_uid != os.getuid() or stat.S_IMODE(leaf.st_mode) != 0o700:
            raise OwnershipError("private namespace owner changed")

    def snapshot(self):
        self.revalidate()
        rows = []
        total_extent = 0

        def walk(descriptor, prefix, depth):
            nonlocal total_extent
            self.budget.checkpoint()
            if depth > 8:
                raise OwnershipError("namespace depth budget")
            before = source_identity(os.fstat(descriptor))
            with os.scandir(descriptor) as entries:
                for entry in entries:
                    self.budget.checkpoint()
                    if len(rows) >= 128 or len(os.fsencode(entry.name)) > 255:
                        raise OwnershipError("namespace node budget")
                    info = entry.stat(follow_symlinks=False)
                    if info.st_uid != os.getuid() or not (stat.S_ISREG(info.st_mode) or stat.S_ISDIR(info.st_mode)):
                        raise OwnershipError("namespace unexpected owner or object")
                    name = prefix + entry.name
                    kind = "directory" if stat.S_ISDIR(info.st_mode) else "file"
                    rows.append({"relativePath": name, "kind": kind, "identity": source_identity(info)})
                    if kind == "file":
                        if info.st_nlink != 1:
                            raise OwnershipError("namespace unexpected hard link")
                        total_extent += info.st_size
                        if total_extent > 1024 * 1024 * 1024:
                            raise OwnershipError("namespace extent budget")
                    else:
                        child = os.open(entry.name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW |
                                        os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=descriptor)
                        try:
                            if source_identity(os.fstat(child)) != source_identity(info):
                                raise OwnershipError("namespace directory changed before traversal")
                            walk(child, name + "/", depth + 1)
                        finally:
                            os.close(child)
            if source_identity(os.fstat(descriptor)) != before:
                raise OwnershipError("namespace changed during snapshot")

        walk(self.descriptor, "", 0)
        self.revalidate()
        rows.sort(key=lambda row: os.fsencode(row["relativePath"]))
        return {"rows": rows, "regularFileExtentBytes": total_extent,
                "rawBytesRead": 0, "atomicSnapshotProven": False, "ACLPolicyProven": False}

    def require_empty(self):
        if self.snapshot()["rows"]:
            raise OwnershipError("fresh empty namespace required")

    def cleanup_snapshot(self):
        snapshot = self.snapshot()
        # Current Runtime.load_tools creates the actor owner store even when
        # parser trust admission fails. Only its empty directory skeleton is
        # allowed; remaining owner records are still rejected below.
        directories = {".actors", ".actors/.owners", ".staging", ".staging/.owners",
                       ".ready", ".leases", ".locks"}
        unexpected = []
        for row in snapshot["rows"]:
            name = row["relativePath"]
            lock = name.removeprefix(".locks/").removesuffix(".lock")
            allowed_lock = (row["kind"] == "file" and name == ".locks/" + lock + ".lock" and
                            len(lock) == 64 and all(char in "0123456789abcdef" for char in lock) and
                            row["identity"][2] == 0)
            if not (row["kind"] == "directory" and name in directories and
                    stat.S_IMODE(row["identity"][3]) == 0o700 or allowed_lock):
                unexpected.append(name)
        return {**snapshot, "cleanupLayoutClean": not unexpected, "unexpectedEntries": unexpected,
                "activeLocksOrPrivateRegistryCountsProven": False}


@contextmanager
def open_owned_namespace(path, *, hash_budget):
    if type(hash_budget) is not HashBudget:
        raise OwnershipError("namespace operation budget required")
    hash_budget.checkpoint()
    if (type(path) is not str or not path.startswith("/") or "\x00" in path or
            len(os.fsencode(path)) > 4096):
        raise OwnershipError("bounded absolute namespace required")
    parts = path.split("/")[1:]
    if not 1 <= len(parts) <= 64 or any(part in ("", ".", "..") for part in parts):
        raise OwnershipError("canonical namespace path required")
    descriptors = []
    try:
        descriptor = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
        descriptors.append(descriptor)
        directories = [("/", descriptor, directory_identity(os.fstat(descriptor)))]
        prefix = ""
        for part in parts:
            hash_budget.checkpoint()
            descriptor = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW |
                                 os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=descriptor)
            descriptors.append(descriptor)
            prefix += "/" + part
            directories.append((prefix, descriptor, directory_identity(os.fstat(descriptor))))
        held = HeldNamespace(directories, hash_budget)
        held.revalidate()
        yield held
        held.revalidate()
    except OSError:
        raise OwnershipError("namespace observation unavailable") from None
    finally:
        for descriptor in reversed(descriptors):
            os.close(descriptor)
