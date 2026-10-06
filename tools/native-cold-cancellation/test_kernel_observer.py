"""Real self-PID resource checks, no product/child/forest acceptance."""
import ctypes as C
import json
import os
from pathlib import Path
import sys
import time

from hash_budget import HashBudget, HashPolicy
from kernel_observer import KernelObserver
from ownership import OwnershipError, Row, digest


def main():
    bridge = Path(sys.argv[1])
    deadline = time.monotonic_ns() + 5_000_000_000
    policy = HashPolicy(1, 64 * 1024 * 1024, 128 * 1024 * 1024, 65536, deadline)
    budget = HashBudget(policy, lambda: False)
    expected, _ = digest(str(bridge), hash_budget=budget)
    observer = KernelObserver(str(bridge), expected, {}, budget)
    pid = os.getpid()

    def birth():
        row, raw, error = Row(), C.c_int(), C.c_int()
        result = observer.bridge.pf_identity_detail(pid, C.byref(row), C.byref(raw), C.byref(error))
        assert result == 0 and raw.value > 0 and error.value == 0 and row.pid == pid
        assert row.rss_status == -1, "unqueried identity-row RSS must remain unknown"
        return (row.pid, row.ppid, row.pgid, row.sec, row.usec)

    before = birth()
    resident, footprint, raw, error = C.c_uint64(), C.c_uint64(), C.c_int(), C.c_int()
    result = observer.bridge.arktrace_memory(pid, C.byref(resident), C.byref(footprint), C.byref(raw), C.byref(error))
    after = birth()
    assert before == after and result == raw.value == error.value == 0
    assert resident.value > 0 and footprint.value > 0
    assert observer.children(pid) == []
    invalid = observer.bridge.arktrace_memory(-1, C.byref(resident), C.byref(footprint), C.byref(raw), C.byref(error))
    assert invalid == -1
    for bad in (0, -1, True, 2147483648):
        try:
            observer.children(bad)
        except OwnershipError:
            pass
        else:
            raise AssertionError("invalid PID accepted")
    assert time.monotonic_ns() < deadline
    print(json.dumps({"selfPID": pid, "same_birth_before_after": True,
                      "resident_bytes": resident.value, "physical_footprint_bytes": footprint.value,
                      "rusage_facts": observer.rusage_facts, "actualSelfResourceQueries": 1,
                      "sharedHashBudgetActualBytes": budget.bytes_read_total,
                      "sharedHashBudgetReadCalls": budget.read_calls,
                      "actualSelfIdentityQueries": 2, "actualSelfChildEnumerations": 1,
                      "unqueriedIdentityRowRSSStillUnknown": True,
                      "invalidPIDCases": 5, "newChildProcesses": 0,
                      "EngineCalls": 0, "TaskCancelCalls": 0, "signalsSent": 0,
                      "completeForestProven": False, "completePeakRSSProven": False,
                      "wholeMacOSAcceptance": False}, sort_keys=True))


if __name__ == "__main__":
    main()
