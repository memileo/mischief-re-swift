#!/bin/sh
# Pixel-identity A/B for the live-view splat path.
#
# Every view is rendered twice, each time from its own private copy of the document, so a
# run can never compare against (or accidentally reuse) a PNG from an earlier view:
#
#   tmp/splat-ab/<doc>@<zoom>/off/kaos.art      ART_LIVE_SPLAT=0      (the walk)
#   tmp/splat-ab/<doc>@<zoom>/default/kaos.art  ART_LIVE_SPLAT unset  (tool default)
#
# art2png writes <input>.live-view.png next to its input, i.e. next to each copy. The two
# PNGs are compared by SHA-256: IDENTICAL is the pass condition.
#
# Usage:
#   Scripts/stroke-splat-ab.sh [--viewport WxH] [--zoom Z] [--pan X,Y] [--rotate R] <doc.art>
#   Scripts/stroke-splat-ab.sh <doc.art> <zoom>      -- shorthand for --zoom
#   Scripts/stroke-splat-ab.sh --all                 -- the standard view matrix
#
# Defaults: --viewport 1920x1080, --zoom 1. Exit status: 0 all identical, 1 any DIFFER or
# failed run, 2 bad usage.
#
# A view where the cost model declines the splat (e.g. kaos at 0.25: the walk is cheaper)
# is a legitimate walk-vs-walk pass and is reported as such. To force the splat there for
# an identity check, turn the model off for the default side: ART_LIVE_SPLAT_COST=0.
#
# Env: ART2PNG (binary, default .build/release/art2png),
#      ART_SPLAT_AB_OUT (output dir, default tmp/splat-ab — project-local and gitignored).
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN=${ART2PNG:-$ROOT/.build/release/art2png}
OUT=${ART_SPLAT_AB_OUT:-$ROOT/tmp/splat-ab}

VP=1920x1080
ZOOM=""
PAN=""
ROT=""
ALL=0
DOC=""
fail=0
splat_views=0
total_views=0

die() {
    echo "stroke-splat-ab: $*" >&2
    exit 2
}

usage() {
    sed -n '13,26p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --all)     ALL=1; shift ;;
        --viewport) [ $# -ge 2 ] || die "--viewport needs WxH"; VP=$2; shift 2 ;;
        --zoom)     [ $# -ge 2 ] || die "--zoom needs a number"; ZOOM=$2; shift 2 ;;
        --pan)      [ $# -ge 2 ] || die "--pan needs X,Y"; PAN=$2; shift 2 ;;
        --rotate)   [ $# -ge 2 ] || die "--rotate needs a number"; ROT=$2; shift 2 ;;
        --)         shift
                    while [ $# -gt 0 ]; do DOC=$1; shift; done ;;
        -*)
            die "unknown option '$1' — see --help"
            ;;
        *)
            # First bare word is the document; a second one is the zoom (the old
            # two-positional form: `stroke-splat-ab.sh art/kaos.art 0.25`).
            if [ -z "$DOC" ]; then
                DOC=$1
            elif [ -z "$ZOOM" ]; then
                ZOOM=$1
            else
                die "unexpected argument '$1' — see --help"
            fi
            shift
            ;;
    esac
done

case "$VP" in
    *x*) ;;
    *) die "--viewport needs WxH (e.g. 1920x1080), got '$VP'" ;;
esac
case "${VP%x*}" in
    ''|*[!0-9]*) die "--viewport needs whole pixels (e.g. 1920x1080), got '$VP'" ;;
esac
case "${VP#*x}" in
    ''|*[!0-9]*) die "--viewport needs whole pixels (e.g. 1920x1080), got '$VP'" ;;
esac

if [ ! -x "$BIN" ]; then
    echo "No executable at $BIN" >&2
    echo "Build it first:  swift build -c release" >&2
    exit 2
fi
mkdir -p "$OUT" || exit 2
cd "$ROOT" || exit 2

sha_of() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        cksum "$1" | awk '{print "cksum:" $1 "-" $2}'
    fi
}

bytes_of() {
    wc -c <"$1" | tr -d ' '
}

# "width height" from the PNG's IHDR (big-endian at offset 16), or non-zero when the file
# is not a readable PNG. One `od` per byte keeps this free of word splitting, so the same
# code works under /bin/sh (bash 3.2 on macOS), bash and zsh — zsh does not split unquoted
# expansions, which is exactly the kind of difference that made the old script lie.
png_size() {
    w=0
    h=0
    i=0
    for off in 16 17 18 19 20 21 22 23; do
        b=$(od -An -tu1 -j"$off" -N1 "$1" 2>/dev/null | tr -d ' \n')
        [ -n "$b" ] || return 1
        i=$((i + 1))
        if [ $i -le 4 ]; then
            w=$(((w << 8) | b))
        else
            h=$(((h << 8) | b))
        fi
    done
    echo "$w $h"
}

# Tag for the output dir: name@zoom, plus +pan / +rot when those are used.
view_tag() {
    d=$1; shift
    name=$(basename "$d"); name=${name%.art}
    z=1
    extra=""
    prev=""
    for a in "$@"; do
        case "$prev" in
            --zoom)   z=$a ;;
            --pan)    extra="$extra+pan" ;;
            --rotate) extra="$extra+rot" ;;
        esac
        prev=$a
    done
    echo "$name@$z$extra"
}

# render <mode off|default> <dir> <doc-copy> [view args...]
# The command line is echoed into the log first, so a failure is always attributable.
render() {
    mode=$1; dir=$2; copy=$3; shift 3
    log="$dir/run.log"
    if [ "$mode" = off ]; then
        echo "+ ART_LIVE_SPLAT=0 ART_LIVE_BINTIME=1 $BIN --live-view --viewport $VP${1:+ $*} $(basename "$copy")" >"$log"
        ART_LIVE_SPLAT=0 ART_LIVE_BINTIME=1 "$BIN" --live-view --viewport "$VP" "$@" "$copy" >>"$log" 2>&1
    else
        echo "+ ART_LIVE_SPLAT=<unset>  ART_LIVE_BINTIME=1 $BIN --live-view --viewport $VP${1:+ $*} $(basename "$copy")" >"$log"
        env -u ART_LIVE_SPLAT  ART_LIVE_BINTIME=1 "$BIN" --live-view --viewport "$VP" "$@" "$copy" >>"$log" 2>&1
    fi
}

# check_png <file> <label>: exists, non-empty, and the requested viewport size.
check_png() {
    f=$1; label=$2
    if [ ! -s "$f" ]; then
        echo "FAIL       $label — no PNG written"
        return 1
    fi
    size=$(png_size "$f") || {
        echo "FAIL       $label — $(basename "$f") is not a readable PNG"
        return 1
    }
    if [ "$size" != "${VP%x*} ${VP#*x}" ]; then
        echo "FAIL       $label — PNG is ${size% *}x${size#* }, expected $VP"
        return 1
    fi
    return 0
}

# check_view <doc> [view args...]
check_view() {
    doc=$1; shift
    if [ ! -f "$doc" ]; then
        echo "SKIP       $doc — no such document"
        return 0
    fi
    tag=$(view_tag "$doc" "$@")
    base=$(basename "$doc")
    root="$OUT/$tag"
    rm -rf "$root"

    total_views=$((total_views + 1))
    for mode in off default; do
        dir="$root/$mode"
        if ! mkdir -p "$dir" || ! cp "$doc" "$dir/$base"; then
            echo "FAIL       $tag ($mode) — cannot prepare $dir"
            fail=1
            return 0
        fi
        render "$mode" "$dir" "$dir/$base" "$@"
        rc=$?
        if [ $rc -ne 0 ]; then
            echo "FAIL       $tag ($mode) — art2png exited $rc"
            sed 's/^/           /' "$dir/run.log" | tail -n 6
            fail=1
            return 0
        fi
        if ! check_png "$dir/${base%.art}.live-view.png" "$tag ($mode)"; then
            sed 's/^/           /' "$dir/run.log" | tail -n 6
            fail=1
            return 0
        fi
    done

    off_png="$root/off/${base%.art}.live-view.png"
    def_png="$root/default/${base%.art}.live-view.png"
    off_sha=$(sha_of "$off_png")
    def_sha=$(sha_of "$def_png")
    off_bytes=$(bytes_of "$off_png")
    def_bytes=$(bytes_of "$def_png")

    if grep -q '\[splat' "$root/off/run.log" 2>/dev/null; then
        echo "FAIL       $tag — the splat-off run logged [splat ...]; ART_LIVE_SPLAT=0 did not take"
        fail=1
    fi
    marks=$(sed -n 's/.*\(\[splat [^]]*\]\).*/\1/p' "$root/default/run.log" | sort -u | tr '\n' ' ')
    marks=${marks% }

    if [ "$off_sha" = "$def_sha" ]; then
        [ -n "$marks" ] && splat_views=$((splat_views + 1))
        printf 'IDENTICAL  %-34s %8s B  %s..  %s\n' "$tag" "$off_bytes" \
            "$(echo "$off_sha" | cut -c1-12)" "${marks:-walk (splat declined)}"
        echo "           $root"
    else
        echo "DIFFER     $tag"
        echo "           off     $off_bytes B  $off_sha"
        echo "           default $def_bytes B  $def_sha"
        echo "           $root"
        fail=1
    fi
}

all_views() {
    check_view art/kaos.art
    check_view art/kaos.art --zoom 0.25
    check_view art/kaos.art --zoom 0.05
    check_view art/logo-sketch-s6d5h46e54h_03.art
    check_view art/logo-sketch-s6d5h46e54h_03.art --zoom 0.05
    check_view art/complex.art
    check_view art/complex.art --zoom 0.3
    check_view art/complex.art --zoom 0.05
    check_view art/dots.art --zoom 20
    check_view art/dots.art
}

if [ "$ALL" -eq 1 ]; then
    all_views
elif [ -n "$DOC" ]; then
    set --
    [ -n "$ZOOM" ] && set -- "$@" --zoom "$ZOOM"
    [ -n "$PAN" ] && set -- "$@" --pan "$PAN"
    [ -n "$ROT" ] && set -- "$@" --rotate "$ROT"
    check_view "$DOC" "$@"
else
    usage
    exit 2
fi

echo
if [ "$fail" -ne 0 ]; then
    echo "FAILED — a view differed or did not render as asked. Images and logs: $OUT"
    exit 1
fi
echo "All $total_views views identical ($splat_views with the splat; the rest are walk vs walk)."
echo "Images and logs: $OUT"
