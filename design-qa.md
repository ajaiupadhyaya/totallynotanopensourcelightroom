# Design QA — 2.1, "The Develop Desk"

## What this pass was

A rebuild of the interface's execution, holding the 2.0 design *position* — a
drawn, achromatic darkroom instrument — and raising everything under it to the
standard of shipped software. Plus the correctness work the visual pass sat on
top of, because a beautiful interface over a torn preview is not a finished app.

## Verification

- Full suite: **281 tests, 0 failures** (was 259 before this pass; 22 added).
- The app was built, launched, and captured at native Retina scale in every
  workspace. Screenshots are the evidence for anything a test cannot assert —
  orientation, layout, hierarchy, legibility.
- State for screenshots was seeded through the app's **own preferences**
  (`lastOpenedEntryID`, the panel expansion keys) and never by synthesizing
  mouse or keyboard input.

## Defects found and fixed

Four of these predate the visual work and were found by looking at the running
app rather than at the code.

| Severity | Defect | Resolution |
|---|---|---|
| P0 | Preview rendered as offset bands at every zoom — the tiled renderer replayed the whole stack per 512 px tile, so crop, straighten, perspective, vignette, grain and masks all resolved against a tile instead of the frame | Hand tiling removed; Core Image tiles internally when rasterizing. Regression test asserts a half-width crop halves the preview |
| P0 | Canvas rendered the photograph upside down | `CIRenderDestination.isFlipped`; placement extracted and unit-tested, including the flip |
| P1 | Histogram measured in linear light — sRGB 50 % grey landed in bin 55, and a normally-lit frame reported ~28 % shadow clipping | Measured in display space. Test pins mid-grey to mid-histogram |
| P1 | A clipped spike flattened the whole histogram | Scale taken from the interior bins; clipping still reported exactly by the diagnostics |
| P1 | Missing thumbnails were permanent — nothing retried, and refreshing one never recorded its path | Repair on launch; refresh records where it wrote |
| P2 | Metal command queue allocated every frame | Created once |
| P2 | At 100 % zoom the drawable was sized to the whole photograph — gigabytes on a large frame | Canvas is viewport-sized; zoom is a transform |

## Visual findings and fixes

- **P1 — one voice, no hierarchy.** The interface was monospaced throughout, so
  section titles, control names, values, buttons and captions all read at one
  weight. Split into two voices by meaning: monospace for measurement, the
  system text face for language. This is the single largest change.
- **P1 — the develop column was a flat list.** Thirteen near-identical collapsed
  rows, including one numbered "09a". Regrouped under four headings, renumbered
  honestly 01–14, and threaded onto a spine that lights beside any stage
  carrying edits.
- **P2 — dead space.** The tool options bar spent a full-width strip on one
  sentence of advice for the default tool; it now collapses when the tool has no
  options. The rail's rotated "TOOLS" filler label is gone.
- **P2 — weak affordances.** Faders drew a hairline and a tick, with a 14 pt hit
  band and nothing at neutral to say they were controls. Rebuilt with a groove,
  a lit delta bar, a responsive thumb, an 18 pt band, keyboard focus and arrow
  nudging.
- **P2 — hand-drawn tool pictograms did not survive 15 pt.** The gradient mark
  rendered as a solid bar, the hand as a blob. Tool marks moved to SF Symbols,
  which are hinted for that size; the chrome's own two-stroke glyphs stayed
  drawn, where matching the faders' hairline weight is what matters.
- **P2 — no depth.** Added one device only: a specular top hairline and a shadow
  line on raised surfaces. No colour, survives a dim display.
- **P3 — decorative structure removed.** The inspector headings carried a large
  accent letter — "M" beside "Masks", "H" beside "History" — that encoded
  nothing. The space went to the sentence that tells you what the pane is for.
- **P3 — filter bar overflowed** and silently dropped its first tab.

## Additions

- A menu bar (File, Edit, View, Develop, Frame). Every command in it already
  existed as a keystroke with nowhere to be found.
- Empty states on the canvas and in both inspector panes that say what to do.
- A new app icon, drawn in code so it is reviewable and diffable.

## Intentional deviations

- **The chrome stays drawn.** Stock macOS controls were considered and rejected:
  the "no platform widgets in the editor" position is load-bearing for this app's
  character, and the brief was to raise the execution, not replace the identity.
- **Bare-key tool shortcuts are not in the menu bar.** `B`, `C`, `J` and the rest
  are handled by `ToolKeyMonitor`, which yields to text fields. Binding them as
  menu shortcuts would make them win everywhere, so typing "crop" into the
  search field would change tools four times.
- **Fit never enlarges.** A frame smaller than the window is shown at its own
  size rather than interpolated up to fill space.

## Follow-up

- P0: none · P1: none · P2: none
- P3: the README's `before-after.jpg` and `gallery.jpg` are photographic
  compositions rather than interface captures, so they were not regenerated;
  every figure that shows the interface was.

---

## Archive — 2.0 pass: Refined Darkroom Instrument

## Visual truth and implementation

- Source concept: `/Users/ajaiupadhyaya/Documents/totallynotanopensourcelightroom/design-reference/refined-darkroom-instrument.png`
- Final implementation capture: `/Users/ajaiupadhyaya/Documents/totallynotanopensourcelightroom/design-qa-evidence/implementation-pass-2.png`
- Full comparison: `/Users/ajaiupadhyaya/Documents/totallynotanopensourcelightroom/design-qa-evidence/comparison-pass-2.png`
- Focused inspector comparison: `/Users/ajaiupadhyaya/Documents/totallynotanopensourcelightroom/design-qa-evidence/focused-inspector-pass-2.png`

The source is 1487 × 1058 px. The native macOS app was captured from an 1881 × 1206 pt Retina window at 2× (3762 × 2412 px). Both full views were normalized into adjacent 1440 × 1024 panels for visual comparison. The app is resizable, so the source's exact viewport is not a production constraint.

## State under review

- TIFF open in Develop
- Hand tool selected
- Adjust workspace selected
- Fit view with the current image and filmstrip visible
- Light section expanded; remaining signal-chain sections collapsed
- Clipping diagnostics available and off

## Visual findings and fixes

### Pass 1

- **P2 — context hierarchy:** the context-options bar crossed the library, canvas, and inspector, flattening the intended three-pane hierarchy.
- **Fix:** scoped the options bar to the canvas workspace and kept the roll and inspector independently anchored.
- **Additional refinement:** added a compact bottom canvas status rail for fit/zoom, profile, pixel dimensions, and before/developed state.

### Pass 2

No actionable P0, P1, or P2 visual issues remain.

- **Typography:** compact monospaced instrument labels and readable control copy match the source's editorial/technical character.
- **Layout:** left film roll, narrow stable tool rail, dominant image canvas, and fixed right inspector reproduce the source hierarchy.
- **Spacing and shape:** square rules, tight spacing, low-radius surfaces, and restrained separators preserve the minimalist/brutalist direction.
- **Color:** achromatic graphite surfaces, neutral text, blue active states, amber film metadata, and warning amber diagnostics are coherent and tokenized.
- **Images/assets:** the implementation uses the real loaded photograph and thumbnails; controls use consistent SF Symbols with no placeholder art or approximate custom icons.
- **Copy:** PHOTOEDITOR, ROLL, ADJUST / MASKS / HISTORY, clipping controls, and editing-stage labels are concise and state-aware.

## Intentional deviations

- The implementation retains the app's complete 13-stage editing signal chain and honest pipeline numbering instead of reducing the inspector to the concept's smaller illustrative set.
- The default capture shows the Hand context because Hand is selected. The source concept combines a selected Hand icon with Crop-specific options, an internally inconsistent state.
- The production inspector prioritizes working painted masks, retouching, snapshots, and clickable history over decorative per-section bypass icons that were not part of the existing rendering contract.

## Functional validation

- Native debug build succeeded after the visual fixes.
- Full automated suite passed: 192 tests, 0 failures.
- Painted brush-mask rendering, locality, resolution independence, persistence, and history restoration are covered by dedicated tests.
- The real app was launched and captured at native Retina scale. External pointer injection could not be used to capture alternate tabs because macOS accessibility permission was unavailable; workspace state and editing behavior remain covered by compiled implementation and automated state tests.

## Follow-up severity

- P0: none
- P1: none
- P2: none
- P3: alternate workspace hover/focus screenshots can be added later if accessibility-driven UI automation is introduced; no known functional defect is associated with this.

final result: passed
