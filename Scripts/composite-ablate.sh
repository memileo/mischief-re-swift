#!/bin/sh
# Time attribution for the live per-tile composite kernel (ART_LIVE_ABLATE).
#
# `livePerTileAACompositeKernel` is one dispatch, and AMD + Metal has no per-line shader
# counters. Each ablation bit instead removes exactly one stage behind a dispatch-uniform
# branch, so the delta against bit 0 is that stage's cost:
#
#   bit 0   nothing removed           (the shipping kernel)
#   bit 1   no SDF                    (distance field + coverage)
#   bit 2   prune rejects all         (loop + tile-list/segment loads + block table)
#   bit 4   no per-stroke blend       (8-bit quantise + source-over)
#   bit 8   no pixel write
#   bit 16  constant segment address  (the 64-byte per-iteration segment load)
#
# Every bit but 0 produces wrong pixels by construction — this is a timer, not an A/B
# (use stroke-splat-ab.sh for identity). Each view renders from a private copy of the
# document under tmp/, with one warmup frame, so the numbers are steady state.
#
# Usage: Scripts/composite-ablate.sh [--viewport WxH] [--zoom Z] [--pan X,Y]
#                                  [--rotate DEG] [doc.art]
# Defaults: art/kaos.art at zoom 1, viewport 1920x1080.
# Env: ART2PNG (binary, default .build/release/art2png),
#      ART_ABLATE_OUT (output dir, default tmp/ablate — project-local and gitignored).
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN=${ART2PNG:-$ROOT/.build/release/art2png}
OUT=${ART_ABLATE_OUT:-$ROOT/tmp/ablate}

VP=1920x1080
ZOOM=1
PAN=""
ROTATE=""
DOC="$ROOT/art/kaos.art"

die() {
    echo "composite-ablate: $*" >&2
    exit 2
}

usage() {
    sed -n '19,22p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --viewport) [ $# -ge 2 ] || die "--viewport needs WxH"; VP=$2; shift 2 ;;
        --zoom)     [ $# -ge 2 ] || die "--zoom needs a number"; ZOOM=$2; shift 2 ;;
        --pan)      [ $# -ge 2 ] || die "--pan needs X,Y"; PAN=$2; shift 2 ;;
        --rotate)   [ $# -ge 2 ] || die "--rotate needs degrees"; ROTATE=$2; shift 2 ;;
        -*)         die "unknown option '$1' — see --help" ;;
        *)          DOC=$1; shift ;;
    esac
done

[ -n "$OUT" ] && [ "$OUT" != "/" ] || die "refusing an empty/root output dir"
[ -x "$BIN" ] || die "art2png not found at $BIN (build: swift build -c release)"
[ -f "$DOC" ] || die "no such document: $DOC"

base=$(basename "$DOC" .art)
mkdir -p "$OUT" || die "cannot create $OUT"

# Render arguments, built once; empty PAN/ROTATE must not become stray words.
set -- --live-view --viewport "$VP" --zoom "$ZOOM" --warmup 1
[ -n "$PAN" ] && set -- "$@" --pan "$PAN"
[ -n "$ROTATE" ] && set -- "$@" --rotate "$ROTATE"
VIEWARGS="$*"

printf '%-4s %-12s %s\n' bit render+comp livebin
for bit in 0 1 2 4 8 16; do
    dir="$OUT/$bit"
    mkdir -p "$dir" || die "cannot create $dir"
    cp "$DOC" "$dir/$base.art" || die "cannot copy $DOC"
    log="$dir/run.log"
    # art2png writes <input>.live-view.png next to its input, i.e. next to this copy.
    {
        echo "+ ART_LIVE_ABLATE=$bit ART_LIVE_BINTIME=1 $BIN $VIEWARGS $base.art"
        # shellcheck disable=SC2086
        ART_LIVE_ABLATE=$bit ART_LIVE_BINTIME=1 "$BIN" $VIEWARGS "$dir/$base.art"
    } >"$log" 2>&1 || {
        echo "run failed for bit $bit — $log:" >&2
        tail -5 "$log" >&2
        exit 1
    }
    # Two frames run (warmup + measured): the last line of each kind is the steady state.
    line=$(grep '^livebin layer 0:' "$log" | tail -1)
    if [ -z "$line" ]; then
        echo "no livebin line for bit $bit (is ART_LIVE_BINTIME honoured?) — $log:" >&2
        tail -5 "$log" >&2
        exit 1
    fi
    ms=$(printf '%s\n' "$line" | sed -n 's/.*render+comp \([0-9]*\.[0-9]*\) ms.*/\1/p')
    printf '%-4s %-12s %s\n' "$bit" "${ms:-?}" "$line"
    grep '^Live view:' "$log" | tail -1 | sed 's/^/     /'
done

echo
echo "Deltas: (0 - 1) SDF | (0 - 4) blend | (0 - 8) write | (0 - 16) segment load | 2 = loop/loads floor"
