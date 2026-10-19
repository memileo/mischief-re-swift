#!/bin/sh
# A/B pixel-identity check for splat on/off:
# runs art2png live-view twice per view -- once with ART_LIVE_SPLAT=0
# and once with the variable UNSET entirely (tool default) -- then
# byte-compares the produced PNGs. Output must be IDENTICAL.
#
# Usage: sh Scripts/stroke-splat-ab.sh <doc.art> <viewport> [zoom]
#   e.g.  sh Scripts/stroke-splat-ab.sh art/kaos.art 1920x1080
#         sh Scripts/stroke-splat-ab.sh art/kaos.art 1920x1080 0.05
#
# The tool writes <doc-dir>/<name>.live-view.png each run; we copy them aside.
set -e
DOC="$1"; VP="$2"; ZOOM="${3:-}"
cd "$(dirname "$0")/.."
B=.build/release/art2png
BASE="${DOC%.*}.live-view.png"

run() {
  # mode "0" -> run with ART_LIVE_SPLAT=0  (splat forced off)
  # mode ""  -> run with ART_LIVE_SPLAT unset (tool default behaviour)
  # NB: an empty-string var is NOT the same as an unset var, so we
  # export/unset explicitly instead of using a one-shot env prefix.
  mode="$1"; out="$2"
  if [ -n "$mode" ]; then
    export ART_LIVE_SPLAT="$mode"
  else
    unset ART_LIVE_SPLAT
  fi
  if [ -n "$ZOOM" ]; then
    "$B" --live-view --viewport "$VP" --zoom "$ZOOM" "$DOC" >/dev/null
  else
    "$B" --live-view --viewport "$VP" "$DOC" >/dev/null
  fi
  cp "$BASE" "$out"
}

run 0  /tmp/splat-off.png
run "" /tmp/splat-default.png

if cmp -s /tmp/splat-off.png /tmp/splat-default.png; then
  echo "IDENTICAL: $(basename "${DOC%.*}") ${ZOOM:+zoom $ZOOM} (splat-off == default)"
else
  echo "DIFFER!!: $(basename "${DOC%.*}") ${ZOOM:+zoom $ZOOM} (splat-off vs default)"
  cmp /tmp/splat-off.png /tmp/splat-default.png | head -3
fi