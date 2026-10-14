#!/bin/bash
# Reproducibly builds the pinned TraceStreamer as a PE x64 executable on a
# Windows 11 x64 host and stages it plus a provenance manifest into
# ThirdParty/TraceStreamer/windows-x86_64/ (or ARKTRACE_TS_STAGE_DIR).
#
# Run from an MSYS2 shell (MSYSTEM=MSYS). MSYS2 supplies only the POSIX tools
# (pacman: git patch unzip jq p7zip diffutils). The compiler is the
# SHA-locked mingw-builds GCC from windows-toolchain-lock.json; MSYS2's own
# mingw-w64 GCC is never used. ARKTRACE_TS_PYTHON must name a native Windows
# python.exe: the upstream protoc wrapper selects protoc.exe and the
# protoreader plugin only when platform.system() is "Windows", and silently
# skips the *.pbreader.h generation otherwise.
set -euo pipefail

fail() {
    printf 'ERROR: %s\n' "$1" >&2
    exit 1
}

case "$(uname -s)" in
    MSYS_NT-*) ;;
    *) fail "run from an MSYS2 MSYS shell on Windows" ;;
esac
[ "$(uname -m)" = "x86_64" ] || fail "host must be x86_64"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TS_ROOT="$REPO_ROOT/ThirdParty/TraceStreamer"
SOURCE_LOCK="$TS_ROOT/source-lock.json"
WINDOWS_LOCK="$TS_ROOT/windows-toolchain-lock.json"
PROTO_READER_PATCH="$TS_ROOT/patches/proto-reader-sparse-validity.patch"
WINDOWS_LINK_PATCH="$TS_ROOT/patches/windows-reproducible-utf8-link.patch"
RESOURCE_MANIFEST="$TS_ROOT/windows/trace_streamer.manifest"
RESOURCE_SCRIPT="$TS_ROOT/windows/trace_streamer.rc"
WORK_PARENT="$REPO_ROOT/.build/trace-streamer-workspaces"
WORK_ROOT="${ARKTRACE_TS_WORK_DIR:-$WORK_PARENT/windows-default}"
STAGE_DIR="${ARKTRACE_TS_STAGE_DIR:-$TS_ROOT/windows-x86_64}"
PYTHON="${ARKTRACE_TS_PYTHON:-}"
PLUGINS="hilog,hisysevent,arkts,bytrace,rawtrace,htrace,ffrt,memory,hidump,cpudata,network,diskio,process,xpower"
DISABLED_PLUGINS="hiperf ebpf native_hook"
ADAPTER_VERSION="1"
JOBS="${ARKTRACE_TS_JOBS:-4}"

for command_name in git jq curl sha256sum stat patch perl unzip 7z cygpath cmp; do
    command -v "$command_name" >/dev/null 2>&1 \
        || fail "required command is unavailable: $command_name"
done
for input in "$SOURCE_LOCK" "$WINDOWS_LOCK" "$PROTO_READER_PATCH" \
    "$WINDOWS_LINK_PATCH" "$RESOURCE_MANIFEST" "$RESOURCE_SCRIPT"
do
    [ -f "$input" ] && [ ! -L "$input" ] || fail "recipe input is missing: ${input#"$REPO_ROOT"/}"
done
[ -n "$PYTHON" ] || fail "ARKTRACE_TS_PYTHON must name a native Windows python.exe"
[ -f "$PYTHON" ] || fail "ARKTRACE_TS_PYTHON does not exist"
[ "$("$PYTHON" -I -c 'import platform; print(platform.system())' | tr -d '\r')" = "Windows" ] \
    || fail "ARKTRACE_TS_PYTHON is not a native Windows interpreter"
[[ "$JOBS" =~ ^[1-9][0-9]?$ ]] || fail "ARKTRACE_TS_JOBS must be 1-99"
CMD_EXE="$(cygpath -S)/cmd.exe"
[ -f "$CMD_EXE" ] || fail "system cmd.exe is unavailable"

# Work and stage directories are owned leaves below fixed parents; never
# accept a symlinked or foreign root.
case "$WORK_ROOT" in
    "$WORK_PARENT"/*) ;;
    *) fail "work root must be below .build/trace-streamer-workspaces" ;;
esac
case "${WORK_ROOT#"$WORK_PARENT"/}" in
    ""|*/*|.*) fail "work root must be a direct, non-hidden child" ;;
esac
mkdir -p "$WORK_PARENT" "$WORK_ROOT" "$STAGE_DIR"
for owned in "$WORK_PARENT" "$WORK_ROOT" "$STAGE_DIR"; do
    [ -d "$owned" ] && [ ! -L "$owned" ] || fail "owned directory is not physical: $owned"
done

sha_of() { sha256sum "$1" | awk '{print $1}'; }

UPSTREAM_URL=$(jq -er '.upstream.repository' "$SOURCE_LOCK")
UPSTREAM_REVISION=$(jq -er '.upstream.revision' "$SOURCE_LOCK")
BUILD_RECIPE_VERSION=$(
    for input in "${BASH_SOURCE[0]}" "$SOURCE_LOCK" "$WINDOWS_LOCK" \
        "$PROTO_READER_PATCH" "$WINDOWS_LINK_PATCH" "$RESOURCE_MANIFEST" "$RESOURCE_SCRIPT"
    do
        printf '%s:%s\n' "$(basename "$input")" "$(sha_of "$input")"
    done | sha256sum | awk '{print $1}'
)

UPSTREAM_DIR="$WORK_ROOT/upstream"
TS_DIR="$UPSTREAM_DIR/smartperf_host/trace_streamer"
TP_DIR="$TS_DIR/third_party"
DOWNLOAD_DIR="$WORK_ROOT/downloads"
TOOLCHAIN_DIR="$WORK_ROOT/toolchain"
mkdir -p "$DOWNLOAD_DIR"

for inherited_git_variable in \
    GIT_CONFIG GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 \
    GIT_ATTR_NOSYSTEM GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
    GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_WORK_TREE GIT_DIR
do
    unset "$inherited_git_variable"
done
export GIT_CONFIG_GLOBAL="$WORK_ROOT/.arktrace-gitconfig" GIT_CONFIG_NOSYSTEM=1 \
    GIT_ATTR_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=Never
[ ! -L "$GIT_CONFIG_GLOBAL" ] || fail "isolated Git configuration must not be a symlink"
# Upstream sources must check out byte-exact (no CRLF conversion, no symlink
# emulation) for the locked patches and Windows paths to apply.
printf '[core]\n\tlongpaths = true\n\tautocrlf = false\n\tsymlinks = false\n\tattributesFile = /dev/null\n' \
    >"$GIT_CONFIG_GLOBAL"

verify_file() {
    [ "$(sha_of "$1")" = "$2" ] && [ "$(stat -c '%s' "$1")" = "$3" ] \
        || fail "locked download bytes drifted: $(basename "$1")"
}

fetch_locked() {
    url=$1 sha=$2 bytes=$3 archive=$4
    [ ! -L "$archive" ] || fail "locked archive must not be a symlink"
    if [ ! -f "$archive" ]; then
        rm -f -- "$archive.partial"
        curl --proto '=https' --tlsv1.2 --location --fail --silent \
            "$url" --output "$archive.partial"
        verify_file "$archive.partial" "$sha" "$bytes"
        mv "$archive.partial" "$archive"
    fi
    verify_file "$archive" "$sha" "$bytes"
}

checkout_exact() {
    destination=$1 repository=$2 revision=$3 label=$4
    case "$destination" in "$WORK_ROOT"/*) ;; *) fail "checkout escapes work root" ;; esac
    if [ ! -d "$destination/.git" ]; then
        if [ -e "$destination" ]; then
            [ -d "$destination" ] && [ -z "$(ls -A "$destination")" ] \
                || fail "checkout target is existing and invalid: $label"
        fi
        mkdir -p "$destination"
        git init -q "$destination"
        git -C "$destination" remote add origin "$repository"
    fi
    [ "$(git -C "$destination" remote get-url origin)" = "$repository" ] \
        || fail "locked source remote drifted: $label"
    git -C "$destination" fetch -q --depth=1 origin "$revision"
    git -C "$destination" reset -q --hard "$revision"
    git -C "$destination" clean -ffdqx
    [ "$(git -C "$destination" rev-parse HEAD)" = "$revision" ] \
        || fail "locked source revision drifted: $label"
}

echo "==> Install SHA-locked compiler"
COMPILER_ARCHIVE="$DOWNLOAD_DIR/compiler.7z"
fetch_locked "$(jq -er '.compiler.url' "$WINDOWS_LOCK")" \
    "$(jq -er '.compiler.sha256' "$WINDOWS_LOCK")" \
    "$(jq -er '.compiler.byteCount' "$WINDOWS_LOCK")" "$COMPILER_ARCHIVE"
rm -rf -- "$TOOLCHAIN_DIR"
mkdir -p "$TOOLCHAIN_DIR"
7z x -y -o"$TOOLCHAIN_DIR" "$COMPILER_ARCHIVE" >/dev/null
COMPILER_BIN="$TOOLCHAIN_DIR/mingw64/bin"
COMPILER_VERSION=$("$COMPILER_BIN/g++.exe" --version | head -1 | tr -d '\r')
[ "$COMPILER_VERSION" = "$(jq -er '.compiler.expectedVersion' "$WINDOWS_LOCK")" ] \
    || fail "locked compiler reports an unexpected version"

echo "==> Checkout locked upstream and third-party sources"
# Remove only a previous run's junction (rmdir never follows it) so the
# upstream clean cannot traverse into the LLVM checkout.
if [ -e "$TS_DIR/llvm" ] || [ -L "$TS_DIR/llvm" ]; then
    MSYS2_ARG_CONV_EXCL='*' "$CMD_EXE" /d /c rmdir "$(cygpath -w "$TS_DIR/llvm")" \
        || fail "could not remove the previous llvm junction"
fi
checkout_exact "$UPSTREAM_DIR" "$UPSTREAM_URL" "$UPSTREAM_REVISION" upstream
while IFS=$'\t' read -r name path repository revision; do
    case "$path" in
        ""|/*|*..*|*[!A-Za-z0-9_./+-]*) fail "locked source path is invalid" ;;
    esac
    checkout_exact "$TP_DIR/$path" "$repository" "$revision" "$name"
done < <(jq -r '.sources[] | [.name,.path,.repository,.revision] | @tsv' "$SOURCE_LOCK" | tr -d '\r')

echo "==> Apply reviewed upstream and ArkTrace patches"
# Same upstream patch sequence as the macOS recipe. The Apple clang
# faultloggerd patch is not needed: GCC accepts that conversion.
perl -pi -e 's/\r$//' \
    "$TP_DIR/hiviewdfx/faultloggerd/interfaces/innerkits/unwinder/src/elf/dfx_elf.cpp"
patch -s -d "$TP_DIR/hiviewdfx/faultloggerd" -p1 \
    < "$TS_DIR/prebuilts/patch_hiperf/hiviewdfx_faultloggerd.patch"
perl -pi -e 's/\r$//' \
    "$TP_DIR/hiviewdfx/faultloggerd/interfaces/innerkits/unwinder/include/dfx_elf.h"
patch -s -d "$TP_DIR/hiviewdfx/faultloggerd" -p1 \
    < "$TS_DIR/prebuilts/patch_hiperf/hiviewdfx_faultloggerd_smo.patch"
patch -s -d "$TP_DIR/hiperf" -p1 < "$TS_DIR/prebuilts/patch_hiperf/hiperf.patch"
patch -s -d "$TP_DIR/hiperf" -p1 < "$TS_DIR/prebuilts/patch_hiperf/hiperf_smo.patch"
patch -s -d "$TP_DIR/llvm-project" -p1 < "$TS_DIR/prebuilts/patch_llvm/llvm.patch"
patch -s -d "$UPSTREAM_DIR" -p1 < "$PROTO_READER_PATCH"
patch -s -d "$UPSTREAM_DIR" -p1 < "$WINDOWS_LINK_PATCH"
# .gn_win resolves //llvm through a secondary source root; a junction keeps it
# inside the work root without copying the LLVM tree.
[ ! -e "$TS_DIR/llvm" ] || fail "upstream checkout unexpectedly contains llvm"
MSYS2_ARG_CONV_EXCL='*' "$CMD_EXE" /d /c mklink /J \
    "$(cygpath -w "$TS_DIR/llvm")" "$(cygpath -w "$TP_DIR/llvm-project/llvm")" >/dev/null
cp "$TS_DIR/.gn_win" "$TS_DIR/.gn"

echo "==> Install SHA-locked GN/Ninja archives"
mkdir -p "$TS_DIR/prebuilts/windows"
for tool in gn ninja; do
    archive="$DOWNLOAD_DIR/$tool.zip"
    fetch_locked "$(jq -er ".tools.$tool.url" "$WINDOWS_LOCK")" \
        "$(jq -er ".tools.$tool.sha256" "$WINDOWS_LOCK")" \
        "$(jq -er ".tools.$tool.byteCount" "$WINDOWS_LOCK")" "$archive"
    unzip -q -o "$archive" "$(jq -er ".tools.$tool.member" "$WINDOWS_LOCK")" \
        -d "$TS_DIR/prebuilts/windows"
done

echo "==> Compile the UTF-8 application manifest"
mkdir -p "$TS_DIR/arktrace"
cp "$RESOURCE_MANIFEST" "$RESOURCE_SCRIPT" "$TS_DIR/arktrace/"
(cd "$TS_DIR/arktrace" && PATH="$COMPILER_BIN:/usr/bin" windres.exe --input trace_streamer.rc \
    --output trace_streamer.res.o --output-format=coff)

echo "==> Build (plugins: $PLUGINS)"
GN_ARGS='is_debug=false target="trace_streamer" target_os="windows" is_independent_compile=true use_local_emsdk=false'
for plugin in $DISABLED_PLUGINS; do GN_ARGS="$GN_ARGS enable_$plugin=false"; done
for plugin in ${PLUGINS//,/ }; do GN_ARGS="$GN_ARGS enable_$plugin=true"; done
GN_ARGS="$GN_ARGS enable_stream_extend=false enable_addr2line=false"
PYTHON_DIR=$(dirname "$PYTHON")
BUILD_LOG="$WORK_ROOT/build.log"
rm -rf -- "$TS_DIR/out/windows"
if ! (
    cd "$TS_DIR"
    export PATH="$COMPILER_BIN:$PYTHON_DIR:/usr/bin" LC_ALL=C
    ./prebuilts/windows/gn.exe gen out/windows --args="$GN_ARGS"
    ./prebuilts/windows/ninja.exe -C out/windows -j "$JOBS"
) >"$BUILD_LOG" 2>&1; then
    grep -E 'error|FAILED' "$BUILD_LOG" | head -20 >&2 || true
    fail "TraceStreamer build failed; see ${BUILD_LOG#"$REPO_ROOT"/}"
fi

BINARY="$TS_DIR/out/windows/trace_streamer.exe"
[ -f "$BINARY" ] || fail "build did not produce trace_streamer.exe"
"$COMPILER_BIN/objdump.exe" -p "$BINARY" >"$WORK_ROOT/pe.txt"
grep -q 'Magic.*020b' "$WORK_ROOT/pe.txt" || fail "binary is not PE32+"
grep -q 'Time/Date.* 1970' "$WORK_ROOT/pe.txt" \
    || fail "PE header carries a link timestamp"
IMPORTS=$(awk '/DLL Name:/ {print $3}' "$WORK_ROOT/pe.txt" | sort -u | tr -d '\r')
ALLOWED=$(jq -r '.allowedImports[]' "$WINDOWS_LOCK" | sort -u | tr -d '\r')
[ "$IMPORTS" = "$ALLOWED" ] || fail "binary imports drifted from the closed system-DLL set"
REPORTED_VERSION=$("$BINARY" --version 2>&1 | tr -d '\r' \
    | sed -n 's/.*version[[:space:]]*\([0-9][0-9A-Za-z.\-]*\).*/\1/p' | head -1 || true)
[ -n "$REPORTED_VERSION" ] || fail "built binary does not run"

echo "==> Stage binary and manifest"
cp "$BINARY" "$STAGE_DIR/.trace_streamer.exe.partial"
cmp -s "$BINARY" "$STAGE_DIR/.trace_streamer.exe.partial" || fail "staged copy differs"
BINARY_SHA256=$(sha_of "$STAGE_DIR/.trace_streamer.exe.partial")
PYTHON_VERSION=$("$PYTHON" -I -c 'import platform; print(platform.python_version())' | tr -d '\r')
THIRD_PARTY_REVISIONS=$(jq -c 'reduce .sources[] as $s ({}; .[$s.name] = $s.revision)' "$SOURCE_LOCK")
IMPORTS_JSON=$(printf '%s\n' "$IMPORTS" | jq -R . | jq -sc .)
jq -n \
    --arg name trace_streamer.exe \
    --arg upstreamRepository "$UPSTREAM_URL" \
    --arg upstreamRevision "$UPSTREAM_REVISION" \
    --arg reportedVersion "$REPORTED_VERSION" \
    --arg binarySHA256 "$BINARY_SHA256" \
    --arg adapterVersion "$ADAPTER_VERSION" \
    --arg buildRecipeVersion "$BUILD_RECIPE_VERSION" \
    --arg plugins "$PLUGINS" \
    --arg hostToolchain "$COMPILER_VERSION" \
    --arg protocWrapperPython "$PYTHON_VERSION" \
    --arg builtAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson imports "$IMPORTS_JSON" \
    --argjson thirdPartyRevisions "$THIRD_PARTY_REVISIONS" '
    {
      name: $name,
      upstreamRepository: $upstreamRepository,
      upstreamRevision: $upstreamRevision,
      reportedVersion: $reportedVersion,
      binarySHA256: $binarySHA256,
      architecture: "x86_64",
      format: "PE32+",
      imports: $imports,
      signed: false,
      adapterVersion: $adapterVersion,
      buildRecipeVersion: $buildRecipeVersion,
      plugins: $plugins,
      localPatches: [
        "patches/proto-reader-sparse-validity.patch",
        "patches/windows-reproducible-utf8-link.patch"
      ],
      thirdPartySources: "source-lock.json exact revisions over HTTPS",
      thirdPartyRevisions: $thirdPartyRevisions,
      hostToolchain: $hostToolchain,
      protocWrapperPython: $protocWrapperPython,
      builtAt: $builtAt
    }' >"$STAGE_DIR/.manifest.json.partial"
mv -f "$STAGE_DIR/.trace_streamer.exe.partial" "$STAGE_DIR/trace_streamer.exe"
mv -f "$STAGE_DIR/.manifest.json.partial" "$STAGE_DIR/manifest.json"

echo "==> Done"
echo "    sha256:   $BINARY_SHA256"
echo "    version:  $REPORTED_VERSION"
echo "    recipe:   $BUILD_RECIPE_VERSION"
echo "    imports:  $(printf '%s ' $IMPORTS)"
