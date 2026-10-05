#!/bin/sh
# Current native App distribution helpers; caller sources phase3_shell_safety.sh first.

arktrace_copy_visible_source() {
    arktrace_source_root=$1
    arktrace_source_copy=$2
    arktrace_source_list=$3
    arktrace_require_absent_leaf "$arktrace_source_copy" "native source snapshot"
    git -C "$arktrace_source_root" ls-files --cached --others --exclude-standard -z \
        >"$arktrace_source_list" || fail "native source inventory failed"
    mkdir "$arktrace_source_copy" || fail "native source snapshot could not be created"
    /usr/bin/rsync -ac --from0 --files-from="$arktrace_source_list" \
        "$arktrace_source_root/" "$arktrace_source_copy/" \
        || fail "native source snapshot failed"
}

# The current App always owns the Rust runtime. A parser-only bundle cannot
# pass a new release gate, even when its outer signature is otherwise valid.
arktrace_verify_native_app_closure() {
    arktrace_native_app=$1
    arktrace_native_label=$2
    arktrace_native_manifest="$arktrace_native_app/Contents/Resources/ArkTraceRuntime/manifest.json"
    arktrace_native_record="$arktrace_native_app/Contents/Resources/ArkTraceRuntime/distribution-signing.json"
    arktrace_native_helper="$arktrace_native_app/Contents/Helpers/arktrace-host-process"
    for arktrace_native_file in "$arktrace_native_manifest" "$arktrace_native_record" "$arktrace_native_helper"; do
        arktrace_assert_physical_file_within "$arktrace_native_app" "$arktrace_native_file" "$arktrace_native_label native resource"
    done
    for arktrace_native_json in "$arktrace_native_manifest" "$arktrace_native_record"; do
        [ "$(stat -f '%z' "$arktrace_native_json")" -le 65536 ] \
            || fail "$arktrace_native_label native manifest exceeds its byte bound"
    done
    arktrace_native_sha=$(shasum -a 256 "$arktrace_native_helper" | awk '{print $1}')
    arktrace_native_contract=$(cat "$repository_root/contracts/ffi-v1.sha256")
    jq -e --arg sha "$arktrace_native_sha" --arg contract "$arktrace_native_contract" --arg team "$team" '
        .formatVersion == 1
        and ((keys | sort) == ["contractSHA256","formatVersion","helperSHA256","publisher"])
        and .helperSHA256 == $sha and .contractSHA256 == $contract
        and .publisher == {teamIdentifier:$team,helperCodeIdentifier:"com.arktrace.ArkTrace.host-process",parserCodeIdentifier:"com.arktrace.ArkTrace.trace-streamer"}
    ' "$arktrace_native_manifest" >/dev/null || fail "$arktrace_native_label native runtime identity drifted"
    jq -e --arg sha "$arktrace_native_sha" --arg contract "$arktrace_native_contract" \
        --arg team "$team" --arg certificate "$certificate_sha1" '
        .formatVersion == 1
        and ((keys | sort) == ["contractSHA256","formatVersion","publisher","signedHelperSHA256","signingCertificateSHA1","signingPolicy","unsignedHelperSHA256"])
        and .contractSHA256 == $contract and .signedHelperSHA256 == $sha
        and (.unsignedHelperSHA256 | type == "string" and test("^[0-9a-f]{64}$"))
        and .publisher == {teamIdentifier:$team,helperCodeIdentifier:"com.arktrace.ArkTrace.host-process",parserCodeIdentifier:"com.arktrace.ArkTrace.trace-streamer"}
        and .signingCertificateSHA1 == $certificate
        and .signingPolicy == "developer-id-runtime-timestamp"
    ' "$arktrace_native_record" >/dev/null || fail "$arktrace_native_label native signing provenance drifted"
    for arktrace_native_tool in arktrace-host-process trace_streamer; do
        arktrace_native_path="$arktrace_native_app/Contents/Helpers/$arktrace_native_tool"
        arktrace_assert_physical_file_within "$arktrace_native_app" "$arktrace_native_path" "$arktrace_native_label native tool"
        [ "$(stat -f '%Lp' "$arktrace_native_path")" = 555 ] \
            && [ "$(stat -f '%l' "$arktrace_native_path")" = 1 ] \
            || fail "$arktrace_native_label native tool must be read-only and unlinked"
        run_external "$arktrace_native_label native signature verification failed" \
            codesign --verify --strict "$arktrace_native_path"
        arktrace_native_detail="$temporary_root/native-$external_log_index.txt"
        codesign -dv --verbose=4 "$arktrace_native_path" 2>"$arktrace_native_detail" \
            || fail "$arktrace_native_label native signature details are unavailable"
        case "$arktrace_native_tool" in
            arktrace-host-process) arktrace_native_code_id=com.arktrace.ArkTrace.host-process ;;
            trace_streamer) arktrace_native_code_id=com.arktrace.ArkTrace.trace-streamer ;;
        esac
        grep -Fx "Identifier=$arktrace_native_code_id" "$arktrace_native_detail" >/dev/null \
            && grep -Fx "TeamIdentifier=$team" "$arktrace_native_detail" >/dev/null \
            && grep -Fx "Authority=$identity" "$arktrace_native_detail" >/dev/null \
            && grep -E '^CodeDirectory .* flags=.*\(runtime\)' "$arktrace_native_detail" >/dev/null \
            && grep -E '^Timestamp=' "$arktrace_native_detail" >/dev/null \
            || fail "$arktrace_native_label native publisher or runtime drifted"
        [ "$(signature_certificate_sha1 "$arktrace_native_path" "native-$external_log_index")" = "$certificate_sha1" ] \
            || fail "$arktrace_native_label native signing certificate drifted"
    done
}
