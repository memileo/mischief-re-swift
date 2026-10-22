#!/bin/sh
# Pixel-identity A/B for the composite stroke-block table (ART_LIVE_STROKE_PRUNE).
#
# Modes:
#   0  table disabled          (the plain segment walk)
#   1  default                 (built only when it can pay for itself — the usability gate)
#   2  table forced            (built regardless of the gate; measurement escape hatch)
#
# All modes must produce byte-identical PNGs: the table only decides which provably-empty
# work is skipped, never what is painted. 0-vs-1 proves the gate's "declined" path is
# identical on views where it declines; 1-vs-2 proves the built table is identical.
#
# Each render uses its own copy of the document under tmp/prune-ab/<mode>/, because art2png
# writes <input>.live-view.png next to its input. SHA-256 is the comparison.
#
# Usage:
#   Scripts/stroke-prune-ab.sh [--viewport WxH] [--zoom Z] [--modes 0,1,2] <doc.art>
# Defaults: --viewport 1920x1080, --zoom 1, --modes 0,1.
# Env: ART2PNG (binary, default .build/release/art2png),
#      ART_PRUNE_AB_OUT (output dir, default tmp/prune-ab)
# Exit: 0 identical, 1 differ/failed run, 2 bad usage.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN=${ART2PNG:-$ROOT/.build/release/art2png}
OUT=${ART_PRUNE_AB_OUT:-$ROOT/tmp/prune-ab}

VP=1920x1080
ZOOM=1
MODES=0,1
DOC=""

die() { echo "stroke-prune-ab: $*" >&2; exit 2; }

usage() { sed -n '16,21p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --viewport) [ $# -ge 2 ] || die "--viewport needs WxH"; VP=$2; shift 2 ;;
        --zoom)     [ $# -ge 2 ] || die "--zoom needs a number"; ZOOM=$2; shift 2 ;;
        --modes)    [ $# -ge 2 ] || die "--modes needs a list"; MODES=$2; shift 2 ;;
        -*)         die "unknown option '$1' — see --help" ;;
        *)          DOC=$1; shift ;;
    esac
done

[ -n "$DOC" ] || die "no document given — see --help"
[ -n "$OUT" ] && [ "$OUT" != "/" ] || die "refusing an empty/root output dir"
[ -x "$BIN" ] || die "art2png not found at $BIN (build: swift build -c release)"
[ -f "$DOC" ] || die "no such document: $DOC"

base=$(basename "$DOC" .art)
mkdir -p "$OUT" || die "cannot create $OUT"

# png_size <file>: "W H" from the IHDR (big-endian u32 pair at bytes 16…23).
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

sha() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        sha256sum "$1" | awk '{print $1}'
    fi
}

# check_png <file> <label>
check_png() {
    [ -s "$1" ] || { echo "  $2: missing/empty PNG ($1)" >&2; return 1; }
    size=$(png_size "$1") || { echo "  $2: not a readable PNG ($1)" >&2; return 1; }
    want="${VP%x*} ${VP#*x}"
    [ "$size" = "$want" ] || {
        echo "  $2: PNG is ${size% *}x${size#* }, wanted $VP" >&2
        return 1
    }
}

hashes=""
for mode in $(printf '%s' "$MODES" | tr ',' ' '); do
    case "$mode" in 0|1|2) ;; *) die "bad mode '$mode' (0, 1 or 2)" ;; esac
    dir="$OUT/$base@${ZOOM}/$mode"
    mkdir -p "$dir" || die "cannot create $dir"
    cp "$DOC" "$dir/$base.art" || die "cannot copy $DOC"
    log="$dir/run.log"
    {
        echo "+ ART_LIVE_STROKE_PRUNE=$mode $BIN --live-view --viewport $VP --zoom $ZOOM $base.art"
        ART_LIVE_STROKE_PRUNE="$mode" "$BIN" --live-view --viewport "$VP" \
            --zoom "$ZOOM" "$dir/$base.art"
    } >"$log" 2>&1 || { echo "run failed (mode $mode) — $log:" >&2; tail -5 "$log" >&2; exit 1; }
    png="$dir/$base.live-view.png"
    check_png "$png" "mode $mode" || exit 1
    h=$(sha "$png")
    echo "  mode $mode: $h"
    hashes="$hashes $h"
    grep -h 'prune table skipped' "$log" | sed 's/^/    /' || true
done

set -- $hashes
first=$1
shift
for h in "$@"; do
    if [ "$h" != "$first" ]; then
        echo "DIFFER!!: $DOC ${ZOOM:+@zoom $ZOOM} — PNGs differ (see $OUT)"
        exit 1
    fi
done
echo "IDENTICAL: $DOC${ZOOM:+ @zoom $ZOOM} — $(printf '%s' "$MODES" | tr ',' ' ') all byte-equal"
