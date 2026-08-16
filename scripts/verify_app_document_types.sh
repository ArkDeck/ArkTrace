#!/bin/sh
# Verifies that a built ArkTrace.app registers exactly the document types the
# tracked Info.plist declares.
#
# The reviewed root is ArkTraceAppDistribution.supportedTraceExtensions;
# AppDistributionTests binds that constant to Apps/ArkTraceApp/Info.plist, and
# this script binds that plist to the built bundle. Keeping the comparison in
# one place stops the expected list from being copied into each caller, which
# is how a positional assertion in the Phase 3 batch gate came to report a
# dropped type after an extension was merely inserted earlier in the array.
#
# Usage: verify_app_document_types.sh <path-to-ArkTrace.app>
set -eu

fail() {
    printf 'App document type verification failed: %s\n' "$1" >&2
    exit 1
}

test $# -eq 1 || fail "usage: verify_app_document_types.sh <ArkTrace.app>"
candidate_app=$1
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source_plist="$repo_root/Apps/ArkTraceApp/Info.plist"

test -f "$source_plist" || fail "tracked Info.plist is missing"
test -f "$candidate_app/Contents/Info.plist" \
    || fail "candidate bundle has no Info.plist"

extensions_of() {
    plutil -extract CFBundleDocumentTypes.0.CFBundleTypeExtensions json -o - "$1" \
        2>/dev/null
}

declared=$(extensions_of "$source_plist") \
    || fail "tracked Info.plist document types are unreadable"
test -n "$declared" || fail "tracked Info.plist declares no document types"

built=$(extensions_of "$candidate_app/Contents/Info.plist") \
    || fail "candidate bundle document types are unreadable"

test "$built" = "$declared" \
    || fail "candidate registers $built but the tracked Info.plist declares $declared"

printf 'App document types verified: %s\n' "$declared"
