#!/bin/sh
set -eu

fail() {
    printf 'License verifier regression failed: %s\n' "$1" >&2
    exit 1
}

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_directory/.." && pwd)
temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/arktrace-license-test.XXXXXX")
cleanup() { rm -rf -- "$temporary_root"; }
trap cleanup EXIT HUP INT TERM

mkdir -p "$temporary_root/ThirdParty/TraceStreamer"
git -C "$temporary_root" init -q
cp "$repository_root/LICENSE" "$temporary_root/LICENSE"
cp "$repository_root/THIRD_PARTY_NOTICES.md" "$temporary_root/THIRD_PARTY_NOTICES.md"
cp "$repository_root/ThirdParty/TraceStreamer/license-inventory.json" \
    "$temporary_root/ThirdParty/TraceStreamer/license-inventory.json"
cp "$repository_root/ThirdParty/TraceStreamer/source-lock.json" \
    "$temporary_root/ThirdParty/TraceStreamer/source-lock.json"
cp -R "$repository_root/ThirdParty/TraceStreamer/LICENSES" \
    "$temporary_root/ThirdParty/TraceStreamer/LICENSES"
git -C "$temporary_root" add LICENSE THIRD_PARTY_NOTICES.md ThirdParty

verify() {
    ARKTRACE_VERIFY_LICENSE_ROOT="$temporary_root" \
        "$script_directory/verify_licenses.sh" >/dev/null 2>"$temporary_root/error.log"
}

verify || fail "exact copied evidence did not verify"
printf 'undeclared\n' >"$temporary_root/ThirdParty/TraceStreamer/LICENSES/secret.txt"
git -C "$temporary_root" add ThirdParty/TraceStreamer/LICENSES/secret.txt
if verify; then fail "undeclared shipped license file was accepted"; fi
rm -f -- "$temporary_root/ThirdParty/TraceStreamer/LICENSES/secret.txt"

printf 'ArkTrace itself is licensed under Apache-2.0.\n' \
    >"$temporary_root/THIRD_PARTY_NOTICES.md"
if verify; then fail "incorrect ArkTrace license notice was accepted"; fi
cp "$repository_root/THIRD_PARTY_NOTICES.md" "$temporary_root/THIRD_PARTY_NOTICES.md"

printf '\nmutation\n' >>"$temporary_root/LICENSE"
if verify; then fail "mutated ArkTrace MIT license was accepted"; fi
cp "$repository_root/LICENSE" "$temporary_root/LICENSE"

cp "$repository_root/ThirdParty/TraceStreamer/source-lock.json" \
    "$temporary_root/ThirdParty/TraceStreamer/source-lock.json"
jq '(.components[] | select(.name == "libbpf") | .additionalLicenseFiles[0].path) = "../../LICENSE"' \
    "$repository_root/ThirdParty/TraceStreamer/license-inventory.json" \
    >"$temporary_root/ThirdParty/TraceStreamer/license-inventory.json"
if verify; then fail "traversing additional license path was accepted"; fi

jq '(.components[] | select(.name == "libbpf") | .additionalLicenseFiles[0]) += {unexpected:true}' \
    "$repository_root/ThirdParty/TraceStreamer/license-inventory.json" \
    >"$temporary_root/ThirdParty/TraceStreamer/license-inventory.json"
if verify; then fail "additional license entry with extra keys was accepted"; fi

cp "$repository_root/ThirdParty/TraceStreamer/license-inventory.json" \
    "$temporary_root/ThirdParty/TraceStreamer/license-inventory.json"
mv "$temporary_root/ThirdParty/TraceStreamer/LICENSES" \
    "$temporary_root/ThirdParty/TraceStreamer/LICENSES-real"
ln -s "$temporary_root/ThirdParty/TraceStreamer/LICENSES-real" \
    "$temporary_root/ThirdParty/TraceStreamer/LICENSES"
if verify; then fail "symlinked license directory was accepted"; fi
rm "$temporary_root/ThirdParty/TraceStreamer/LICENSES"
mv "$temporary_root/ThirdParty/TraceStreamer/LICENSES-real" \
    "$temporary_root/ThirdParty/TraceStreamer/LICENSES"

jq '.upstream.revision = "0000000000000000000000000000000000000000"' \
    "$repository_root/ThirdParty/TraceStreamer/source-lock.json" \
    >"$temporary_root/source-lock-mutated.json"
mv "$temporary_root/source-lock-mutated.json" \
    "$temporary_root/ThirdParty/TraceStreamer/source-lock.json"
if verify; then fail "TraceStreamer notice/source-lock provenance drift was accepted"; fi

[ "$(stat -f '%z' "$temporary_root/error.log")" -le 1024 ] \
    || fail "negative diagnostic exceeded its byte bound"
printf 'License verifier regression passed: product, notice, and provenance fail closed\n'
