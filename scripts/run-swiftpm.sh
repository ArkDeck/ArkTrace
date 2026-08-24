#!/bin/sh
# Run ArkTrace SwiftPM commands through one stable, cache-owned source path.
#
# SwiftPM keys incremental state by absolute source paths and file identity.
# A build directory inside each checkout therefore makes every new worktree
# cold. This runner checksum-syncs the Git-visible tree into one stable mirror
# and serializes the mirror update plus the complete SwiftPM invocation.

set -eu

lock_held=0
if [ "${1:-}" = '--arktrace-internal-lock-held' ]; then
    lock_held=1
    shift
fi

usage() {
    cat <<'EOF'
usage: sh scripts/run-swiftpm.sh {build|test} [swiftpm options]

Default cache root:
  ~/Library/Caches/com.arkdeck.ArkTrace/SwiftPM/Shared

Environment overrides:
  ARKTRACE_SWIFTPM_CACHE_ROOT  Absolute cache root owned by this runner.
  ARKTRACE_SWIFT_EXECUTABLE    Absolute Swift executable path.

The runner owns --package-path, --scratch-path and --cache-path. Its stable
source mirror contains tracked and non-ignored untracked files. A local pinned
TraceStreamer binary is mirrored only after its SHA-256 matches the manifest.
EOF
}

fail() {
    printf 'run-swiftpm: ERROR: %s\n' "$1" >&2
    exit "${2:-1}"
}

case ${1:-} in
    -h|--help)
        usage
        exit 0
        ;;
    build|test)
        swift_command=$1
        shift
        ;;
    '')
        usage >&2
        exit 64
        ;;
    *)
        fail "unsupported command '$1' (expected build or test)" 64
        ;;
esac

for argument in "$@"; do
    case $argument in
        --package-path|--package-path=*|--scratch-path|--scratch-path=*|--cache-path|--cache-path=*)
            fail "'$argument' is managed by this runner" 64
            ;;
    esac
done

script_directory=$(CDPATH= cd -P -- "$(dirname -- "$0")" && pwd)
script_path=$script_directory/$(basename -- "$0")
repository_root=$(CDPATH= cd -P -- "$script_directory/.." && pwd)

if [ -n "${ARKTRACE_SWIFTPM_CACHE_ROOT:-}" ]; then
    cache_root=$ARKTRACE_SWIFTPM_CACHE_ROOT
elif [ -n "${XDG_CACHE_HOME:-}" ]; then
    cache_root=$XDG_CACHE_HOME/com.arkdeck.ArkTrace/SwiftPM/Shared
elif [ -n "${HOME:-}" ]; then
    cache_root=$HOME/Library/Caches/com.arkdeck.ArkTrace/SwiftPM/Shared
else
    fail 'HOME and XDG_CACHE_HOME are unset; set ARKTRACE_SWIFTPM_CACHE_ROOT' 78
fi

case $cache_root in
    /*) ;;
    *) fail "cache root must be absolute: $cache_root" 64 ;;
esac
case $cache_root/ in
    "$repository_root"/*) fail "cache root must be outside the worktree: $cache_root" 64 ;;
esac

swift_executable=${ARKTRACE_SWIFT_EXECUTABLE:-$(command -v swift || true)}
[ -n "$swift_executable" ] || fail 'swift executable not found' 69
case $swift_executable in
    /*) ;;
    *) fail "Swift executable must be absolute: $swift_executable" 64 ;;
esac
[ -x "$swift_executable" ] || fail "Swift executable is not executable: $swift_executable" 69

umask 077
cache_root_created=0
if [ ! -d "$cache_root" ]; then
    mkdir -p "$cache_root"
    cache_root_created=1
fi
cache_root=$(CDPATH= cd -P -- "$cache_root" && pwd)
case $cache_root/ in
    "$repository_root"/*)
        if [ "$cache_root_created" -eq 1 ]; then
            rmdir "$cache_root" 2>/dev/null || true
        fi
        fail "cache root must be outside the worktree: $cache_root" 64
        ;;
esac

workspace_path=$cache_root/workspace
scratch_path=$cache_root/build
dependency_cache=$cache_root/dependencies
module_cache=$cache_root/ModuleCache
lock_path=$cache_root/build.lock
ignored_paths=$cache_root/ignored-paths
untracked_paths=$cache_root/untracked-paths
source_state=$cache_root/source-state
source_state_input=$cache_root/source-state-input
source_state_candidate=$cache_root/source-state.next
mkdir -p "$scratch_path" "$dependency_cache" "$module_cache"

if [ "$lock_held" -eq 0 ]; then
    exec /usr/bin/lockf -k "$lock_path" \
        /bin/sh "$script_path" --arktrace-internal-lock-held "$swift_command" "$@"
fi

workspace_ready=false
if [ -L "$workspace_path" ]; then
    rm "$workspace_path"
elif [ -e "$workspace_path" ] && [ ! -d "$workspace_path" ]; then
    fail "cache workspace exists and is not a directory: $workspace_path" 73
elif [ -f "$workspace_path/Package.swift" ]; then
    workspace_ready=true
fi
mkdir -p "$workspace_path"

# A clean worktree is identified by HEAD without walking every file. Dirty and
# untracked content is hashed so repeated invocations can skip rsync entirely;
# this keeps a no-change run fast even on a cloud-backed checkout.
: > "$source_state_input"
if head_revision=$(git -C "$repository_root" rev-parse --verify HEAD 2>/dev/null); then
    printf 'HEAD %s\n' "$head_revision" >> "$source_state_input"
    git -C "$repository_root" diff --no-ext-diff --binary HEAD -- \
        >> "$source_state_input"
else
    printf 'HEAD unborn\n' >> "$source_state_input"
    git -C "$repository_root" diff --no-ext-diff --binary --cached -- \
        >> "$source_state_input"
    git -C "$repository_root" diff --no-ext-diff --binary -- \
        >> "$source_state_input"
fi
git -C "$repository_root" ls-files --others --exclude-standard -z > "$untracked_paths"
if [ -s "$untracked_paths" ]; then
    cat "$untracked_paths" >> "$source_state_input"
    /usr/bin/xargs -0 /usr/bin/printf './%s\0' < "$untracked_paths" \
        > "$untracked_paths.anchored"
    (CDPATH= cd -P -- "$repository_root" && \
        /usr/bin/xargs -0 shasum -a 256 < "$untracked_paths.anchored") \
        >> "$source_state_input"
fi
shasum -a 256 "$source_state_input" | awk '{print $1}' > "$source_state_candidate"

if [ "$workspace_ready" = false ] || ! cmp -s "$source_state" "$source_state_candidate"; then
    # --checksum + --no-times preserves inode/mtime for unchanged mirror files.
    git -C "$repository_root" ls-files --others --ignored --exclude-standard --directory -z \
        > "$ignored_paths"
    if [ -s "$ignored_paths" ]; then
        /usr/bin/xargs -0 /usr/bin/printf '/%s\0' < "$ignored_paths" \
            > "$ignored_paths.anchored"
        mv -f "$ignored_paths.anchored" "$ignored_paths"
    fi
    /usr/bin/rsync -ac --no-times --delete --delete-excluded --from0 \
        --exclude=.git --exclude-from="$ignored_paths" \
        "$repository_root/" "$workspace_path/"
    mv -f "$source_state_candidate" "$source_state"
else
    rm -f "$source_state_candidate"
fi

# The parser is intentionally gitignored. Never let stale or unverified bytes
# survive in the shared mirror, but retain the full local test/app behavior on
# a machine that owns the approved binary.
source_parser=$repository_root/ThirdParty/TraceStreamer/macx/trace_streamer
mirror_parser=$workspace_path/ThirdParty/TraceStreamer/macx/trace_streamer
if [ -f "$source_parser" ]; then
    command -v jq >/dev/null 2>&1 || fail 'jq is required to verify TraceStreamer' 69
    expected=$(jq -er '.binarySHA256' "$repository_root/ThirdParty/TraceStreamer/macx/manifest.json")
    actual=$(shasum -a 256 "$source_parser" | awk '{print $1}')
    [ "$actual" = "$expected" ] || fail 'TraceStreamer differs from the pinned manifest' 65
    mkdir -p "$(dirname -- "$mirror_parser")"
    /usr/bin/rsync -ac --no-times "$source_parser" "$mirror_parser"
else
    rm -f "$mirror_parser"
fi

printf 'ArkTrace SwiftPM cache: %s\n' "$cache_root" >&2
printf 'ArkTrace SwiftPM worktree: %s\n' "$repository_root" >&2

exec env \
    CLANG_MODULE_CACHE_PATH="$module_cache" \
    SWIFTPM_MODULECACHE_OVERRIDE="$module_cache" \
    "$swift_executable" "$swift_command" \
    --package-path "$workspace_path" \
    --scratch-path "$scratch_path" \
    --cache-path "$dependency_cache" \
    "$@"
