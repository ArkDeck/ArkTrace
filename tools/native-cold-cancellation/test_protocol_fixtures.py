"""Reject missing or changed guard inputs before launching the consumer."""
import json
from pathlib import Path
import tempfile
import time

from hash_budget import HashBudget, HashPolicy
from namespace_guard import open_owned_namespace
from ownership import OwnershipError
from protocol_fixtures import admit, populate


def main():
    budget = HashBudget(HashPolicy(1, 64 * 1024 * 1024, 128 * 1024 * 1024, 65536,
                                  time.monotonic_ns() + 10_000_000_000), lambda: False)
    cases = []
    with tempfile.TemporaryDirectory(prefix="arktrace-protocol-fixtures-") as temporary:
        root = str(Path(temporary).resolve())
        with open_owned_namespace(root, hash_budget=budget) as held:
            try:
                admit(held, root, budget)
            except OwnershipError:
                cases.append("missing inputs rejected before producer launch")
            else:
                raise AssertionError("empty guard accepted")
            prepared = populate(held, root, budget)
            admitted = admit(held, root, budget)
            cases.append("all 15 exact fixtures admitted without following specials")
            (Path(root) / "valid").write_bytes(b"xx")
            try:
                admit(held, root, budget)
            except OwnershipError:
                cases.append("same-size poisoned input rejected")
            else:
                raise AssertionError("poisoned input accepted")
    print(json.dumps({"caseCount": len(cases), "cases": cases, "prepared": prepared,
                      "admitted": admitted, "newConsumerProcesses": 0,
                      "EngineCalls": 0, "TaskCancelCalls": 0}))


if __name__ == "__main__":
    main()
