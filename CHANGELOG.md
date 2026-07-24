# Changelog

All notable changes to PhotoEditor are documented here.

## 2.0.0 — 2026-07-24

### Added

- **Metal preview canvas** — the develop view renders the Core Image graph
  directly through `CIRenderDestination` into a Metal layer, eliminating the
  CGImage round-trip and enabling smoother slider scrubbing on ProMotion displays.
- **Full-resolution zoom** — at 100%+ zoom the preview renders from the
  original file in 512 px tiles instead of the 1600 px proxy.
- **EDR display** — extended-linear working space with
  `wantsExtendedDynamicRangeContent` on the Metal layer for HDR-capable displays.
- **Render scheduling** — preview renders coalesce during rapid slider bursts so
  stale frames are dropped instead of queued.
- **Point Color** — sample colours on the photograph and shift their hue,
  saturation, and luminance within a chosen range, folded into the LUT pipeline.
- **Parametric tone curve** — region sliders for highlights, lights, darks, and
  shadows alongside the point curve.
- **Color calibration** — primary hue and saturation sliders for red, green, and
  blue primaries, applied before the mixer.
- **Creative LUT import** — load Adobe `.cube` files as a look stage with
  adjustable intensity.
- **Local colour tools** — masked regions now support grading, mixer bands, and
  per-channel curves through the local colour LUT.
- **ML masking** — on-device Vision subject, person, background, and sky masks
  as composable components with disk cache.
- **Stroke retouch** — brush-stroke heal, clone, and remove regions with
  per-region opacity and feather; content-aware Remove via PatchMatch inpainting
  with automatic source selection for heal.

### Changed

- Thumbnails and test fallbacks still rasterize through a 1600 px proxy; the
  Metal canvas shows the full-res graph when zoomed.

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
