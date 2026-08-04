# Phase 2 — The print engine

Replace the single-matrix negative conversion with a density-domain inversion
followed by a paper response, and put a one-button Auto in front of it.

This is Phase 2 of [PhotoEditor 3.0 — "The Darkroom"](2026-08-02-darkroom-3.0-design.md).
It supersedes that document's Phase 2 section, which described the density
inversion but stopped short of the rendering that makes the result look like a
photograph.

---

## The problem, in two halves

### The inversion cannot fix crossover

The conversion is one `CIColorMatrix`. For a channel with base `b` and gain
`g` it computes `out = -(g/b)·x + g` — mask division, inversion and balance
collapsed into one affine operation on gamma-encoded values.

It is a good first-order inversion and it is genuinely fast. It also has one
gain per channel, and a single gain scales shadows and highlights together. A
scan that is cyan in the shadows and warm in the highlights therefore has no
setting that corrects both: every value of `g` that neutralises one end pushes
the other further out. That is the defining problem of colour negative work and
the matrix model has no term for it.

There is also only one measured reference point. `Dmin` (the film base) is
sampled; the highlight end is assumed. Two unknowns, one measurement.

### A correct inversion still looks bad

This is the half the earlier spec missed, and it is the half the user actually
complained about.

darktable's `negadoctor` implements essentially the density model described
below, and the user's own sidecars show it in use on 59 of these frames. Its
inversion is not wrong. Its *output* is flat, because a density inversion
produces a scene-linear positive and expects you to bring your own tone
mapping — in those sidecars, `sigmoid`. The result reads as plasticky and
desaturated, and highlights walk through a hue as they clip.

What separates that from the rendering people recognise as correct is not the
inversion. It is:

1. **A characteristic curve with a real toe and shoulder.** Photographic paper
   builds density slowly out of paper white, runs straight through the
   midtones, and shoulders into maximum black. That shape is most of why a
   print looks like a print. A pure power function — which is what
   `R = 10^(gamma·(D − Dmax))` is — has neither, and clips hard at both ends.

2. **A highlight rolloff that desaturates toward white without rotating hue.**
   Shouldering each channel independently walks a saturated red highlight
   through orange, then yellow, then white. That hue skew is the visual
   signature of per-channel filmic tone mapping. Preserving the channel ratio
   exactly instead avoids the skew but holds saturation constant, so bright
   areas stay neon and never reach white. The rendering that reads as correct
   does neither: it preserves the ratio through the midtones and progressively
   collapses it toward neutral inside the shoulder.

So the engine is a density inversion *and* a print.

---

## The model

### Stage 1 — density

A scanner measures transmittance `T` per channel. Density relative to the film
base is

```
D_c = log10( Dmin_c / max(T_c, ε) )
```

At the film base `T = Dmin`, so `D = 0`. In the densest area — the brightest
part of the photographed scene — `D` is at its maximum. Values brighter than
the base (the clear lightbox around the frame) give `D < 0`, which is not an
error and needs no special case; it simply lands past paper white and the
shoulder absorbs it.

### Stage 2 — the straight line

```
s_c = 10^( gamma_c · (D_c − Dmax_c) + printEV · log10(2) )
```

Three quantities per channel, each one a thing a printer actually controls:

| Term      | Analogue                    | How it is set                       |
| --------- | --------------------------- | ----------------------------------- |
| `Dmin_c`  | the film base / orange mask | sampled from the rebate or the base |
| `Dmax_c`  | the white point             | sampled from the densest area       |
| `gamma_c` | the paper grade             | per-channel contrast                |

Per-channel `Dmax` neutralises a highlight cast. Per-channel `gamma` is the
crossover fix — it gives the three channels different slopes, which is exactly
the degree of freedom the matrix model lacks.

`printEV` is a log-domain offset rather than a shift of `Dmax`, so one stop is
one stop regardless of grade. Shifting `Dmax` instead would make the exposure
control's effect depend on contrast, which is true of a real enlarger and
unhelpful in a slider.

This stage must be per-channel. Everything after it is not.

### Stage 3 — the paper

Take the norm and its ratio:

```
n       = max(s_r, s_g, s_b)
ratio_c = n > 0 ? s_c / n : 1
```

`max` rather than a weighted luma, because the norm is what the shoulder will
compress and the max channel is the one that would otherwise clip.

The paper response maps `n ∈ [0, ∞)` to `[0, 1)`, monotonically, with no clamp:

```
softknee(x, k) = x / (1 + x^k)^(1/k)

shoulder(n)    = softknee(n, p)
paper(n)       = 1 − softknee(1 − shoulder(n), q)
```

`softknee` is the identity for small `x`, approaches 1 asymptotically for large
`x`, and never clips. `k` sets how abrupt the knee is: large `k` is nearly a
hard clip, small `k` is a long gradual rolloff.

The toe is the same function applied to the complement, which lifts and
compresses the deep shadows the way paper does — `paper(0) = 1 − 2^(−1/q) > 0`,
a lifted black rather than a plugged one. That lifted black is not a
compromise; it is the look the user's own lab scans have.

Both parameters degenerate cleanly. As `p → ∞` the shoulder becomes a hard
clip at 1.0; as `q → ∞` the toe vanishes and black is true black. The sliders
are mapped so that 0 means "no effect" at both ends.

### Stage 4 — the rolloff

```
w     = smoothstep(shoulderStart, 1.0, paper(n)) · highlightDesat
out_c = paper(n) · mix(ratio_c, 1.0, w)
```

Below `shoulderStart` the ratio is preserved exactly: hue and saturation both
survive the midtones untouched. Inside the shoulder the ratio collapses toward
1, which desaturates toward white.

Hue is preserved exactly by construction, and this is provable rather than
approximate: `ratio_c` lerped toward 1 by a common `w` scales every
inter-channel difference by `(1 − w)`, so the channel ordering and the ratios
of the differences between them are unchanged, and HSV hue is invariant. That
becomes a test.

A final hue-preserving `printSaturation` scales `ratio_c` around 1 before the
rolloff, because C-41 papers are more saturated than a straight solve.

### Where it runs

On **linear** values, not gamma-encoded ones — the opposite of the legacy
converter, and deliberately so.

The legacy path brackets its work in `CILinearToSRGBToneCurve` because a linear
divide-and-invert crushes highlights: a correct workaround for a model with no
logarithm in it. The density model is *defined* on linear transmittance.
`log10` of a linear signal is the physically meaningful quantity, and encoding
to sRGB first would corrupt it. Core Image's working space is already linear,
so the new path simply does not bracket.

For a RAW scan edited in the sensor domain under PV2's `SourceImage`, the
values reaching the converter are linear sensor data — closer to true
transmittance than any rendered image, and therefore the best possible input.

`log10`, per-channel `pow` and the knee functions are not expressible as a
colour matrix, so this is a new `CIColorKernel` in
`Sources/Pipeline/Kernels/Film.ci.metal`, loaded through the existing
`KernelLibrary`. One GPU pass, same as before.

---

## Auto

The control that decides whether this feels like a tool or a chore. One
action, one undo entry, every value it writes left visible and editable.

1. **`Dmin`** — from the rebate when frame detection (Phase 3) has found one;
   until then, the **98th percentile** of each channel over the whole scan,
   since the film base is the thinnest and therefore brightest part of a
   negative.

   Not the 99.9th, and this matters. In the medium-format corpus the frame
   floats on a lit panel, and bare lightbox is brighter than film base — the
   very top of the histogram is not film at all. Backing off to the 98th
   lands inside the base for a scan that is mostly frame, and a scan that is
   mostly lightbox will be wrong no matter what percentile is chosen. That
   failure is exactly why the eyedropper stays and why the Phase 3 rebate
   sample is the route worth building.

   The panel reports which source was used, the way it already distinguishes
   a sampled base from an assumed one.

2. **`D_c`** across a downsampled render of the frame — 256 px on the long
   edge, which is enough for stable percentiles and cheap enough to be
   instant.

3. **`Dmax_c`** = the 99.5th percentile of `D_c`. A percentile rather than the
   maximum, so one dust speck cannot set the white point.

4. **`D_low_c`** = the 0.5th percentile.

5. **`gamma_c`** solved so every channel's low end lands on a common target
   black:

   ```
   gamma_c = log10(targetBlack) / (D_low_c − Dmax_c)
   ```

   Both ends of all three channels now coincide, which is what "no crossover"
   means. Closed form, no search.

6. **`printEV`** solved so the frame's **median** density renders at the target
   midtone. Median rather than either extreme: percentile ends are noisy and
   the midtone is what the eye judges. `paper()` is monotonic but not
   analytically invertible, so this is a bisection on one scalar with a fixed
   iteration count — deterministic, and a fraction of a millisecond.

7. Grade, shoulder, toe and saturation take their defaults.

White balance is deliberately not touched. Per-channel `Dmax` neutralises the
highlight cast and per-channel `gamma` neutralises crossover, so a solved frame
arrives close to neutral without spending the user's white balance sliders on
work the conversion already did.

Auto reports a confidence. A scan with no clean base — the whole lightbox in
frame, blown corners, a `D_low` that collides with `Dmax` — degrades to the
defaults for whichever term it could not measure and says so, rather than
producing a confidently wrong number.

---

## Controls

The Film panel (`01 FILM`) grows two tiers.

**Front:** Print Exposure (EV), Print Contrast (paper grade), Shoulder, Toe,
Print Saturation, and the Auto button.

**Behind a disclosure:** per-channel `Dmin`, `Dmax` trim and `gamma` trim. The
gamma trims are the crossover control; they belong in the interface because
they are the whole reason this engine exists, and behind a disclosure because
nobody wants to drive three gammas by hand as a first move.

**Print Contrast** is a paper grade on `0…5`, and grade 2 is defined as ×1.0 —
the gammas Auto solved. Each whole grade is a factor of `1.15` either side, so
the control is `gammaScale = 1.15^(grade − 2)`. Grade rather than a percentage
because the number then means the thing a printer already knows.

**Shoulder** drives the knee exponent `p` alone. Where the rolloff begins
(`shoulderStart`) and how completely it desaturates (`highlightDesat`) are
tuned constants, not controls — they are the two numbers that define the house
rendering, and exposing them would invite a user to dial in the hue-skewed
look this engine exists to avoid.

**Toe** drives `q` alone.

### Constants

Every taste judgment in the engine lives in one block, so that "the defaults
are arbitrary" is a claim anyone can check against a single screen of code.

| Constant | Default | Why |
| --- | --- | --- |
| `shoulderP` at Shoulder 0 / 100 | `64` → `2` | 64 is visually a hard clip; 2 is a very long rolloff |
| `toeQ` at Toe 0 / 100 | `64` → `3` | same family, same reasoning |
| Shoulder default | `40` (`p ≈ 8`) | a visible but unobtrusive knee |
| Toe default | `30` (`q ≈ 16`) | a lifted black in the region the user's lab scans sit |
| `shoulderStart` | `0.75` | rolloff engages in the top quarter, not the midtones |
| `highlightDesat` | `0.9` | paper white is reached, but not so abruptly that it reads as a clip |
| `printSaturation` default | `+12` | C-41 papers are more saturated than a straight solve |
| `targetBlack` | `0.004` | the `D_low` landing point, roughly one stop above true black |
| `targetMid` | `0.18` | display middle grey, where the median density is placed |
| `dmaxPercentile` | `99.5` | above dust, below the true maximum |
| `dLowPercentile` | `0.5` | symmetric |
| `autoDownsample` | `256 px` | stable percentiles, instant |

---

## Not breaking existing photos

The matrix model is **frozen**, not replaced. `FilmNegativeSettings` gains a
`conversionModel` field whose decoded default is `.matrix` and whose
initialised default is `.density`, so a stack loaded from an existing catalog
keeps its exact rendering while a newly enabled conversion gets the new
engine. Both paths stay in the renderer permanently.

The Film panel grows an **Update Conversion** action on any photo still on the
matrix model, which snapshots the current look before switching — the same
pattern, and the same guarantees, as the existing Process badge.

Stock profiles gain density parameters. The existing `contrast`/`saturation`
character fields stay, and are read only by the frozen path.

---

## Files

| File | Contains |
| --- | --- |
| `Sources/Film/FilmDensity.swift` | the parameter set and the density arithmetic |
| `Sources/Film/PaperResponse.swift` | `softknee`, `paper`, the rolloff — pure Swift, shared by the solver and the tests |
| `Sources/Film/AutoInvert.swift` | measurement and the solve |
| `Sources/Film/FilmDensityConverter.swift` | the render stage |
| `Sources/Pipeline/Kernels/Film.ci.metal` | the kernel |
| `Sources/Views/SliderPanel/FilmPanel.swift` | extended |

`PaperResponse.swift` existing separately from the kernel is the point: the
curve is defined once in Swift, the kernel mirrors it, and a test asserts the
two agree to within float precision across the range. A curve that exists only
inside a `.metal` file cannot be unit-tested, and this one carries the whole
look.

---

## Testing

**Synthetic round-trip.** Take a known positive, apply a simulated film
response with a known `Dmin`, per-channel gamma and *deliberate crossover*,
run Auto, and assert the recovered image matches within a ΔE2000 tolerance.
Running the same fixture through the matrix model documents in a test, rather
than in a claim, what the old engine provably cannot fix.

**Hue preservation.** A saturated primary driven through the shoulder holds its
hue angle within tolerance while losing saturation. This is where "not
sigmoid" is written down.

**Kernel/Swift agreement.** `PaperResponse` in Swift and the Metal kernel
produce the same value across a sampled range.

**Degeneracy.** `D_low == Dmax`, `Dmin` at zero, an entirely blown scan, a
fully clear frame: monotonic output, no NaN, no Inf.

**Conformance.** Every new scalar control gets a row in the Phase 1
`ControlConformanceTests` inventory. The completeness test will not allow one
to be added without it.

**Real scans.** Both corpora — 59 medium-format CR2 frames in
`~/Desktop/negatives` and 155 35 mm phone scans in
`~/Desktop/all film/film aug 4th 2026`. The gated RAW fixture tests are
un-gated against the CR2 set.

**Acceptance.** The rendered frames are shown to the user and the user calls
it. The paper defaults are a taste judgment and no assertion in CI can settle
them; they live as named constants in one place with the reasoning written
down, and they get tuned against these frames before the phase is done.

---

## Risks

**Changing conversion math silently alters every existing negative.** Handled
by freezing the matrix model permanently and making the switch an explicit,
snapshotted, undoable action.

**Auto degrades on a scan with no clean base.** It falls back per-term, reports
which source each term came from, and leaves every value as a slider.

**Bare lightbox outranks film base in the histogram.** A frame with a lot of
unmasked panel around it puts non-film pixels above the base, and no percentile
choice fixes a scan that is mostly panel. Mitigated by the 98th-percentile
estimate, by the eyedropper, and properly solved by Phase 3's rebate sample.

**The paper defaults are taste, not physics.** Acknowledged rather than
hidden: one constants block, documented reasoning, tuned against real frames
before the phase closes.

**The kernel and the Swift curve drift apart.** A test asserts they agree.

---

## Out of scope

Frame detection, rolls, roll-wide sync and dust removal (Phase 3). Grid view,
collections, keywords and sync-across-selection (Phase 4). Lab-look LUT
profiles, which need honest reference data before they are anything but a
guessed preset.
