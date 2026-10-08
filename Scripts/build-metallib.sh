#!/bin/bash
#
# Installs ArtRenderShaders.metallib where the runtime actually looks for it:
#
#   Sources/ArtRenderLibrary/ArtRenderShaders.metallib
#
# That checked-in file is what SwiftPM copies into the ArtRenderLibrary resource bundle,
# and what MetalRenderer loads at runtime. Building the **ArtRenderShaders** scheme in
# Xcode produces a metallib in DerivedData/BUILT_PRODUCTS_DIR which is *not* embedded
# anywhere, so it has to be installed here.
#
# Usage:
#   Scripts/build-metallib.sh                  compile the .metal sources with xcrun metal
#   Scripts/build-metallib.sh --from-xcode     install the metallib Xcode just built
#   Scripts/build-metallib.sh --verify-only    only report which functions are present
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/ArtQuickLook/ArtRenderShaders"
DEST="$ROOT/Sources/ArtRenderLibrary/ArtRenderShaders.metallib"

mode="build"
case "${1:-}" in
    --from-xcode)  mode="from-xcode" ;;
    --verify-only) mode="verify" ;;
    "")            mode="build" ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
esac

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "build-metallib.sh needs macOS (xcrun metal / Xcode)." >&2
    echo "On other platforms the checked-in metallib is used as-is." >&2
    exit 1
fi

# Entry point names the renderer looks up by. If any is missing the corresponding
# feature fails — and the live view silently falls back to the static render path — so
# they are verified after every install.
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
    # live view
    liveCompositeLayerKernel
    livePaperBackgroundKernel
    livePresentVertexShader
    livePresentFragmentShader
)

verify() {
    local file="$1"
    local missing=0
    for kernel in "${REQUIRED_KERNELS[@]}"; do
        if ! strings -a "$file" | grep -qx "$kernel"; then
            echo "  MISSING: $kernel"
            missing=1
        fi
    done
    if [[ $missing -eq 0 ]]; then
        echo "  OK: all ${#REQUIRED_KERNELS[@]} kernels/functions present"
        return 0
    fi
    return 1
}

install() {
    local file="$1"
    echo "Verifying $file"
    if ! verify "$file"; then
        echo "ERROR: refusing to install an incomplete metallib — the live view would" >&2
        echo "       silently fall back to the static render path." >&2
        return 1
    fi
    cp "$file" "$DEST"
    echo "Installed $DEST"
}

case "$mode" in
    verify)
        if [[ -f "$DEST" ]]; then
            verify "$DEST"
        else
            echo "No metallib at $DEST" >&2
            exit 1
        fi
        ;;

    from-xcode)
        # Newest ArtRenderShaders.metallib anywhere in DerivedData / the build dirs.
        FOUND="$(find "$HOME/Library/Developer/Xcode/DerivedData" \
                      "$HOME/Library/Developer/Xcode/Archives" \
                      "$ROOT/build" \
                      -name 'ArtRenderShaders.metallib' -type f 2>/dev/null \
                 | while read -r f; do
                       printf '%s\t%s\n' "$(stat -f '%m' "$f")" "$f"
                   done | sort -rn | head -1 | cut -f2- || true)"
        if [[ -z "${FOUND:-}" ]]; then
            echo "No ArtRenderShaders.metallib found — build the ArtRenderShaders" >&2
            echo "scheme in Xcode first." >&2
            exit 1
        fi
        echo "Found $(echo "$FOUND" | tr -cd '\n')built metallib: $FOUND"
        install "$FOUND"
        ;;

    build)
        TMP="$(mktemp -d)"
        trap 'rm -rf "$TMP"' EXIT
        COUNT="$(ls -1 "$SRC"/*.metal | wc -l | tr -d ' ')"
        echo "Compiling $COUNT Metal source(s) from $SRC"
        # shellcheck disable=SC2086
        xcrun -sdk macosx metal -c "$SRC"/*.metal -I "$SRC" -o "$TMP/ArtRenderShaders.metallib"
        install "$TMP/ArtRenderShaders.metallib"
        ;;
esac

echo
echo "Next: build the ArtQuickLook scheme in ArtQuickLook.xcodeproj"