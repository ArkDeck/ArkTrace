#!/bin/sh
# Shared fail-closed filesystem and diagnostic helpers for Phase 3 tooling.
# The sourcing script must define fail().

arktrace_validate_reviewed_roots() {
    arktrace_repository_root=$1
    [ -d "$arktrace_repository_root" ] && [ ! -L "$arktrace_repository_root" ] \
        || fail "repository root is not a physical directory"
    arktrace_repository_root=$(CDPATH= cd -- "$arktrace_repository_root" && pwd -P) \
        || fail "repository root is inaccessible"

    arktrace_build_root="$arktrace_repository_root/.build"
    [ ! -L "$arktrace_build_root" ] \
        || fail "repository build root must not be a symlink"
    if [ -e "$arktrace_build_root" ]; then
        [ -d "$arktrace_build_root" ] && [ ! -L "$arktrace_build_root" ] \
            || fail "repository build root is not a physical directory"
        ARKTRACE_REVIEWED_BUILD_ROOT=$(CDPATH= cd -- "$arktrace_build_root" && pwd -P) \
            || fail "repository build root is inaccessible"
        [ "$ARKTRACE_REVIEWED_BUILD_ROOT" = "$arktrace_build_root" ] \
            || fail "repository build root escaped its physical location"
    else
        ARKTRACE_REVIEWED_BUILD_ROOT=$arktrace_build_root
    fi

    arktrace_temp_input=$(/usr/bin/getconf DARWIN_USER_TEMP_DIR 2>/dev/null || true)
    if [ -z "$arktrace_temp_input" ]; then arktrace_temp_input=/private/tmp; fi
    [ -d "$arktrace_temp_input" ] || fail "system temporary root is unavailable"
    ARKTRACE_REVIEWED_TEMP_ROOT=$(CDPATH= cd -- "$arktrace_temp_input" && pwd -P) \
        || fail "system temporary root is inaccessible"
    case "$ARKTRACE_REVIEWED_TEMP_ROOT" in
        /|"$HOME"|"$arktrace_repository_root"|"$(dirname -- "$arktrace_repository_root")")
            fail "system temporary root overlaps user or repository data" ;;
    esac
}

arktrace_create_reviewed_build_root() {
    [ ! -L "$ARKTRACE_REVIEWED_BUILD_ROOT" ] \
        || fail "repository build root must not be a symlink"
    if [ ! -e "$ARKTRACE_REVIEWED_BUILD_ROOT" ]; then
        mkdir "$ARKTRACE_REVIEWED_BUILD_ROOT" \
            || fail "repository build root could not be created"
    fi
    [ -d "$ARKTRACE_REVIEWED_BUILD_ROOT" ] \
        && [ ! -L "$ARKTRACE_REVIEWED_BUILD_ROOT" ] \
        || fail "repository build root is not a physical directory"
}

arktrace_prepare_reviewed_roots() {
    arktrace_validate_reviewed_roots "$1"
    arktrace_create_reviewed_build_root
}

arktrace_validate_owned_directory_request() {
    arktrace_requested=$1
    arktrace_kind=$2
    case "$arktrace_requested" in /*) ;; *) fail "$arktrace_kind path must be absolute" ;; esac
    case "/$arktrace_requested/" in */../*|*/./*) fail "$arktrace_kind path is not normalized" ;; esac
    arktrace_requested=$(printf '%s' "$arktrace_requested" | sed 's#//*#/#g')
    arktrace_requested_parent=$(dirname -- "$arktrace_requested")
    if [ -d "$arktrace_requested_parent" ] && [ ! -L "$arktrace_requested_parent" ]; then
        arktrace_requested_parent=$(CDPATH= cd -- "$arktrace_requested_parent" && pwd -P) \
            || fail "$arktrace_kind parent is inaccessible"
        arktrace_requested="$arktrace_requested_parent/$(basename -- "$arktrace_requested")"
    fi
    arktrace_root=$(arktrace_root_for_path "$arktrace_requested") \
        || fail "$arktrace_kind path is outside reviewed build/temp roots"
    arktrace_assert_physical_directory_chain "$arktrace_root" "$(dirname -- "$arktrace_requested")" \
        || fail "$arktrace_kind parent chain is not physical"
    [ ! -L "$arktrace_requested" ] || fail "$arktrace_kind path must not be a symlink"
}

arktrace_root_for_path() {
    arktrace_candidate=$1
    case "$arktrace_candidate/" in
        "$ARKTRACE_REVIEWED_BUILD_ROOT"/*)
            printf '%s\n' "$ARKTRACE_REVIEWED_BUILD_ROOT" ;;
        "$ARKTRACE_REVIEWED_TEMP_ROOT"/*)
            printf '%s\n' "$ARKTRACE_REVIEWED_TEMP_ROOT" ;;
        *) return 1 ;;
    esac
}

arktrace_assert_physical_directory_chain() {
    arktrace_root=$1
    arktrace_path=$2
    [ "$arktrace_path" != "$arktrace_root" ] || return 0
    case "$arktrace_path/" in "$arktrace_root"/*) ;; *) return 1 ;; esac
    arktrace_relative=${arktrace_path#"$arktrace_root"/}
    arktrace_probe=$arktrace_root
    arktrace_old_ifs=$IFS
    IFS=/
    for arktrace_component in $arktrace_relative; do
        IFS=$arktrace_old_ifs
        case "$arktrace_component" in ""|.|..) return 1 ;; esac
        arktrace_probe="$arktrace_probe/$arktrace_component"
        [ ! -L "$arktrace_probe" ] || return 1
        if [ -e "$arktrace_probe" ]; then [ -d "$arktrace_probe" ] || return 1; fi
        IFS=/
    done
    IFS=$arktrace_old_ifs
}

arktrace_secure_owned_directory() {
    arktrace_requested=$1
    arktrace_marker=$2
    arktrace_kind=$3
    case "$arktrace_requested" in /*) arktrace_candidate=$arktrace_requested ;; *) return 1 ;; esac
    case "/$arktrace_candidate/" in */../*|*/./*) fail "$arktrace_kind path is not normalized" ;; esac
    arktrace_candidate=$(printf '%s' "$arktrace_candidate" | sed 's#//*#/#g')
    arktrace_parent_input=$(dirname -- "$arktrace_candidate")
    [ -d "$arktrace_parent_input" ] && [ ! -L "$arktrace_parent_input" ] \
        || fail "$arktrace_kind parent must already be a physical directory"
    arktrace_parent=$(CDPATH= cd -- "$arktrace_parent_input" && pwd -P) \
        || fail "$arktrace_kind parent is inaccessible"
    arktrace_candidate="$arktrace_parent/$(basename -- "$arktrace_candidate")"
    arktrace_root=$(arktrace_root_for_path "$arktrace_candidate") \
        || fail "$arktrace_kind path is outside reviewed build/temp roots"
    arktrace_assert_physical_directory_chain "$arktrace_root" "$arktrace_parent" \
        || fail "$arktrace_kind parent chain is not physical"
    [ ! -L "$arktrace_candidate" ] || fail "$arktrace_kind path must not be a symlink"
    if [ ! -e "$arktrace_candidate" ]; then
        mkdir "$arktrace_candidate" || fail "$arktrace_kind directory could not be created"
    fi
    [ -d "$arktrace_candidate" ] && [ ! -L "$arktrace_candidate" ] \
        || fail "$arktrace_kind path is not a physical directory"
    arktrace_owner="$arktrace_candidate/$arktrace_marker"
    if [ -e "$arktrace_owner" ] || [ -L "$arktrace_owner" ]; then
        [ -f "$arktrace_owner" ] && [ ! -L "$arktrace_owner" ] \
            && [ "$(cat "$arktrace_owner")" = "ArkTrace-owned-v1" ] \
            || fail "$arktrace_kind owner marker is invalid"
    else
        [ -z "$(find "$arktrace_candidate" -mindepth 1 -maxdepth 1 -print -quit)" ] \
            || fail "$arktrace_kind directory is existing and unowned"
        arktrace_marker_tmp=$(mktemp "$arktrace_candidate/.owner.XXXXXX") \
            || fail "$arktrace_kind owner marker could not be created"
        printf 'ArkTrace-owned-v1\n' >"$arktrace_marker_tmp"
        chmod 600 "$arktrace_marker_tmp"
        mv "$arktrace_marker_tmp" "$arktrace_owner" \
            || fail "$arktrace_kind owner marker could not be installed"
    fi
    printf '%s\n' "$arktrace_candidate"
}

arktrace_assert_owned_child() {
    arktrace_root=$1
    arktrace_child=$2
    arktrace_kind=$3
    arktrace_assert_physical_directory_chain "$arktrace_root" "$arktrace_child" \
        || fail "$arktrace_kind path contains a symlink or escapes its owner"
    if [ -e "$arktrace_child" ]; then
        [ -d "$arktrace_child" ] && [ ! -L "$arktrace_child" ] \
            || fail "$arktrace_kind path is not a physical directory"
    fi
    if [ -e "$arktrace_child/.git" ] || [ -L "$arktrace_child/.git" ]; then
        [ ! -L "$arktrace_child/.git" ] \
            || fail "$arktrace_kind Git metadata must not be a symlink"
    fi
}

arktrace_require_absent_leaf() {
    arktrace_leaf=$1
    arktrace_kind=$2
    if [ -e "$arktrace_leaf" ] || [ -L "$arktrace_leaf" ]; then
        fail "$arktrace_kind path already exists or is a symlink"
    fi
}

arktrace_assert_physical_file_within() {
    arktrace_file_root=$1
    arktrace_file_path=$2
    arktrace_file_kind=$3
    [ -d "$arktrace_file_root" ] && [ ! -L "$arktrace_file_root" ] \
        || fail "$arktrace_file_kind root is not physical"
    arktrace_physical_root=$(CDPATH= cd -- "$arktrace_file_root" && pwd -P) \
        || fail "$arktrace_file_kind root is inaccessible"
    case "$arktrace_file_path" in
        "$arktrace_physical_root"/*) ;;
        *) fail "$arktrace_file_kind path escaped its root" ;;
    esac
    arktrace_file_parent=$(dirname -- "$arktrace_file_path")
    arktrace_assert_physical_directory_chain \
        "$arktrace_physical_root" "$arktrace_file_parent" \
        || fail "$arktrace_file_kind parent chain is not physical"
    [ -f "$arktrace_file_path" ] && [ ! -L "$arktrace_file_path" ] \
        || fail "$arktrace_file_kind is not a physical regular file"
}

arktrace_is_fully_allocated_regular_file() {
    arktrace_allocation_path=$1
    [ -f "$arktrace_allocation_path" ] && [ ! -L "$arktrace_allocation_path" ] \
        || return 1
    arktrace_logical_bytes=$(stat -f '%z' "$arktrace_allocation_path") \
        || return 1
    arktrace_allocated_blocks=$(stat -f '%b' "$arktrace_allocation_path") \
        || return 1
    case "$arktrace_logical_bytes:$arktrace_allocated_blocks" in
        *[!0-9:]*|:*|*:) return 1 ;;
    esac
    [ $((arktrace_allocated_blocks * 512)) -ge "$arktrace_logical_bytes" ]
}

arktrace_bounded_failure_summary() {
    # External tools can print arbitrary Unicode paths, credentials, SQL, or
    # unbounded diagnostics. Keep their private log for the transaction only;
    # the public boundary emits no caller-controlled bytes.
    : "$1"
    printf 'external tool diagnostics withheld\n' >&2
}

arktrace_is_reviewed_trace_streamer_tail_failure() {
    arktrace_log=$1
    arktrace_filtered=$(mktemp "$ARKTRACE_REVIEWED_TEMP_ROOT/arktrace-build-tail.XXXXXX") \
        || return 1
    grep -Fvx 'Successfully found the configuration!' "$arktrace_log" \
        | grep -Fvx './build_operator.sh: line 74: ./mac_depend.sh: Permission denied' \
        >"$arktrace_filtered" || true
    # Build logs include compiler-rendered source lines and string literals such
    # as "read ... error" and "assert failed".  Only treat anchored tool and
    # compiler diagnostic records as an earlier failure; otherwise a successful
    # link followed by the one reviewed mac_depend tail is rejected by its own
    # source text.
    if grep -Ei '^FAILED:|^ninja: build stopped|^(error|fatal|failed|failure):|^(clang|clang\+\+|cc|c\+\+|ld): (error|fatal error):|^[^[:space:]|][^|]*:[0-9]+:[0-9]+: (error|fatal error):|^Undefined symbols|^duplicate symbol|^[^|]*: (Permission denied|No such file or directory)$|^[0-9]+ errors? generated\.$' \
        "$arktrace_filtered" >/dev/null 2>&1
    then
        rm -f -- "$arktrace_filtered"
        return 1
    fi
    rm -f -- "$arktrace_filtered"
    arktrace_tail=$(tail -2 "$arktrace_log")
    [ "$arktrace_tail" = "Successfully found the configuration!
./build_operator.sh: line 74: ./mac_depend.sh: Permission denied" ]
}
