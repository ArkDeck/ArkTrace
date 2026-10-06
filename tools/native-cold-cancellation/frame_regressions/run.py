"""Execute the reviewed N48 cases against current production source methods."""
import json
import time
from test_frame_checkpoints import run_group

start = time.monotonic_ns()
result = run_group(start, start + 5_000_000_000,
                   {"origin": "mainline regression invocation", "noProductAuthority": True})
print(json.dumps(result, sort_keys=True))
raise SystemExit(0 if result["status"] == "PASS" else 2)
