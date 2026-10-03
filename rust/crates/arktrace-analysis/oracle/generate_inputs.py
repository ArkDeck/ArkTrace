#!/usr/bin/env python3
"""Deterministic synthetic typed inputs; expected results come only from Swift."""
import copy
import json
from pathlib import Path
import random

CRATE = Path(__file__).resolve().parent.parent


def cpu(row, start, end, core=0, ipid=1, itid=11, **extra):
    value = dict(key=dict(table="sched_slice", rowID=row), range=dict(startNs=start, endNs=end), cpu=core,
        processKey=None if ipid is None else dict(ipid=ipid), threadKey=None if itid is None else dict(itid=itid),
        pid=None if ipid is None else 42, tid=None if itid is None else 7,
        threadName=None, processName=None, endState=None, priority=None, isOpenEnded=False)
    value.update(extra)
    return value


def state(row, start, end, raw="R", normalized="runnable", ipid=1, itid=11, **extra):
    value = dict(key=dict(table="thread_state", rowID=row), range=dict(startNs=start, endNs=end),
        processKey=None if ipid is None else dict(ipid=ipid), threadKey=dict(itid=itid),
        pid=None if ipid is None else 42, tid=7, state=raw, normalizedState=normalized,
        cpu=None, processName=None, threadName=None, isOpenEnded=False)
    value.update(extra)
    return value


def named(row, start, end):
    return dict(key=dict(table="callstack", rowID=row), range=dict(startNs=start, endNs=end))


def vector(name, cpu_rows=None, states=None, named_rows=None, start=0, end=1000, **parameters):
    request = dict(range=dict(startNs=start, endNs=end), maximumCPUSlices=20_000, maximumProcessSlices=20_000,
        maximumThreadSlices=20_000, maximumStateIntervals=20_000, maximumSchedulingEvents=20_000, maximumHotEvents=20_000,
        topProcessLimit=10, topThreadLimit=10, schedulingSampleLimit=20, hotIntervalLimit=20, hotBucketCount=7,
        minimumLongSliceDurationNs=0, maximumOutputRows=100_000)
    request.update(parameters)
    return dict(name=name, request=request, durationNs=end, cpuAvailable=True, stateAvailable=True,
        namedAvailable=True, cpuRows=cpu_rows or [], stateRows=states or [], namedRows=named_rows or [])


def main():
    vectors = [vector("empty-supported")]
    unavailable = vector("all-capabilities-unavailable")
    unavailable.update(cpuAvailable=False, stateAvailable=False, namedAvailable=False)
    vectors.append(unavailable)
    normal = vector("clipping-overlap-reused-pid-tid-and-instant",
        [cpu(1, 0, 150), cpu(2, 50, 200, ipid=2, itid=12), cpu(3, 80, 90, core=3),
         cpu(4, 120, 120, core=3), cpu(5, 200, 200, core=5), cpu(6, 90, 220, core=2, ipid=None, itid=None)],
        [state(1, 80, 100), state(2, 100, 130, raw="未知", normalized=None), state(3, 120, 120)],
        [named(1, 80, 220), named(2, 120, 120), named(3, 200, 200)], start=100, end=200, hotBucketCount=4)
    vectors.append(normal)
    independent = copy.deepcopy(normal)
    independent["name"] = "independent-input-and-output-budgets"
    independent["request"].update(maximumCPUSlices=1, maximumProcessSlices=2, maximumThreadSlices=3,
        maximumStateIntervals=1, maximumSchedulingEvents=1, maximumHotEvents=2, topProcessLimit=1, topThreadLimit=1,
        schedulingSampleLimit=1, hotIntervalLimit=1)
    vectors.append(independent)
    trimmed = copy.deepcopy(normal)
    trimmed["name"] = "global-row-budget"
    trimmed["request"]["maximumOutputRows"] = 4
    vectors.append(trimmed)
    zero = copy.deepcopy(normal)
    zero["name"] = "zero-output-rows-retains-evidence"
    zero["request"]["maximumOutputRows"] = 0
    vectors.append(zero)
    vectors.append(vector("nearest-rank-percentiles-and-duplicate-boundary", [
        cpu(9, 100, 120), cpu(2, 100, 130), cpu(3, 200, 300, itid=12), cpu(4, 400, 500, itid=13),
        cpu(5, 600, 700, itid=14), cpu(6, 800, 900, itid=15)], [
        state(1, 99, 100), state(2, 198, 200, itid=12), state(3, 397, 400, itid=13),
        state(4, 596, 600, itid=14), state(5, 700, 800, itid=15),
        state(6, 100, 200, raw="Runnable", normalized=None, itid=12)], schedulingSampleLimit=2))
    vectors.append(vector("metadata-null-first-nonnull-and-state-order", [
        cpu(1, 0, 200, ipid=2, itid=12), cpu(2, 100, 200, ipid=2, itid=12, processName="p", threadName="t"),
        cpu(3, 200, 500)], [state(1, 0, 20, raw="é", normalized=None, ipid=None),
        state(2, 20, 40, raw="e\u0301", normalized="sleeping"), state(3, 40, 60, raw="é", normalized="blocked"),
        state(4, 60, 80, raw="é", normalized=None)]))
    max_ns = (1 << 63) - 1
    vectors.append(vector("checked-saturation-max-time", [cpu(1, 0, max_ns), cpu(2, 0, max_ns)],
        [state(1, 0, max_ns, raw="X", normalized=None), state(2, 0, max_ns, raw="X", normalized=None)],
        [named(1, 0, max_ns), named(2, 0, max_ns)], end=max_ns, hotBucketCount=1))
    vectors.append(vector("near-int64-max-open-ended-and-remainder", [cpu(1, max_ns-10, max_ns, isOpenEnded=True),
        cpu(2, max_ns-7, max_ns-7), cpu(3, max_ns, max_ns)], [state(1, max_ns-10, max_ns, raw="X", normalized=None, isOpenEnded=True)],
        [named(1, max_ns-9, max_ns)], start=max_ns-10, end=max_ns, hotBucketCount=6))
    vectors.append(vector("nanosecond-buckets-long-threshold-and-start-observations", [cpu(1, 0, 7), cpu(2, 4, 4), cpu(3, 7, 7)],
        named_rows=[named(1, 0, 7), named(2, 4, 4)], start=1, end=7, hotBucketCount=100,
        minimumLongSliceDurationNs=2))
    random_source = random.Random(9009)
    for index in range(12):
        cpus, states, named_rows = [], [], []
        for row in range(1, 80):
            start = random_source.randrange(0, 500)
            end = start + random_source.randrange(0, 450)
            cpus.append(cpu(row, start, end, core=random_source.randrange(4), ipid=random_source.randrange(1, 5), itid=random_source.randrange(11, 18)))
            states.append(state(row, start, end, raw=random_source.choice(["R", "X", "S", "未知"]), normalized=random_source.choice([None, "runnable", "sleeping"]),
                ipid=random_source.randrange(1, 5), itid=random_source.randrange(11, 18)))
            named_rows.append(named(row, start, end))
        vectors.append(vector(f"seed-9009-{index}", cpus, states, named_rows, start=100, end=800,
            hotBucketCount=random_source.randrange(1, 100), maximumCPUSlices=random_source.randrange(1, 80),
            maximumProcessSlices=random_source.randrange(1, 80), maximumThreadSlices=random_source.randrange(1, 80),
            maximumStateIntervals=random_source.randrange(1, 80), maximumHotEvents=random_source.randrange(1, 80),
            maximumOutputRows=random_source.choice([0, 10, 100_000])))
    (CRATE / "tests/fixtures/inputs.json").write_text(json.dumps(vectors, indent=2, ensure_ascii=False) + "\n")
    deviations = [vector("open-ended-runnable-boundary-not-observed", [cpu(1, 100, 200)],
        [state(1, 0, 100, isOpenEnded=True)]), vector("canonical-unicode-raw-state", states=[
        state(1, 0, 30, raw="é", normalized=None), state(2, 30, 60, raw="e\u0301", normalized=None)])]
    (CRATE / "tests/fixtures/deviation-inputs.json").write_text(json.dumps(deviations, indent=2, ensure_ascii=False) + "\n")
    print(f"Generated {len(vectors)} parity vectors and {len(deviations)} independent behavior-gap vectors (no expected results)")


if __name__ == "__main__":
    main()
