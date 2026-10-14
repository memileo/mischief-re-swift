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
#   Scripts/build-metallib.sh --force             install even if verification finds gaps
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/ArtQuickLook/ArtRenderShaders"
DEST="$ROOT/Sources/ArtRenderLibrary/ArtRenderShaders.metallib"
PROJECT="$ROOT/ArtQuickLook/ArtQuickLook.xcodeproj"
SCHEME="ArtRenderShaders"

mode="build"
force=0
explicit=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --from-xcode)  mode="from-xcode" ;;
        --verify-only) mode="verify" ;;
        --build)       mode="build" ;;
        --force)       force=1 ;;
        --install)     mode="install"; shift; explicit="${1:-}" ;;
        -h|--help)     sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
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
    liveBinSortTilesKernel
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
has_function() {
    local file="$1" name="$2"
    strings -a "$file" 2>/dev/null | grep -Fq -- "$name"
}

verify() {
    local file="$1" missing=0 missing_live=0
    [[ -f "$file" ]] || { echo "  no such file: $file"; return 1; }
    for kernel in "${REQUIRED_KERNELS[@]}"; do
        if ! has_function "$file" "$kernel"; then
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
        BUILT="$(products_dir_from_xcodebuild || true)"
        if [[ -n "${BUILT:-}" ]]; then
            echo "BUILT_PRODUCTS_DIR: $BUILT"
            if [[ -f "$BUILT/ArtRenderShaders.metallib" ]]; then
                FOUND="$BUILT/ArtRenderShaders.metallib"
            fi
        fi
        if [[ -z "$FOUND" ]]; then
            echo "Not in BUILT_PRODUCTS_DIR — searching DerivedData for the newest build…"
            FOUND="$(newest_metallib \
                "$HOME/Library/Developer/Xcode/DerivedData" \
                "$HOME/Library/Developer/Xcode/Archives" \
                "$ROOT/build" || true)"
        fi
        if [[ -z "${FOUND:-}" ]]; then
            echo "No ArtRenderShaders.metallib found." >&2
            echo "Build it first:" >&2
            echo "  xcodebuild -project \"$PROJECT\" -scheme $SCHEME -configuration Release build" >&2
            echo "or build the $SCHEME scheme in Xcode, then re-run this script." >&2
            echo "Already have the file somewhere? Scripts/build-metallib.sh --install <path>" >&2
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