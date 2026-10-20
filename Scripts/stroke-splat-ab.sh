#!/bin/sh
# A/B pixel-identity check for the splat live-view path.
#
# Runs art2png --live-view twice per view:
#   * ART_LIVE_SPLAT=0     -> the per-tile walk (the baseline)
#   * ART_LIVE_SPLAT unset -> tool default (the splat, when the layer's cost model
#                             predicts it is cheaper)
# and byte-compares the two PNGs. They must be IDENTICAL.
#
# The default run's own `[splat NxB]` marker is reported per case, so a view that quietly
# fell back to the walk is called out as "walk vs walk" instead of counting as a pass
# (that is how a round of A/B came back green while the splat kernels were not even in
# the metallib). A splat-off run that still logs `[splat ...]` is flagged too: the env
# override did not take.
#
# Usage:
#   sh Scripts/stroke-splat-ab.sh <doc.art> [viewport] [zoom] [panX,panY] [rotate]
#     e.g. sh Scripts/stroke-splat-ab.sh art/kaos.art 1920x1080 0.05
#          sh Scripts/stroke-splat-ab.sh art/kaos.art 1920x1080 "" 40,-20 0.3
#   sh Scripts/stroke-splat-ab.sh --all        # the standard view matrix
#
# A run writes <doc-dir>/<name>.live-view.png; this script deletes that path before every
# run (so a stale PNG can never be compared) and keeps each result here:
#   tmp/splat-ab/<doc>@<zoom>-splat-{off,default}.png   plus one .log per run
#
# Env: ART2PNG overrides the binary (default .build/release/art2png), ART_SPLAT_AB_OUT
# the output directory.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN=${ART2PNG:-$ROOT/.build/release/art2png}
OUT=${ART_SPLAT_AB_OUT:-$ROOT/tmp/splat-ab}
fail=0

if [ ! -x "$BIN" ]; then
    echo "No executable at $BIN" >&2
    echo "Build it first:  swift build -c release" >&2
    exit 2
fi
mkdir -p "$OUT"
cd "$ROOT" || exit 2

# Print "<w> <h>" for a PNG, or nothing when no dimension tool is available.
png_size() {
    if command -v sips >/dev/null 2>&1; then
        w=$(sips -g pixelWidth "$1" 2>/dev/null | awk '/pixelWidth/ {print $2}')
        h=$(sips -g pixelHeight "$1" 2>/dev/null | awk '/pixelHeight/ {print $2}')
        if [ -n "${w:-}" ] && [ -n "${h:-}" ]; then
            echo "$w $h"
        fi
    fi
}

# check_size <png> <label> <viewport WxH> — the live view is always rasterised at the
# viewport size; anything else means the view is not what was asked for (a 1x1 PNG is
# the classic symptom of a viewport that never reached the tool).
check_size() {
    png=$1; label=$2; vp=$3
    size=$(png_size "$png")
    [ -n "$size" ] || return 0
    want="${vp%x*} ${vp#*x}"
    if [ "$size" != "$want" ]; then
        echo "  !! $label: PNG is ${size% *}x${size#* }, expected $vp"
        fail=1
        return 1
    fi
}

# ab_case <tag> <doc> <viewport> <extra art2png args...>
ab_case() {
    tag=$1; doc=$2; vp=$3; shift 3
    base="${doc%.*}.live-view.png"
    off="$OUT/$tag-splat-off.png"
    def="$OUT/$tag-splat-default.png"
    logoff="$OUT/$tag-splat-off.log"
    logdef="$OUT/$tag-splat-default.log"

    if [ ! -f "$doc" ]; then
        echo "SKIP       $tag — no such document: $doc"
        return 0
    fi
    rm -f "$base" "$off" "$def" "$logoff" "$logdef"

    ART_LIVE_SPLAT=0 "$BIN" --live-view --viewport "$vp" "$@" "$doc" >"$logoff" 2>&1
    rc=$?
    if [ $rc -ne 0 ] || [ ! -s "$base" ]; then
        echo "FAIL       $tag — splat-off run failed (exit $rc, no PNG); see $logoff"
        fail=1
        return 0
    fi
    mv "$base" "$off"

    env -u ART_LIVE_SPLAT "$BIN" --live-view --viewport "$vp" "$@" "$doc" >"$logdef" 2>&1
    rc=$?
    if [ $rc -ne 0 ] || [ ! -s "$base" ]; then
        echo "FAIL       $tag — default run failed (exit $rc, no PNG); see $logdef"
        fail=1
        return 0
    fi
    mv "$base" "$def"

    # Did the two runs actually take different paths?
    if grep -q '\[splat' "$logoff" 2>/dev/null; then
        echo "  !! $tag: the splat-off run still logged [splat ...] — ART_LIVE_SPLAT=0 did not take effect"
        fail=1
    fi
    marks=$(sed -n 's/.*\(\[splat [^]]*\]\).*/\1/p' "$logdef" | sort -u | tr '\n' ' ')
    bad=0
    check_size "$off" "$tag (splat-off)" "$vp" || bad=1
    check_size "$def" "$tag (splat-default)" "$vp" || bad=1
    if [ $bad -ne 0 ]; then
        echo "NOT COMPARED  $tag — the PNGs are not the requested view (see above)"
        fail=1
        return 0
    fi

    if cmp -s "$off" "$def"; then
        printf 'IDENTICAL  %-32s %-14s %s bytes\n' "$tag" "${marks:-walk}" \
            "$(wc -c <"$off" | tr -d ' ')"
        if [ -z "$marks" ]; then
            echo "  note: default run used the walk (no [splat ...]) — walk vs walk, nothing exercised"
        fi
        echo "           $off"
    else
        echo "DIFFER!!   $tag ${marks:-(walk)}"
        cmp "$off" "$def" | head -3
        echo "           $off"
        echo "           $def"
        fail=1
    fi
}

usage() {
    sed -n '2,27p' "$0"
}

# Standard matrix: the views that matter for the splat (regular zoom walks; deep
# zoom-out splats; dots @ 20 must stay walk-only because radiusFactor > 1).
all_cases() {
    while IFS='|' read -r tag doc vp zoom pan rot; do
        [ -n "${tag:-}" ] || continue
        set --
        [ -n "${zoom:-}" ] && set -- "$@" --zoom "$zoom"
        [ -n "${pan:-}" ] && set -- "$@" --pan "$pan"
        [ -n "${rot:-}" ] && set -- "$@" --rotate "$rot"
        ab_case "$tag" "$doc" "$vp" "$@"
    done <<'CASES'
kaos|art/kaos.art|1920x1080|||
kaos@0.21|art/kaos.art|1920x1080|0.21||
kaos@0.05|art/kaos.art|1920x1080|0.05||
logo@1|art/logo-sketch-s6d5h46e54h_03.art|1920x1080|||
logo@0.05|art/logo-sketch-s6d5h46e54h_03.art|1920x1080|0.05||
complex@1|art/complex.art|1920x1080|||
complex@0.3|art/complex.art|1920x1080|0.3||
complex@0.05|art/complex.art|1920x1080|0.05||
dots@20|art/dots.art|1920x1080|20||
dots@1|art/dots.art|1920x1080|||
CASES
}

case "${1:-}" in
    ""|-h|--help)
        usage
        [ -z "${1:-}" ] && exit 2
        exit 0
        ;;
    --all)
        all_cases
        ;;
    *)
        doc=$1
        vp=${2:-1920x1080}
        zoom=${3:-}
        pan=${4:-}
        rot=${5:-}
        name=$(basename "$doc" .art)
        tag="$name@${zoom:-1}"
        [ -n "$pan" ] && tag="$tag+pan"
        [ -n "$rot" ] && tag="$tag+rot"
        set --
        [ -n "$zoom" ] && set -- "$@" --zoom "$zoom"
        [ -n "$pan" ] && set -- "$@" --pan "$pan"
        [ -n "$rot" ] && set -- "$@" --rotate "$rot"
        ab_case "$tag" "$doc" "$vp" "$@"
        ;;
esac

if [ $fail -ne 0 ]; then
    echo
    echo "FAILED — at least one view was not identical (or did not run as asked)."
    exit 1
fi
echo
echo "All views identical. Images in $OUT"
