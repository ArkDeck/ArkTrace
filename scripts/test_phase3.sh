#!/bin/sh
set -eu

fail() {
    printf 'Phase 3 gate failed: %s\n' "$1" >&2
    exit 1
}

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_directory/.." && pwd)

[ -n "${ARKTRACE_REVIEWED_SIGNED_APP:-}" ] \
    || fail "ARKTRACE_REVIEWED_SIGNED_APP is required for the final distribution gate"
[ -n "${ARKTRACE_ACCESSIBILITY_EVIDENCE:-}" ] \
    || fail "ARKTRACE_ACCESSIBILITY_EVIDENCE is required for AC-AT-016"

cd "$repository_root"
scripts/test_phase3_batch1.sh
scripts/verify_trace_streamer_lock.sh
scripts/verify_licenses.sh
scripts/test_trace_streamer_reproducibility.sh
scripts/benchmark_phase3.sh medium

[ -n "${ARKTRACE_LARGE_TRACE:-}" ] \
    || fail "ARKTRACE_LARGE_TRACE is required to close release gates 6 and 7"
[ -n "${ARKTRACE_LARGE_TRACE_EVIDENCE:-}" ] \
    || fail "ARKTRACE_LARGE_TRACE_EVIDENCE is required to close release gates 6 and 7"
scripts/benchmark_phase3.sh large

scripts/package_phase3.sh
printf 'Phase 3 gate passed: inherited gates + signed-App accessibility evidence + real performance + licenses + notarization\n'
