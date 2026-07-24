# Changelog

All notable changes to PhotoEditor are documented here.

## 1.3.0 — 2026-07-21

### Added

- Masks are now built from components combined with add, subtract, and
  intersect, so a tonal range can be intersected with a gradient and a painted
  area subtracted from the result.
- Luminance range masks: select a band of tones with an adjustable falloff.
- Colour range masks: sample a colour on the photograph and select everything
  within a tolerance of it.
- Per-component refinement — blur, and expand or contract — plus per-component
  invert alongside the existing whole-mask invert.
- A red mask overlay (⌘⇧M) for tuning a selection you would otherwise not be
  able to see.

### Changed

- With a mask selected, the Brush and Gradient tools add a component to it
  instead of always starting a new mask.

### Notes

- Masks from earlier versions load unchanged as single-component selections.

## 1.2.1 — 2026-07-21

### Fixed

- The tool rail advertised a single-key shortcut in every tooltip — `B` for
  brush, `C` for crop, and so on — but none of them were bound. All eight now
  work, and they yield to text fields, so typing in search or naming a preset
  no longer risks switching tools.
- Comparing with `\` no longer commits an in-progress crop or changes the tool
  in hand; it is a momentary look at the original again.
- Opening a different frame resets the tool rail instead of inheriting the
  previous frame's tool while the canvas is not in that mode.

## 1.2.0 — 2026-07-21

### Added

- Resolution-independent painted brush masks with adjustable size, feather,
  and flow.
- Dedicated Adjust, Masks, and clickable History workspaces.
- A stable canvas tool rail with context-sensitive controls for crop, retouch,
  brush, gradient, eyedropper, and comparison tools.
- Highlight and shadow clipping diagnostics.
- A compact canvas status rail for zoom, profile, dimensions, and developed or
  original state.

### Improved

- Reworked the editor into a focused three-pane darkroom instrument with a
  graphite, blue, and amber visual system.
- Strengthened editing hierarchy, spacing, typography, separators, hover
  feedback, and keyboard navigation.
- Made committed edit states visible and directly restorable while preserving
  undo and redo behavior.
- Made virtual-copy ordering deterministic during rapid imports.
- Expanded local-adjustment and history test coverage.
