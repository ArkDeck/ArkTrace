"""Freshness regressions with synthetic Swift stamps, actual Python clock."""
import json
import time

from clock_admission import ClockAdmission
from hash_budget import HashBudget, HashPolicy
from protocol import CLOCK


def budget(deadline=None, cancelled=lambda: False):
    return HashBudget(HashPolicy(1, 64 * 1024 * 1024, 128 * 1024 * 1024,
                                 65536, deadline or time.monotonic_ns() + 5_000_000_000), cancelled)


def rejected(operation):
    try:
        operation()
    except ValueError:
        return
    raise AssertionError("invalid freshness admitted")


def main():
    cases = []
    gate = ClockAdmission(budget())
    start = gate.begin()
    calibration = {"event": "clock.calibration", "clockID": CLOCK,
                   "monotonicNs": 1_000_000_000}
    gate.receive(calibration)
    progress = {"event": "open.progress", "stage": "parsing", "clockID": CLOCK,
                "monotonicNs": 1_000_000_000 + time.monotonic_ns() - start}
    assert 0 <= gate.progress_age_upper_ns(progress) <= 100_000_000
    cases.append("fresh interval admitted")
    rejected(lambda: gate.progress_age_upper_ns({**progress, "monotonicNs": progress["monotonicNs"] - 101_000_000}))
    cases.append("queued stale parsing rejected")
    rejected(lambda: gate.progress_age_upper_ns({**progress, "monotonicNs": progress["monotonicNs"] + 101_000_000}))
    cases.append("clock outside calibrated interval rejected")
    rejected(lambda: gate.receive(calibration))
    cases.append("no calibration renewal")
    rejected(lambda: ClockAdmission(budget(deadline=1)).begin())
    cases.append("original deadline enforced")
    rejected(lambda: ClockAdmission(budget(cancelled=lambda: True)).begin())
    cases.append("caller cancellation enforced")
    receipt = gate.receipt()
    assert receipt["clockEquivalenceProven"] is False and receipt["futureDriftProven"] is False
    print(json.dumps({"caseCount": len(cases), "cases": cases, "SwiftStampsSynthetic": True,
                      "actualSwiftClockHandshake": False, "EngineCalls": 0,
                      "newChildProcesses": 0, "TaskCancelCalls": 0,
                      "wholeMacOSAcceptance": False}, sort_keys=True))


if __name__ == "__main__":
    main()
