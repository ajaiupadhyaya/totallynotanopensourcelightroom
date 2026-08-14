# Frame Detection — One-Click Auto on Lightbox Scans

**Date:** 2026-08-10
**Status:** Approved design (Phase 3 pull-forward), sequenced after Minilab Task 13
**Why now:** every frame the user actually shoots arrives as a phone photograph of a negative lying on a lightbox. Blind Auto measures the backlight and produces garbage (measured 2026-08-10: deep blue, median luma 0.19 across the Aug 9 corpus); the fix today is a manual crop before Auto, which is exactly the kind of 36-times-per-roll chore the roadmap says to kill. The Minilab engine makes conversions *good*; this makes them good **on the first click**.

## Problem

A lightbox phone scan is three nested regions:

1. **Backlight** — bare panel around the film: near-clipped luminance, and (through no dye at all) bluer than any orange-masked film can be.
2. **Rebate** — the film's clear border: unexposed base, the most reliable Dmin measurement that exists.
3. **Image area** — the dense picture inside the rebate.

Auto's existing gates (clipped-backlight exclusion, film-chroma gate) discard backlight *pixels* from the measured population, but statistics on the survivors still see the frame's composition skewed, and the 98th-percentile Dmin estimate still competes with rebate-adjacent flare. The measured consequence on one roll: per-frame red gamma spread 0.70–2.23 blind vs a coherent solve when cropped to the film.

Hard-won constraint (measured, 2026-08-10, recorded in `RealScanTests`): **"crop to the negative" means masking the lightbox and KEEPING the rebate.** Cropping tight to the picture area removes the unexposed base and drives the solve *worse* than blind (red gamma 3.55, and 6.91 on IMG_7080, vs neutral ≈ 0.66).

## Goals

- `FrameDetector`: deterministic, closed-form, pure-Swift detection of the film rectangle (rebate **included**) on a lightbox scan. No ML, no iteration beyond fixed passes, unit-testable without fixtures.
- Auto uses it: an uncropped scan that looks lightbox-like gets measured through the detected rect **and** the rect is written to `Geometry.crop` in the same undoable gesture — visible, reviewable, adjustable, per the roadmap ("the user reviews it — it writes to Geometry").
- The rebate ring hands `sampledBase` a real base color — through `AutoInvert`'s existing `sampledBase` parameter, the seam its own doc comment reserves for exactly this.
- Scans without a lightbox surround are untouched: the detector returns nil and Auto behaves exactly as today.

## Non-goals

- Straighten-angle estimation (Phase 3 proper; these scans are hand-held but roughly axis-aligned, and Geometry's straighten already exists for the user).
- Multi-frame strip splitting (Phase 3, via virtual copies).
- Any change to solve math, renderVersion semantics, or the frozen paths.

## Design

### FrameDetector (pure core)

```swift
struct DetectedFrame: Equatable {
    /// Unit rect, Core Image bottom-left origin, rebate INCLUDED.
    var rect: CGRect
    /// Fraction of the scan classified as backlight — the caller's gate.
    var backlightFraction: Double
    /// Brightest-percentile linear color of the rebate ring, display-encoded,
    /// nil when the ring is too thin or inconsistent to trust.
    var rebateBase: FilmColor?
}

enum FrameDetector {
    static func detect(pixels: [(Double, Double, Double)], width: Int, height: Int)
        -> DetectedFrame?
    static func detect(scan: CIImage, context: CIContext) -> DetectedFrame?  // wrapper
}
```

- Downsample via the same `linearPixels` path Auto measures through (~128 px long side).
- **Classifier** — two cues, both type-agnostic (a B&W rebate has no orange mask, so no chroma assumption in the core):
  - Log-luma 2-means split (Otsu-style, deterministic): backlight is its own bright mode on every lightbox scan.
  - Near-clip test (`maxChannel` ≥ the backlight level Auto already uses) forces obviously-blown pixels into the backlight class regardless of the split.
- **Rectangle**: per-row and per-column film-fraction profiles; the film box is the longest contiguous run of rows (and columns) with film-fraction ≥ 0.5 that contains the film centroid. Marginal profiles, not connected components: the film area on a lightbox is a solid rectangle, and profiles are robust to dust and holder shadows.
- **Gate**: `backlightFraction < 0.08` → return nil (the scan is already film-filling; nothing to do). Degenerate boxes (< 25% of frame area, or touching zero borders while claiming backlight) → nil. When in doubt, nil — a false negative costs one manual crop; a false positive writes a wrong crop into the user's geometry.

  **Revised 2026-08-13** (measured on the ProRAW corpus). That lower gate read one cause into a measurement with two. Little bare panel in shot means *either* the film fills the frame (nothing to crop) *or* the negative is framed tightly on a dark table — and the second is the scan that most needs cropping. IMG_7178 (7.4%) and IMG_7179 (8.1%) are the same scan on either side of the line; IMG_7201 (5.3%) was refused and rendered blown, because Auto then measured a frame that was four-fifths tabletop. Nor is the false-negative cost one manual crop: it is a blown conversion that carries no warning.

  So the gate becomes a floor of 0.01 (below which there is no backlight signal to bound anything with), and between 0.01 and 0.08 the candidate box must **prove it is backlit**: mean luma inside ≥ 6× mean luma outside. Measured across all three corpora, genuine tight-framed scans run 6.1–35.2× while degenerate slivers run 1.4–5.2× and whole-frame boxes from ordinary photographs 0.8–1.9×. A bare light in a dark room cannot exploit this: its box never outgrows its own backlight, so the area gates refuse it. When the *film* box fails the proof the answer is the looser lightbox box, not nil — the film box gives up exactly the bright rim the ratio is measuring.

  Detection across the 2026-08-13 batch went 17/33 → 30/33, with no frame blown. The three refusals are dense film covering the panel with no bare margin at all: no signal, so nil, and a manual crop.
- **Rebate ring**: the outer 10% band of the detected box. Take the ~98th-percentile linear color of the ring per channel (brightest film = clearest base — Auto's own reasoning, now aimed at actual rebate). Trust it only if the ring's percentile color is not near-clipped (that would be leaked backlight) — otherwise return nil for `rebateBase` and let Auto's statistics run inside the crop.

### Auto wiring (EditorModel)

In `autoConvertNegative`, before measurement, when **all** of: density model, no existing `geometry.crop`, no user-sampled base, and `FrameDetector.detect` returns a frame — then:

1. Measure through the detected rect (the existing crop-aware measurement path).
2. Pass `rebateBase` as `sampledBase` (origin `.estimated` — honest: it is detector-estimated, not user-clicked; the swatch caption says so).
3. Write the rect to `geometry.crop` in the same single `editStack` assignment as the film settings — one undo step reverts the whole gesture, and the crop is visible in the canvas for review.
4. Report `"frame detected — review the crop"` through the solve's degraded-terms channel so the panel caption states provenance.

A user-set crop always wins (the detector never runs); Reset Crop then re-Auto reruns detection. Roll conversion (Task 10's `convertRoll`) measures each frame through its own detection with the same rules.

## Validation

- **Unit (fixtures-free):** composite the `FilmSim` negative onto a synthetic bright surround (both C-41-orange and B&W-neutral rebates) → detector finds the film rect within one downsample cell on every edge; rebate percentile lands on the synthetic base within 2%; a surround-free probe returns nil; a 50%-gray flat field returns nil.
- **Corpus (gated, all three):** detected rect must contain each corpus's hand-measured interior and stay inside the hand-measured film bounds (mf: x 0.25–0.80, top-down y 0.13–0.92; aug9: x 0.13–0.89, y 0.16–0.89). Render aug9 + mf through detection-Auto; artifact grid beside the manual-crop renders; assert median luma lands in the plausible-positive band the manual crops achieve.
- **Human:** the acceptance sheet grows a `detected` column; the user judges it against the manual-crop column.

## Risks

- Holder shadows and table edges darker than backlight classify as film → box too generous. Acceptable by construction: a generous box still masks the lightbox, and Auto's percentile statistics inside the box tolerate slack (the mf demo rect is deliberately loose today).
- A scan whose subject IS mostly white sky could imitate backlight modes. The near-clip cue plus the ≥ 25%-area and centroid-containment gates bound this; failure mode is nil → today's behavior.
- Hand-held perspective skew means the film "rectangle" isn't axis-aligned. The marginal-profile box is the axis-aligned hull — slightly generous, same acceptable direction as above.
