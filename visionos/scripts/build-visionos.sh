#!/usr/bin/env bash
# Builds Wind Waker VR for Apple Vision Pro: the game (WindWakerVisionGame.framework),
# then the SwiftUI app around it (xcodegen + xcodebuild), and optionally installs
# it on the paired headset.
#
#   visionos/scripts/build-visionos.sh --team TEAMID [--bundle-id ID] [--debug]
#                                      [--install [--device UDID]] [--game-only]
#   visionos/scripts/build-visionos.sh --simulator [--debug] [--game-only]
#
# --simulator builds for the visionOS Simulator, unsigned (no team needed).
# The bundle ID defaults to dev.windwakervr.vision.<TEAMID>: a bare ID may already be
# registered to another team, and automatic signing then falls back to a wildcard
# profile without the memory entitlement.
set -euo pipefail

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
visionos="${root}/visionos"
team=""
bundle_id=""
config="RelWithDebInfo"
xcode_config="Release"
install=0
device=""
game_only=0
simulator=0
stub=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --team) team="${2:?}"; shift 2 ;;
        --bundle-id) bundle_id="${2:?}"; shift 2 ;;
        --debug) config="Debug"; xcode_config="Debug"; shift ;;
        --install) install=1; shift ;;
        --device) device="${2:?}"; shift 2 ;;
        --game-only) game_only=1; shift ;;
        --simulator) simulator=1; shift ;;
        -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

# CMake's Xcode lookup breaks when the Xcode path has a space in it; keep the
# active Xcode at /Applications/Xcode.app.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
for tool in xcodegen xcrun; do
    command -v "${tool}" >/dev/null || { echo "ERROR: ${tool} not found (brew install ${tool})" >&2; exit 1; }
done
if [[ ${simulator} -eq 1 ]]; then flavour="xrsimulator"; else flavour="visionos"; fi
build="${root}/.scratch/build-${flavour}-${config}"

# 1. The game framework: SwitchWaker's CMake build (native/), cross-compiled for visionOS, with
# visionos/cmake/framework.cmake adding the framework target (native/CMakeLists.txt includes it).
build_game() {
    # What the build needs, checked before anything is fetched or built (Dawn alone takes an hour).
    for tool in cmake ninja git curl python3; do
        command -v "${tool}" >/dev/null || { echo "ERROR: ${tool} not found (brew install ${tool})" >&2; exit 1; }
    done
    # The game's asset headers come from the player's disc (native/tools/gen_assets.sh, once).
    [[ -d "${root}/build/native-mac/assets/GZLE01/include" ]] || {
        echo "ERROR: no asset headers: COS_DISC=<your GZLE01 .iso> native/tools/gen_assets.sh first" >&2; exit 1; }
    # nod (the disc reader) is Rust: a nightly with the visionOS targets. Homebrew's rustup is
    # keg-only. The nightly is pinned by date (TPVR's), so a new one can't break the build.
    [[ -d /opt/homebrew/opt/rustup/bin ]] && export PATH="/opt/homebrew/opt/rustup/bin:${PATH}"
    local rust_toolchain="${WWVR_RUST_TOOLCHAIN:-nightly-2026-09-30}" rust_target
    if [[ ${simulator} -eq 1 ]]; then rust_target=aarch64-apple-visionos-sim; else rust_target=aarch64-apple-visionos; fi
    command -v rustup >/dev/null &&
        rustup target list --toolchain "${rust_toolchain}" --installed 2>/dev/null | grep -qx "${rust_target}" || {
        echo "ERROR: Rust ${rust_toolchain} with ${rust_target} is needed (brew install rustup, then):" >&2
        echo "  rustup toolchain install ${rust_toolchain} --profile minimal && rustup target add --toolchain ${rust_toolchain} ${rust_target}" >&2
        exit 1; }

    # Aurora at SwitchWaker's pin, checked out once (it's FETCHCONTENT_SOURCE_DIR_AURORA: each build
    # directory patches its own copy with native/patches/aurora, then visionos/patches/aurora).
    local aurora_pin
    aurora_pin="$(sed -n 's/^set(COS_AURORA_COMMIT "\([0-9a-f]*\)".*/\1/p' "${root}/native/cmake/Aurora.cmake")"
    if [[ ! -d "${root}/ref/aurora/.git" ]]; then
        git clone -q https://github.com/encounter/aurora.git "${root}/ref/aurora"
    fi
    if [[ "$(git -C "${root}/ref/aurora" rev-parse HEAD)" != "${aurora_pin}" ]]; then
        git -C "${root}/ref/aurora" fetch -q origin "${aurora_pin}" 2>/dev/null || true
        git -C "${root}/ref/aurora" -c advice.detachedHead=false checkout -q "${aurora_pin}"
    fi
    [[ -d "${root}/ref/recompcore/.git" ]] || "${root}/native/tools/fetch_recompcore.sh"

    # Dawn for xrOS (cached by revision, patch and flags; ~1 h the first time).
    local dawn_package
    if [[ ${simulator} -eq 1 ]]; then
        dawn_package="$("${visionos}/scripts/build-dawn-visionos.sh" --simulator | tail -1)"
        local sysroot=xrsimulator
    else
        dawn_package="$("${visionos}/scripts/build-dawn-visionos.sh" | tail -1)"
        local sysroot=xros
    fi
    # The cc crate targets the SDK's own visionOS version unless told otherwise.
    export XROS_DEPLOYMENT_TARGET=26.0
    # Host package prefixes CMake must not search: their libraries are macOS builds (a Miniconda
    # fmt/zstd once got linked into TPVR's framework). Exact prefixes, Conda's own included.
    local ignore="/opt/homebrew;/usr/local;/opt/homebrew/Caskroom/miniconda/base;${HOME}/miniconda3;${HOME}/miniforge3;${HOME}/anaconda3"
    [[ -n "${CONDA_PREFIX:-}" ]] && ignore="${ignore};${CONDA_PREFIX}"
    cmake -S "${root}/native" -B "${build}" -G Ninja \
        -DCMAKE_SYSTEM_NAME=visionOS \
        -DCMAKE_OSX_SYSROOT="${sysroot}" \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 \
        -DCMAKE_BUILD_TYPE="${config}" \
        -DBUILD_SHARED_LIBS=OFF \
        -DCMAKE_DISABLE_FIND_PACKAGE_PkgConfig=ON \
        "-DCMAKE_IGNORE_PREFIX_PATH=${ignore}" \
        "-DFETCHCONTENT_SOURCE_DIR_AURORA=${root}/ref/aurora" \
        "-DCOS_AURORA_EXTRA_PATCH_DIR=${visionos}/patches/aurora" \
        "-DCOS_ASSETS_DIR=${root}/build/native-mac/assets/GZLE01" \
        -DAURORA_DAWN_PROVIDER=package \
        "-DAURORA_DAWN_PACKAGE_URL=file://${dawn_package}" \
        -DAURORA_SDL3_PROVIDER=vendor \
        -DAURORA_NOD_PROVIDER=vendor \
        -DRust_CARGO_TARGET="${rust_target}" \
        "-DRust_TOOLCHAIN=${rust_toolchain}" \
        -DTRACY_ENABLE=OFF \
        -Ufmt_DIR -Uzstd_DIR
    cmake --build "${build}" --target WindWakerVisionGame --parallel "$(sysctl -n hw.ncpu)"
}
if [[ ${stub} -eq 0 ]]; then
    build_game
    [[ -d "${build}/WindWakerVisionGame.framework" ]] || {
        echo "ERROR: ${build}/WindWakerVisionGame.framework was not produced" >&2; exit 1; }
    echo "Game framework: ${build}/WindWakerVisionGame.framework"
fi
[[ ${game_only} -eq 1 ]] && exit 0

# 2. The app. The launcher's kit is vendored, never fetched at build time.
[[ -f "${visionos}/TrevorbiltKit/Package.swift" ]] || {
    echo "ERROR: visionos/TrevorbiltKit is missing: run visionos/scripts/sync-trevorbilt-kit.sh" >&2; exit 1; }
# Clean-built every time: Xcode's incremental build (especially in a
# shared custom build location) has kept stale embedded frameworks and stale
# Swift objects. The app is a handful of files; the clean costs seconds.
# A clean of one platform's products can delete the other's in a shared build
# location, so rebuild the Simulator app before Simulator tests after a device build.
#
# Where xcodebuild put the product: Xcode's "Custom" build-location preference
# (IDEBuildLocationStyle) overrides -derivedDataPath, so ask xcodebuild.
products_dir() {
    xcodebuild "$@" -showBuildSettings 2>/dev/null | awk -F' = ' '/^ *BUILT_PRODUCTS_DIR = / {print $2; exit}'
}
app_dir="${visionos}/App"
# Our own products and intermediates: this Mac's Xcode puts every project's products in one shared
# "Custom" location, where another port's clean build deleted this app (and the kit's bundle is
# built there by every port). SYMROOT/OBJROOT on the command line override that preference.
xcode_dirs=(SYMROOT="${root}/.scratch/xcode/Products" OBJROOT="${root}/.scratch/xcode/Intermediates")
if [[ ${simulator} -eq 1 ]]; then
    export WWVR_TEAM="${team:-NONE}" WWVR_BUNDLE_ID="${bundle_id:-dev.windwakervr.vision.simulator}" WWVR_GAME_BUILD_DIR="${build}"
    (cd "${app_dir}" && xcodegen generate --quiet)
    args=(-project "${app_dir}/WindWakerVision.xcodeproj" -scheme WindWakerVision -configuration "${xcode_config}"
          -destination 'generic/platform=visionOS Simulator' -derivedDataPath "${root}/.scratch/DerivedData-simulator"
          ARCHS=arm64 CODE_SIGNING_ALLOWED=NO "${xcode_dirs[@]}")
    xcodebuild "${args[@]}" clean build
    echo "App: $(products_dir "${args[@]}")/WindWakerVision.app"
    exit 0
fi
[[ -n "${team}" ]] || { echo "ERROR: --team TEAMID is needed to sign the app" >&2; exit 2; }
[[ -n "${bundle_id}" ]] || bundle_id="dev.windwakervr.vision.${team}"
export WWVR_TEAM="${team}" WWVR_BUNDLE_ID="${bundle_id}" WWVR_GAME_BUILD_DIR="${build}"
(cd "${app_dir}" && xcodegen generate --quiet)
args=(-project "${app_dir}/WindWakerVision.xcodeproj" -scheme WindWakerVision -configuration "${xcode_config}"
      -destination 'generic/platform=visionOS' -derivedDataPath "${root}/.scratch/DerivedData"
      DEVELOPMENT_TEAM="${team}" PRODUCT_BUNDLE_IDENTIFIER="${bundle_id}" "${xcode_dirs[@]}")
xcodebuild "${args[@]}" -allowProvisioningUpdates clean build
app="$(products_dir "${args[@]}")/WindWakerVision.app"
echo "App: ${app}"

# 3. Install. A locked or asleep headset makes devicectl hang: wake and unlock it first.
if [[ ${install} -eq 1 ]]; then
    if [[ -z "${device}" ]]; then
        json="$(mktemp)"
        xcrun devicectl list devices --json-output "${json}" >/dev/null 2>&1 || true
        device="$(python3 - "${json}" <<'PY'
import json, sys
try:
    devices = json.load(open(sys.argv[1]))["result"]["devices"]
except Exception:
    devices = []
for d in devices:
    hw = d.get("hardwareProperties", {})
    if hw.get("platform") == "visionOS" and hw.get("reality") == "physical":
        print(hw.get("udid", d.get("identifier", "")))
        break
PY
)"
        rm -f "${json}"
    fi
    [[ -n "${device}" ]] || { echo "ERROR: no paired Apple Vision Pro found; pass --device UDID" >&2; exit 1; }
    xcrun devicectl device install app --device "${device}" "${app}"
fi
