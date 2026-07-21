# PhotoEditor

*totally not an open source Lightroom*

A native macOS photo editor built for film. Non-destructive from the ground
up: your original files are never modified — every edit is a small JSON
description replayed through a GPU filter chain, from the live preview to the
final export.

Built with SwiftUI and Core Image (Metal-backed), with a GRDB/SQLite catalog.
No AI, no cloud, no accounts, no telemetry. Your photos stay files on your
disk; your edits stay rows in a database you can read with `sqlite3`.

## The design

The interface is drawn from scratch — no stock macOS controls anywhere in the
editor. The design position: **the photograph is the only picture on screen;
everything else is annotation.** The chrome speaks in a single monospaced
voice, like the title block of an architectural drawing or the engraved fascia
of a darkroom instrument:

- **Faders, not sliders** — every adjustment is a drawn fader: a hairline
  baseline, a tick at the neutral value, and a quiet bar from the tick to the
  needle, so what has been done to a photo is visible as a length. Drag the
  track to set; hold **⌥** for 10× finer motion; drag the numeric readout to
  scrub; double-click to reset.
- **A numbered signal chain** — the develop column's sections are numbered in
  the order the render pipeline actually runs (01 FILM … 13 EFFECTS). The
  numbers are a legend, not decoration.
- **The filmstrip is a film rebate** — frame numbers and stock names
  edge-printed in dim amber above each frame, the way a negative carries its
  own provenance. Virtual copies print their copy number the same way.
- **Achromatic chrome** — every interface gray has R = G = B exactly, because
  any tint in the surround shifts perceived white balance. Color appears only
  where it carries photographic meaning: the histogram's channels, a film
  base swatch, a label dot.

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
sharpening and two-axis noise reduction; grain and vignette.

**Geometry and optics:** crop, rotate, straighten, flip with an interactive
crop overlay; manual barrel/pincushion distortion correction; vertical and
horizontal keystone (perspective) correction; chromatic-aberration defringe
that desaturates purple/green fringes only along hard edges, so subject color
is safe at any strength.

**Retouch:** heal and clone spot removal — click the defect, then drag the
solid circle (the repair) and the dashed circle (the source). Heal shifts the
copied pixels to match the destination's local tone; clone copies verbatim.

**Local adjustments:** resolution-independent painted brush masks plus linear
and radial gradients — the graduated burn and the dodge, placed by hand on the
canvas. A dedicated tool rail keeps crop, heal, clone, brush, gradient,
eyedropper, and compare tools in stable positions. The inspector separates
global adjustments, masks, and a clickable history of committed edit states;
clipping diagnostics, focus peaking, zoom to 200%, and before/after remain
preview-only viewing aids.

**The library:** a filmstrip drawn as a film rebate with star ratings,
pick/reject flags, color labels, filtering, and search over camera/lens/file.
Keyboard culling: `1–5` rate, `6–9` label, `P`/`X`/`U` flag. **Virtual
copies** — one negative, several interpretations, no duplicated pixels.
**Snapshots** — named saved states of a frame's edits; restoring one is
undoable. Copy and paste settings across a roll (pasting a look deliberately
leaves each frame's crop and its own sampled film base alone), save develop
presets, batch export. Exports render from the full-resolution original with
your choice of format, color profile, size, and output sharpening.

## Installing

Grab `PhotoEditor.app` from the latest
[release](../../releases), unzip, and drag it to `/Applications`. The app is
Developer ID signed and notarized by Apple — it opens with a normal
double-click. Requires macOS 14+.

## Building from source

Requires Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`). `project.yml` is the source of truth.

```sh
xcodegen generate
xcodebuild -project PhotoEditor.xcodeproj -scheme PhotoEditor \
  -destination 'platform=macOS' build
```

Tests (192):

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
  collapse into one cached 32³ LUT; defringe is a second, edge-gated LUT.
- The "developed source" prefix (film conversion, geometry, defringe,
  retouch) is memoized, so dragging a tone slider never re-runs the negative
  conversion or a heal's GPU read-backs.
- The preview is a downsampled proxy; export re-decodes the original at full
  resolution and replays the same stack. Masks, crops, and retouch spots live
  in unit coordinates so both paths land identically.
- The catalog lives at `~/Library/Application Support/PhotoEditor/`.

## License

MIT — see [LICENSE](LICENSE).
