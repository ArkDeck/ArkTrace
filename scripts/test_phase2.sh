#!/bin/sh
set -eu

fail() {
    printf 'Phase 2 gate failed: %s\n' "$1" >&2
    exit 1
}

for command_name in swift jq shasum git file; do
    command -v "$command_name" >/dev/null 2>&1 \
        || fail "$command_name is unavailable"
done

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_directory/.." && pwd)
parser="$repository_root/ThirdParty/TraceStreamer/macx/trace_streamer"
small_trace="$repository_root/Fixtures/traces/zlib.htrace"
large_trace="$repository_root/Fixtures/traces/trace_small_10.systrace"

[ -x "$parser" ] || fail "pinned trace_streamer is unavailable"
[ -r "$small_trace" ] || fail "small locked trace is unavailable"
[ -r "$large_trace" ] || fail "scheduling locked trace is unavailable"

phase2_temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/arktrace-phase2.XXXXXX")
release_log="$phase2_temporary_directory/release-tests.log"
sanitized_release_log="$phase2_temporary_directory/release-tests.sanitized.log"
phase2_evidence="$phase2_temporary_directory/phase2-evidence.json"
phase2_evidence_with_results="$phase2_temporary_directory/phase2-evidence-with-results.json"
cli_user_root="$phase2_temporary_directory/cli-user"
mkdir -m 700 "$cli_user_root"

cleanup() {
    rm -rf -- "$phase2_temporary_directory"
}
trap cleanup EXIT HUP INT TERM

print_release_failure() {
    sed \
        -e "s|$repository_root|<repo>|g" \
        -e "s|$phase2_temporary_directory|<temp>|g" \
        "$release_log" >"$sanitized_release_log"
    # Preserve every XCTest failure location before the bounded tail. Long
    # suites can otherwise push the actionable line out of the final window.
    grep -nE 'error: -\[|Test Case .* failed|fatal error|unexpected failure' \
        "$sanitized_release_log" >&2 || true
    tail -n 160 "$sanitized_release_log" >&2
}

# Phase 2 inherits every locked Phase 1 requirement and cannot weaken its
# real-parser/fixture zero-skip gate.
"$script_directory/test_phase1.sh"

base_revision=$(git -C "$repository_root" rev-parse HEAD)
worktree_dirty=0
if ! git -C "$repository_root" diff --quiet \
    || ! git -C "$repository_root" diff --cached --quiet \
    || [ -n "$(git -C "$repository_root" ls-files --others --exclude-standard)" ]
then
    worktree_dirty=1
fi

cd "$repository_root"
if ! env \
    ARKTRACE_PHASE2_GATE=1 \
    ARKTRACE_PHASE2_EVIDENCE_OUTPUT="$phase2_evidence" \
    ARKTRACE_BASE_REVISION="$base_revision" \
    ARKTRACE_WORKTREE_DIRTY="$worktree_dirty" \
    ARKTRACE_TRACE_STREAMER="$parser" \
    ARKTRACE_TEST_TRACE="$large_trace" \
    CI=true \
    swift test -c release >"$release_log" 2>&1
then
    print_release_failure
    fail "Release test suite failed"
fi

if grep -Eq "' skipped \(|[0-9] tests? skipped" "$release_log"; then
    print_release_failure
    fail "Phase 2 Release gate must contain zero skipped tests"
fi

test_count=$(grep -oE 'Executed [0-9]+ tests' "$release_log" | tail -n 1 | awk '{print $2}')
[ -n "$test_count" ] && [ "$test_count" -gt 0 ] \
    || fail "could not determine a positive Release XCTest count"
[ -s "$phase2_evidence" ] || fail "benchmark evidence was not produced"
[ "$(stat -f '%z' "$phase2_evidence")" -le 4096 ] \
    || fail "benchmark evidence exceeded 4096 bytes"

expected_trace_sha=$(shasum -a 256 "$small_trace" | awk '{print $1}')
expected_parser_sha=$(shasum -a 256 "$parser" | awk '{print $1}')
jq -e \
    --arg traceSHA "$expected_trace_sha" \
    --arg parserSHA "$expected_parser_sha" '
    .formatVersion == 1
    and .arkTraceVersion == "0.1.0"
    and (.arkTraceBaseRevision | test("^[0-9a-f]{40}$"))
    and (.workingTreeDirty | type == "boolean")
    and .machine.architecture == "arm64"
    and (.machine.model | length > 0)
    and (.machine.operatingSystem | length > 0)
    and .machine.physicalMemoryBytes > 0
    and .traceSHA256 == $traceSHA
    and .traceByteCount > 0
    and .parserBinarySHA256 == $parserSHA
    and .parserVersion == "4.3.7"
    and (.parserUpstreamRevision | test("^[0-9a-f]{40}$"))
    and .databaseByteCount > 0
    and .iterations == 20
    and .cacheHitCount == .iterations
    and .cacheOpenP50Ms >= 0
    and .cacheOpenP95Ms >= .cacheOpenP50Ms
    and .metadataP50Ms >= 0
    and .metadataP95Ms >= .metadataP50Ms
' "$phase2_evidence" >/dev/null || fail "benchmark evidence contract failed"

release_bin_path=$(swift build -c release --show-bin-path)
arktrace="$release_bin_path/arktrace"
[ -x "$arktrace" ] || fail "Release arktrace executable was not built"

run_expect_status() {
    expected_status=$1
    stdout_path=$2
    stderr_path=$3
    shift 3
    set +e
    "$@" >"$stdout_path" 2>"$stderr_path"
    actual_status=$?
    set -e
    [ "$actual_status" -eq "$expected_status" ] \
        || fail "expected status $expected_status but received $actual_status"
}

human_error="$phase2_temporary_directory/human-error.txt"
human_stdout="$phase2_temporary_directory/human-stdout.txt"
json_error="$phase2_temporary_directory/json-error.txt"
json_stdout="$phase2_temporary_directory/json-stdout.json"
run_expect_status 2 "$human_stdout" "$human_error" \
    env CFFIXED_USER_HOME="$cli_user_root" "$arktrace" --unknown inspect "$small_trace"
grep -q 'INVALID_ARGUMENT' "$human_error" \
    || fail "human malformed-argument error lost the Core error code"
run_expect_status 2 "$json_stdout" "$json_error" \
    env CFFIXED_USER_HOME="$cli_user_root" "$arktrace" --json --unknown inspect "$small_trace"
jq -e '.error.code == "INVALID_ARGUMENT" and (.result == null)' "$json_stdout" >/dev/null \
    || fail "machine malformed-argument envelope is invalid"

wrong_parser_stdout="$phase2_temporary_directory/wrong-parser.json"
wrong_parser_stderr="$phase2_temporary_directory/wrong-parser.stderr"
run_expect_status 4 "$wrong_parser_stdout" "$wrong_parser_stderr" \
    env CFFIXED_USER_HOME="$cli_user_root" "$arktrace" --json --no-cache \
    --trace-streamer /bin/echo inspect "$small_trace"
jq -e '
    (.error.code == "TRACE_STREAMER_UNAVAILABLE"
        or .error.code == "TRACE_STREAMER_IDENTITY_MISMATCH")
    and (.result == null)
' "$wrong_parser_stdout" >/dev/null || fail "wrong-parser error contract is invalid"

timeout_stdout="$phase2_temporary_directory/timeout.json"
timeout_stderr="$phase2_temporary_directory/timeout.stderr"
run_expect_status 7 "$timeout_stdout" "$timeout_stderr" \
    env CFFIXED_USER_HOME="$cli_user_root" "$arktrace" --json --no-cache \
    --timeout-ms 100 --trace-streamer "$parser" inspect "$large_trace"
jq -e '.error.code == "QUERY_TIMEOUT" and (.result == null)' "$timeout_stdout" >/dev/null \
    || fail "timeout error contract is invalid"

overflow_stdout="$phase2_temporary_directory/overflow.json"
overflow_stderr="$phase2_temporary_directory/overflow.stderr"
run_expect_status 7 "$overflow_stdout" "$overflow_stderr" \
    env CFFIXED_USER_HOME="$cli_user_root" "$arktrace" --json --no-cache \
    --max-output-bytes 1024 --trace-streamer "$parser" summary "$small_trace"
jq -e '.error.code == "OUTPUT_LIMIT_EXCEEDED" and (.result == null)' \
    "$overflow_stdout" >/dev/null || fail "output-overflow contract is invalid"

cancel_stdout="$phase2_temporary_directory/cancel.json"
cancel_stderr="$phase2_temporary_directory/cancel.stderr"
env CFFIXED_USER_HOME="$cli_user_root" "$arktrace" --json --no-cache \
    --timeout-ms 120000 --trace-streamer "$parser" inspect "$large_trace" \
    >"$cancel_stdout" 2>"$cancel_stderr" &
cancel_pid=$!
sleep 0.10
kill -INT "$cancel_pid" 2>/dev/null || fail "cancel process exited before SIGINT"
set +e
wait "$cancel_pid"
cancel_status=$?
set -e
[ "$cancel_status" -eq 8 ] || fail "SIGINT did not map to status 8"
jq -e '.error.code == "CANCELLED" and (.result == null)' "$cancel_stdout" >/dev/null \
    || fail "SIGINT cancellation envelope is invalid"

forced_stdout="$phase2_temporary_directory/forced.stdout"
forced_stderr="$phase2_temporary_directory/forced.stderr"
env CFFIXED_USER_HOME="$cli_user_root" "$arktrace" --json --no-cache \
    --timeout-ms 120000 --trace-streamer "$parser" inspect "$large_trace" \
    >"$forced_stdout" 2>"$forced_stderr" &
forced_pid=$!
sleep 0.10
kill -TERM "$forced_pid" 2>/dev/null || fail "force process exited before first SIGTERM"
kill -TERM "$forced_pid" 2>/dev/null || fail "force process exited before second SIGTERM"
set +e
wait "$forced_pid"
forced_status=$?
set -e
[ "$forced_status" -eq 143 ] || fail "second SIGTERM did not force status 143"

jq \
    --argjson testCount "$test_count" \
    --argjson malformedStatus 2 \
    --argjson wrongParserStatus 4 \
    --argjson timeoutStatus 7 \
    --argjson outputLimitStatus 7 \
    --argjson cancelStatus 8 \
    --argjson secondSignalStatus 143 '
    . + {
        testCount: $testCount,
        skippedTestCount: 0,
        cliChecks: {
            malformedStatus: $malformedStatus,
            wrongParserStatus: $wrongParserStatus,
            timeoutStatus: $timeoutStatus,
            outputLimitStatus: $outputLimitStatus,
            cancelStatus: $cancelStatus,
            secondSignalStatus: $secondSignalStatus
        }
    }
' "$phase2_evidence" >"$phase2_evidence_with_results"
mv "$phase2_evidence_with_results" "$phase2_evidence"
[ "$(stat -f '%z' "$phase2_evidence")" -le 4096 ] \
    || fail "final Phase 2 evidence exceeded 4096 bytes"

printf 'Phase 2 gate passed: tests=%s skipped=0 cache-open-p95-ms=%s metadata-p95-ms=%s\n' \
    "$test_count" \
    "$(jq -r '.cacheOpenP95Ms' "$phase2_evidence")" \
    "$(jq -r '.metadataP95Ms' "$phase2_evidence")"
jq -c . "$phase2_evidence"
