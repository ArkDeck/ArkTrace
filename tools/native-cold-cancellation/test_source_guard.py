"""Source preflight regressions; no Engine, parser, child, or trace read."""
import errno
import json
import os
from pathlib import Path
import sys
import tempfile
import time

from hash_budget import HashBudget, HashPolicy
from ownership import OwnershipError
from source_guard import open_owned_source


def budget(cancelled=lambda: False):
    return HashBudget(HashPolicy(1, 64 * 1024 * 1024, 128 * 1024 * 1024,
                                 65536, time.monotonic_ns() + 5_000_000_000), cancelled)


def arguments(path):
    info = os.lstat(path)
    return (str(path), info.st_size, info.st_dev, info.st_ino)


def rejected(args, operation_budget=None):
    try:
        with open_owned_source(*args, hash_budget=operation_budget or budget()):
            pass
    except (OwnershipError, ValueError):
        return
    raise AssertionError("unsafe source accepted")


def main():
    cases = []
    fresh_ebadf = 0
    with tempfile.TemporaryDirectory(prefix="arktrace-source-admission-") as temporary:
        root = Path(temporary).resolve()
        source = root / "owned.htrace"
        source.write_bytes(b"tiny source guard fixture")
        source.chmod(0o400)
        operation_budget = budget()
        with open_owned_source(*arguments(source), hash_budget=operation_budget) as held:
            descriptors = [row[1] for row in held.directories] + [held.descriptor]
            held.revalidate()
            assert os.lseek(held.descriptor, 0, os.SEEK_CUR) == 0
        for descriptor in descriptors:
            try:
                os.fstat(descriptor)
            except OSError as error:
                assert error.errno == errno.EBADF
                fresh_ebadf += 1
            else:
                raise AssertionError("source admission descriptor retained")
        assert operation_budget.bytes_read_total == operation_budget.read_calls == 0
        cases.append("physical owner-only source and descriptor closure")
        alias = root / "alias.htrace"
        alias.symlink_to(source)
        rejected((str(alias), *arguments(source)[1:]))
        cases.append("leaf symlink")
        parent_alias = root / "alias-parent"
        parent_alias.symlink_to(root, target_is_directory=True)
        rejected((str(parent_alias / source.name), *arguments(source)[1:]))
        cases.append("parent symlink")
        fifo = root / "fifo.htrace"
        os.mkfifo(fifo, 0o400)
        rejected((str(fifo), *arguments(source)[1:]))
        cases.append("FIFO without blocking")
        expected = arguments(source)
        rejected((*expected[:-1], expected[-1] + 1))
        cases.append("inode mismatch")
        source.chmod(0o600)
        rejected(arguments(source))
        cases.append("writable source")
        source.chmod(0o400)
        try:
            with open_owned_source(*arguments(source), hash_budget=budget()):
                source.chmod(0o600)
        except OwnershipError:
            cases.append("held source mutation")
        else:
            raise AssertionError("mutation after admission accepted")
        source.chmod(0o400)
        rejected(arguments(source), budget(lambda: True))
        cases.append("caller cancellation before admission")

    actual = None
    if len(sys.argv) > 1:
        args = (sys.argv[1], *map(int, sys.argv[2:5]))
        operation_budget = budget()
        with open_owned_source(*args, hash_budget=operation_budget) as held:
            descriptors = [row[1] for row in held.directories] + [held.descriptor]
            held.revalidate()
            assert os.lseek(held.descriptor, 0, os.SEEK_CUR) == 0
            actual = {"sourceIdentity": held.identity, "physicalParents": len(held.directories),
                      "rawBytesRead": 0, "snapshotOnly": True}
        for descriptor in descriptors:
            try:
                os.fstat(descriptor)
            except OSError as error:
                assert error.errno == errno.EBADF
                fresh_ebadf += 1
            else:
                raise AssertionError("actual source descriptor retained")
        assert operation_budget.bytes_read_total == operation_budget.read_calls == 0
    print(json.dumps({"cases": cases, "caseCount": len(cases), "freshEBADF": fresh_ebadf,
                      "actualSourcePreflight": actual, "rawBytesRead": 0,
                      "EngineCalls": 0, "newChildProcesses": 0, "signalsSent": 0,
                      "wholeMacOSAcceptance": False}, sort_keys=True))


if __name__ == "__main__":
    main()
