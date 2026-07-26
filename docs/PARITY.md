# Measuring PV2 against Lightroom CC

One-time setup per reference photo (15 minutes):

1. `swift scripts/make-parity-presets.swift` — writes `scripts/parity-presets/`
   (17 XMP presets) and `Tests/Fixtures/Parity/manifest.json`. Run this from
   the repository root; it locates its own directory relative to the CWD
   (see the comment at the top of the script).
2. In Lightroom CC: add a reference photo (any well-exposed photo with real
   shadows, midtones, highlights, and some saturated color).
3. Presets panel → ⋯ → Import Presets → select the `scripts/parity-presets`
   folder. They arrive under the "PV2 Parity" group.
4. Export the photo untouched as 16-bit TIFF, sRGB, 1024 px long edge →
   `Tests/Fixtures/Parity/neutral.tif`. **Every slider at zero.**
5. For each preset: apply it (one preset at a time, on top of the untouched
   photo — easiest with a virtual copy per preset), export with the same
   settings, named after the preset: `contrast_p50.tif`, `exposure_p1.tif`, …
   (the manifest lists the exact names).
6. Run the suite. `ParityTests` un-gates automatically and prints a ΔE2000
   report per control; WB cases are report-only (Lightroom's incremental WB
   units have no exact Kelvin mapping).

Export every fixture as `.tif` — that extension is what keeps these personal
photos out of the repository. Only `Tests/Fixtures/Parity/*.tif` is gitignored;
anything else dropped in that folder (a stray `.jpg`, a `.png`) would be
committed.
