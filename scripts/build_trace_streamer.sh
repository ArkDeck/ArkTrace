#!/bin/bash
# Builds the pinned TraceStreamer for macOS and stages the binary plus a
# provenance manifest into ThirdParty/TraceStreamer/macx/.
#
# Everything this script does was established as Phase 0/1 evidence (see
# docs/TRACE_STREAMER.md):
#   - canonical upstream is GitCode; third_party dependencies must come from
#     Gitee over anonymous https because the two mirrors have diverged and the
#     upstream patches target the Gitee tips;
#   - the upstream build script's `git config --global` write is isolated via
#     GIT_CONFIG_GLOBAL so the user's ~/.gitconfig is never touched;
#   - faultloggerd is pre-provisioned so a one-line pointer-cast fix (required
#     by current Apple clang) can be applied before ninja runs;
#   - hiperf/ebpf/native_hook plugins are disabled: ArkTrace does not consume
#     them and they are the only users of the fragile native unwinder.
set -euo pipefail

UPSTREAM_URL="https://gitcode.com/openharmony/developtools_smartperf_host.git"
UPSTREAM_REVISION="447a0a49a7b3b914d6e9bd00648ba5a340f6fbf6"
PLUGINS="hilog,hisysevent,arkts,bytrace,rawtrace,htrace,ffrt,memory,hidump,cpudata,network,diskio,process,xpower"
BUILD_RECIPE_VERSION="1"
ADAPTER_VERSION="1"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${ARKTRACE_TS_WORK_DIR:-$REPO_ROOT/.build/trace_streamer-upstream}"
STAGE_DIR="$REPO_ROOT/ThirdParty/TraceStreamer/macx"
TS_DIR="$WORK_DIR/smartperf_host/trace_streamer"
TP_DIR="$TS_DIR/third_party"

echo "==> Checkout $UPSTREAM_REVISION"
if [ ! -d "$WORK_DIR/.git" ]; then
    git clone --filter=blob:none "$UPSTREAM_URL" "$WORK_DIR"
fi
git -C "$WORK_DIR" fetch origin "$UPSTREAM_REVISION" 2>/dev/null || git -C "$WORK_DIR" fetch origin
git -C "$WORK_DIR" checkout -f "$UPSTREAM_REVISION"

echo "==> Isolate git global config and rewrite gitee ssh to https"
export GIT_CONFIG_GLOBAL="$WORK_DIR/.arktrace-gitconfig"
cat > "$GIT_CONFIG_GLOBAL" <<'EOF'
[url "https://gitee.com/openharmony/"]
	insteadOf = git@gitee.com:openharmony/
EOF

echo "==> Pre-provision faultloggerd with upstream patches + macOS cast fix"
if [ ! -d "$TP_DIR/hiviewdfx/faultloggerd" ]; then
    mkdir -p "$TP_DIR/hiviewdfx"
    git clone --depth=1 https://gitee.com/openharmony/hiviewdfx_faultloggerd.git \
        "$TP_DIR/hiviewdfx/faultloggerd"
    (
        cd "$TP_DIR/hiviewdfx/faultloggerd"
        perl -pi -e 's/\r$//' interfaces/innerkits/unwinder/src/elf/dfx_elf.cpp
        patch -p1 < ../../../prebuilts/patch_hiperf/hiviewdfx_faultloggerd.patch
        perl -pi -e 's/\r$//' interfaces/innerkits/unwinder/include/dfx_elf.h
        patch -p1 < ../../../prebuilts/patch_hiperf/hiviewdfx_faultloggerd_smo.patch
    )
fi
DFX_ELF="$TP_DIR/hiviewdfx/faultloggerd/interfaces/innerkits/unwinder/src/elf/dfx_elf.cpp"
if grep -q '(ElfW(Addr))(uintptr_t)(shdr.offset' "$DFX_ELF"; then
    echo "    cast fix already applied"
elif grep -q '(ElfW(Addr))(shdr.offset' "$DFX_ELF"; then
    perl -pi -e \
        's/\(ElfW\(Addr\)\)\(shdr\.offset \+ \(char\*\)GetMmapPtr\(\)\)/(ElfW(Addr))(uintptr_t)(shdr.offset + (char*)GetMmapPtr())/' \
        "$DFX_ELF"
    echo "    cast fix applied"
else
    echo "ERROR: dfx_elf.cpp no longer matches the known cast pattern; review the recipe" >&2
    exit 1
fi

echo "==> Build (plugins: $PLUGINS)"
BINARY="$TS_DIR/out/macx/trace_streamer"
rm -f "$BINARY"
# build.sh's tail step runs mac_depend.sh, which on modern macOS finds no
# /usr libc++ dylib on disk (dyld shared cache) and would rewrite the binary's
# libc++ load command to a broken relative path. It fails first on its missing
# exec bit; both outcomes are expected — the real success criterion is a fresh
# working binary, verified below.
(cd "$TS_DIR" && ./build.sh -e "$PLUGINS") \
    || echo "    build.sh exited non-zero (expected mac_depend tail failure); verifying binary"

if [ ! -x "$BINARY" ]; then
    echo "ERROR: no binary at $BINARY — the compile itself failed" >&2
    exit 1
fi
# trace_streamer --version exits non-zero by design; only the output matters.
if ! ("$BINARY" --version 2>&1 || true) | grep -q "version"; then
    echo "ERROR: built binary does not run" >&2
    exit 1
fi
if otool -L "$BINARY" | grep -q "\./lib/libc++"; then
    echo "ERROR: mac_depend.sh rewrote libc++ to a relative path; binary is not portable" >&2
    exit 1
fi

echo "==> Stage binary and manifest"
mkdir -p "$STAGE_DIR"
cp "$BINARY" "$STAGE_DIR/trace_streamer"
BINARY_SHA256=$(shasum -a 256 "$STAGE_DIR/trace_streamer" | awk '{print $1}')
REPORTED_VERSION=$(("$STAGE_DIR/trace_streamer" --version 2>&1 || true) | sed -n 's/.*version[[:space:]]*\([0-9][0-9A-Za-z.\-]*\).*/\1/p' | head -1)
# Record the staged binary's Mach-O architecture, not the build host's uname.
# Keep the ordering/format aligned with TraceStreamerBinaryInspector.
BINARY_ARCH=$(/usr/bin/lipo -archs "$STAGE_DIR/trace_streamer" | tr ' ' '\n' | sort | paste -sd+ -)
CLANG_VERSION=$(clang --version | head -1)
BUILT_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

THIRD_PARTY_JSON=""
for dir in "$TP_DIR"/*/ "$TP_DIR"/hiviewdfx/faultloggerd/ "$TP_DIR"/commonlibrary/c_utils/; do
    [ -d "$dir/.git" ] || continue
    name=$(basename "$dir")
    sha=$(git -C "$dir" rev-parse HEAD 2>/dev/null || echo unknown)
    THIRD_PARTY_JSON="$THIRD_PARTY_JSON    \"$name\": \"$sha\",\n"
done
THIRD_PARTY_JSON=$(printf '%b' "$THIRD_PARTY_JSON" | sed '$ s/,$//')

cat > "$STAGE_DIR/manifest.json" <<EOF
{
  "name": "trace_streamer",
  "upstreamRepository": "$UPSTREAM_URL",
  "upstreamRevision": "$UPSTREAM_REVISION",
  "reportedVersion": "$REPORTED_VERSION",
  "binarySHA256": "$BINARY_SHA256",
  "architecture": "$BINARY_ARCH",
  "adapterVersion": "$ADAPTER_VERSION",
  "buildRecipeVersion": "$BUILD_RECIPE_VERSION",
  "plugins": "$PLUGINS",
  "localPatches": [
    "faultloggerd dfx_elf.cpp: route pointer cast through uintptr_t (Apple clang rejects the truncating cast)"
  ],
  "thirdPartySources": "gitee https (diverged from gitcode; upstream patches target gitee tips)",
  "thirdPartyRevisions": {
$THIRD_PARTY_JSON
  },
  "hostToolchain": "$CLANG_VERSION",
  "builtAt": "$BUILT_AT"
}
EOF

echo "==> Done"
echo "    binary:   $STAGE_DIR/trace_streamer"
echo "    sha256:   $BINARY_SHA256"
echo "    version:  $REPORTED_VERSION"
echo "    manifest: $STAGE_DIR/manifest.json"
