# PhotoEditor

*totally not an open source Lightroom*

A native macOS photo editor built for film. Non-destructive from the ground
up: your original files are never modified — every edit is a small JSON
description replayed through a GPU filter chain, from the live preview to the
final export.

Built with SwiftUI and Core Image (Metal-backed), with a GRDB/SQLite catalog.
No AI, no cloud, no accounts, no telemetry. Your photos stay files on your
disk; your edits stay rows in a database you can read with `sqlite3`.

## The film workflow

This editor treats scanned negatives as a first-class subject, not a plugin
afterthought:

- **Negative conversion** — divide out the film base, invert, rebalance, in a
  single GPU pass. The math runs in gamma-encoded space, where scans actually
  live; inverting in linear light is what makes conversions look harsh.
- **Film base sampling** — automatic (the brightest region of a scan is
  unexposed base) or by clicking the film border with the eyedropper.
- **Stock profiles** — built-in starting points for common C-41, ECN-2, B&W,
  and slide stocks, honestly labeled as approximations. The reliable path is
  **calibration**: name the stock you shot, sample the base from your own
  scan, and save a profile that captures your whole chain — stock,
  development, and scanner together.
- **Stock matching** — ranks candidates by base chromaticity. It reliably
  separates color negative from B&W from slide; within C-41 it presents
  candidates, not identifications, because most modern masks are
  near-identical.

## Everything else

Exposure, contrast, highlights/shadows/whites/blacks; white balance with a
click-a-neutral eyedropper; texture, clarity, dehaze, vibrance; an 8-band HSL
color mixer; black & white with per-band channel mixing (a red filter for
skies, in software); three-way color grading; RGB and per-channel tone curves;
sharpening and two-axis noise reduction; grain and vignette; crop, rotate,
straighten, flip with an interactive crop overlay; **local adjustments** as
linear and radial gradient masks — the graduated burn and the dodge, placed by
hand; focus peaking; zoom to 100%; before/after.

The library is a filmstrip drawn as a film rebate — frame numbers and stock
names edge-printed in amber — with star ratings, pick/reject flags, color
labels, filtering, and search over camera/lens/file. Keyboard culling: `1–5`
rate, `6–9` label, `P`/`X`/`U` flag. Copy and paste settings across a roll
(pasting a look deliberately leaves each frame's crop and its own sampled film
base alone), save develop presets, batch export. Exports render from the
full-resolution original with your choice of format, color profile, size, and
output sharpening.

## Building

Requires Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`). `project.yml` is the source of truth.

```sh
xcodegen generate
xcodebuild -project PhotoEditor.xcodeproj -scheme PhotoEditor \
  -destination 'platform=macOS' build
```

Tests (163):

```sh
xcodebuild -project PhotoEditor.xcodeproj -scheme PhotoEditor \
  -destination 'platform=macOS' test
```

## Architecture notes

- `EditStack` is the whole edit state: a flat, `Codable` value stored as JSON
  in the catalog. Every field decodes leniently, so adding a field never
  invalidates an existing library.
- `EditRenderer` replays a stack as a lazy `CIImage` chain in a deliberate
  order (film conversion first — on an un-inverted negative every other slider
  would work backwards). The color mixer, B&W mix, grading, and channel curves
  collapse into one cached 32³ LUT.
- The preview is a downsampled proxy; export re-decodes the original at full
  resolution and replays the same stack. Masks and crops live in unit
  coordinates so both paths land identically.
- The catalog lives at `~/Library/Application Support/PhotoEditor/`.
