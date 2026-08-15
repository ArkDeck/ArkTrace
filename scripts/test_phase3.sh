#!/bin/sh
set -eu

fail() {
    printf 'Phase 3 gate failed: %s\n' "$1" >&2
    exit 1
}

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_directory/.." && pwd)
. "$script_directory/phase3_shell_safety.sh"

[ -n "${ARKTRACE_REVIEWED_SIGNED_APP:-}" ] \
    || fail "ARKTRACE_REVIEWED_SIGNED_APP is required for the final distribution gate"
[ -n "${ARKTRACE_ACCESSIBILITY_EVIDENCE:-}" ] \
    || fail "ARKTRACE_ACCESSIBILITY_EVIDENCE is required for AC-AT-016"

# Freeze the exact reviewed App before inherited clean-build gates run.  The
# candidate builder may publish under repository .build, which SwiftPM/Xcode
# cleanup is allowed to replace; packaging must consume the pre-clean bytes,
# never a rebuilt or caller-substituted App.
reviewed_app_input=$ARKTRACE_REVIEWED_SIGNED_APP
[ -d "$reviewed_app_input" ] && [ ! -L "$reviewed_app_input" ] \
    || fail "ARKTRACE_REVIEWED_SIGNED_APP is unavailable or is a symlink"
arktrace_validate_reviewed_roots "$repository_root"
umask 077
gate_snapshot_root=$(mktemp -d \
    "$ARKTRACE_REVIEWED_TEMP_ROOT/arktrace-phase3-reviewed-app.XXXXXX") \
    || fail "reviewed App snapshot root could not be created"
cleanup() { rm -rf -- "$gate_snapshot_root"; }
trap cleanup EXIT HUP INT TERM
reviewed_app_snapshot="$gate_snapshot_root/ArkTrace.app"
/usr/bin/ditto --noqtn "$reviewed_app_input" "$reviewed_app_snapshot" \
    || fail "reviewed App snapshot failed"
[ -d "$reviewed_app_snapshot" ] && [ ! -L "$reviewed_app_snapshot" ] \
    || fail "reviewed App snapshot is unavailable or symbolic"
ARKTRACE_REVIEWED_SIGNED_APP=$reviewed_app_snapshot
export ARKTRACE_REVIEWED_SIGNED_APP

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

retained_notarized_zip=${ARKTRACE_REVIEWED_NOTARIZED_ZIP:-}
retained_notarization_evidence=${ARKTRACE_REVIEWED_NOTARIZATION_EVIDENCE:-}
if [ -z "$retained_notarized_zip" ] && [ -z "$retained_notarization_evidence" ]; then
    scripts/package_phase3.sh
elif [ -n "$retained_notarized_zip" ] && [ -n "$retained_notarization_evidence" ]; then
    scripts/verify_phase3_notarized_artifact.sh
else
    fail "retained notarized ZIP and its reviewed evidence must be supplied together"
fi
printf 'Phase 3 gate passed: inherited gates + signed-App accessibility evidence + real performance + licenses + verified notarization\n'
