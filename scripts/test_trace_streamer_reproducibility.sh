#!/bin/sh
set -eu

fail() {
    printf 'TraceStreamer reproducibility gate failed: %s\n' "$1" >&2
    exit 1
}

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_directory/.." && pwd)
temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/arktrace-repro.XXXXXX")
cleanup() { rm -rf -- "$temporary_root"; }
trap cleanup EXIT HUP INT TERM

print_build_failure() {
    : "$1"
    printf 'clean-build diagnostics withheld\n' >&2
}

for run in one two; do
    if ! ARKTRACE_TS_WORK_DIR="$temporary_root/work-$run" \
        ARKTRACE_TS_STAGE_DIR="$temporary_root/stage-$run" \
        "$script_directory/build_trace_streamer.sh" \
        >"$temporary_root/build-$run.log" 2>&1
    then
        print_build_failure "$temporary_root/build-$run.log"
        fail "clean build failed"
    fi
done

repository_binary="$repository_root/ThirdParty/TraceStreamer/macx/trace_streamer"
repository_manifest="$repository_root/ThirdParty/TraceStreamer/macx/manifest.json"

verify_binary_manifest_pair() {
    binary=$1
    manifest=$2
    expected_sha=$(jq -er '.binarySHA256' "$manifest")
    actual_sha=$(shasum -a 256 "$binary" | awk '{print $1}')
    [ "$actual_sha" = "$expected_sha" ] || return 1
    expected_arch=$(jq -er '.architecture' "$manifest")
    actual_arch=$(/usr/bin/lipo -archs "$binary" | tr ' ' '\n' | sort | paste -sd+ -)
    [ "$actual_arch" = "$expected_arch" ] || return 1
}

verify_binary_manifest_pair "$repository_binary" "$repository_manifest" \
    || fail "repository binary differs from its manifest identity"
verify_binary_manifest_pair "$temporary_root/stage-one/trace_streamer" \
    "$temporary_root/stage-one/manifest.json" \
    || fail "first clean build differs from its manifest identity"
verify_binary_manifest_pair "$temporary_root/stage-two/trace_streamer" \
    "$temporary_root/stage-two/manifest.json" \
    || fail "second clean build differs from its manifest identity"

cmp "$temporary_root/stage-one/trace_streamer" \
    "$temporary_root/stage-two/trace_streamer" >/dev/null 2>&1 \
    || fail "two clean work directories produced different binary bytes"
cmp "$repository_binary" "$temporary_root/stage-one/trace_streamer" >/dev/null 2>&1 \
    || fail "first clean build differs from the locked repository binary"
cmp "$repository_binary" "$temporary_root/stage-two/trace_streamer" >/dev/null 2>&1 \
    || fail "second clean build differs from the locked repository binary"

first_recipe=$(jq -er '.buildRecipeVersion' "$temporary_root/stage-one/manifest.json")
second_recipe=$(jq -er '.buildRecipeVersion' "$temporary_root/stage-two/manifest.json")
[ "$first_recipe" = "$second_recipe" ] \
    || fail "content-derived recipe version changed between clean builds"
[ "$first_recipe" = "$(jq -er '.buildRecipeVersion' "$repository_manifest")" ] \
    || fail "clean build recipe differs from the locked repository manifest"
[ "$(printf '%s' "$first_recipe" | wc -c | tr -d ' ')" -eq 64 ] \
    || fail "recipe version is not a SHA-256 identity"

first_sources=$(jq -cS '.thirdPartyRevisions' "$temporary_root/stage-one/manifest.json")
locked_sources=$(jq -cS 'reduce .sources[] as $source ({}; .[$source.name] = $source.revision)' \
    "$repository_root/ThirdParty/TraceStreamer/source-lock.json")
[ "$first_sources" = "$locked_sources" ] \
    || fail "manifest source revisions do not equal the source lock"

identity_projection='del(.builtAt, .hostToolchain)'
repository_identity=$(jq -cS "$identity_projection" "$repository_manifest")
first_identity=$(jq -cS "$identity_projection" "$temporary_root/stage-one/manifest.json")
second_identity=$(jq -cS "$identity_projection" "$temporary_root/stage-two/manifest.json")
[ "$repository_identity" = "$first_identity" ] \
    && [ "$repository_identity" = "$second_identity" ] \
    || fail "clean build provenance differs from the locked repository manifest"

# Regression: a same-shape executable drift must not pass the four-way bind.
drifted="$temporary_root/drifted-trace_streamer"
cp "$repository_binary" "$drifted"
printf '\001' | dd of="$drifted" bs=1 seek=4096 conv=notrunc 2>/dev/null
if verify_binary_manifest_pair "$drifted" "$repository_manifest" 2>/dev/null; then
    fail "drifted binary unexpectedly matched the locked manifest"
fi

printf 'TraceStreamer reproducibility gate passed: sha256=%s recipe=%s\n' \
    "$(shasum -a 256 "$repository_binary" | awk '{print $1}')" \
    "$first_recipe"
