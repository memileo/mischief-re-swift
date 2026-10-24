#!/bin/sh
# Pixel-identity A/B for one live-view environment knob.
#
# Renders the same document once per value of an env var into its own copy under
# tmp/var-ab/<doc>@<zoom>/<value>/ and compares the `.live-view.png` SHA-256s. Use it for
# knobs whose only claim is "same pixels, less work" (ART_LIVE_SATURATE, ART_LIVE_PERTILE,
# ART_LIVE_STROKE_PRUNE, ...): identical hashes = the lever only removed provably-dead work.
#
# Usage:
#   Scripts/live-var-ab.sh [--var NAME] [--values A,B] [--viewport WxH] [--zoom Z]
#                          [--pan X,Y] [--rotate DEG] <doc.art> [doc.art ...]
# Defaults: --var ART_LIVE_SATURATE, --values 1,0, --viewport 1920x1080, --zoom 1.
# Env: ART2PNG (binary, default .build/release/art2png),
#      ART_VAR_AB_OUT (output dir, default tmp/var-ab)
# Exit: 0 identical, 1 differ/failed run, 2 bad usage.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN=${ART2PNG:-$ROOT/.build/release/art2png}
OUT=${ART_VAR_AB_OUT:-$ROOT/tmp/var-ab}

VAR=ART_LIVE_SATURATE
VALUES=1,0
VP=1920x1080
ZOOM=1
PAN=""
ROTATE=""
DOCS=""

die() { echo "live-var-ab: $*" >&2; exit 2; }

usage() { sed -n '9,15p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --var)      [ $# -ge 2 ] || die "--var needs a name"; VAR=$2; shift 2 ;;
        --values)   [ $# -ge 2 ] || die "--values needs a list"; VALUES=$2; shift 2 ;;
        --viewport) [ $# -ge 2 ] || die "--viewport needs WxH"; VP=$2; shift 2 ;;
        --zoom)     [ $# -ge 2 ] || die "--zoom needs a number"; ZOOM=$2; shift 2 ;;
        --pan)      [ $# -ge 2 ] || die "--pan needs X,Y"; PAN=$2; shift 2 ;;
        --rotate)   [ $# -ge 2 ] || die "--rotate needs degrees"; ROTATE=$2; shift 2 ;;
        -*)         die "unknown option '$1' — see --help" ;;
        *)          DOCS="$DOCS $1"; shift ;;
    esac
done

[ -n "$DOCS" ] || die "no document given — see --help"
[ -n "$VAR" ] || die "empty --var"
[ -n "$OUT" ] && [ "$OUT" != "/" ] || die "refusing an empty/root output dir"
[ -x "$BIN" ] || die "art2png not found at $BIN (build: swift build -c release)"

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

# Extra render arguments, built once (no word-splitting surprises on empty PAN/ROTATE).
set -- --live-view --viewport "$VP" --zoom "$ZOOM"
[ -n "$PAN" ] && set -- "$@" --pan "$PAN"
[ -n "$ROTATE" ] && set -- "$@" --rotate "$ROTATE"
VIEWARGS="$*"

status=0
for doc in $DOCS; do
    [ -f "$doc" ] || die "no such document: $doc"
    base=$(basename "$doc" .art)
    dir="$OUT/$base@${ZOOM}${PAN:+_$PAN}"
    hashes=""
    for value in $(printf '%s' "$VALUES" | tr ',' ' '); do
        slot="$dir/v$(printf '%s' "$value" | tr -c 'A-Za-z0-9_.-' '_')"
        mkdir -p "$slot" || die "cannot create $slot"
        cp "$doc" "$slot/$base.art" || die "cannot copy $doc"
        log="$slot/run.log"
        {
            echo "+ $VAR=$value $BIN $VIEWARGS $base.art"
            # shellcheck disable=SC2086
            env "$VAR=$value" "$BIN" $VIEWARGS "$slot/$base.art"
        } >"$log" 2>&1 || { echo "run failed ($VAR=$value) — $log:" >&2; tail -5 "$log" >&2; exit 1; }
        png="$slot/$base.live-view.png"
        check_png "$png" "$VAR=$value" || exit 1
        h=$(sha "$png")
        echo "  $VAR=$value: $h"
        hashes="$hashes $h"
    done
    set -- $hashes
    first=$1
    shift
    for h in "$@"; do
        if [ "$h" != "$first" ]; then
            echo "DIFFER!!: $doc${ZOOM:+ @zoom $ZOOM} — $VAR=$VALUES not byte-equal (see $dir)"
            status=1
            continue 2
        fi
    done
    echo "IDENTICAL: $doc${ZOOM:+ @zoom $ZOOM} — $VAR=$VALUES all byte-equal"
done
exit $status
