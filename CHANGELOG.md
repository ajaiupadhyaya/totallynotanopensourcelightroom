# Changelog

All notable changes to PhotoEditor are documented here.

## 2.2.0 — 2026-07-26

A second develop engine, opt-in per photo. An already-edited photo keeps
rendering exactly as it always has — Process Version 1 is frozen — until
updated from the new Process badge; new imports start on Process Version 2,
which corrects the specific, measured bugs below.

### Fixed

- **Contrast crushed midtones.** Process Version 1 pivoted contrast around
  linear 0.5 instead of display middle grey, and a midtone could clip to
  solid black or white well before the slider reached either end. Process
  Version 2's contrast pivots at display middle grey and never crushes.
- **Positive Highlights did nothing.** `CIHighlightShadowAdjust`'s highlight
  side was silently a no-op. PV2 retones a guided-filter base/detail split
  instead, so highlights and shadows move tone without haloing across hard
  edges.
- **Whites and Blacks didn't move the frame's actual clipping point.** They
  shaped tone without affecting what the clipping diagnostics measure. PV2's
  soft-knee implementation moves the real point.
- **Saturation and Vibrance destroyed luminance and clipped hue.** +50
  saturation could drop a bright red's display luma from 0.43 to 0.21, and
  channels clipped flat into the gamut wall instead of rolling off. PV2
  scales chroma about the luma axis instead — luma-invariant by
  construction — with an exponential rolloff at the gamut edge, and Vibrance
  now favors muted, non-skin colors over already-vivid and skin-tone ones.
- **White balance's Temperature slider was uniform in Kelvin, not in a
  perceptual unit**, so the same slider distance meant a much bigger shift
  at 3000 K than at 8000 K. PV2's Bradford adaptation is parameterized in
  mired, so a given slider distance means the same shift anywhere on the
  range.
- **Grain was measured in output pixels**, so the same Amount and Size
  looked different at every preview and export resolution and wasn't
  reproducible between renders. PV2's grain is a deterministic,
  frame-relative lattice: identical across preview, export, and resolution.

### Added

- **RAW files are edited in the sensor domain.** White balance, exposure,
  and a new **Raw Boost** slider (0–100; Apple's baseline RAW rendering
  lift — 100 is the default look, 0 the flat linear render) now run on the
  sensor data through `CIRAWFilter` before the rest of the develop stack
  sees a rendered image, instead of every RAW being flattened to its
  default render before any edit could reach it. A RAW's as-shot white
  balance is read from the file and used as that photo's starting
  Temperature/Tint, instead of an assumed 6500 K.
- **Vignette gained Roundness, Feather, and Highlights sliders**, alongside
  the existing Amount and Midpoint: shape from rectangular to circular,
  falloff width, and how far a bright area can punch back through a
  darkened corner.
- **The develop panel shows a Process badge** on any photo still on the
  original engine, with an Update button. Updating snapshots the current
  look first — the Process Version 1 result stays one click away in
  Snapshots — then switches the engine; it's a normal, undoable edit like
  any slider.
- **A Lightroom parity harness** (`docs/PARITY.md`) measures PV2's sliders
  against Lightroom CC in ΔE2000 from manually exported reference photos.
  Developer-facing; not part of the app's UI.

### Changed

- New imports start on Process Version 2 instead of 1. Existing catalog
  entries are unaffected until updated from the Process badge.

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
