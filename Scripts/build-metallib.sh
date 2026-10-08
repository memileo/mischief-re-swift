#!/bin/bash
#
# Rebuilds ArtRenderShaders.metallib from ArtQuickLook/ArtRenderShaders/*.metal and
# installs it where SwiftPM expects it:
#
#   Sources/ArtRenderLibrary/ArtRenderShaders.metallib
#
# That checked-in metallib is what the ArtRenderLibrary resource bundle copies, and it
# is what MetalRenderer loads at runtime. So this must be re-run whenever a .metal file
# is added or changed — including after pulling changes that touch the shaders.
#
# Usage:  Scripts/build-metallib.sh [--verify-only]
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/ArtQuickLook/ArtRenderShaders"
DEST="$ROOT/Sources/ArtRenderLibrary/ArtRenderShaders.metallib"

verify_only=0
if [[ "${1:-}" == "--verify-only" ]]; then
    verify_only=1
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "build-metallib.sh needs macOS (xcrun metal). On other platforms the checked-in" >&2
    echo "metallib is used as-is." >&2
    exit 1
fi

# Entry point names the renderer looks up. If any is missing, the corresponding
# feature fails (and the live view silently falls back to the static render path), so
# verify them explicitly after every rebuild.
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
    else
        return 1
    fi
}

echo "Verifying $DEST"
if verify "$DEST"; then
    echo "  (up to date)"
else
    echo "  metallib is stale or incomplete — rebuild with Scripts/build-metallib.sh"
    if [[ $verify_only -eq 1 ]]; then
        exit 1
    fi
fi

if [[ $verify_only -eq 1 ]]; then
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Compiling $(ls -1 "$SRC"/*.metal | wc -l | tr -d ' ') Metal source(s) from $SRC"
xcrun -sdk macosx metal -c "$SRC"/*.metal -I "$SRC" -o "$TMP/ArtRenderShaders.metallib"

echo "Verifying the freshly built metallib"
verify "$TMP/ArtRenderShaders.metallib"

cp "$TMP/ArtRenderShaders.metallib" "$DEST"
echo "Installed $DEST"
echo
echo "Next: open ArtQuickLook.xcodeproj and build the ArtQuickLook scheme"