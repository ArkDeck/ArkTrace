#!/usr/bin/env python3
"""Replay ArkDeck's reviewed ArkTrace analyzer requests against a staged CLI candidate.

ArkDeck records 12 reviewed Swift CLI envelopes (context and analyze, every kind) with
the operation inputs that produced them. This rebuilds the exact argv with ArkDeck's
`arguments()` mapping, runs the candidate with a minimal environment and NUL stdin on a
staged copy of the fixture, and compares the parsed envelopes. Only tool/parser build
identity and the index schema version (bumped after the recording) may differ.

Usage: python -I hack/test_cli_analysis_oracle.py <arkdeck-checkout> <candidate-dir> <work-dir> [name ...]
"""
import json, os, shutil, subprocess, sys
from pathlib import Path

ORACLE = None
FIXTURES = Path(__file__).resolve().parent.parent / "test/fixtures" / "traces"
HALF_WINDOW_NS = 50_000_000
# Identity that legitimately differs: the Windows tool/parser build and the
# Rust index schema (3 -> 4 predates the oracle recording).
IGNORED = {
    ("tool", "buildRevision"),
    ("trace", "parser", "binarySha256"),
    ("provenance", "parserBuildRecipeVersion"),
    ("provenance", "indexSchemaVersion"),
}


def argv(inputs, source):
    kind = inputs["kind"]
    ts, start, end = inputs.get("timestampNs"), inputs.get("startNs"), inputs.get("endNs")
    if start is None and end is None and ts is not None:
        start, end = max(0, ts - min(ts, HALF_WINDOW_NS)), ts + HALF_WINDOW_NS
    max_rows, max_events = inputs["maxRows"], inputs["maxEvents"]
    limit = inputs.get("limit", min(1000, max_rows, max_events))
    out = ["context" if kind == "context" else "analyze", "--json", "--no-cache",
           "--timeout-ms", str(inputs["timeoutMs"]), "--max-rows", str(max_rows),
           "--max-events", str(max_events), "--max-output-bytes", str(inputs["maxOutputBytes"])]
    if kind == "context" and ts is not None:
        out += ["--timestamp-ns", str(ts), "--window-ms", "50"]
    else:
        if kind != "context":
            out += ["--kind", kind]
        out += ["--start-ns", str(start), "--end-ns", str(end)]
    for key, flag in (("processKey", "--process-key"), ("pid", "--pid"),
                      ("threadKey", "--thread-key"), ("tid", "--tid")):
        if key in inputs:
            out += [flag, str(inputs[key])]
    if kind != "context":
        out += ["--threshold-ns", str(inputs.get("thresholdNs", 0)), "--limit", str(limit)]
    return out + [str(source)]


def diff(a, b, path, out):
    if path in IGNORED:
        return
    if isinstance(a, dict) and isinstance(b, dict):
        for k in sorted(set(a) | set(b)):
            if k not in a or k not in b:
                out.append(("missing" if k not in a else "extra", path + (k,)))
            else:
                diff(a[k], b[k], path + (k,), out)
    elif isinstance(a, list) and isinstance(b, list):
        if len(a) != len(b):
            out.append(("length", path, len(a), len(b)))
        for i, (x, y) in enumerate(zip(a, b)):
            diff(x, y, path + (i,), out)
    elif isinstance(a, bool) or isinstance(b, bool):
        if a is not b:
            out.append(("value", path, a, b))
    elif isinstance(a, (int, float)) and isinstance(b, (int, float)):
        if a != b:
            out.append(("value", path, a, b))
    elif a != b:
        out.append(("value", path, a, b))


def main():
    global ORACLE
    ORACLE = Path(sys.argv[1]) / "rust" / "tests" / "fixtures" / "arktrace-analysis-validator"
    candidate, work = Path(sys.argv[2]), Path(sys.argv[3])
    only = set(sys.argv[4:])
    requests = json.loads((ORACLE / "requests.json").read_text(encoding="utf-8"))
    work.mkdir(parents=True, exist_ok=True)
    env = {k: os.environ[k] for k in ("SystemRoot", "WINDIR") if k in os.environ}
    env["PATH"] = os.path.join(os.environ["SystemRoot"], "System32")
    results, failures = {}, 0
    for name, entry in requests.items():
        if only and name not in only:
            continue
        source_dir = work / name
        shutil.rmtree(source_dir, ignore_errors=True)
        source_dir.mkdir(parents=True)
        source = source_dir / entry["trace"]
        shutil.copyfile(FIXTURES / entry["trace"], source)
        args = argv(entry["inputs"], source)
        p = subprocess.run([str(candidate / "arktrace.exe"), *args], capture_output=True,
                           stdin=subprocess.DEVNULL, env=env, cwd=candidate, timeout=180)
        expected = json.loads((ORACLE / "reviewed" / f"{name}.json").read_text(encoding="utf-8"))
        try:
            actual = json.loads(p.stdout)
        except Exception:
            print(f"FAIL {name}: exit={p.returncode} stdout={p.stdout[:300]!r} stderr={p.stderr[:300]!r}")
            failures += 1
            continue
        out = []
        diff(expected, actual, (), out)
        (work / f"{name}.actual.json").write_bytes(p.stdout)
        leak = str(source_dir).encode() in p.stdout or b"C:\\\\" in p.stdout
        status = "PASS" if p.returncode == 0 and not out and not p.stderr and not leak else "FAIL"
        failures += status == "FAIL"
        print(f"{status} {name}: exit={p.returncode} diffs={len(out)} stderr={len(p.stderr)} leak={leak}")
        for d in out[:12]:
            print("     ", d)
        results[name] = {"exit": p.returncode, "diffs": len(out), "status": status}
    (work / "summary.json").write_text(json.dumps(results, indent=1), encoding="utf-8")
    print("ALL PASS" if not failures else f"{failures} FAILED")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
