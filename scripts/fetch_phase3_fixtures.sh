#!/bin/sh
set -eu

fail() {
    printf 'Phase 3 fixture fetch failed: %s\n' "$1" >&2
    exit 1
}

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repository_root=$(CDPATH= cd -- "$script_directory/.." && pwd -P)
. "$script_directory/phase3_shell_safety.sh"
lock="$repository_root/Fixtures/phase3-performance-fixtures.json"
fixture_root="${ARKTRACE_PHASE3_FIXTURE_ROOT:-$repository_root/.build/phase3-fixtures}"
arktrace_validate_reviewed_roots "$repository_root"
arktrace_validate_owned_directory_request "$fixture_root" "fixture root"
arktrace_create_reviewed_build_root
checkout="$fixture_root/upstream"
medium="$fixture_root/pbreader.htrace"
partial=
owner_marker="$fixture_root/.arktrace-phase3-fixtures-v1"
fetch_log=$(mktemp "$ARKTRACE_REVIEWED_TEMP_ROOT/arktrace-fixture-fetch.XXXXXX")
cleanup() {
    rm -f -- "$fetch_log"
    if [ -n "${partial:-}" ]; then rm -f -- "$partial"; fi
}
trap cleanup EXIT HUP INT TERM

for command_name in git jq shasum stat; do
    command -v "$command_name" >/dev/null 2>&1 \
        || fail "$command_name is unavailable"
done
jq -e '
    .formatVersion == 1
    and (.upstream.revision | test("^[0-9a-f]{40}$"))
    and (.medium.blob | test("^[0-9a-f]{40}$"))
    and (.medium.sha256 | test("^[0-9a-f]{64}$"))
    and .medium.byteCount > 52428800
    and .medium.byteCount <= 524288000
    and .large.minimumByteCount == 524288001
    and .large.maximumByteCount == 2147483648
' "$lock" >/dev/null || fail "fixture lock is malformed"

verify_medium() {
    candidate=$1
    [ -f "$candidate" ] && [ ! -L "$candidate" ] || return 1
    [ "$(stat -f '%z' "$candidate")" = "$(jq -er '.medium.byteCount' "$lock")" ] \
        || return 1
    [ "$(shasum -a 256 "$candidate" | awk '{print $1}')" = \
        "$(jq -er '.medium.sha256' "$lock")" ] || return 1
    [ "$(git hash-object "$candidate")" = "$(jq -er '.medium.blob' "$lock")" ] \
        || return 1
}

fixture_root=$(arktrace_secure_owned_directory \
    "$fixture_root" .arktrace-phase3-fixtures-v1 "fixture root")
checkout="$fixture_root/upstream"
medium="$fixture_root/pbreader.htrace"
owner_marker="$fixture_root/.arktrace-phase3-fixtures-v1"
if ! verify_medium "$medium"; then
    partial=$(mktemp "$fixture_root/.pbreader.XXXXXX") \
        || fail "fixture temporary output could not be created"
    upstream=$(jq -er '.upstream.repository' "$lock")
    revision=$(jq -er '.upstream.revision' "$lock")
    path=$(jq -er '.medium.path' "$lock")
    arktrace_assert_owned_child "$fixture_root" "$checkout" "fixture checkout"
    if [ ! -d "$checkout/.git" ]; then
        [ ! -e "$checkout" ] || fail "fixture checkout is existing and invalid"
        git clone --filter=blob:none --no-checkout "$upstream" "$checkout" \
            >"$fetch_log" 2>&1 || fail "fixture source clone failed"
    fi
    arktrace_assert_owned_child "$fixture_root" "$checkout" "fixture checkout"
    [ "$(git -C "$checkout" remote get-url origin)" = "$upstream" ] \
        || fail "fixture checkout remote drifted"
    git -C "$checkout" fetch --depth=1 origin "$revision" \
        >"$fetch_log" 2>&1 || fail "fixture source fetch failed"
    git -C "$checkout" show "$revision:$path" >"$partial"
    verify_medium "$partial" || fail "downloaded medium fixture bytes drifted"
    [ ! -L "$medium" ] || fail "medium fixture output must not be a symlink"
    mv -f "$partial" "$medium"
fi

license="$repository_root/Fixtures/traces/LICENSE.Apache-2.0.txt"
[ "$(stat -f '%z' "$license")" = "$(jq -er '.upstream.licenseByteCount' "$lock")" ] \
    || fail "fixture license size drifted"
[ "$(shasum -a 256 "$license" | awk '{print $1}')" = \
    "$(jq -er '.upstream.licenseSHA256' "$lock")" ] \
    || fail "fixture license SHA drifted"
[ "$(git hash-object "$license")" = "$(jq -er '.upstream.licenseBlob' "$lock")" ] \
    || fail "fixture license blob drifted"

printf '%s\n' "$medium"
