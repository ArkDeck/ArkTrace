#!/bin/sh
set -eu

fail() {
    printf 'TraceStreamer lock verification failed: %s\n' "$1" >&2
    exit 1
}

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_directory/.." && pwd)
lock="$repository_root/ThirdParty/TraceStreamer/source-lock.json"
manifest="$repository_root/ThirdParty/TraceStreamer/macx/manifest.json"
patch="$repository_root/ThirdParty/TraceStreamer/patches/faultloggerd-apple-clang.patch"
build_script="$repository_root/scripts/build_trace_streamer.sh"
safety_helper="$repository_root/scripts/phase3_shell_safety.sh"

for path in "$lock" "$manifest" "$patch" "$build_script" "$safety_helper"; do
    [ -s "$path" ] || fail "required locked input is missing"
done

jq -e '
    .formatVersion == 1
    and (.upstream.repository | startswith("https://"))
    and (.upstream.revision | test("^[0-9a-f]{40}$"))
    and ([.tools[] |
        (.url | startswith("https://"))
        and (.sha256 | test("^[0-9a-f]{64}$"))
        and (.byteCount > 0)] | all)
    and (.sources | length == 13)
    and ([.sources[] |
        (.name | length > 0)
        and (.path | test("^[A-Za-z0-9_./-]+$") and contains("..") | not)
        and (.repository | startswith("https://"))
        and (.revision | test("^[0-9a-f]{40}$"))] | all)
    and ([.sources[].name] | unique | length == 13)
    and ([.sources[].path] | unique | length == 13)
' "$lock" >/dev/null || fail "source lock schema is invalid"

locked_upstream=$(jq -er '.upstream.revision' "$lock")
[ "$locked_upstream" = "$(jq -er '.upstreamRevision' "$manifest")" ] \
    || fail "manifest upstream revision differs from source lock"
locked_sources=$(jq -cS 'reduce .sources[] as $source ({}; .[$source.name] = $source.revision)' "$lock")
manifest_sources=$(jq -cS '.thirdPartyRevisions' "$manifest")
[ "$locked_sources" = "$manifest_sources" ] \
    || fail "manifest third-party revisions differ from source lock"

build_sha=$(shasum -a 256 "$build_script" | awk '{print $1}')
safety_sha=$(shasum -a 256 "$safety_helper" | awk '{print $1}')
lock_sha=$(shasum -a 256 "$lock" | awk '{print $1}')
patch_sha=$(shasum -a 256 "$patch" | awk '{print $1}')
recipe=$(
    printf 'build-script:%s\nsafety-helper:%s\nsource-lock:%s\nlocal-patch:%s\n' \
        "$build_sha" "$safety_sha" "$lock_sha" "$patch_sha" \
        | shasum -a 256 | awk '{print $1}'
)
[ "$recipe" = "$(jq -er '.buildRecipeVersion' "$manifest")" ] \
    || fail "manifest recipe identity does not match current locked inputs"

printf 'TraceStreamer lock verified: recipe=%s sources=13 tools=2\n' "$recipe"
