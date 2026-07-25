# Changelog

All notable changes to PhotoEditor are documented here.

## 2.1.0 — 2026-07-25

A correctness pass over the 2.0 rendering work, and a rebuild of the interface
to the standard the rest of the app was already held to.

### Fixed

- **The preview was torn.** 2.0's tiled preview replayed the whole develop
  stack against each 512 px tile, so every stage that measures the frame —
  crop, straighten, perspective, vignette, grain, masks — resolved against a
  tile instead of the photograph. The tiles then composited as offset bands.
  Because the trigger was "longest edge over 1024 px", this affected *every*
  photograph at *every* zoom, not just magnified ones. The graph is no longer
  tiled by hand; Core Image already tiles internally when it rasterizes.
- **The canvas rendered upside down.** The Metal destination was not marked as
  flipped, so the photograph appeared inverted relative to its own thumbnail.
- **Histograms were measured in linear light.** Core Image's working space puts
  sRGB 50 % grey at 0.21, so an ordinary exposure crushed into the left of the
  graph and a normally-lit frame reported around 28 % shadow clipping. The
  histogram and the clipping diagnostics are now measured in display space.
- **A clipped spike no longer flattens the histogram.** A frame with a black
  surround piles a third of its pixels into the bottom bin; the graph now scales
  to the picture rather than to that spike. Clipping is still reported exactly,
  separately, by the diagnostics.
- **Missing thumbnails are repaired.** A thumbnail that failed to generate at
  import stayed an empty placeholder forever, because nothing ever tried again.
  Missing thumbnails are now rebuilt on launch, and refreshing one records where
  it was written — which the previous code did not, so applying a preset wrote a
  thumbnail the library then ignored.
- **The Metal canvas built a command queue every frame** instead of once.

### Changed

- **The canvas is viewport-sized.** It used to be as large as the zoomed image,
  which asked Metal for a drawable the size of the photograph — multiple
  gigabytes on a large frame, for a picture of which the screen shows a sliver.
  Zooming now costs the same as not zooming, and dragging pans the frame.
- **Two type voices, split by meaning.** Monospace is now reserved for things
  that are *measured* — values, dimensions, frame numbers, exposures — so digits
  hold their column. Everything a person reads is set in the system text face.
  The interface was previously monospaced throughout, which flattened every
  label, value, button and caption to one weight.
- **The develop column is grouped and honestly numbered.** Fourteen pipeline
  stages run 01–14 under four headings instead of thirteen in a flat list with a
  section numbered "09a".
- **The signal chain has a spine.** The stage indices sit in a gutter with a
  hairline running through it, and it lights beside any stage carrying edits —
  so "what have I done to this frame" is answerable without opening anything.
- **Faders are instruments.** A groove, a neutral tick, a lit bar from neutral
  to the current value, and a thumb that responds to the pointer; arrow keys
  nudge, and a reset appears on a row only once there is something to reset.
- **The tool options bar collapses when the tool has no options**, instead of
  spending a strip of the photograph on a sentence of advice.
- **Empty states say what to do**, on the canvas and in both inspector panes.

### Added

- **A menu bar.** File, Edit, View, Develop and Frame, covering import, export,
  virtual copies, undo/redo, copy and paste settings, zoom, panel visibility,
  viewing aids, clipping overlays, workspaces, tools, ratings, flags and colour
  labels. Every one of these was already a keystroke with nowhere to be found.
- **A new app icon**, drawn in code (`scripts/make-app-icon.sh`) so it can be
  reviewed and adjusted like the rest of the interface.

### Removed

- The hand-tiled preview renderer. It is recoverable from history at `4a53e9a`;
  it was not correct at any size.

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
