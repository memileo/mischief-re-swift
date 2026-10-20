#!/bin/bash
#
# Installs ArtRenderShaders.metallib where the runtime actually looks for it:
#
#   Sources/ArtRenderLibrary/ArtRenderShaders.metallib
#
# That checked-in file is what SwiftPM copies into the ArtRenderLibrary resource bundle,
# and what MetalRenderer loads at runtime. Building the **ArtRenderShaders** scheme in
# Xcode produces a metallib in DerivedData which is *not* embedded anywhere, so it has to
# be installed here.
#
# Usage:
#   Scripts/build-metallib.sh                     compile the .metal sources with xcrun metal
#   Scripts/build-metallib.sh --from-xcode        find the metallib Xcode just built and install it
#   Scripts/build-metallib.sh --install <path>    install a metallib from an explicit path
#   Scripts/build-metallib.sh --verify-only       only report which functions are present
#   Scripts/build-metallib.sh --no-verify         skip the symbol check (fast, no metal-nm)
#   Scripts/build-metallib.sh --force             install even if verification finds gaps
#
# Prefer plain `Scripts/build-metallib.sh`: it compiles ArtQuickLook/ArtRenderShaders/*.metal
# directly into Sources/ArtRenderLibrary/ArtRenderShaders.metallib, so it can never pick up a
# stale DerivedData product (which is exactly how an out-of-date metallib once got installed
# unnoticed). Use --from-xcode only if you deliberately built the ArtRenderShaders scheme in
# Xcode and want that product.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/ArtQuickLook/ArtRenderShaders"
DEST="$ROOT/Sources/ArtRenderLibrary/ArtRenderShaders.metallib"
PROJECT="$ROOT/ArtQuickLook/ArtQuickLook.xcodeproj"
SCHEME="ArtRenderShaders"

mode="build"
force=0
noverify=0
explicit=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --from-xcode)  mode="from-xcode" ;;
        --verify-only) mode="verify" ;;
        --build)       mode="build" ;;
        --force)       force=1 ;;
        --no-verify)   noverify=1 ;;
        --install)     mode="install"; shift; explicit="${1:-}" ;;
        -h|--help)     sed -n '2,24p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "build-metallib.sh needs macOS (xcrun metal / Xcode)." >&2
    echo "On other platforms the checked-in metallib is used as-is." >&2
    exit 1
fi

# Entry point names the renderer looks up by. If any is missing the corresponding
# feature fails — and the live view silently falls back to the static render path — so
# they are verified after every install.
LIVE_KERNELS=(
    liveCompositeLayerKernel
    livePaperBackgroundKernel
    livePresentVertexShader
    livePresentFragmentShader
    liveSegmentAACompositeKernel
    liveSegmentNoiseCompositeKernel
    livePerTileAACompositeKernel
    livePerTileNoiseCompositeKernel
    liveBinTransformCountKernel
    liveBinScatterKernel
    liveBinChunkSortV3Kernel
    liveBinChunkSortV4Kernel
    liveBinMergePassV3Kernel
    liveSplatKernel
    liveSplatCompositeKernel
    liveSplatWriteKernel
)
REQUIRED_KERNELS=(
    clearKernel
    vs_passthrough
    fs_convert
    distanceFieldMaskKernel
    highQualityAntiAliasKernel
    highQualityStampKernel
    highQualityStampWithNoiseKernel
    fxaaKernel
    eraserKernel
    segmentAACompositeKernel
    segmentNoiseCompositeKernel
    segmentPasteLayerAACompositeKernel
    segmentPasteLayerNoiseCompositeKernel
    segmentCutCompositeKernel
    mergeFlattenCompositeKernel
    "${LIVE_KERNELS[@]}"
)

# Names are matched as substrings: depending on the compiler a metallib stores them
# standalone or with a suffix, and "close enough to be found" is what matters here.
# Two inspection methods — `metal-nm` knows the symbol table, `strings` sees through
# almost anything else. A name counts as present when EITHER method sees it (each
# method can silently yield nothing on some setups: missing CLI tools, unexpected
# container layout — and "every kernel missing" then means the inspection failed,
# not the metallib).
inspect_symbols() {
    local file="$1"
    # Both probes are time-bounded: a hung tool must never look like a hung build.
    if command -v xcrun >/dev/null 2>&1; then
        with_timeout 20 xcrun -sdk macosx metal-nm "$file" 2>/dev/null || true
    fi
    with_timeout 20 strings -a "$file" 2>/dev/null || true
}

verify() {
    local file="$1" missing=0 missing_live=0
    [[ -f "$file" ]] || { echo "  no such file: $file"; return 1; }
    local haystack
    haystack="$(inspect_symbols "$file")"
    if [[ -z "${haystack//[[:space:]]/}" ]]; then
        echo "  WARNING: neither metal-nm nor strings could read symbols from $file."
        echo "  (inspection tools failed — this says nothing about the metallib itself;"
        echo "   the runtime's makeFunction check at launch is authoritative.)"
    fi
    for kernel in "${REQUIRED_KERNELS[@]}"; do
        if [[ "$haystack" != *"$kernel"* ]]; then
            echo "  MISSING: $kernel"
            missing=1
            [[ " ${LIVE_KERNELS[*]} " == *" $kernel "* ]] && missing_live=1
        fi
    done
    if [[ $missing -eq 0 ]]; then
        echo "  OK: all ${#REQUIRED_KERNELS[@]} kernels/functions present"
        return 0
    fi
    if [[ $missing_live -eq 1 ]]; then
        echo "  (live-view kernels missing → the live view will fall back to the static path)"
    fi
    return 1
}

install() {
    local file="$1"
    if [[ $noverify -eq 1 ]]; then
        cp "$file" "$DEST"
        echo "Installed $DEST (verification skipped)"
        return 0
    fi
    echo "Verifying $file"
    if verify "$file"; then
        cp "$file" "$DEST"
        echo "Installed $DEST ($(du -h "$DEST" | cut -f1))"
        return 0
    fi
    if [[ $force -eq 1 ]]; then
        echo "  --force: installing anyway"
        cp "$file" "$DEST"
        echo "Installed $DEST"
        return 0
    fi
    echo "ERROR: refusing to install an incomplete metallib." >&2
    echo "       Re-run with --force to install it anyway." >&2
    return 1
}

# Portable command timeout for macOS (no `timeout(1)` there): runs the command in
# the background and kills it after N seconds. Returns the command's status, or a
# non-zero status on timeout. Callers under `set -e` must guard with `|| true`.
with_timeout() {
    local secs="$1"; shift
    "$@" &
    local pid=$!
    (sleep "$secs"; kill -9 "$pid" 2>/dev/null) &
    local watcher=$!
    wait "$pid"
    local rc=$?
    kill "$watcher" 2>/dev/null
    wait "$watcher" 2>/dev/null || true
    return $rc
}

# Newest metallib under the given roots, newest first. Prints nothing if there is none.
newest_metallib() {
    local roots=()
    for root in "$@"; do
        [[ -d "$root" ]] && roots+=("$root")
    done
    [[ ${#roots[@]} -eq 0 ]] && return 0
    find "${roots[@]}" -name 'ArtRenderShaders.metallib' -type f -print0 2>/dev/null \
        | xargs -0 stat -f '%m\t%N' 2>/dev/null \
        | sort -rn | head -1 | cut -f2- || true
}

# Where Xcode puts this scheme's products. Authoritative; the find-based search below is
# only the fallback for when xcodebuild cannot be run (e.g. no scheme selected yet).
products_dir_from_xcodebuild() {
    [[ -d "$PROJECT" ]] || return 0
    local settings
    settings="$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -showBuildSettings 2>/dev/null || true)"
    local dir
    dir="$(printf '%s\n' "$settings" | awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{print $2; exit}')"
    [[ -n "${dir:-}" ]] && printf '%s\n' "$dir"
}

case "$mode" in
    verify)
        if [[ -f "$DEST" ]]; then
            echo "Checking $DEST"
            verify "$DEST" || exit 1
        else
            echo "No metallib at $DEST" >&2
            exit 1
        fi
        ;;

    install)
        if [[ -z "$explicit" ]]; then
            echo "--install needs a path to a .metallib" >&2
            exit 1
        fi
        install "$explicit"
        ;;

    from-xcode)
        FOUND=""
        # Fast escape hatch: point straight at the products dir, skipping both
        # xcodebuild and the DerivedData search.
        #   ART_METALLIB_DIR=.../Debug Scripts/build-metallib.sh --from-xcode
        if [[ -n "${ART_METALLIB_DIR:-}" ]]; then
            if [[ -f "$ART_METALLIB_DIR/ArtRenderShaders.metallib" ]]; then
                echo "Using ART_METALLIB_DIR: $ART_METALLIB_DIR"
                FOUND="$ART_METALLIB_DIR/ArtRenderShaders.metallib"
            else
                echo "ART_METALLIB_DIR is set but has no ArtRenderShaders.metallib: $ART_METALLIB_DIR" >&2
                exit 1
            fi
        fi
        if [[ -z "$FOUND" ]]; then
            echo "Resolving BUILT_PRODUCTS_DIR via xcodebuild (one-off, can take a minute)…"
            BUILT="$(with_timeout 120 products_dir_from_xcodebuild || true)"
            if [[ -n "${BUILT:-}" ]]; then
                echo "BUILT_PRODUCTS_DIR: $BUILT"
                if [[ -f "$BUILT/ArtRenderShaders.metallib" ]]; then
                    FOUND="$BUILT/ArtRenderShaders.metallib"
                fi
            else
                echo "(xcodebuild probe timed out or failed — falling back to search)"
            fi
        fi
        if [[ -z "$FOUND" ]]; then
            echo "Not in BUILT_PRODUCTS_DIR — searching DerivedData (up to 120s)…"
            FOUND="$(with_timeout 120 newest_metallib \
                "$HOME/Library/Developer/Xcode/DerivedData" \
                "$HOME/Library/Developer/Xcode/Archives" \
                "$ROOT/build" || true)"
        fi
        if [[ -z "${FOUND:-}" ]]; then
            echo "No ArtRenderShaders.metallib found." >&2
            echo "Build it first:" >&2
            echo "  xcodebuild -project \"$PROJECT\" -scheme $SCHEME -configuration Release build" >&2
            echo "or build the $SCHEME scheme in Xcode, then re-run this script." >&2
            echo "Already have the file somewhere? Skip the probe entirely:" >&2
            echo "  ART_METALLIB_DIR=<dir-with-metallib> Scripts/build-metallib.sh --from-xcode" >&2
            echo "or verify a known file directly: Scripts/build-metallib.sh --verify-only" >&2
            exit 1
        fi
        echo "Using $FOUND"
        install "$FOUND"
        ;;

    build)
        TMP="$(mktemp -d)"
        trap 'rm -rf "$TMP"' EXIT
        COUNT="$(ls -1 "$SRC"/*.metal | wc -l | tr -d ' ')"
        echo "Compiling $COUNT Metal source(s) from $SRC"
        xcrun -sdk macosx metal "$SRC"/*.metal -I "$SRC" -o "$TMP/ArtRenderShaders.metallib"
        install "$TMP/ArtRenderShaders.metallib"
        ;;
esac

echo
echo "Next: build the ArtQuickLook scheme in ArtQuickLook.xcodeproj"