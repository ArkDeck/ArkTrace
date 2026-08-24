#!/bin/sh
# Build ArkTrace through one stable, cache-owned source path.
#
# Xcode and Swift key incremental state by absolute paths. This runner mirrors
# source bytes into one path shared by all worktrees and owns every expensive
# cache used by the app build.

set -eu

lock_held=0
if [ "${1:-}" = '--arktrace-internal-lock-held' ]; then
    lock_held=1
    shift
fi

usage() {
    cat <<'EOF'
usage: sh scripts/run-xcodebuild.sh

Default cache root:
  ~/Library/Caches/com.arkdeck.ArkTrace/Xcode/Shared

Environment overrides:
  ARKTRACE_XCODE_CACHE_ROOT       Absolute cache root owned by this runner.
  ARKTRACE_XCODE_OUTPUT_ROOT      Absolute product output root.
  ARKTRACE_XCODEBUILD_EXECUTABLE  Absolute xcodebuild executable path.

The runner owns the project, target, configuration, object/package/module
caches and build action. It requires the locally pinned TraceStreamer binary
and verifies its SHA-256 before copying it to the stable source mirror.
EOF
}

fail() {
    printf 'run-xcodebuild: ERROR: %s\n' "$1" >&2
    exit "${2:-1}"
}

case ${1:-} in
    -h|--help)
        usage
        exit 0
        ;;
    '') ;;
    *) fail "unexpected argument '$1'" 64 ;;
esac

script_directory=$(CDPATH= cd -P -- "$(dirname -- "$0")" && pwd)
script_path=$script_directory/$(basename -- "$0")
repository_root=$(CDPATH= cd -P -- "$script_directory/.." && pwd)

if [ -n "${ARKTRACE_XCODE_CACHE_ROOT:-}" ]; then
    cache_root=$ARKTRACE_XCODE_CACHE_ROOT
elif [ -n "${XDG_CACHE_HOME:-}" ]; then
    cache_root=$XDG_CACHE_HOME/com.arkdeck.ArkTrace/Xcode/Shared
elif [ -n "${HOME:-}" ]; then
    cache_root=$HOME/Library/Caches/com.arkdeck.ArkTrace/Xcode/Shared
else
    fail 'HOME and XDG_CACHE_HOME are unset; set ARKTRACE_XCODE_CACHE_ROOT' 78
fi

case $cache_root in
    /*) ;;
    *) fail "cache root must be absolute: $cache_root" 64 ;;
esac
case $cache_root/ in
    "$repository_root"/*) fail "cache root must be outside the worktree: $cache_root" 64 ;;
esac

xcodebuild_executable=${ARKTRACE_XCODEBUILD_EXECUTABLE:-$(command -v xcodebuild || true)}
[ -n "$xcodebuild_executable" ] || fail 'xcodebuild executable not found' 69
case $xcodebuild_executable in
    /*) ;;
    *) fail "xcodebuild executable must be absolute: $xcodebuild_executable" 64 ;;
esac
[ -x "$xcodebuild_executable" ] || fail "xcodebuild executable is not executable: $xcodebuild_executable" 69

if [ -n "${ARKTRACE_XCODE_OUTPUT_ROOT:-}" ]; then
    output_root=$ARKTRACE_XCODE_OUTPUT_ROOT
else
    output_root=$cache_root/Products
fi
case $output_root in
    /*) ;;
    *) fail "output root must be absolute: $output_root" 64 ;;
esac
case $output_root/ in
    "$repository_root"/*) fail "output root must be outside the worktree: $output_root" 64 ;;
esac

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
object_root=$cache_root/Objects
source_packages=$cache_root/SourcePackages
package_cache=$cache_root/PackageCache
module_cache=$cache_root/ModuleCache
precompiled_headers=$cache_root/PrecompiledHeaders
lock_path=$cache_root/build.lock
ignored_paths=$cache_root/ignored-paths
untracked_paths=$cache_root/untracked-paths
source_state=$cache_root/source-state
source_state_input=$cache_root/source-state-input
source_state_candidate=$cache_root/source-state.next
output_root_created=0
if [ ! -d "$output_root" ]; then
    mkdir -p "$output_root"
    output_root_created=1
fi
output_root=$(CDPATH= cd -P -- "$output_root" && pwd)
case $output_root/ in
    "$repository_root"/*)
        if [ "$output_root_created" -eq 1 ]; then
            rmdir "$output_root" 2>/dev/null || true
        fi
        fail "output root must be outside the worktree: $output_root" 64
        ;;
esac
mkdir -p "$object_root" "$source_packages" "$package_cache" "$module_cache" \
    "$precompiled_headers"

if [ "$lock_held" -eq 0 ]; then
    exec /usr/bin/lockf -k "$lock_path" \
        /bin/sh "$script_path" --arktrace-internal-lock-held
fi

workspace_ready=false
if [ -L "$workspace_path" ]; then
    rm "$workspace_path"
elif [ -e "$workspace_path" ] && [ ! -d "$workspace_path" ]; then
    fail "cache workspace exists and is not a directory: $workspace_path" 73
elif [ -f "$workspace_path/ArkTrace.xcodeproj/project.pbxproj" ]; then
    workspace_ready=true
fi
mkdir -p "$workspace_path"

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

source_parser=$repository_root/ThirdParty/TraceStreamer/macx/trace_streamer
mirror_parser=$workspace_path/ThirdParty/TraceStreamer/macx/trace_streamer
[ -f "$source_parser" ] || {
    rm -f "$mirror_parser"
    fail 'pinned TraceStreamer is unavailable; build or restore it before the app target' 66
}
command -v jq >/dev/null 2>&1 || fail 'jq is required to verify TraceStreamer' 69
expected=$(jq -er '.binarySHA256' "$repository_root/ThirdParty/TraceStreamer/macx/manifest.json")
actual=$(shasum -a 256 "$source_parser" | awk '{print $1}')
[ "$actual" = "$expected" ] || fail 'TraceStreamer differs from the pinned manifest' 65
mkdir -p "$(dirname -- "$mirror_parser")"
/usr/bin/rsync -ac --no-times "$source_parser" "$mirror_parser"

printf 'ArkTrace Xcode cache: %s\n' "$cache_root" >&2
printf 'ArkTrace Xcode worktree: %s\n' "$repository_root" >&2

exec env \
    CLANG_MODULE_CACHE_PATH="$module_cache" \
    SWIFTPM_MODULECACHE_OVERRIDE="$module_cache" \
    "$xcodebuild_executable" \
    -project "$workspace_path/ArkTrace.xcodeproj" \
    -target ArkTraceApp \
    -configuration Debug \
    -clonedSourcePackagesDirPath "$source_packages" \
    -packageCachePath "$package_cache" \
    -showBuildTimingSummary \
    -hideShellScriptEnvironment \
    SYMROOT="$output_root" \
    OBJROOT="$object_root" \
    SHARED_PRECOMPS_DIR="$precompiled_headers" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGN_IDENTITY= \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=YES \
    SWIFT_OPTIMIZATION_LEVEL=-Onone \
    SWIFT_COMPILATION_MODE=singlefile \
    build
