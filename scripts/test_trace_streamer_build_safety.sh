#!/bin/sh
set -eu

fail() {
    printf 'TraceStreamer build safety test failed: %s\n' "$1" >&2
    exit 1
}

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/arktrace-build-safety.XXXXXX")
cleanup() { rm -rf -- "$temporary_root"; }
trap cleanup EXIT HUP INT TERM
. "$script_directory/phase3_shell_safety.sh"
repository_root=$(CDPATH= cd -- "$script_directory/.." && pwd -P)
arktrace_validate_reviewed_roots "$repository_root"

printf 'Successfully found the configuration!\n./build_operator.sh: line 74: ./mac_depend.sh: Permission denied\n' \
    >"$temporary_root/reviewed-tail.log"
arktrace_is_reviewed_trace_streamer_tail_failure "$temporary_root/reviewed-tail.log" \
    || fail "reviewed locked-upstream post-link tail was rejected"
printf 'Successfully found the configuration!\nclang: error: post-link plugin packaging failed\n' \
    >"$temporary_root/unreviewed-tail.log"
if arktrace_is_reviewed_trace_streamer_tail_failure "$temporary_root/unreviewed-tail.log"; then
    fail "unreviewed non-zero build tail was accepted"
fi
printf 'error: earlier plugin packaging failed\nSuccessfully found the configuration!\n./build_operator.sh: line 74: ./mac_depend.sh: Permission denied\n' \
    >"$temporary_root/mixed-tail.log"
if arktrace_is_reviewed_trace_streamer_tail_failure "$temporary_root/mixed-tail.log"; then
    fail "an earlier build error hidden by the reviewed tail was accepted"
fi

foreign="$temporary_root/foreign"
mkdir "$foreign"
git -C "$foreign" init -q
printf 'tracked sentinel\n' >"$foreign/tracked.txt"
git -C "$foreign" add tracked.txt
git -C "$foreign" -c user.name=ArkTrace -c user.email=arktrace.invalid \
    commit -qm sentinel
printf 'untracked sentinel\n' >"$foreign/untracked.txt"
before_head=$(git -C "$foreign" rev-parse HEAD)
before_status=$(git -C "$foreign" status --porcelain=v1 --untracked-files=all)
before_tracked=$(shasum -a 256 "$foreign/tracked.txt" | awk '{print $1}')
before_untracked=$(shasum -a 256 "$foreign/untracked.txt" | awk '{print $1}')
outside_work="$repository_root/Fixtures/arktrace-build-safety-should-not-exist"
[ ! -e "$outside_work" ] || fail "outside-root sentinel path already exists"

if ARKTRACE_TS_WORK_DIR="$outside_work" \
    ARKTRACE_TS_STAGE_DIR="$temporary_root/outside-stage" \
    "$script_directory/build_trace_streamer.sh" >/dev/null 2>"$temporary_root/outside-error"
then
    fail "a new directory outside reviewed roots was accepted"
fi
[ ! -e "$outside_work" ] \
    || fail "rejected outside-root work path was created"

if ARKTRACE_TS_WORK_DIR="$foreign" \
    ARKTRACE_TS_STAGE_DIR="$temporary_root/stage" \
    "$script_directory/build_trace_streamer.sh" >/dev/null 2>"$temporary_root/work-error"
then
    fail "an existing unowned work directory was accepted"
fi

[ "$(git -C "$foreign" rev-parse HEAD)" = "$before_head" ] \
    && [ "$(git -C "$foreign" status --porcelain=v1 --untracked-files=all)" = "$before_status" ] \
    && [ "$(shasum -a 256 "$foreign/tracked.txt" | awk '{print $1}')" = "$before_tracked" ] \
    && [ "$(shasum -a 256 "$foreign/untracked.txt" | awk '{print $1}')" = "$before_untracked" ] \
    || fail "rejected work directory was modified"

if ARKTRACE_TS_WORK_DIR="$temporary_root/new-work" \
    ARKTRACE_TS_STAGE_DIR="$foreign" \
    "$script_directory/build_trace_streamer.sh" >/dev/null 2>"$temporary_root/stage-error"
then
    fail "an existing unowned stage directory was accepted"
fi
[ "$(git -C "$foreign" rev-parse HEAD)" = "$before_head" ] \
    && [ "$(git -C "$foreign" status --porcelain=v1 --untracked-files=all)" = "$before_status" ] \
    || fail "rejected stage directory was modified"

for log in "$temporary_root/outside-error" "$temporary_root/work-error" "$temporary_root/stage-error"; do
    [ "$(stat -f '%z' "$log")" -le 1024 ] \
        || fail "safety diagnostic exceeded its byte bound"
    if grep -F "$temporary_root" "$log" >/dev/null; then
        fail "safety diagnostic disclosed an absolute temporary path"
    fi
done

make_fake_repository() {
    destination=$1
    mkdir -p "$destination/scripts" "$destination/ThirdParty/TraceStreamer/patches" \
        "$destination/ThirdParty/TraceStreamer/macx" "$destination/Fixtures"
    cp "$script_directory/phase3_shell_safety.sh" \
        "$script_directory/build_trace_streamer.sh" \
        "$script_directory/fetch_phase3_fixtures.sh" \
        "$script_directory/build_phase3_distribution_candidate.sh" \
        "$script_directory/package_phase3.sh" \
        "$script_directory/benchmark_phase3.sh" "$destination/scripts/"
    chmod +x "$destination/scripts/"*.sh
    printf 'reviewed patch\n' \
        >"$destination/ThirdParty/TraceStreamer/patches/faultloggerd-apple-clang.patch"
    printf 'reviewed parser patch\n' \
        >"$destination/ThirdParty/TraceStreamer/patches/proto-reader-sparse-validity.patch"
    jq -n '
      {upstream:{repository:"https://invalid.example/upstream.git",revision:"0000000000000000000000000000000000000000"},tools:{},sources:[]}
    ' >"$destination/ThirdParty/TraceStreamer/source-lock.json"
    jq -n '
      {formatVersion:1,upstream:{repository:"https://invalid.example/upstream.git",revision:"0000000000000000000000000000000000000000",license:"Apache-2.0",licensePath:"LICENSE",licenseBlob:"0000000000000000000000000000000000000000",licenseSHA256:"0000000000000000000000000000000000000000000000000000000000000000",licenseByteCount:1},medium:{path:"trace",blob:"0000000000000000000000000000000000000000",sha256:"0000000000000000000000000000000000000000000000000000000000000000",byteCount:52428801},large:{minimumByteCount:524288001,maximumByteCount:2147483648}}
    ' >"$destination/Fixtures/phase3-performance-fixtures.json"
}

symlink_repository="$temporary_root/symlink-repository"
make_fake_repository "$symlink_repository"
build_escape="$temporary_root/build-escape"
mkdir "$build_escape"
printf 'foreign build sentinel\n' >"$build_escape/sentinel"
build_escape_sha=$(shasum -a 256 "$build_escape/sentinel" | awk '{print $1}')
ln -s "$build_escape" "$symlink_repository/.build"
for phase3_script in build_trace_streamer fetch_phase3_fixtures \
    build_phase3_distribution_candidate package_phase3 benchmark_phase3
do
    if "$symlink_repository/scripts/$phase3_script.sh" \
        >/dev/null 2>"$temporary_root/$phase3_script-symlink-root.log"
    then
        fail "$phase3_script accepted a symlinked repository build root"
    fi
done
[ "$(shasum -a 256 "$build_escape/sentinel" | awk '{print $1}')" = "$build_escape_sha" ] \
    && [ "$(find "$build_escape" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" = 1 ] \
    || fail "a symlinked repository build root was modified"

preflight_repository="$temporary_root/preflight-repository"
make_fake_repository "$preflight_repository"
if ARKTRACE_TS_WORK_DIR="$repository_root/Fixtures/arktrace-preflight-should-not-exist" \
    "$preflight_repository/scripts/build_trace_streamer.sh" >/dev/null 2>&1
then
    fail "invalid build preflight unexpectedly succeeded"
fi
[ ! -e "$preflight_repository/.build" ] \
    || fail "invalid build preflight mutated the reviewed build root"
if ARKTRACE_DEVELOPER_ID_APPLICATION='Developer ID Application: Invalid (INVALIDTEAM)' \
    ARKTRACE_DEVELOPMENT_TEAM='INVALIDTEAM' \
    "$preflight_repository/scripts/build_phase3_distribution_candidate.sh" \
        >/dev/null 2>&1
then
    fail "invalid candidate preflight unexpectedly succeeded"
fi
[ ! -e "$preflight_repository/.build" ] \
    || fail "invalid candidate preflight mutated the reviewed build root"
if "$preflight_repository/scripts/package_phase3.sh" >/dev/null 2>&1; then
    fail "invalid package preflight unexpectedly succeeded"
fi
[ ! -e "$preflight_repository/.build" ] \
    || fail "invalid package preflight mutated the reviewed build root"
if "$preflight_repository/scripts/benchmark_phase3.sh" invalid >/dev/null 2>&1; then
    fail "invalid benchmark preflight unexpectedly succeeded"
fi
[ ! -e "$preflight_repository/.build" ] \
    || fail "invalid benchmark preflight mutated the reviewed build root"

stage_repository="$temporary_root/stage-repository"
make_fake_repository "$stage_repository"
stage_escape="$temporary_root/stage-escape"
mkdir "$stage_escape"
printf 'foreign stage sentinel\n' >"$stage_escape/sentinel"
rm -rf "$stage_repository/ThirdParty/TraceStreamer/macx"
ln -s "$stage_escape" "$stage_repository/ThirdParty/TraceStreamer/macx"
if "$stage_repository/scripts/build_trace_streamer.sh" >/dev/null 2>&1; then
    fail "default repository stage symlink was accepted"
fi
[ "$(cat "$stage_escape/sentinel")" = 'foreign stage sentinel' ] \
    || fail "default stage symlink target was modified"
rm "$stage_repository/ThirdParty/TraceStreamer/macx"
mkdir "$stage_repository/ThirdParty/TraceStreamer/macx"
for output_name in trace_streamer manifest.json; do
    output_sentinel="$temporary_root/$output_name-sentinel"
    printf 'output sentinel\n' >"$output_sentinel"
    ln -s "$output_sentinel" \
        "$stage_repository/ThirdParty/TraceStreamer/macx/$output_name"
    if "$stage_repository/scripts/build_trace_streamer.sh" >/dev/null 2>&1; then
        fail "default stage output symlink was accepted"
    fi
    [ "$(cat "$output_sentinel")" = 'output sentinel' ] \
        || fail "default stage output symlink target was modified"
    rm "$stage_repository/ThirdParty/TraceStreamer/macx/$output_name"
done

checkout_repository="$temporary_root/checkout-repository"
make_fake_repository "$checkout_repository"
owned_work="$temporary_root/owned-work"
mkdir "$owned_work"
printf 'ArkTrace-owned-v1\n' >"$owned_work/.arktrace-trace-streamer-workspace-v1"
ln -s "$foreign" "$owned_work/upstream"
if ARKTRACE_TS_WORK_DIR="$owned_work" \
    "$checkout_repository/scripts/build_trace_streamer.sh" >/dev/null 2>&1
then
    fail "symlinked owned upstream checkout was accepted"
fi
[ "$(git -C "$foreign" rev-parse HEAD)" = "$before_head" ] \
    && [ "$(git -C "$foreign" status --porcelain=v1 --untracked-files=all)" = "$before_status" ] \
    || fail "symlinked upstream checkout modified a foreign repository"

fixture_repository="$temporary_root/fixture-repository"
make_fake_repository "$fixture_repository"
owned_fixture="$temporary_root/owned-fixture"
mkdir "$owned_fixture"
printf 'ArkTrace-owned-v1\n' >"$owned_fixture/.arktrace-phase3-fixtures-v1"
ln -s "$foreign" "$owned_fixture/upstream"
if ARKTRACE_PHASE3_FIXTURE_ROOT="$owned_fixture" \
    "$fixture_repository/scripts/fetch_phase3_fixtures.sh" >/dev/null 2>&1
then
    fail "symlinked fixture checkout was accepted"
fi
[ "$(git -C "$foreign" rev-parse HEAD)" = "$before_head" ] \
    && [ "$(git -C "$foreign" status --porcelain=v1 --untracked-files=all)" = "$before_status" ] \
    || fail "symlinked fixture checkout modified a foreign repository"

printf 'TraceStreamer build safety test passed: foreign git repository unchanged\n'
