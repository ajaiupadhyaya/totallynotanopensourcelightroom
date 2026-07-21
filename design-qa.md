# Design QA — Refined Darkroom Instrument

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
