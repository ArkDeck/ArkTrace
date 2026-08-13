#!/bin/bash
# Reproducibly builds the pinned TraceStreamer for macOS and stages the binary
# plus a provenance manifest into ThirdParty/TraceStreamer/macx/.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SAFETY_HELPER="$REPO_ROOT/scripts/phase3_shell_safety.sh"
[ -r "$SAFETY_HELPER" ] || { echo "ERROR: shell safety helper is missing" >&2; exit 1; }
# shellcheck source=phase3_shell_safety.sh
. "$SAFETY_HELPER"
SOURCE_LOCK="$REPO_ROOT/ThirdParty/TraceStreamer/source-lock.json"
LOCAL_PATCH="$REPO_ROOT/ThirdParty/TraceStreamer/patches/faultloggerd-apple-clang.patch"
REQUESTED_WORK_ROOT="${ARKTRACE_TS_WORK_DIR:-$REPO_ROOT/.build/trace-streamer-workspaces/default}"
REQUESTED_STAGE_DIR="${ARKTRACE_TS_STAGE_DIR:-$REPO_ROOT/ThirdParty/TraceStreamer/macx}"
SAFE_WORK_PARENT="$REPO_ROOT/.build/trace-streamer-workspaces"
REPOSITORY_STAGE="$REPO_ROOT/ThirdParty/TraceStreamer/macx"
WORK_PARENT_MARKER=.arktrace-trace-streamer-workspaces-v1
WORK_MARKER=.arktrace-trace-streamer-workspace-v1
STAGE_MARKER=.arktrace-trace-streamer-stage-v1
PLUGINS="hilog,hisysevent,arkts,bytrace,rawtrace,htrace,ffrt,memory,hidump,cpudata,network,diskio,process,xpower"
ADAPTER_VERSION="1"

for command_name in git jq curl shasum stat tar patch perl lipo otool clang; do
    command -v "$command_name" >/dev/null 2>&1 || {
        echo "ERROR: required command is unavailable: $command_name" >&2
        exit 1
    }
done
[ -r "$SOURCE_LOCK" ] || { echo "ERROR: source lock is missing" >&2; exit 1; }
[ -r "$LOCAL_PATCH" ] || { echo "ERROR: local patch is missing" >&2; exit 1; }

fail() {
    printf 'ERROR: %s\n' "$1" >&2
    exit 1
}

arktrace_validate_reviewed_roots "$REPO_ROOT"
arktrace_validate_owned_directory_request "$SAFE_WORK_PARENT" "workspace parent"
arktrace_validate_owned_directory_request "$REQUESTED_WORK_ROOT" "work"
if [ "$REQUESTED_STAGE_DIR" = "$REPOSITORY_STAGE" ]; then
    for stage_component in \
        "$REPO_ROOT/ThirdParty" \
        "$REPO_ROOT/ThirdParty/TraceStreamer" \
        "$REPOSITORY_STAGE"
    do
        [ -d "$stage_component" ] && [ ! -L "$stage_component" ] \
            || fail "repository stage chain must be physical"
    done
    for stage_output in \
        "$REPOSITORY_STAGE/trace_streamer" "$REPOSITORY_STAGE/manifest.json"
    do
        [ ! -L "$stage_output" ] || fail "repository stage output must not be a symlink"
    done
else
    arktrace_validate_owned_directory_request "$REQUESTED_STAGE_DIR" "stage"
fi
arktrace_create_reviewed_build_root
SAFE_WORK_PARENT=$(arktrace_secure_owned_directory \
    "$SAFE_WORK_PARENT" "$WORK_PARENT_MARKER" "workspace parent")
WORK_ROOT=$(arktrace_secure_owned_directory "$REQUESTED_WORK_ROOT" "$WORK_MARKER" "work")
if [ "$REQUESTED_STAGE_DIR" = "$REPOSITORY_STAGE" ]; then
    STAGE_DIR=$REPOSITORY_STAGE
else
    STAGE_DIR=$(arktrace_secure_owned_directory "$REQUESTED_STAGE_DIR" "$STAGE_MARKER" "stage")
fi
UPSTREAM_DIR="$WORK_ROOT/upstream"
TS_DIR="$UPSTREAM_DIR/smartperf_host/trace_streamer"
TP_DIR="$TS_DIR/third_party"
DOWNLOAD_DIR="$WORK_ROOT/downloads"
GIT_CONFIG_GLOBAL="$WORK_ROOT/.arktrace-gitconfig"
[ ! -L "$GIT_CONFIG_GLOBAL" ] \
    || fail "isolated Git configuration must not be a symlink"
arktrace_assert_owned_child "$WORK_ROOT" "$DOWNLOAD_DIR" "download root"
while IFS= read -r tool_name; do
    arktrace_require_absent_leaf \
        "$DOWNLOAD_DIR/$tool_name.tar.gz.partial" "locked tool partial archive"
done < <(jq -r '.tools | keys[]' "$SOURCE_LOCK")

for inherited_git_variable in \
    GIT_CONFIG GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 \
    GIT_ATTR_NOSYSTEM GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
    GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_WORK_TREE GIT_DIR
do
    unset "$inherited_git_variable"
done
export GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM=1 GIT_ATTR_NOSYSTEM=1 \
    GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=Never
[ ! -L "$GIT_CONFIG_GLOBAL" ] \
    || fail "isolated Git configuration must not be a symlink"
if [ -e "$GIT_CONFIG_GLOBAL" ]; then
    [ -f "$GIT_CONFIG_GLOBAL" ] \
        || fail "isolated Git configuration is not a regular file"
fi
GIT_CONFIG_TEMP=$(mktemp "$WORK_ROOT/.gitconfig.XXXXXX")
{
    printf '[url "https://gitee.com/openharmony/"]\n'
    printf '\tinsteadOf = git@gitee.com:openharmony/\n'
    printf '\tinsteadOf = ssh://git@gitee.com/openharmony/\n'
    printf '[core]\n\tattributesFile = /dev/null\n'
} >"$GIT_CONFIG_TEMP"
chmod 600 "$GIT_CONFIG_TEMP"
mv -f "$GIT_CONFIG_TEMP" "$GIT_CONFIG_GLOBAL"

UPSTREAM_URL=$(jq -er '.upstream.repository' "$SOURCE_LOCK")
UPSTREAM_REVISION=$(jq -er '.upstream.revision' "$SOURCE_LOCK")
BUILD_SCRIPT_SHA=$(shasum -a 256 "${BASH_SOURCE[0]}" | awk '{print $1}')
SAFETY_HELPER_SHA=$(shasum -a 256 "$SAFETY_HELPER" | awk '{print $1}')
SOURCE_LOCK_SHA=$(shasum -a 256 "$SOURCE_LOCK" | awk '{print $1}')
LOCAL_PATCH_SHA=$(shasum -a 256 "$LOCAL_PATCH" | awk '{print $1}')
BUILD_RECIPE_VERSION=$(
    printf 'build-script:%s\nsafety-helper:%s\nsource-lock:%s\nlocal-patch:%s\n' \
        "$BUILD_SCRIPT_SHA" "$SAFETY_HELPER_SHA" "$SOURCE_LOCK_SHA" "$LOCAL_PATCH_SHA" \
        | shasum -a 256 | awk '{print $1}'
)

verify_file() {
    path=$1
    expected_sha=$2
    expected_bytes=$3
    actual_sha=$(shasum -a 256 "$path" | awk '{print $1}')
    actual_bytes=$(stat -f '%z' "$path")
    [ "$actual_sha" = "$expected_sha" ] && [ "$actual_bytes" = "$expected_bytes" ] || {
        echo "ERROR: locked archive bytes drifted" >&2
        exit 1
    }
}

checkout_locked_source() {
    name=$1
    path=$2
    repository=$3
    revision=$4
    case "$path" in
        ""|/*|*..*|*[!A-Za-z0-9_./+-]*) fail "locked source path is invalid" ;;
    esac
    destination="$TP_DIR/$path"
    arktrace_assert_owned_child "$WORK_ROOT" "$destination" "locked source"
    mkdir -p "$(dirname "$destination")"
    if [ ! -d "$destination/.git" ]; then
        if [ -e "$destination" ]; then
            [ -d "$destination" ] \
                && [ -z "$(find "$destination" -mindepth 1 -maxdepth 1 -print -quit)" ] \
                || fail "locked source checkout target is existing and invalid"
        fi
        git clone --filter=blob:none --no-checkout "$repository" "$destination" \
            >/dev/null 2>&1
    fi
    arktrace_assert_owned_child "$WORK_ROOT" "$destination" "locked source"
    [ "$(git -C "$destination" remote get-url origin)" = "$repository" ] \
        || fail "locked source remote drifted: $name"
    git -C "$destination" fetch --depth=1 origin "$revision" >/dev/null 2>&1
    git -C "$destination" reset --hard "$revision" >/dev/null 2>&1
    git -C "$destination" clean -ffdqx >/dev/null 2>&1
    actual_revision=$(git -C "$destination" rev-parse HEAD)
    [ "$actual_revision" = "$revision" ] || {
        echo "ERROR: locked source revision drifted: $name" >&2
        exit 1
    }
}

fetch_locked_tool() {
    name=$1
    url=$(jq -er ".tools.$name.url" "$SOURCE_LOCK")
    sha=$(jq -er ".tools.$name.sha256" "$SOURCE_LOCK")
    bytes=$(jq -er ".tools.$name.byteCount" "$SOURCE_LOCK")
    archive="$DOWNLOAD_DIR/$name.tar.gz"
    [ ! -L "$archive" ] || fail "locked tool archive must not be a symlink"
    if [ -e "$archive" ]; then
        [ -f "$archive" ] || fail "locked tool archive is not a regular file"
    fi
    if [ ! -f "$archive" ]; then
        arktrace_require_absent_leaf "$archive.partial" "locked tool partial archive"
        curl --proto '=https' --tlsv1.2 --location --fail --silent \
            "$url" --output "$archive.partial" >/dev/null 2>&1
        verify_file "$archive.partial" "$sha" "$bytes"
        mv "$archive.partial" "$archive"
    fi
    verify_file "$archive" "$sha" "$bytes"
    tar -xzf "$archive" --directory "$TS_DIR/prebuilts/macx" >/dev/null 2>&1
}

echo "==> Checkout locked upstream"
arktrace_assert_owned_child "$WORK_ROOT" "$UPSTREAM_DIR" "upstream checkout"
if [ ! -d "$UPSTREAM_DIR/.git" ]; then
    if [ -e "$UPSTREAM_DIR" ]; then
        [ -d "$UPSTREAM_DIR" ] \
            && [ -z "$(find "$UPSTREAM_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ] \
            || fail "owned upstream directory is not an empty checkout target"
    fi
    git clone --filter=blob:none --no-checkout "$UPSTREAM_URL" "$UPSTREAM_DIR" \
        >/dev/null 2>&1
fi
arktrace_assert_owned_child "$WORK_ROOT" "$UPSTREAM_DIR" "upstream checkout"
[ "$(git -C "$UPSTREAM_DIR" remote get-url origin)" = "$UPSTREAM_URL" ] \
    || fail "owned upstream checkout has an unexpected remote"
git -C "$UPSTREAM_DIR" fetch --depth=1 origin "$UPSTREAM_REVISION" >/dev/null 2>&1
git -C "$UPSTREAM_DIR" reset --hard "$UPSTREAM_REVISION" >/dev/null 2>&1
git -C "$UPSTREAM_DIR" clean -ffdqx >/dev/null 2>&1
[ "$(git -C "$UPSTREAM_DIR" rev-parse HEAD)" = "$UPSTREAM_REVISION" ] || {
    echo "ERROR: upstream revision drifted" >&2
    exit 1
}

echo "==> Checkout exact third-party source lock"
arktrace_assert_owned_child "$WORK_ROOT" "$TP_DIR" "third-party checkout root"
arktrace_assert_owned_child "$WORK_ROOT" "$DOWNLOAD_DIR" "download root"
mkdir -p "$TP_DIR" "$DOWNLOAD_DIR"
arktrace_assert_owned_child "$WORK_ROOT" "$TP_DIR" "third-party checkout root"
arktrace_assert_owned_child "$WORK_ROOT" "$DOWNLOAD_DIR" "download root"
while IFS=$'\t' read -r name path repository revision; do
    checkout_locked_source "$name" "$path" "$repository" "$revision"
done < <(jq -r '.sources[] | [.name,.path,.repository,.revision] | @tsv' "$SOURCE_LOCK")

echo "==> Apply reviewed upstream and ArkTrace patches"
perl -pi -e 's/\r$//' \
    "$TP_DIR/hiviewdfx/faultloggerd/interfaces/innerkits/unwinder/src/elf/dfx_elf.cpp" \
    >/dev/null 2>&1
patch -d "$TP_DIR/hiviewdfx/faultloggerd" -p1 \
    < "$TS_DIR/prebuilts/patch_hiperf/hiviewdfx_faultloggerd.patch" >/dev/null 2>&1
perl -pi -e 's/\r$//' \
    "$TP_DIR/hiviewdfx/faultloggerd/interfaces/innerkits/unwinder/include/dfx_elf.h" \
    >/dev/null 2>&1
patch -d "$TP_DIR/hiviewdfx/faultloggerd" -p1 \
    < "$TS_DIR/prebuilts/patch_hiperf/hiviewdfx_faultloggerd_smo.patch" >/dev/null 2>&1
patch -d "$TP_DIR/hiviewdfx/faultloggerd" -p1 < "$LOCAL_PATCH" >/dev/null 2>&1
patch -d "$TP_DIR/hiperf" -p1 < "$TS_DIR/prebuilts/patch_hiperf/hiperf.patch" \
    >/dev/null 2>&1
patch -d "$TP_DIR/hiperf" -p1 < "$TS_DIR/prebuilts/patch_hiperf/hiperf_smo.patch" \
    >/dev/null 2>&1
patch -d "$TP_DIR/llvm-project" -p1 < "$TS_DIR/prebuilts/patch_llvm/llvm.patch" \
    >/dev/null 2>&1
rm -f "$TS_DIR/llvm"
ln -s "$TP_DIR/llvm-project/llvm" "$TS_DIR/llvm"

echo "==> Install SHA-locked GN/Ninja archives"
rm -rf -- "$TS_DIR/prebuilts/macx"
mkdir -p "$TS_DIR/prebuilts/macx"
fetch_locked_tool gn
fetch_locked_tool ninja
chmod 755 "$TS_DIR/prebuilts/macx/gn" "$TS_DIR/prebuilts/macx/ninja"

echo "==> Build (plugins: $PLUGINS)"
BINARY="$TS_DIR/out/macx/trace_streamer"
rm -f "$BINARY"
# The locked upstream links the binary successfully, then invokes its checked-in
# non-executable mac_depend.sh. That obsolete tail would also rewrite libc++ to
# a private relative path. Accept only this exact post-link failure, then prove
# the executable, version, architecture and load-command contract below.
BUILD_LOG=$(mktemp "$WORK_ROOT/.build-log.XXXXXX")
cleanup_build_log() { rm -f -- "$BUILD_LOG"; }
trap cleanup_build_log EXIT HUP INT TERM
if ! (cd "$TS_DIR" && LC_ALL=C ./build.sh -e "$PLUGINS") >"$BUILD_LOG" 2>&1; then
    if ! arktrace_is_reviewed_trace_streamer_tail_failure "$BUILD_LOG"; then
        arktrace_bounded_failure_summary "$BUILD_LOG"
        fail "TraceStreamer build exited non-zero for an unreviewed reason"
    fi
fi
rm -f -- "$BUILD_LOG"
trap - EXIT HUP INT TERM

if [ ! -x "$BINARY" ]; then
    echo "ERROR: TraceStreamer compile did not produce an executable" >&2
    exit 1
fi
if ! ("$BINARY" --version 2>&1 || true) | grep -q "version"; then
    echo "ERROR: built binary does not run" >&2
    exit 1
fi
if otool -L "$BINARY" | grep -q "\./lib/libc++"; then
    echo "ERROR: binary contains a non-portable relative libc++ load command" >&2
    exit 1
fi

echo "==> Stage binary and manifest"
for output in "$STAGE_DIR/trace_streamer" "$STAGE_DIR/manifest.json"; do
    [ ! -L "$output" ] || fail "stage output must not be a symlink"
done
STAGED_BINARY=$(mktemp "$STAGE_DIR/.trace_streamer.XXXXXX")
STAGED_MANIFEST=$(mktemp "$STAGE_DIR/.manifest.XXXXXX")
cleanup_stage() { rm -f -- "$STAGED_BINARY" "$STAGED_MANIFEST"; }
trap cleanup_stage EXIT HUP INT TERM
cp "$BINARY" "$STAGED_BINARY"
chmod 755 "$STAGED_BINARY"
BINARY_SHA256=$(shasum -a 256 "$STAGED_BINARY" | awk '{print $1}')
REPORTED_VERSION=$( \
    ("$STAGED_BINARY" --version 2>&1 || true) \
        | sed -n 's/.*version[[:space:]]*\([0-9][0-9A-Za-z.\-]*\).*/\1/p' | head -1
)
BINARY_ARCH=$(/usr/bin/lipo -archs "$STAGED_BINARY" | tr ' ' '\n' | sort | paste -sd+ -)
CLANG_VERSION=$(clang --version | head -1)
BUILT_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
THIRD_PARTY_REVISIONS=$(jq -c '
    reduce .sources[] as $source ({}; .[$source.name] = $source.revision)
' "$SOURCE_LOCK")

jq -n \
    --arg name trace_streamer \
    --arg upstreamRepository "$UPSTREAM_URL" \
    --arg upstreamRevision "$UPSTREAM_REVISION" \
    --arg reportedVersion "$REPORTED_VERSION" \
    --arg binarySHA256 "$BINARY_SHA256" \
    --arg architecture "$BINARY_ARCH" \
    --arg adapterVersion "$ADAPTER_VERSION" \
    --arg buildRecipeVersion "$BUILD_RECIPE_VERSION" \
    --arg plugins "$PLUGINS" \
    --arg thirdPartySources "source-lock.json exact revisions over HTTPS" \
    --arg hostToolchain "$CLANG_VERSION" \
    --arg builtAt "$BUILT_AT" \
    --argjson thirdPartyRevisions "$THIRD_PARTY_REVISIONS" '
    {
      name: $name,
      upstreamRepository: $upstreamRepository,
      upstreamRevision: $upstreamRevision,
      reportedVersion: $reportedVersion,
      binarySHA256: $binarySHA256,
      architecture: $architecture,
      adapterVersion: $adapterVersion,
      buildRecipeVersion: $buildRecipeVersion,
      plugins: $plugins,
      localPatches: ["patches/faultloggerd-apple-clang.patch"],
      thirdPartySources: $thirdPartySources,
      thirdPartyRevisions: $thirdPartyRevisions,
      hostToolchain: $hostToolchain,
      builtAt: $builtAt
    }
  ' >"$STAGED_MANIFEST"
mv -f "$STAGED_BINARY" "$STAGE_DIR/trace_streamer"
mv -f "$STAGED_MANIFEST" "$STAGE_DIR/manifest.json"
trap - EXIT HUP INT TERM

echo "==> Done"
echo "    sha256:   $BINARY_SHA256"
echo "    version:  $REPORTED_VERSION"
echo "    recipe:   $BUILD_RECIPE_VERSION"
echo "    artifacts: trace_streamer manifest.json"
