# Composable masks: luminosity, color range, and set algebra

Date: 2026-07-21
Status: approved, ready for implementation planning

## Why

The app has linear, radial, and brush masks. Each local adjustment carries
exactly one of them. That is Lightroom's older model, and it is the ceiling on
what local work can express here.

What separates Photoshop from Lightroom for a photographer is not more sliders.
It is that a selection can be *built* — a tonal range intersected with a
gradient, minus a painted area — and derived from the image's own content
rather than drawn by hand over it. This spec brings that model in.

Two capabilities do the work:

- **Generated masks** — select by luminance band or by sampled color, so the
  mask follows the subject instead of approximating it with a shape.
- **Set algebra** — add, subtract, and intersect several components into one
  selection.

Both are classical algorithms. Neither uses machine learning, so both stay
inside the `handoff.md` prohibition on AI masking and subject selection.
Quick-select and subject-detect are deliberately excluded for that reason.

## Scope

In scope:

- `MaskComponent` as the unit of selection, with five shapes: `linear`,
  `radial`, `brush`, `luminance`, `colorRange`.
- Combine modes: add, subtract, intersect.
- Per-component refinement: blur, and expand/contract.
- Per-component invert, alongside the existing whole-mask invert.
- Red mask overlay for tuning, preview only.
- Migration of every existing single-shape local adjustment.

Out of scope, deliberately:

- **Blend modes** per adjustment (multiply, screen, soft light). Additive, and
  they need no schema change, so they are a clean second cycle.
- **Shared masks** across adjustments. Normalizing masks into their own table
  buys reuse nothing in the current UI asks for, at the cost of indirection and
  delete-lifecycle handling.
- Layers, painterly tools, blur gallery. Separate cycles.

## Data model

New file `Sources/Models/MaskComponent.swift`.

```swift
/// Blur and grow/shrink applied to one component's mask before it is
/// combined. Per component rather than per mask because edge character
/// differs by kind: a brush is already soft, a luminance band is not.
struct MaskRefinement: Codable, Equatable {
    var blur = 0.0    // 0...1, relative to min(extent.width, extent.height)
    var shift = 0.0   // -1...1, expand positive / contract negative
}

/// One piece of a built selection.
struct MaskComponent: Codable, Equatable, Identifiable {
    enum Shape: String, Codable { case linear, radial, brush, luminance, colorRange }
    enum Combine: String, Codable { case add, subtract, intersect }

    var id = UUID()
    var shape: Shape = .linear
    var combine: Combine = .add
    var isEnabled = true
    var isInverted = false
    var refine = MaskRefinement()

    // Linear
    var start = CGPoint(x: 0.5, y: 0.8)
    var end = CGPoint(x: 0.5, y: 0.4)

    // Radial
    var center = CGPoint(x: 0.5, y: 0.5)
    var radiusX = 0.3
    var radiusY = 0.25
    var feather = 0.5

    // Brush
    var brushStrokes: [BrushStroke] = []
    var brushSize = 0.04
    var brushFeather = 0.65
    var brushFlow = 0.8

    // Luminance range, all 0...1 on the mask source's Rec.709 luma
    var luminanceMin = 0.0
    var luminanceMax = 1.0
    var luminanceFalloff = 0.15

    // Color range
    var sampledColor: MaskColor?      // nil until sampled; component is empty
    var colorTolerance = 0.25
    var colorFalloff = 0.15
}
```

`MaskColor` is a small `Codable` RGB triple in 0...1. `FilmColor` already exists
but belongs to the film subsystem; a separate type keeps the two from coupling.

`LocalAdjustment` keeps its corrections, `isEnabled`, and `isInverted`, and
gains `components: [MaskComponent]`. Its per-shape fields move into the
component. `isInverted` on the adjustment inverts the *composed* mask; the one
on a component inverts only that component. This is the distinction Photoshop
draws between inverting a channel and inverting a selection, and both are
useful.

### Migration

Stacks are JSON in SQLite, so a stack written by 1.2.x has no `components` key.
The lenient decoder on `LocalAdjustment` synthesizes a single-component list
from the legacy `shape`, `start`, `end`, `center`, `radiusX`, `radiusY`,
`feather`, `brushStrokes`, `brushSize`, `brushFeather`, and `brushFlow` keys
when `components` is absent, and leaves it alone when present.

Per the rule already learned in this codebase, `MaskComponent` and
`MaskRefinement` each get their own lenient decoder. A missing key inside a
nested `Codable` otherwise throws and makes the *parent's* fallback swap in
defaults for the whole sub-struct — silently discarding a mask rather than one
field.

This is the only part of the change that rewrites how existing edits
deserialize. Everything else is additive.

## Rendering

Three files, so none of them does too much. `LocalAdjustmentRenderer` is
already 212 lines and would roughly double if the generators landed in it.

- **`Sources/Pipeline/MaskCompositor.swift`** (new) — folds components into one
  grayscale mask.
- **`Sources/Pipeline/RangeMaskBuilder.swift`** (new) — the luminance and
  color-range generators.
- **`Sources/Pipeline/LocalAdjustmentRenderer.swift`** — keeps the spatial
  generators, the corrections, and the final blend.

### Compositing

Components fold left to right over a black (empty) starting image:

| Combine | Operation |
|---|---|
| `add` | `CIMaximumCompositing` |
| `intersect` | `CIMultiplyCompositing` |
| `subtract` | multiply by the component's inverse |

Multiplicative subtract rather than `CISubtractBlendMode` keeps partial
coverage smooth instead of clipping it at zero.

A component whose `isEnabled` is false is skipped. A `colorRange` component
with no `sampledColor` contributes nothing and is skipped, so an
`intersect` against it cannot blank the whole selection before the user has
sampled anything.

Refinement applies to a component before it is combined: blur first
(`CIGaussianBlur`), then shift (`CIMorphologyMaximum` to expand,
`CIMorphologyMinimum` to contract). Blur before morphology, so the shift
operates on a softened edge and produces a smooth grow rather than a
stair-stepped one.

Both radii are stored unit-relative and multiplied by
`min(extent.width, extent.height)` at render time, so refinement — like every
other mask parameter here — lands identically on the preview proxy and the
full-resolution export. `blur` spans 0...1 mapped to 0...10% of that
dimension; `shift` spans -1...1 mapped to ∓5%. Both clamp to at least one
pixel before reaching the filter, since a zero-radius morphology is a no-op
and a sub-pixel Gaussian is wasted work.

### Generators

**Luminance.** Convert the mask source to Rec.709 grayscale with
`CIColorMatrix`, then push it through `CIColorCurves` as a 1-D transfer
function: zero below `luminanceMin`, one between the bounds, zero above
`luminanceMax`, with `luminanceFalloff`-wide smoothstep shoulders at each edge.
Building the curve as sampled data keeps the shape exact and stays on the GPU.

**Color range.** A 64³ `CIColorCube` maps color to mask value by distance from
`sampledColor`, smoothstepped across `colorTolerance` with `colorFalloff`
shoulders. Distance is computed with chroma weighted above luminance, so
sampling a green leaf selects greens across a range of brightness rather than
only leaves at that exact exposure.

Note this is a *sibling* of `ColorCubeBuilder`, not a reuse of it:
`ColorCubeBuilder.makeFilter(for:)` is typed to `ColorSettings` and produces a
color transform, while this produces a mask. The reusable parts are the cube
construction technique, the `smoothstep` helper, and the caching pattern in
`ColorCubeCache` — a parallel cache keyed on
`(sampledColor, tolerance, falloff)` avoids rebuilding 262,144 entries on every
slider tick.

### Mask source

Generated masks read the image **as it enters the local-adjustment stage** —
after global adjustments, before any local one — passed to the compositor as a
separate `maskSource` parameter rather than the running result.

Two consequences, both wanted. Masks do not cascade, so mask #2 does not shift
when mask #1 is edited. And a luminance mask still tracks the photograph you
are actually looking at, because global exposure and contrast are already
applied to the source.

## Overlay

`EditorModel.isShowingMaskOverlay`, following `isShowingBefore` and
`isFocusPeakingEnabled` exactly: a stored property with
`didSet { renderPreview() }`.

When on, the selected adjustment's composed mask tints the preview red. A
generated mask is invisible otherwise — a luminance band cannot be tuned by
looking at the photograph, only at the selection — so this is required for the
feature to be usable, not a convenience.

It is a viewing aid. It must never reach `ExportService`, and a test asserts
that directly.

## UI

All within the existing MASKS workspace of `InspectorPanel`, in the established
`PanelSection` / engraved-label / drawn-fader vocabulary. No stock macOS
controls.

- The mask list (local adjustments) stays as it is.
- Selecting a mask reveals its **component list**: one row per component with a
  combine glyph (`+`, `−`, `∩`), the shape name, an enable dot, and a delete
  control.
- An **add component** row offers Linear, Radial, Brush, Luminance, Color Range.
- Selecting a component reveals its controls, in a new
  `Sources/Views/SliderPanel/MaskComponentPanel.swift`:
  - *Luminance* — range faders drawn over the histogram, plus falloff.
  - *Color range* — a color swatch, a Sample button, tolerance, falloff.
  - *Linear, radial, brush* — the controls that exist today.
  - *All* — combine mode, invert, refine blur, refine shift.

Sampling arms the existing `CanvasPicker` mechanism with a new
`.colorRangeSample` case, alongside `whiteBalance`, `filmBase`, and
`retouchPlace`. No new canvas interaction model.

In the tool rail, Brush and Gradient add a *component* to the selected mask
instead of always creating a new mask. Creating a new mask stays available from
the panel. This changes shipped 1.2.1 behavior and is called out in the
changelog.

## Testing

- `MaskComponent` and `MaskRefinement` round-trip through `Codable`.
- **Legacy migration**: a real 1.2.x `EditStack` JSON blob decodes into
  one-component masks with geometry preserved. This is the highest-value test
  in the set.
- Compositor set algebra: add, subtract, and intersect produce the expected
  coverage on synthetic images.
- A disabled component, and an unsampled `colorRange` component, are both
  skipped rather than blanking the selection.
- Luminance mask selects its band and spares tones outside it.
- Color range mask selects the sampled color and spares others.
- Refinement: blur softens an edge; positive shift grows coverage and negative
  shrinks it.
- Generated masks are resolution independent, following the existing brush
  test — the same mask at 200px and 1000px selects the same relative region.
- The overlay never changes exported pixels.

## Risks

**Migration** is the only real one. Mitigated by lenient decoders on every
nested type and by the legacy-blob test above.

**Render cost** grows with component count, since each adds filter nodes to the
graph. The color cube is the expensive piece and is cached on its parameters.
Existing `DevelopedSourceCache` behavior is unaffected — masks live downstream
of it.

**UI density** in a 320pt inspector is a real constraint. The component list
and its controls are disclosure-driven: only the selected component expands.
