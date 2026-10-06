"""Real tiny-file identity races under one shared executable-sized budget."""
import errno
import hashlib
import json
import os
from pathlib import Path
import tempfile
import time
from unittest.mock import patch

from hash_budget import HashBudget, HashPolicy
from ownership import OwnershipError, digest, identity


def main():
    budget = HashBudget(HashPolicy(1, 64 * 1024 * 1024, 128 * 1024 * 1024,
                                  65536, time.monotonic_ns() + 5_000_000_000), lambda: False)
    original_deadline = budget.policy.absolute_deadline_ns
    cases, closures = [], []
    real_open, real_read, real_close = os.open, os.read, os.close
    hash_descriptors = set()

    def closed(descriptor):
        real_close(descriptor)
        if descriptor in hash_descriptors:
            try:
                os.fstat(descriptor)
            except OSError as error:
                assert error.errno == errno.EBADF
                closures.append(descriptor)
            else:
                raise AssertionError("hash descriptor not closed")
            hash_descriptors.remove(descriptor)

    def rejected(path, expected):
        try:
            digest(str(path), hash_budget=budget, expected_identity=expected, max_extent_bytes=8)
        except OwnershipError:
            return
        raise AssertionError("raced log pin accepted")

    with tempfile.TemporaryDirectory(prefix="arktrace-digest-extent-") as temporary:
        root = Path(temporary).resolve()
        path = root / "log"
        path.write_bytes(b"12345678")

        def opened(name, flags, *args, **kwargs):
            descriptor = real_open(name, flags, *args, **kwargs)
            if name == str(path):
                hash_descriptors.add(descriptor)
            return descriptor

        with patch("os.open", opened), patch("os.close", closed):
            sha, _ = digest(str(path), hash_budget=budget, expected_identity=identity(str(path)), max_extent_bytes=8)
            assert sha == hashlib.sha256(b"12345678").hexdigest() and budget.bytes_read_total == 8
            cases.append({"name": "exact log cap", "actualReadBytes": 8})
            expected = identity(str(path))
            replacement = root / "replacement"
            replacement.write_bytes(b"0123456789abcdef")
            os.replace(replacement, path)
            before = budget.bytes_read_total
            rejected(path, expected)
            assert budget.bytes_read_total == before
            cases.append({"name": "replacement before digest", "actualReadBytes": 0})
            path.write_bytes(b"12345678")
            expected = identity(str(path))
            replacement.write_bytes(b"0123456789abcdef")

            def replaced_open(name, flags, *args, **kwargs):
                if name == str(path):
                    os.replace(replacement, path)
                return opened(name, flags, *args, **kwargs)

            with patch("os.open", replaced_open):
                rejected(path, expected)
            assert budget.bytes_read_total == before
            cases.append({"name": "replacement between stat and held open", "actualReadBytes": 0})
            path.write_bytes(b"12345678")
            expected = identity(str(path))
            grew = False

            def grown_read(descriptor, amount):
                nonlocal grew
                data = real_read(descriptor, amount)
                if descriptor in hash_descriptors and not grew:
                    grew = True
                    with path.open("ab") as stream:
                        stream.write(b"more than the log cap")
                return data

            with patch("os.read", grown_read):
                rejected(path, expected)
            assert budget.bytes_read_total - before == 8
            cases.append({"name": "growth after held read", "actualReadBytes": 8})
    assert not hash_descriptors and len(closures) == 3
    assert budget.policy.absolute_deadline_ns == original_deadline and budget.bytes_read_total == 16
    print(json.dumps({"cases": cases, "caseCount": len(cases), "sharedActualReadBytes": 16,
                      "freshEBADF": len(closures), "originalDeadlinePreserved": True,
                      "EngineCalls": 0, "newChildProcesses": 0, "wholeMacOSAcceptance": False}, sort_keys=True))


if __name__ == "__main__":
    main()
