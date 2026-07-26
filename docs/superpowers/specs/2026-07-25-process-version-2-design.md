# Process Version 2: a calibrated tone and color engine

Date: 2026-07-25
Status: approved, ready for implementation planning

## Why

The develop controls do not do what their names promise. This was measured,
not felt: a probe harness fed known sRGB display values through the exact
filter chain `EditRenderer` builds and read back what came out.

- **Contrast +50 sends display tones 0.10–0.40 to 0.000.** `CIColorControls`
  pivots at 0.5 in the *linear working space*, which is display 0.735 — deep
  in the highlights. Everything below deep-highlight territory is pushed down;
  the bottom 40 % of the tonal range clips to black.
- **Highlights is a no-op in the positive direction.** `CIHighlightShadowAdjust`
  documents `highlightAmount` as `0…1`; the renderer feeds it `1.0 + h/100`,
  so every positive slider value clamps to "no change".
- **Saturation destroys luminance and posterizes.** `CIColorControls.saturation`
  in linear space drives a bright red at +50 from (0.90, 0.30, 0.30) to
  (1.00, 0.00, 0.00) — channels slam into the gamut walls and display luma
  falls from 0.43 to 0.21. Saturating a photo makes it darker and coarser.
- **Whites and Blacks cannot clip.** They are a `CIToneCurve` pinned at (0,0)
  and (1,1) with ±0.15 of travel at the quarter-tones. In Lightroom these
  controls *move the white and black points*; here display 1.0 maps to exactly
  1.0 at whites +100, always. A test (`testWhitesAndBlacksActOnOppositeEnds`)
  encodes this inability as intended behavior.
- **Clarity halos catastrophically.** An unsharp mask at radius 30 in linear
  light crushes the dark side of a hard edge from 0.157 to 0.000 across a
  30 px band. (Out of scope for this pass — recorded here so it is not
  mistaken for fixed.)
- **Temperature is ~15× more sensitive at one end.** The slider is uniform in
  Kelvin; perceptual uniformity (and Lightroom's slider) is uniform in mired.
  2000→3000 K is 167 mired; 9000→10000 K is 11.
- **The RAW decode discards the sensor domain.** `ImageDecoder.loadRAW` takes
  `CIRAWFilter.outputImage` at defaults, baking Apple's boost curve and gamut
  mapping into the pixels, then white balance is re-derived downstream from
  those baked pixels with `CITemperatureAndTint`. Every sensor-domain control
  the filter exposes — `neutralTemperature`, `neutralTint`, `exposure`,
  `boostAmount`, `extendedDynamicRangeAmount`, `scaleFactor` — goes unused.
- **Grain is sized in output pixels**, so a 1600 px preview and a 6000 px
  export of the same photo carry visibly different grain.

The root cause is singular: **the pipeline never declares what color space it
computes in.** `EditRenderer` constructs a bare `CIContext()`, inherits a
linear working space, and then runs display-referred operations on
scene-linear numbers. The individual filters are also the nearest built-in
rather than the named control, but fixing them one at a time without fixing
the space would be whack-a-mole.

The existing 281 tests pass because they assert *direction only* ("brighter
than before"), never placement or magnitude.

## Scope

In scope (user-selected):

- **Tone + color core** — exposure, contrast, highlights, shadows, whites,
  blacks, temperature/tint, vibrance, saturation, tone curve.
- **RAW handling** — route scene-domain edits into `CIRAWFilter`; stop baking
  Apple's rendering; preview-sized decode.
- **Effects + optics** — post-crop vignette with roundness/feather/highlight
  priority; resolution-independent deterministic grain.
- **Parity harness** — measured comparison against Adobe Lightroom CC
  (installed on this machine), in CIELAB ΔE2000, per control.
- **Process versioning** — existing edits keep rendering through the frozen
  old code; only new (or explicitly upgraded) photos get the new engine.

Out of scope, explicitly, and still broken after this pass:

- Clarity (still halos), texture, dehaze (still a contrast/saturation
  stand-in), sharpening (no masking control), noise reduction sub-controls.
  Once `LocalTone.ci.metal`'s guided-filter base/detail split exists, clarity
  and texture become ~a day of work on top of it; deferred by user choice.
- Local adjustments, masks, film negative conversion, retouch — untouched.
- Any UI redesign. Slider ranges and labels stay; only the math behind them
  changes. (New vignette sub-controls and the RAW default handling add
  minimal UI, matching existing panel idiom.)

## Architecture

### Two declared spaces, matching Lightroom's own split

| Space | Operations |
|---|---|
| **Scene-linear, wide-gamut, extended range** (unclamped, values may exceed 1.0) | RAW decode, white balance, exposure, highlight rolloff, vignette gain |
| **Display-referred, gamma-encoded** | contrast, whites/blacks, highlights/shadows, tone curve, HSL mixer, vibrance/saturation, grading, grain, histogram |

Every pipeline stage declares its space. Conversions between the two are
explicit, named, and appear exactly where the design says they do — never
implicit in a filter's choice of working space.

Working space candidates, in order: a calibrated linear-ROMM (ProPhoto
primaries, gamma 1.0) `CGColorSpace` built from primaries (no named constant
exists — verified); fall back to `extendedLinearITUR_2020` if Core Image
rejects the custom space as a working space. Phase 0 settles this with a
probe, not an assumption. Intermediate format `RGBAh` minimum.

### Metal kernels — `Sources/Pipeline/Kernels/`

Compiled at build time (`-fcikernel`, `MTLLINKER_FLAGS = -cikernel`; XcodeGen
changes in `project.yml`), loaded via `CIKernel(functionName:fromMetalLibraryData:)`.

- **`Tone.ci.metal`**
  - *Contrast*: pivots at display middle grey (0.5 gamma-encoded), sigmoid
    with cubic-Hermite shoulder so ±100 compresses rather than clips.
  - *Whites/Blacks*: move the clipping points — whites +100 maps a
    progressively lower input to 1.0 with a soft shoulder; blacks −100
    symmetric at the toe. Replaces the pinned-endpoint curve.
  - *Parametric tone curve*: real region weight functions (shadows / darks /
    lights / highlights) rather than five fixed Catmull-Rom points.
- **`LocalTone.ci.metal`**
  - *Highlights/Shadows*: base/detail decomposition. `CIGuidedFilter`
    (verified halo-free on a hard edge: base stays a step, Gaussian smears to
    a ramp) produces the base; the kernel applies tone-region-weighted gain
    to the base only; detail layer recombines untouched. This is the halo-free
    property Adobe gets from Local Laplacian, by a cheaper native route.
- **`Color.ci.metal`**
  - *Temperature/tint*: Bradford chromatic adaptation through XYZ,
    parameterized in mired internally (Kelvin in the UI), applied in
    scene-linear space — or routed to the RAW filter's sensor-domain
    neutral when the source is RAW.
  - *Vibrance*: gain weighted by (1 − saturation), attenuated over the skin
    hue band.
  - *Saturation*: holds display luminance constant; soft rolloff approaching
    the gamut boundary instead of channel clipping.
- **`Effects.ci.metal`**
  - *Vignette*: superellipse distance field over the **cropped** extent;
    amount, midpoint, roundness, feather, highlight-priority (applied in
    scene-linear so recovered highlights punch through the darkening).
  - *Grain*: deterministic value noise, seeded per photo, sized as a fraction
    of frame dimension — identical structure at preview and export size.

`EditRenderer` keeps its shape (pure chain assembly, testable without
rasterizing); stages swap their implementation. The one-LUT color pipeline
(`ColorCubeBuilder`) survives — it is the right architecture — but its inputs
are corrected (e.g. luminance-preserving saturation feeding it).

### RAW path — `SourceImage`

A source type with two cases replaces "CIImage in, provenance lost":

```
enum SourceImage {
  case raw(CIRAWFilter)      // sensor domain available
  case rendered(CIImage)     // JPEG/HEIC/TIFF — display-referred origin
}
```

For `.raw`:
- White balance → `neutralTemperature` / `neutralTint` (as-shot values read
  from the filter become the stack's WB defaults, so a freshly imported RAW
  shows its true as-shot temperature instead of assumed 6500 K).
- Exposure → `CIRAWFilter.exposure` (scene-referred, pre-demosaic-rendering).
- `boostAmount = 0` — Apple's baked contrast curve would fight our tone stack.
- `isGamutMappingEnabled = false`, `extendedDynamicRangeAmount` raised —
  keep out-of-gamut and >1.0 highlight data alive into the chain.
- `scaleFactor` for preview decode — decode at preview size rather than
  decode-full-then-downsample.

Because `boostAmount = 0` renders flatter than Apple's default, PV2 RAW
imports get a neutral baseline tone lift in the stack (visible, adjustable,
honest) rather than an invisible baked one. For `.rendered`, scene-domain
stages run on linearized pixels as before — correctly spaced this time.

### Parity harness

The measuring instrument that turns "calibrated" from an adjective into a
number. Key trick: **Lightroom's own neutral render is our input.** For each
reference photo, Lightroom exports a neutral TIFF (all sliders zero) plus one
export per (control, value) pair. Our tests feed the *neutral* export through
our stack with that control set and compare against Lightroom's corresponding
export. Adobe's proprietary camera profile appears on both sides and cancels;
what remains is purely the slider math.

- `scripts/make-parity-presets.swift` — emits the `.xmp` preset set (contrast
  ±50/±100, highlights ±100, shadows ±100, whites ±100, blacks ±100, temp at
  fixed mired offsets, vibrance/saturation ±50/±100, exposure ±1/±2 EV) and a
  manifest mapping preset → expected stack values.
- Manual step (documented in `docs/PARITY.md`, one-time per reference set):
  import the preset folder into Lightroom CC via the presets panel ⋯ menu,
  apply to virtual copies, batch export TIFF.
- `Tests/ParityTests.swift` — per control: mean and max ΔE2000 in CIELAB
  against a per-control tolerance table. Failures print a per-tone-band
  breakdown (shadows/mids/highlights) so a miss says *where*.
- Reference images live under `Tests/Fixtures/Parity/` (small — 512 px
  exports are plenty for ΔE statistics).

Honesty clause: Lightroom's algorithms are proprietary; exact equality is not
achievable and is not claimed. The target is behavioral equivalence within a
stated, per-control ΔE tolerance, ratcheted down as kernels improve. Parity
tests are additionally gated on fixture presence, so the suite passes (with a
skip notice) on a machine without the exports.

### Process versioning

`EditStack.processVersion: Int` (lenient-decoded, default 1). Photos with
existing edits stay at 1 and render through today's code, moved verbatim into
`LegacyToneRenderer.swift` and frozen — bugs and all, because those bugs are
now part of what those edits *look like*. New imports (and untouched photos)
get 2. A per-photo "Update to Process Version 2" action in the UI performs
the explicit opt-in, snapshotting first (the snapshot system already exists).
Nothing is deleted; no existing edit silently changes appearance. This is
Lightroom's own answer to the same problem, and the archive-don't-delete
rule applied to rendering behavior.

### Tests that would have caught this

New tests assert placement and magnitude, not direction:

- Contrast pivot sits within 2 % of display 0.5; a ±100 sweep never sends a
  mid-ramp tone to 0.0 or 1.0.
- Highlights +N and −N both move a highlight patch, monotonically in N.
- Whites +100 drives the top of a ramp to ≥ 0.995 (it can clip); blacks −100
  symmetric at 0.
- Equal slider travel produces equal mired change at both ends of the
  temperature range.
- Saturation ±50 changes display luma of any patch by < 0.01.
- Grain structure at 1600 px and 6400 px renders of the same photo correlates
  after downsampling (resolution independence).
- Probe harness from this investigation becomes `Tests/CalibrationTests.swift`
  — the display-in/display-out tables, asserted.

The direction-only tests that encode wrong behavior
(`testWhitesAndBlacksActOnOppositeEnds` and kin) are updated to assert the
PV2 semantics against the PV2 renderer, and pinned as-is against
`LegacyToneRenderer` so the frozen path stays frozen.

## Delivery order

0. **Probes** — working-space viability (custom linear-ROMM vs
   extendedLinear2020), CIRAWFilter behavior with boost 0 + EDR on a real
   RAW, kernel build config proof (one trivial `.ci.metal` through XcodeGen).
1. **Space plumbing** — explicit `CIContext` configuration, conversion
   points, process-version scaffolding, `LegacyToneRenderer` freeze.
2. **`Tone.ci.metal`** + calibration tests (contrast, whites/blacks,
   parametric curve).
3. **`LocalTone.ci.metal`** (highlights/shadows) + calibration tests.
4. **`Color.ci.metal`** (WB, vibrance, saturation) + calibration tests.
5. **RAW path** (`SourceImage`, sensor-domain routing, preview scaleFactor).
6. **Effects** (vignette sub-controls, deterministic frame-relative grain).
7. **Parity harness** — preset generator, `PARITY.md`, `ParityTests` (gated
   on fixtures; user performs the one-time Lightroom export).
8. **UI touch-ups** — process-version badge + upgrade action, vignette
   sub-controls, as-shot WB display for RAW.

Each phase lands with its tests green before the next begins.

## Risks

- **Custom working space rejection**: if Core Image refuses the calibrated
  linear-ROMM space, `extendedLinearITUR_2020` covers ~99.9 % of ProPhoto in
  practice; decided by probe in phase 0.
- **CIGuidedFilter cost at full resolution**: guided filter is O(N) and
  Apple's is Metal-backed; if export-size renders regress, the base is
  computed at a capped resolution and upsampled with
  `CIEdgePreserveUpsampleFilter` (shipped for exactly this).
- **Kernel build config under XcodeGen**: `-fcikernel` + `MTLLINKER_FLAGS`
  are settings-level flags, expressible in `project.yml`; proven in phase 0
  before anything depends on it.
- **Parity fixtures block the harness**: mitigated by gating — everything
  except the final numbers works without the exports, and calibration tests
  (which need no Lightroom) carry the correctness load meanwhile.
