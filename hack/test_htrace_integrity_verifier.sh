#!/bin/sh
set -eu

fail() {
    printf 'htrace integrity verifier test failed: %s\n' "$1" >&2
    exit 1
}

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/arktrace-htrace-verifier.XXXXXX")
cleanup() { rm -rf -- "$temporary_root"; }
trap cleanup EXIT HUP INT TERM

python3 - "$temporary_root" <<'PY'
import hashlib, pathlib, struct, sys

root = pathlib.Path(sys.argv[1])

def segment(packets, data_type=0):
    payload = b"".join(struct.pack("<I", len(packet)) + packet for packet in packets)
    header = bytearray(1024)
    header[:8] = b"OHOSPROF"
    struct.pack_into("<Q", header, 8, 1024 + len(payload))
    struct.pack_into("<I", header, 16, 1 << 16)
    struct.pack_into("<I", header, 20, len(packets) * 2 if data_type == 0 else 0)
    header[24:56] = hashlib.sha256(payload).digest()
    struct.pack_into("<I", header, 56, data_type)
    return bytes(header) + payload

valid = segment([b"one", b"two", b"three"])
(root / "dayu-count-shape.htrace").write_bytes(
    segment([struct.pack("<I", index) for index in range(110_380)])
)
(root / "valid.htrace").write_bytes(valid)
(root / "truncated.htrace").write_bytes(valid[:-1])
(root / "padding.htrace").write_bytes(valid + b"padding")
(root / "zero-packet.htrace").write_bytes(segment([b""]))
(root / "duplicates.htrace").write_bytes(segment([b"same", b"same"]))
(root / "repeated-segment.htrace").write_bytes(valid + valid)
(root / "distinct-concat.htrace").write_bytes(
    segment([b"first-capture"]) + segment([b"second-capture"])
)
(root / "cross-type-concat.htrace").write_bytes(
    segment([b"first-capture"], data_type=0)
    + segment([b"independent-symbols"], data_type=1)
)
(root / "digest-drift.htrace").write_bytes(
    valid[:24] + bytes([valid[24] ^ 1]) + valid[25:]
)
odd_count = bytearray(valid)
struct.pack_into("<I", odd_count, 20, 5)
(root / "odd-count.htrace").write_bytes(odd_count)
underreported_count = bytearray(valid)
struct.pack_into("<I", underreported_count, 20, 2)
(root / "underreported-count.htrace").write_bytes(underreported_count)
overreported_count = bytearray(valid)
struct.pack_into("<I", overreported_count, 20, 8)
(root / "overreported-count.htrace").write_bytes(overreported_count)
(root / "digest-index-overflow.htrace").write_bytes(
    segment([struct.pack("<I", index) for index in range(262_145)])
)
PY

PYTHONDONTWRITEBYTECODE=1 python3 -B - \
    "$script_directory/verify_htrace_integrity.py" "$temporary_root/valid.htrace" <<'PY'
import importlib.util, os, pathlib, sys
spec = importlib.util.spec_from_file_location("integrity", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
trace = pathlib.Path(sys.argv[2])
original_size = trace.stat().st_size
def grow():
    with trace.open("ab") as handle:
        handle.write(b"growth" * 1024)
try:
    module.inspect(trace, after_open=grow)
except module.IntegrityError:
    pass
else:
    raise SystemExit("growing input was accepted")
if trace.stat().st_size <= original_size:
    raise SystemExit("growth seam did not modify the input")
trace.write_bytes(trace.read_bytes()[:original_size])
PY

"$script_directory/verify_htrace_integrity.py" \
    "$temporary_root/valid.htrace" "$temporary_root/report.json"
jq -e '
    .formatVersion == 1 and .segmentCount == 1
    and .protobufPacketCount == 3
    and .segments[0].protobufPacketCount == 3
    and .byteCount > 1024
    and (.traceSHA256 | test("^[0-9a-f]{64}$"))
' "$temporary_root/report.json" >/dev/null || fail "valid report shape drifted"

"$script_directory/verify_htrace_integrity.py" \
    "$temporary_root/dayu-count-shape.htrace" "$temporary_root/dayu-count-report.json"
jq -e '
    .formatVersion == 1 and .segmentCount == 1
    and .protobufPacketCount == 110380
    and .segments[0].protobufPacketCount == 110380
' "$temporary_root/dayu-count-report.json" >/dev/null \
    || fail "DAYU packet-count shape was not accepted"

printf 'foreign output sentinel\n' >"$temporary_root/foreign-output"
foreign_output_sha=$(shasum -a 256 "$temporary_root/foreign-output" | awk '{print $1}')
ln -s "$temporary_root/foreign-output" "$temporary_root/symlink-report.json"
"$script_directory/verify_htrace_integrity.py" \
    "$temporary_root/valid.htrace" "$temporary_root/symlink-report.json"
[ "$(shasum -a 256 "$temporary_root/foreign-output" | awk '{print $1}')" = \
    "$foreign_output_sha" ] || fail "output symlink target was overwritten"
[ -f "$temporary_root/symlink-report.json" ] \
    && [ ! -L "$temporary_root/symlink-report.json" ] \
    || fail "verified report did not atomically replace the output entry"
[ -z "$(find "$temporary_root" -maxdepth 1 -name '.*.partial' -print -quit)" ] \
    || fail "integrity verifier left a private partial output"

for invalid in truncated padding zero-packet duplicates repeated-segment \
    distinct-concat cross-type-concat digest-drift odd-count \
    underreported-count overreported-count digest-index-overflow
do
    if "$script_directory/verify_htrace_integrity.py" \
        "$temporary_root/$invalid.htrace" "$temporary_root/$invalid.json" \
        >/dev/null 2>"$temporary_root/$invalid.log"
    then
        fail "$invalid input was accepted"
    fi
    [ "$(stat -f '%z' "$temporary_root/$invalid.log")" -le 512 ] \
        || fail "$invalid diagnostic exceeded its byte bound"
    if grep -F "$temporary_root" "$temporary_root/$invalid.log" >/dev/null; then
        fail "$invalid diagnostic disclosed an absolute path"
    fi
done

printf 'htrace integrity verifier test passed: DAYU count accepted; truncation, digest, framing, concat, duplicates, and index overflow rejected\n'
