"""Ephemeral namespace admission/residue regressions, no SDK or data read."""
import errno
import json
import os
from pathlib import Path
import sys
import tempfile
import time

from hash_budget import HashBudget, HashPolicy
from namespace_guard import open_owned_namespace
from ownership import OwnershipError


def main():
    budget = HashBudget(HashPolicy(1, 64 * 1024 * 1024, 128 * 1024 * 1024,
                                  65536, time.monotonic_ns() + 5_000_000_000), lambda: False)
    cases = []
    closures = 0
    with tempfile.TemporaryDirectory(prefix="arktrace-namespace-admission-") as temporary:
        root = Path(temporary).resolve()
        with open_owned_namespace(str(root), hash_budget=budget) as held:
            descriptors = [row[1] for row in held.directories]
            held.require_empty()
            cases.append("fresh physical owner-only namespace")
            for name in (".actors", ".locks", ".leases", ".ready", ".staging"):
                (root / name).mkdir(mode=0o700)
            (root / ".actors/.owners").mkdir(mode=0o700)
            (root / ".staging/.owners").mkdir(mode=0o700)
            (root / ".locks" / ("a" * 64 + ".lock")).touch(mode=0o600)
            assert held.cleanup_snapshot()["cleanupLayoutClean"] is True
            cases.append("empty publication and zero-byte key lock layout")
            owner = root / ".actors/.owners/live-owner"
            owner.write_bytes(b"x")
            assert held.cleanup_snapshot()["cleanupLayoutClean"] is False
            owner.unlink()
            cases.append("remaining actor owner record rejected")
            try:
                held.require_empty()
            except OwnershipError:
                cases.append("nonempty initial namespace rejected")
            else:
                raise AssertionError("nonempty namespace accepted")
            residue = root / ".ready/residue"
            residue.write_bytes(b"x")
            result = held.cleanup_snapshot()
            assert result["cleanupLayoutClean"] is False and ".ready/residue" in result["unexpectedEntries"]
            residue.unlink()
            cases.append("remaining publication rejected")
            alias = root / ".ready/alias"
            alias.symlink_to(root)
            try:
                held.snapshot()
            except OwnershipError:
                cases.append("symlink never followed")
            else:
                raise AssertionError("namespace alias followed")
            alias.unlink()
            for index in range(129):
                (root / ".ready" / str(index)).touch(mode=0o600)
            try:
                held.snapshot()
            except OwnershipError:
                cases.append("bounded node enumeration")
            else:
                raise AssertionError("node budget ignored")
        for descriptor in descriptors:
            try:
                os.fstat(descriptor)
            except OSError as error:
                assert error.errno == errno.EBADF
                closures += 1
            else:
                raise AssertionError("namespace descriptor retained")
    actual = None
    if len(sys.argv) == 2:
        with open_owned_namespace(sys.argv[1], hash_budget=budget) as held:
            descriptors = [row[1] for row in held.directories]
            held.require_empty()
            actual = held.snapshot()
            actual["physicalParentCount"] = len(held.directories)
        for descriptor in descriptors:
            try:
                os.fstat(descriptor)
            except OSError as error:
                assert error.errno == errno.EBADF
                closures += 1
            else:
                raise AssertionError("actual namespace descriptor retained")
    assert budget.bytes_read_total == budget.read_calls == 0
    print(json.dumps({"cases": cases, "caseCount": len(cases), "actualEmptyNamespace": actual,
                      "freshHeldDescriptorEBADF": closures, "rawBytesRead": 0,
                      "implicitScandirIOOrFDOwnershipComplete": False, "EngineCalls": 0,
                      "newChildProcesses": 0, "wholeMacOSAcceptance": False}, sort_keys=True))


if __name__ == "__main__":
    main()
