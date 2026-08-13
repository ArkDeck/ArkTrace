#!/bin/sh
set -eu

fail() {
    printf 'Phase 4 Agent contract failed: %s\n' "$1" >&2
    exit 1
}

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repository_root=$(CDPATH= cd -- "$script_directory/.." && pwd -P)
. "$script_directory/phase3_shell_safety.sh"
arktrace_validate_reviewed_roots "$repository_root"
parser="$repository_root/ThirdParty/TraceStreamer/macx/trace_streamer"
parser_manifest="$repository_root/ThirdParty/TraceStreamer/macx/manifest.json"
small_trace="$repository_root/Fixtures/traces/zlib.htrace"

for command_name in swift jq shasum grep cmp git stat; do
    command -v "$command_name" >/dev/null 2>&1 \
        || fail "$command_name is unavailable"
done
[ -x "$parser" ] && [ -f "$parser" ] && [ ! -L "$parser" ] \
    || fail "pinned TraceStreamer is unavailable"
[ -f "$parser_manifest" ] && [ ! -L "$parser_manifest" ] \
    || fail "pinned TraceStreamer manifest is unavailable"
[ -f "$small_trace" ] && [ ! -L "$small_trace" ] \
    || fail "small locked trace is unavailable"

# Validate the real medium identity before building/running any command so an
# override cannot turn the acceptance contract into a synthetic-trace test.
locked_medium=$("$script_directory/fetch_phase3_fixtures.sh")
medium_trace=${ARKTRACE_PHASE4_MEDIUM_TRACE:-$locked_medium}
[ -f "$medium_trace" ] && [ ! -L "$medium_trace" ] \
    || fail "reviewed medium trace is unavailable"
fixture_lock="$repository_root/Fixtures/phase3-performance-fixtures.json"
[ "$(stat -f '%z' "$medium_trace")" = "$(jq -er '.medium.byteCount' "$fixture_lock")" ] \
    || fail "reviewed medium trace byte count drifted"
[ "$(shasum -a 256 "$medium_trace" | awk '{print $1}')" = \
    "$(jq -er '.medium.sha256' "$fixture_lock")" ] \
    || fail "reviewed medium trace SHA drifted"
[ "$(git hash-object "$medium_trace")" = "$(jq -er '.medium.blob' "$fixture_lock")" ] \
    || fail "reviewed medium trace blob drifted"

expected_parser_sha=$(jq -er '.binarySHA256' "$parser_manifest")
expected_parser_revision=$(jq -er '.upstreamRevision' "$parser_manifest")
expected_small_sha=eb196eeb30c6b959c23d5e18d159ec946ba664ee8d9bc6f1acc32947b4ff5cfe
expected_small_bytes=67837
expected_medium_sha=$(jq -er '.medium.sha256' "$fixture_lock")
expected_medium_bytes=$(jq -er '.medium.byteCount' "$fixture_lock")

temporary_root=$(mktemp -d "$ARKTRACE_REVIEWED_TEMP_ROOT/arktrace-phase4.XXXXXX")
cleanup() {
    rm -rf -- "$temporary_root"
}
trap cleanup EXIT HUP INT TERM
user_root="$temporary_root/user"
mkdir -m 700 "$user_root"

# Run every command against private immutable copies whose bytes were checked
# after copying. Replacing any caller/repository path after preflight therefore
# cannot change what the acceptance commands actually consume.
parser_snapshot_directory="$temporary_root/parser"
mkdir -m 700 "$parser_snapshot_directory"
parser_snapshot="$parser_snapshot_directory/trace_streamer"
cp "$parser" "$parser_snapshot"
cp "$parser_manifest" "$parser_snapshot_directory/manifest.json"
chmod 500 "$parser_snapshot"
chmod 400 "$parser_snapshot_directory/manifest.json"
[ "$(shasum -a 256 "$parser_snapshot" | awk '{print $1}')" = "$expected_parser_sha" ] \
    || fail "private parser snapshot drifted"
small_snapshot="$temporary_root/zlib.htrace"
medium_snapshot="$temporary_root/medium.htrace"
cp "$small_trace" "$small_snapshot"
cp "$medium_trace" "$medium_snapshot"
chmod 400 "$small_snapshot" "$medium_snapshot"
[ "$(shasum -a 256 "$small_snapshot" | awk '{print $1}')" = "$expected_small_sha" ] \
    && [ "$(stat -f '%z' "$small_snapshot")" = "$expected_small_bytes" ] \
    || fail "private small trace snapshot drifted"
[ "$(shasum -a 256 "$medium_snapshot" | awk '{print $1}')" = "$expected_medium_sha" ] \
    && [ "$(stat -f '%z' "$medium_snapshot")" = "$expected_medium_bytes" ] \
    || fail "private medium trace snapshot drifted"
parser=$parser_snapshot
small_trace=$small_snapshot
medium_trace=$medium_snapshot

cd "$repository_root"
release_bin_path=$(swift build -c release --show-bin-path)
arktrace="$release_bin_path/arktrace"
[ -x "$arktrace" ] || fail "Release arktrace executable is unavailable"

contains_local_path() {
    candidate_output=$1
    grep -F "$repository_root" "$candidate_output" >/dev/null 2>&1 \
        || grep -F "$temporary_root" "$candidate_output" >/dev/null 2>&1
}

assert_path_free() {
    label=$1
    shift
    for candidate_output in "$@"; do
        if contains_local_path "$candidate_output"; then
            fail "$label leaked a local path"
        fi
    done
}

# Lock the scanner itself: the private parser/trace/cache roots are siblings of
# CFFIXED_USER_HOME and therefore must be covered by the whole temporary root.
path_scanner_probe="$temporary_root/path-scanner-probe"
printf '%s\n' "$parser_snapshot" >"$path_scanner_probe"
contains_local_path "$path_scanner_probe" \
    || fail "local path scanner omitted the private snapshot root"
rm -f -- "$path_scanner_probe"

run_json() {
    name=$1
    shift
    stdout="$temporary_root/$name.json"
    stderr="$temporary_root/$name.stderr"
    if ! env CFFIXED_USER_HOME="$user_root" "$arktrace" --json \
        --trace-streamer "$parser" "$@" >"$stdout" 2>"$stderr"
    then
        fail "$name command failed"
    fi
    [ ! -s "$stderr" ] || fail "$name wrote machine diagnostics"
    jq -e \
        --arg traceSHA "$expected_trace_sha" \
        --argjson traceBytes "$expected_trace_bytes" \
        --arg parserSHA "$expected_parser_sha" \
        --arg parserRevision "$expected_parser_revision" '
        .schemaVersion == "1.0" and (.result != null) and (.error == null)
        and .trace.sha256 == $traceSHA
        and .trace.byteCount == $traceBytes
        and .trace.parser.binarySha256 == $parserSHA
        and .trace.parser.upstreamRevision == $parserRevision
        and (.provenance.upstreamDatabaseSha256 | test("^[0-9a-f]{64}$"))
    ' "$stdout" >/dev/null || fail "$name machine envelope is invalid"
    assert_path_free "$name" "$stdout" "$stderr"
}

# Small real trace proves every command reaches the production parser/session
# path in both capability-present and semantic-insufficiency cases.
expected_trace_sha=$expected_small_sha
expected_trace_bytes=$expected_small_bytes
run_json inspect inspect "$small_trace"
small_duration=$(jq -er '.trace.durationNs' "$temporary_root/inspect.json")
[ "$small_duration" -gt 1 ] || fail "small trace duration is invalid"
run_json query-small query "$small_trace" --view slices \
    --start-ns 0 --end-ns 1 --limit 10
run_json context-small context "$small_trace" --start-ns 0 --end-ns 1
run_json scheduling-small analyze "$small_trace" --kind scheduling \
    --start-ns 0 --end-ns "$small_duration" --limit 20
jq -e '.result.kind == "scheduling"
    and .result.analysis.schedulingLatency.supported == false
    and .result.analysis.schedulingLatency.unsupportedReason != null' \
    "$temporary_root/scheduling-small.json" >/dev/null \
    || fail "semantic-insufficiency scheduling result was not explicit"

# The reviewed medium fixture is the real 10.2 s Agent acceptance trace.
expected_trace_sha=$expected_medium_sha
expected_trace_bytes=$expected_medium_bytes
run_json inspect-medium inspect "$medium_trace"
duration=$(jq -er '.trace.durationNs' "$temporary_root/inspect-medium.json")
[ "$duration" -gt 1 ] || fail "medium trace duration is invalid"
if [ "$duration" -gt 10300000000 ]; then
    range_start=10100000000
    range_end=10300000000
else
    range_start=0
    range_end=$duration
fi

run_json processes processes "$medium_trace" --limit 100
jq -e '.result.items | length > 0' "$temporary_root/processes.json" >/dev/null \
    || fail "real process directory is empty"
run_json threads threads "$medium_trace" --limit 100
jq -e '.result.items | length > 0' "$temporary_root/threads.json" >/dev/null \
    || fail "real thread directory is empty"
pid=$(jq -er 'first(.result.items[] | select(.pid != null) | .pid)' \
    "$temporary_root/threads.json")
[ -n "$pid" ] || fail "real thread directory has no PID"
run_json threads-by-pid threads "$medium_trace" --pid "$pid" --limit 100
jq -e --argjson pid "$pid" '
    (.result.items | length > 0)
    and ([.result.items[].pid] | all(. == $pid))
    and ([.result.items[].key] | all(type == "number"))
' "$temporary_root/threads-by-pid.json" >/dev/null \
    || fail "PID-scoped thread identity result is invalid"

run_json cpu-near-10s query "$medium_trace" --view cpu-slices \
    --start-ns "$range_start" --end-ns "$range_end" --limit 1000
jq -e '.result.capabilityAvailable == true and (.result.cpuSlices | length > 0)' \
    "$temporary_root/cpu-near-10s.json" >/dev/null \
    || fail "CPU slice query is unavailable"
run_json named-slices query "$medium_trace" --view slices \
    --start-ns "$range_start" --end-ns "$range_end" --limit 1000
jq -e '.result.capabilityAvailable == true and (.result.slices | length > 0)' \
    "$temporary_root/named-slices.json" >/dev/null \
    || fail "named slice query is unavailable"
run_json context-near-10s context "$medium_trace" \
    --start-ns "$range_start" --end-ns "$range_end"
jq -e '
    def event_process_keys:
      ([.cpuSlices[]?.processKey, .threadStates[]?.processKey,
        .slices[]?.processKey, .counters[]?.processKey,
        .counters[]?.samples[]?.processKey, .threads[]?.processKey]
        | map(select(. != null)) | unique);
    def event_thread_keys:
      ([.cpuSlices[]?.threadKey, .threadStates[]?.threadKey,
        .slices[]?.threadKey, .counters[]?.threadKey,
        .counters[]?.samples[]?.threadKey] | map(select(. != null)) | unique);
    .result as $context
    | (($context.cpuSlices | length) + ($context.threadStates | length)
        + ($context.slices | length)
        + ([$context.counters[]?.samples | length] | add // 0)) > 0
    and $context.range.startNs >= 0
    and $context.range.endNs > $context.range.startNs
    and (.truncation.truncated | type == "boolean")
    and $context.truncation.referenceOmittedByBudget == false
    and ((($context | event_process_keys) - [$context.processes[].key] | length) == 0)
    and ((($context | event_thread_keys) - [$context.threads[].key] | length) == 0)
    ' \
    "$temporary_root/context-near-10s.json" >/dev/null \
    || fail "bounded Context result is invalid"
run_json range-analysis analyze "$medium_trace" --kind range \
    --start-ns "$range_start" --end-ns "$range_end" --limit 20
jq -e '.result.kind == "range"
    and (.result.analysis.topThreads | length > 0)
    and ([.result.analysis.topThreads[].runningNs] | any(. > 0))
    and (.result.analysis.cpuUtilization | length > 0)' \
    "$temporary_root/range-analysis.json" >/dev/null \
    || fail "range analysis result is invalid"
run_json long-slices analyze "$medium_trace" --kind slices \
    --start-ns "$range_start" --end-ns "$range_end" --threshold-ns 1 --limit 20
run_json hot-intervals analyze "$medium_trace" --kind hot-intervals \
    --start-ns "$range_start" --end-ns "$range_end" --limit 20
jq -e '(.result.analysis.longSlices | length) > 0
    and ([.result.analysis.longSlices[].range
      | (.endNs - .startNs)] | all(. >= 1))' \
    "$temporary_root/long-slices.json" >/dev/null \
    || fail "long-slice analysis returned no real result"
jq -e '(.result.analysis.hotIntervals | length) > 0
    and ([.result.analysis.hotIntervals[].score
      | (.total > 0)
        and (.total == (.cpuBusyNs + .contextSwitchScoreNs + .longSliceNs))]
      | all)' \
    "$temporary_root/hot-intervals.json" >/dev/null \
    || fail "hot-interval analysis returned no real result"

# Result bytes—not cacheHit—must be deterministic on the same immutable trace.
run_json range-analysis-repeat analyze "$medium_trace" --kind range \
    --start-ns "$range_start" --end-ns "$range_end" --limit 20
jq -S '.result' "$temporary_root/range-analysis.json" \
    >"$temporary_root/result-a.json"
jq -S '.result' "$temporary_root/range-analysis-repeat.json" \
    >"$temporary_root/result-b.json"
cmp "$temporary_root/result-a.json" "$temporary_root/result-b.json" >/dev/null 2>&1 \
    || fail "repeated analysis result bytes drifted"

# Invalid raw-SQL-shaped input and overlong filters fail before trace work.
set +e
env CFFIXED_USER_HOME="$user_root" "$arktrace" --json \
    query "$medium_trace" --view slices --start-ns 0 --end-ns 1 \
    --sql 'SELECT * FROM sched_slice' \
    >"$temporary_root/raw-sql.json" 2>"$temporary_root/raw-sql.stderr"
raw_sql_status=$?
long_name=$(awk 'BEGIN { for (i=0; i<300; i++) printf "x" }')
env CFFIXED_USER_HOME="$user_root" "$arktrace" --json \
    query "$medium_trace" --view slices --start-ns 0 --end-ns 1 \
    --name "$long_name" \
    >"$temporary_root/long-filter.json" 2>"$temporary_root/long-filter.stderr"
long_filter_status=$?
set -e
[ "$raw_sql_status" -eq 2 ] && [ "$long_filter_status" -eq 2 ] \
    || fail "invalid query surface did not return usage status"
jq -e '.error.code == "INVALID_ARGUMENT" and (.result == null)' \
    "$temporary_root/raw-sql.json" >/dev/null \
    || fail "raw SQL negative did not return one typed document"
jq -e '.error.code == "INVALID_ARGUMENT" and (.result == null)' \
    "$temporary_root/long-filter.json" >/dev/null \
    || fail "long filter negative did not return one typed document"
grep -F 'SELECT * FROM' "$temporary_root/raw-sql.json" >/dev/null \
    && fail "raw SQL was reflected into machine output"
assert_path_free "raw SQL negative" \
    "$temporary_root/raw-sql.json" "$temporary_root/raw-sql.stderr"
assert_path_free "long filter negative" \
    "$temporary_root/long-filter.json" "$temporary_root/long-filter.stderr"

printf 'Phase 4 Agent contract passed: real process/thread/query/context/analyze paths are deterministic and path-free\n'
