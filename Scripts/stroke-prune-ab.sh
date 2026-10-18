#!/bin/sh
# A/B pixel-identity check for the composite stroke-box pruning:
# runs art2png live-view twice per view (ART_LIVE_STROKE_PRUNE=0 vs default),
# then byte-compares the produced PNGs. Output must be IDENTICAL.
#
# Usage: sh Scripts/stroke-prune-ab.sh <doc.art> <viewport> [zoom]
#   e.g.  sh Scripts/stroke-prune-ab.sh art/kaos.art 1920x1080
#         sh Scripts/stroke-prune-ab.sh art/kaos.art 1920x1080 0.05
#
# The tool writes <doc-dir>/<name>.live-view.png each run; we copy them aside.
set -e
DOC="$1"; VP="$2"; ZOOM="${3:-}"
cd "$(dirname "$0")/.."
B=.build/release/art2png
BASE="${DOC%.*}.live-view.png"
TAG="$(basename "${DOC%.*}")|${ZOOM:-regular}"   # display tag (dots escaped below)
TAG="$(echo "$TAG" | tr '|' ' ')"

run() {
  mode="$1"; out="$2"
  if [ -n "$ZOOM" ]; then
    ART_LIVE_STROKE_PRUNE="$mode" "$B" --live-view --viewport "$VP" --zoom "$ZOOM" "$DOC" >/dev/null
  else
    ART_LIVE_STROKE_PRUNE="$mode" "$B" --live-view --viewport "$VP" "$DOC" >/dev/null
  fi
  cp "$BASE" "$out"
}

run 0 /tmp/prune-off.png
run 1 /tmp/prune-on.png
if cmp -s /tmp/prune-off.png /tmp/prune-on.png; then
  echo "IDENTICAL: $(basename "${DOC%.*}") ${ZOOM:+zoom $ZOOM}"
else
  echo "DIFFER!!: $(basename "${DOC%.*}") ${ZOOM:+zoom $ZOOM}"
  cmp /tmp/prune-off.png /tmp/prune-on.png | head -3
fi
