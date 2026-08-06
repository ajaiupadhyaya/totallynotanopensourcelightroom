# The Minilab — Negative Conversion Quality & Consistency

**Date:** 2026-08-05
**Status:** Approved design, awaiting implementation plan
**Slots into the 3.0 roadmap as:** Phase 2.5 — between the print engine (Phase 2, shipped) and the scanning workflow (Phase 3). It deliberately absorbs the *conversion core* of Phase 3 (the roll entity and roll-level solving) because frame-to-frame consistency is a present-tense quality complaint, not a future workflow feature. The rest of Phase 3 (frame detection, dust removal, contact sheets, multi-frame splitting) stays in Phase 3.

## Problem

The print engine is physically correct and its math is proven by 402 tests, but converted rolls still do not feel like lab scans. Three named symptoms, each with a diagnosed structural cause:

1. **Color casts / crossed colors.** Without a sampled base, Dmin is a per-frame 98th-percentile statistic — a frame cropped to image area yields an image-content "base," which is a global cast by construction. The per-channel endpoint solve assumes the densest/thinnest content is neutral (gray-world-at-the-extremes), so a genuinely colored extreme gets neutralized and shifts everything else. And the cast *tools* are deliberately thin: filtration is clamped to ±0.25 EV, dmax trims act only at the white end, and there is no midtone-independent cast control at all.
2. **Tone/contrast feel.** The research finding (Negative Lab Pro, Frontier/Noritsu, negadoctor commentary) is unambiguous: a physically-correct inversion plus a fixed paper curve reads as "flat, raw, needs editing." What makes lab output feel *finished* is a scene-adaptive auto-toning layer — per-channel normalization with midtone punch, raised blacks, and softened whites — integrated into the default rendering. We have no such layer; Linear-honest is our only rendering.
3. **Inconsistency across frames.** Every frame solves independently from its own histogram. Dmax/dlow are scene-content percentiles, so gamma, base, and EV differ frame to frame on one roll. The C F Systems / NLP-v3 discipline is the fix: film-stock properties (per-channel gamma, base) are properties of the roll; only exposure varies per frame.

Additionally, the Phase 2 deep-read proved four defects to fix:

- Legacy film EV is applied **after** the paper curve on the density path — a post-tone-map multiply that can push paper white above 1.0, silently breaking the never-clips contract.
- Tint filtration offsets green alone, changing overall luminance — contradicting the "moves exposure between complementary channels" design intent.
- Grade pivots at paper-white: raising contrast darkens everything below white with no exposure compensation, unlike real graded printing which re-trims to hold mid-grey.
- The toe has no chroma treatment: deep shadows can render more saturated than any real print (paper dye limits shadow chroma); only the highlight end desaturates.

## Goals

- A default conversion that reads as a finished lab scan, not an honest flat positive.
- Frames of one roll convert consistently: shared base and gammas, per-frame exposure only.
- Cast removal that actually works: a neutral picker, auto white balance, and zone (shadows/mids/highs) trims.
- Every existing photo renders **bit-identically**. The Phase 2 acceptance is preserved as the named **Linear** profile, not discarded.
- Auto stays deterministic, closed-form where possible, honest about degradation, and lands every solved number in a visible slider.

## Non-goals

- Frame detection, dust/scratch removal, contact sheets, emulsion flip (Phase 3 proper).
- Library grid/collections/keywords (Phase 4).
- Scanner/camera spectral calibration matrices and Frontier/Noritsu emulation LUTs (a later increment; this design reserves the slot).
- Any change to the frozen `.matrix` engine or PV1.

## Architecture & compatibility

**No third conversion engine.** The density engine grows new parameters whose decode-defaults are neutral, exactly the asymmetric-default trick used by `processVersion` and `conversionModel`:

- `PrintSettings.renderVersion: Int` — **decodes 1, initializes 2.** Version 2 gates the four semantic fixes (EV-before-curve, balanced tint, mid-pivot grade, toe chroma compression). Version 1 reproduces today's math bit-for-bit.
- All new fields decode to values that are mathematical identities (trims 0, profile `.linear`, cast offsets 0, auto-toning parameters neutral). New conversions initialize the new defaults (profile `.labStandard`, etc.).

Consequences honored from the existing contracts:

- `PaperResponse.swift` and `Film.ci.metal` change **in lockstep**; `testKernelAgreesWithTheSwiftModel` remains the enforcement. sRGB helpers stay duplicated per translation unit (classic CIKernel metallibs cannot link across TUs); `max3` remains unavailable.
- Every new persisted field uses the lenient field-by-field decoding pattern.
- Every new scalar control gets a `FilmControlCase` row — the reflection completeness test makes omission a failure.
- The persisted film base color stays display-encoded sRGB; the density engine linearizes at its boundary.
- `DevelopedSourceCache` keys on settings equality, so new fields invalidate the memo automatically.
- Multi-field gestures (Auto, Convert Roll, profile switch) follow the single-assignment pattern: build on a local var, one `editStack` write, one undo step, one render.

**Golden bit-stability test.** Before any math changes, record `PaperResponse.develop()` outputs over a committed lattice of input colors × representative settings (renderVersion 1, neutral new fields). The test asserts the new implementation matches the recording within 1 ULP, forever. This is the executable form of "existing photos render identically."

**Stage order within the film stage** (renderVersion 2):

1. Density measurement (unchanged): per-channel `D = log10(dmin/t)` on linear transmittance.
2. Cast correction: per-channel density offsets (new; identity at 0).
3. Straight line with per-channel gamma and Dmax; print EV (now including any legacy film EV) and filtration offsets in log domain (unchanged shape; tint now splits green vs. magenta).
4. Zone trims: shadows/mids/highs per-channel density offsets weighted by tone zone (new; identity at 0).
5. Paper curve on the max-channel norm + profile toning (midtone contrast, black lift, white soften) + hue-preserving highlight rolloff + toe chroma compression (new pieces identity at neutral).
6. Look-layer slot: reserved, identity. A future increment can install a 3×3 or LUT here without touching stages 1–5.

## Roll model & roll analysis

**Catalog migration v8** — adopt the Phase 3 roadmap schema so Phase 3 needs no re-migration (the roadmap sketched this as "v7", but `v7_stockPrintCharacter` shipped with the print engine; the roll migration is therefore v8):

- `roll` table: id, identifier, film stock, camera body, lens, exposure index, push/pull, developer, dev notes, lab, scan date, created-at. This sub-project populates identifier + stock + created-at from the UI; the rest are nullable columns Phase 3 will fill.
- `CatalogEntry` gains nullable `rollID` and `frameNumber`.

**Roll assignment UI (minimal by design):** "New Roll from Selection…" and "Add to Roll ▸" in the filmstrip context menu; a roll legend line in the filmstrip edge print (turning today's decoration into data). No roll browser, no roll inspector — Phase 3/4 surface.

**RollModel** (new file): all roll actions live here, not in the 1080-line `EditorModel`, per the roadmap's own instruction.

**Roll Analysis** — the consistency discipline:

- Per-frame measurement is unchanged (`AutoInvert`'s gated, crop-aware, 256-px linear statistics). Roll analysis aggregates the per-frame statistics across all frames of the roll.
- **Roll-level constants:** per-channel Dmin (base) and per-channel gamma. Base: a user-sampled rebate base on *any* frame of the roll wins for the whole roll; otherwise a robust aggregate (per-channel minimum-density envelope across frames — the thinnest film seen on the roll is closest to true base). Gamma: solved from roll-aggregated dlow/Dmax distributions, so one frame's red dress cannot bend the roll's curves.
- **Frame-level variables:** print EV only (median-to-0.18 bisection per frame against the roll constants). No per-frame black offset in this design — if the roll-consistency metric later shows toe mismatch, that is a measured reason to revisit, not a pre-built knob.
- **Convert Roll** action: one recoverable action across the roll — each frame gets a "Before Roll Conversion" snapshot before its stack is overwritten (the same preservation mechanism as Update Conversion; library-level multi-entry undo does not exist in the app and this sub-project does not invent it). Frames with individually-sampled bases keep them (roadmap semantics). Stored as a `RollConversion` record on the roll so later frames added to the roll adopt it.
- Single-frame Auto remains: un-rolled frames behave exactly as today; rolled frames reuse roll constants and solve only frame-level terms.
- The roll-wide apply shares its implementation shape with Phase 4's sync-across-selection (the roadmap requires they be one mechanism); design the apply API as "apply these settings-mutations to this set of entries as one undo step."

## Tone profiles & scene-adaptive toning

`FilmToneProfile` enum: `.linear`, `.labSoft`, `.labStandard`, `.labHard`. Persisted on `PrintSettings`; decode-default `.linear` (existing photos), init-default `.labStandard` (new conversions). A profile is two things:

1. **A parameter set** for the new toning controls, applied on the max-channel norm path so hue survives untouched (the house architecture):
   - Midtone contrast: an S-curve about the mid target, strength per profile (soft < standard < hard). Applied to the norm only.
   - Black lift and white soften: exposed as two visible sliders named **Fade** (black lift — a faded print's raised black) and **Glow** (white soften — highlight compression into paper white), whose profile defaults differ.
   - Toe chroma compression (renderVersion 2): mirror of the highlight rolloff at the dark end — blend channel ratios toward 1 with a weight rising as the norm approaches paper black. Constants named in `PaperResponse` beside their highlight siblings.
2. **Solver behavior**: Auto solves against the profile's default parameter values (the bisection already solves under shipped defaults — the profile simply defines which defaults). Lab profiles also enable Auto-WB by default (below).

`.linear` is exactly today's render: all toning parameters at identity, no Auto-WB. Switching profiles re-runs the frame's solve under the new profile's defaults (single-assignment, undoable).

## Cast correction

Three sources writing one mechanism — per-channel density offsets applied at stage 2, before the straight line, visible as three fine sliders (R/G/B cast; ±100 = ±0.5 EV per channel — twice the filtration clamp, enough to remove a real base-estimation cast while still bounded against scan-rescue abuse):

- **Neutral picker** (extends the existing `CanvasPicker` enum): click a should-be-neutral patch; offsets solve closed-form so that patch's three straight-line log outputs equalize. Banner prompt + cancel, like the film-base picker.
- **Auto-WB** — Neutral / Warm / Cool: closed-form offsets aligning per-channel median densities (midtone gray-world), with Warm/Cool as fixed documented biases from neutral. On by default under Lab profiles; reported in `degradedTerms` when the midtone population is small or high-chroma (the gray-world assumption is risky and the solver must say so rather than guess confidently).
- **Manual sliders**, double-click reset to 0.

House filtration (Warmth/Tint) keeps its identity and its ±0.25 EV clamp: it is the *taste* trim. Cast correction is the *analysis* layer. They are additive in log domain and independently resettable.

**Zone trims:** shadows/mids/highs per-channel offsets, each weighted by a documented zone weight function computed from the **pre-trim** paper-output norm (evaluate the untrimmed norm through the paper curve once to obtain the zone weight, then apply the weighted trims before the final curve — no circularity; shadows and highlights weights are complementary smoothsteps, mids the remainder). This is the deliberate creative control for shadow color character (Frontier inky blue-black vs. Noritsu drift) — it intentionally rotates color, unlike the hue-preserving tone path, and the spec says so plainly in the panel copy.

## Panel (FilmPanel additions — engine sub-project owns these)

In the existing design language, no new patterns: a Profile selector (TabStrip), Glow/Fade sliders, Cast group (R/G/B sliders + picker button + Auto-WB menu), Zone trims behind a disclosure like the existing per-channel trims. Every control double-click-resets to its profile default. All copy follows the honesty convention (provenance captions where a solve wrote the value).

## Validation

1. **Golden bit-stability**: the recorded-lattice test above; runs everywhere, no fixtures needed.
2. **Conformance**: `FilmControlCase` rows for every new control (profile, glow, fade, casts ×3, zone trims ×9); neutral is a no-op, extremes move the image, direction matches the label. The simulated-crossover probe gains a cast-injection variant so the picker/Auto-WB solves are asserted to neutralize a known injected cast.
3. **Reference harness** (new, gated): `darktable-cli` renders the 59-frame CR2 corpus through the user's own existing negadoctor XMP sidecars into reference positives. Gated with XCTSkip when darktable or the corpus is absent (install: `brew install --cask darktable`). The harness writes side-by-side artifact grids (ours-Linear / ours-LabStandard / negadoctor reference) — evidence for the human pass, not asserted equality.
4. **Roll-consistency metric** (new, gated): a user-editable manifest maps corpus files to rolls; the test solves each roll both ways (per-frame vs. roll analysis) and asserts the variance of post-conversion base-region chromaticity and median luma across same-roll frames *shrinks* under roll analysis. Sanity bands, not beauty.
5. **Human acceptance**: RealScanTests A/B artifact grids (current default vs. Lab Standard) across both corpora. The paper defaults and profile taste are, as the Phase 2 spec already states, judgments no CI assertion can settle: the user's visual pass is the final gate, and it re-opens deliberately what Phase 2's acceptance closed — that is the point of this project.

## Risks

- **Kernel growth**: stage 2/4/5 additions enlarge the one-pass kernel. Mitigation: all additions are per-pixel arithmetic (still a `CIColorKernel`); the parity test catches Swift/Metal drift; neutral guards skip work where possible.
- **Gray-world Auto-WB failures** on legitimately colorful scenes: mitigated by degradedTerms honesty, the picker override, and Lab-profile-only default.
- **Roll aggregation garbage-in** (a roll containing mixed stocks or wildly different scan sessions): the roll is user-asserted; Convert Roll reports per-frame degraded terms and the variance metric makes regressions visible. No silent magic.
- **Freeze-surface growth**: renderVersion 1 joins PV1 and `.matrix` in the forever set. Accepted: it is one flag over shared code paths with neutral-identity math, not a third renderer.

## Out of scope (explicit)

Frame detection; dust removal; contact sheets; multi-frame splitting; scanner calibration matrices; look LUTs (slot reserved); library UI; any `.matrix`/PV1 change.
