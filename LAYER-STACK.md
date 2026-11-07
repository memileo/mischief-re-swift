# Layer-Stack View for ArtQuickLook — Plan

Status: **in progress** (basic panel implemented; polish and edge cases remain)

## Goal

Add a layer-stack panel to the ArtQuickLook app (not the Quick Look extension):

- Utility panel listing all of the active document's art-file layers.
- Exclude hidden Sketch layers (free transform pastes) — identified by name
  `"Sketch Layer"` and layers not in `art.layerOrder`.
- Toggle visibility per layer (eye / eye.slash SF Symbols).
- Opacity slider for the selected layer.
- Panel updates to reflect the active document.

## Implemented so far

- `LayerStackModel` (`LiveDocumentWindow.swift`) holds the layer list, selection,
  visibility toggles and opacity edits, mutating the underlying `ArtParser` and
  triggering a re-render.
- `LayerStackView` SwiftUI view with eye/eye.slash toggles and opacity slider.
- `LayerStackPanelController` singleton utility panel (`NSPanel`).
- View menu item "Layer Stack" (⌘⌥L) toggles the panel.
- Renderer interactive path reads current visibility/opacity from `art.layers`
  instead of the cached values, so toggles take effect without rebuilding cache.
- `LiveDocumentSession.art` made mutable so layer edits persist.
