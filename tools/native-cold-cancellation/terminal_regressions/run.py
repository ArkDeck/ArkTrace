"""Run reviewed N49 internal consistency cases against current pure helpers."""
import json
import time
from test_terminal_consistency import run_group

start = time.monotonic_ns()
result = run_group(start, start + 5_000_000_000,
                   {"origin": "mainline regression invocation", "noProductAuthority": True})
print(json.dumps(result, sort_keys=True))
raise SystemExit(0 if result["status"] == "PASS" else 2)
