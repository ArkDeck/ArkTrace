#!/bin/sh
set -eu

fail() {
    printf 'Phase 3 batch 1 gate failed: %s\n' "$1" >&2
    exit 1
}

repo_root=$(CDPATH= cd -P -- "$(dirname -- "$0")/.." && pwd -P)
cd "$repo_root"

env -u ARKTRACE_RUST_XCFRAMEWORK -u ARKTRACE_RUST_SDK_FIXTURES sh scripts/test_phase2.sh
scripts/test_trace_streamer_build_safety.sh
scripts/test_license_verifier.sh
scripts/test_htrace_integrity_verifier.sh
scripts/test_phase3_benchmark_contract.sh
scripts/test_phase3_distribution_contract.sh

sh scripts/test_native_app_build.sh

echo "Phase 3 batch 1 gate passed: inherited Phase 2 + current native App compile gate; native startup acceptance not claimed"
