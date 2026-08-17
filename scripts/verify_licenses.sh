#!/bin/sh
set -eu

fail() {
    printf 'License inventory verification failed: %s\n' "$1" >&2
    exit 1
}

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=${ARKTRACE_VERIFY_LICENSE_ROOT:-$(CDPATH= cd -- "$script_directory/.." && pwd)}
repository_root=$(CDPATH= cd -- "$repository_root" && pwd -P)
inventory="$repository_root/ThirdParty/TraceStreamer/license-inventory.json"
source_lock="$repository_root/ThirdParty/TraceStreamer/source-lock.json"
license_root="$repository_root/ThirdParty/TraceStreamer"
product_license="$repository_root/LICENSE"
notice="$repository_root/THIRD_PARTY_NOTICES.md"

[ -f "$product_license" ] && [ ! -L "$product_license" ] \
    || fail "ArkTrace product license is missing or a symlink"
[ "$(stat -f '%z' "$product_license")" = 1078 ] \
    || fail "ArkTrace product license byte count drifted"
[ "$(shasum -a 256 "$product_license" | awk '{print $1}')" = \
    27ec10adbe109a67f514a5620190460e52b09352214aaf1d9869be568b6f46d9 ] \
    || fail "ArkTrace product license SHA drifted"
grep -Fx 'MIT License' "$product_license" >/dev/null \
    || fail "ArkTrace product license text is not the reviewed MIT license"
[ -f "$notice" ] && [ ! -L "$notice" ] && [ -s "$notice" ] \
    || fail "third-party notice is missing or invalid"
grep -F 'ArkTrace itself is licensed under the MIT License' "$notice" >/dev/null \
    || fail "third-party notice misstates the ArkTrace product license"
if grep -F 'ArkTrace itself is licensed under Apache-2.0' "$notice" >/dev/null; then
    fail "third-party notice misstates ArkTrace as Apache-2.0"
fi
[ "$(stat -f '%z' "$notice")" = 2621 ] \
    || fail "third-party notice byte count drifted"
[ "$(shasum -a 256 "$notice" | awk '{print $1}')" = \
    0298f7e4ecb1c1b8ffb0bc120aa0ddc1bce93b4baf9983172a047fde3c516dda ] \
    || fail "third-party notice SHA drifted"

jq -e '
    .formatVersion == 1
    and (.buildTools | length == 2)
    and ([.buildTools[].name] | unique | length == 2)
    and ([.buildTools[] |
        (.repository | startswith("https://"))
        and (.revision | test("^[0-9a-f]{40}$"))
        and (.artifactURL | startswith("https://"))
        and (.artifactSHA256 | test("^[0-9a-f]{64}$"))
        and (.artifactByteCount > 0)
        and (.licenseFile | test("^LICENSES/[A-Za-z0-9_.+-]+$") and contains("..") | not)
        and (.licenseSHA256 | test("^[0-9a-f]{64}$"))
        and (.licenseByteCount > 0)
        and .usage == "build-tool-not-distributed"
    ] | all)
    and (.components | length == 14)
    and ([.components[].name] | unique | length == 14)
    and ([.components[] |
        (.repository | startswith("https://"))
        and (.revision | test("^[0-9a-f]{40}$"))
        and (.licenseExpression | length > 0)
        and (.licenseFile | test("^LICENSES/[A-Za-z0-9_.+-]+$") and contains("..") | not)
        and (.licenseSHA256 | test("^[0-9a-f]{64}$"))
        and (.licenseByteCount > 0)
        and (.usage | IN("shipped", "shipped-apache-subset", "build-only", "build-only-disabled-plugin"))
        and ((.additionalLicenseFiles // []) | type == "array" and length <= 8)
        and ([.additionalLicenseFiles[]? |
            ((keys | sort) == ["byteCount","path","sha256"])
            and (.path | test("^LICENSES/[A-Za-z0-9_.+-]+$") and contains("..") | not)
            and (.sha256 | test("^[0-9a-f]{64}$"))
            and (.byteCount > 0)
        ] | all)
    ] | all)
' "$inventory" >/dev/null || fail "inventory schema is invalid"

[ -d "$license_root/LICENSES" ] && [ ! -L "$license_root/LICENSES" ] \
    || fail "license directory is missing or a symlink"
physical_license_root=$(CDPATH= cd -- "$license_root/LICENSES" && pwd -P) \
    || fail "license directory is inaccessible"

expected_license_names=$(mktemp "${TMPDIR:-/tmp}/arktrace-license-expected.XXXXXX")
actual_license_names=$(mktemp "${TMPDIR:-/tmp}/arktrace-license-actual.XXXXXX")
license_candidates=$(mktemp "${TMPDIR:-/tmp}/arktrace-license-candidates.XXXXXX")
cleanup_lists() {
    rm -f -- "$expected_license_names" "$actual_license_names" "$license_candidates"
}
trap cleanup_lists EXIT HUP INT TERM
jq -r '[.components[].licenseFile,.buildTools[].licenseFile,.components[].additionalLicenseFiles[]?.path][]' \
    "$inventory" | sed 's#^LICENSES/##' | LC_ALL=C sort -u >"$expected_license_names"
[ "$(wc -l <"$expected_license_names" | tr -d ' ')" = 18 ] \
    || fail "inventory does not name exactly 18 unique license files"
find "$license_root/LICENSES" -mindepth 1 -maxdepth 1 -print >"$license_candidates"
while IFS= read -r candidate; do
    [ -f "$candidate" ] && [ ! -L "$candidate" ] \
        || fail "license directory contains a non-regular entry"
    basename -- "$candidate" >>"$actual_license_names"
done <"$license_candidates"
LC_ALL=C sort "$actual_license_names" -o "$actual_license_names"
cmp "$expected_license_names" "$actual_license_names" >/dev/null 2>&1 \
    || fail "license directory differs from the exact inventory closure"

verify_license_file() {
    relative=$1
    expected_sha=$2
    expected_bytes=$3
    case "$relative" in
        LICENSES/[A-Za-z0-9_.+-]*) ;;
        *) fail "license path is invalid" ;;
    esac
    case "/$relative/" in */../*|*/./*) fail "license path contains traversal" ;; esac
    candidate="$license_root/$relative"
    candidate_parent=$(CDPATH= cd -- "$(dirname -- "$candidate")" && pwd -P) \
        || fail "license parent is inaccessible"
    [ "$candidate_parent" = "$physical_license_root" ] \
        || fail "license path escapes the physical license directory"
    [ -f "$candidate" ] && [ ! -L "$candidate" ] \
        || fail "license file is missing or a symlink"
    [ "$(stat -f '%z' "$candidate")" = "$expected_bytes" ] \
        || fail "license byte count drifted"
    [ "$(shasum -a 256 "$candidate" | awk '{print $1}')" = "$expected_sha" ] \
        || fail "license SHA drifted"
}

locked_tools=$(jq -cS 'reduce (.tools | to_entries[]) as $tool ({};
    .[$tool.key] = [$tool.value.url,$tool.value.sha256,$tool.value.byteCount])' "$source_lock")
inventory_tools=$(jq -cS 'reduce .buildTools[] as $tool ({};
    .[($tool.name | ascii_downcase)] = [$tool.artifactURL,$tool.artifactSHA256,$tool.artifactByteCount])' "$inventory")
[ "$locked_tools" = "$inventory_tools" ] \
    || fail "build-tool inventory differs from source lock"

locked_sources=$(jq -cS 'reduce .sources[] as $source ({}; .[$source.name] = [$source.repository,$source.revision])' "$source_lock")
inventory_sources=$(jq -cS 'reduce (.components[] | select(.name != "TraceStreamer")) as $component ({}; .[$component.name] = [$component.repository,$component.revision])' "$inventory")
[ "$locked_sources" = "$inventory_sources" ] \
    || fail "inventory repository/revision closure differs from source lock"

locked_upstream=$(jq -cS '[.upstream.repository,.upstream.revision]' "$source_lock")
inventory_upstream=$(jq -cS '[.components[] | select(.name == "TraceStreamer") | .repository,.revision]' "$inventory")
[ "$locked_upstream" = "$inventory_upstream" ] \
    || fail "TraceStreamer notice provenance differs from source lock"

jq -r '.components[] | [.licenseFile,.licenseSHA256,.licenseByteCount] | @tsv' \
    "$inventory" |
while IFS="$(printf '\t')" read -r relative expected_sha expected_bytes; do
    verify_license_file "$relative" "$expected_sha" "$expected_bytes"
done

jq -r '.buildTools[] | [.licenseFile,.licenseSHA256,.licenseByteCount] | @tsv' \
    "$inventory" |
while IFS="$(printf '\t')" read -r relative expected_sha expected_bytes; do
    verify_license_file "$relative" "$expected_sha" "$expected_bytes"
done

jq -r '.components[].additionalLicenseFiles[]? | [.path,.sha256,.byteCount] | @tsv' \
    "$inventory" |
while IFS="$(printf '\t')" read -r relative expected_sha expected_bytes; do
    verify_license_file "$relative" "$expected_sha" "$expected_bytes"
done

printf 'License inventory verified: product=MIT components=14 buildTools=2 policy=conservative-source-closure\n'
