#!/bin/sh
set -eu

fail() {
    printf 'License inventory verification failed: %s\n' "$1" >&2
    exit 1
}

# Portable exact byte count (BSD and GNU stat disagree on flags).
file_bytes() {
    wc -c <"$1" | tr -d ' '
}

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=${ARKTRACE_VERIFY_LICENSE_ROOT:-$(CDPATH= cd -- "$script_directory/.." && pwd)}
repository_root=$(CDPATH= cd -- "$repository_root" && pwd -P)
inventory="$repository_root/third_party/trace-streamer/license-inventory.json"
source_lock="$repository_root/third_party/trace-streamer/source-lock.json"
windows_inventory="$repository_root/third_party/trace-streamer/windows-license-inventory.json"
windows_lock="$repository_root/third_party/trace-streamer/windows-toolchain-lock.json"
license_root="$repository_root/third_party/trace-streamer"
product_license="$repository_root/LICENSE"
notice="$repository_root/THIRD_PARTY_NOTICES.md"

[ -f "$product_license" ] && [ ! -L "$product_license" ] \
    || fail "ArkTrace product license is missing or a symlink"
[ "$(file_bytes "$product_license")" = 1078 ] \
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
[ "$(file_bytes "$notice")" = 3092 ] \
    || fail "third-party notice byte count drifted"
[ "$(shasum -a 256 "$notice" | awk '{print $1}')" = \
    1a32aec7c425b173ffcda1229d297b8befc5866ca7d7f3ea20c0d1acf435d216 ] \
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
    [ "$(file_bytes "$candidate")" = "$expected_bytes" ] \
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

# Windows additions live in their own inventory and directory so the macOS
# bundles (which copy license-inventory.json and LICENSES/ verbatim) are unchanged.
[ -f "$windows_inventory" ] && [ ! -L "$windows_inventory" ] \
    || fail "Windows license inventory is missing or a symlink"
[ -f "$windows_lock" ] && [ ! -L "$windows_lock" ] \
    || fail "Windows toolchain lock is missing or a symlink"
jq -e '
    def license_fields:
        (.licenseExpression | length > 0)
        and (.licenseFile | test("^LICENSES-windows/[A-Za-z0-9_.+-]+$") and contains("..") | not)
        and (.licenseSHA256 | test("^[0-9a-f]{64}$"))
        and (.licenseByteCount > 0);
    (keys | sort) == ["buildTools","formatVersion","platform","policy","staticRuntime","toolchainLock"]
    and .formatVersion == 1
    and .platform == "windows-x86_64"
    and .toolchainLock == "windows-toolchain-lock.json"
    and (.buildTools | length == 3)
    and ([.buildTools[].name] | sort == ["GN","Ninja","mingw-builds GCC"])
    and ([.buildTools[] |
        (.artifactURL | startswith("https://"))
        and (.artifactSHA256 | test("^[0-9a-f]{64}$"))
        and (.artifactByteCount > 0)
        and license_fields
        and .usage == "build-tool-not-distributed"
    ] | all)
    and (.staticRuntime | length == 3)
    and ([.staticRuntime[].name] | unique | length == 3)
    and ([.staticRuntime[] |
        license_fields
        and .usage == "shipped-static"
        and ((.additionalLicenseFiles // []) | type == "array" and length <= 8)
        and ([.additionalLicenseFiles[]? |
            ((keys | sort) == ["byteCount","path","sha256"])
            and (.path | test("^LICENSES-windows/[A-Za-z0-9_.+-]+$") and contains("..") | not)
            and (.sha256 | test("^[0-9a-f]{64}$"))
            and (.byteCount > 0)
        ] | all)
    ] | all)
' "$windows_inventory" >/dev/null || fail "Windows inventory schema is invalid"

locked_windows_tools=$(jq -cS '{
    "GN": [.tools.gn.url,.tools.gn.sha256,.tools.gn.byteCount],
    "Ninja": [.tools.ninja.url,.tools.ninja.sha256,.tools.ninja.byteCount],
    "mingw-builds GCC": [.compiler.url,.compiler.sha256,.compiler.byteCount]}' "$windows_lock")
inventory_windows_tools=$(jq -cS 'reduce .buildTools[] as $tool ({};
    .[$tool.name] = [$tool.artifactURL,$tool.artifactSHA256,$tool.artifactByteCount])' "$windows_inventory")
[ "$locked_windows_tools" = "$inventory_windows_tools" ] \
    || fail "Windows build-tool inventory differs from Windows toolchain lock"

[ -d "$license_root/LICENSES-windows" ] && [ ! -L "$license_root/LICENSES-windows" ] \
    || fail "Windows license directory is missing or a symlink"
physical_windows_root=$(CDPATH= cd -- "$license_root/LICENSES-windows" && pwd -P) \
    || fail "Windows license directory is inaccessible"
windows_records=$(jq -r '((.buildTools[],.staticRuntime[]) | [.licenseFile,.licenseSHA256,.licenseByteCount] | @tsv),
    (.staticRuntime[].additionalLicenseFiles[]? | [.path,.sha256,.byteCount] | @tsv)' "$windows_inventory")
expected_windows=$(printf '%s\n' "$windows_records" | cut -f1 | sed 's#^LICENSES-windows/##' | LC_ALL=C sort -u)
[ "$(printf '%s\n' "$expected_windows" | wc -l | tr -d ' ')" = 6 ] \
    || fail "Windows inventory does not name exactly 6 unique license files"
actual_windows=$(find "$license_root/LICENSES-windows" -mindepth 1 -maxdepth 1 -exec basename {} \; | LC_ALL=C sort)
[ "$expected_windows" = "$actual_windows" ] \
    || fail "Windows license directory differs from the exact inventory closure"
printf '%s\n' "$windows_records" |
while IFS="$(printf '\t')" read -r relative expected_sha expected_bytes; do
    case "$relative" in
        LICENSES-windows/[A-Za-z0-9_.+-]*) ;;
        *) fail "Windows license path is invalid" ;;
    esac
    candidate="$license_root/$relative"
    [ "$(CDPATH= cd -- "$(dirname -- "$candidate")" && pwd -P)" = "$physical_windows_root" ] \
        || fail "Windows license path escapes its directory"
    [ -f "$candidate" ] && [ ! -L "$candidate" ] \
        || fail "Windows license file is missing or a symlink"
    [ "$(file_bytes "$candidate")" = "$expected_bytes" ] \
        || fail "Windows license byte count drifted"
    [ "$(shasum -a 256 "$candidate" | awk '{print $1}')" = "$expected_sha" ] \
        || fail "Windows license SHA drifted"
done
printf 'Windows license inventory verified: buildTools=3 staticRuntime=3 files=6\n'
