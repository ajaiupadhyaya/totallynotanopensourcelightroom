# PhotoEditor

*totally not an open source Lightroom*

<p align="center">
  <img src="docs/media/figures/banner.jpg" alt="No AI. No cloud. No accounts. — PhotoEditor 2.1" width="100%">
</p>

A photo editor for macOS. No AI, no cloud, no accounts, no subscription. Your photos stay as files on your disk and nothing phones home.

I shoot film, and most editors treat a scanned negative as something you fix with a plugin. This one puts the conversion first. It also does all the normal stuff — exposure, curves, masks, retouching, export — so it's not only useful if you shoot film.

Your originals are never touched. Every edit is just a bit of JSON that gets replayed through a GPU filter chain each time you look at the photo, so undo is free and nothing is ever baked in until you export. The catalog is a SQLite file you can poke at with `sqlite3` if you feel like it.

[Download 2.1.0](https://github.com/ajaiupadhyaya/totallynotanopensourcelightroom/releases/latest) · macOS 14+ · signed and notarized

---

<p align="center">
  <img src="docs/media/figures/gallery.jpg" alt="Sample frames: architecture, coast, still life" width="100%">
</p>

## A look at it

<p align="center">
  <img src="docs/media/figures/hero.jpg" alt="The develop workspace with a scanned negative open" width="100%">
</p>

<p align="center">
  <img src="docs/media/figures/before-after.jpg" alt="Before and after of a coastal landscape" width="100%">
</p>

<p align="center">
  <img src="docs/media/figures/develop.jpg" alt="A coastal frame open in the develop workspace" width="100%">
</p>

---

## The interface

I drew all of it — there are no stock macOS controls in the editor. A few choices worth explaining:

**The faders fill from the middle, not from the left.** The bar runs from the neutral point to wherever you've dragged it, so an untouched photo is just a column of empty grooves and you can see what you've changed without reading a single number. Drag anywhere on the groove, hold ⌥ for fine control, drag the number itself to scrub, double-click to reset.

**Sections are numbered in the order they actually render**, `01 FILM` through `14 EFFECTS`, with a thin line down the left that lights up next to anything carrying an edit. Mostly this exists to answer "wait, what did I do to this one" without opening all fourteen.

**Monospaced type is only used for numbers** — values, dimensions, frame numbers, exposures — so digits don't jitter around as they change. Everything you actually read is set in the normal system font. The whole interface used to be monospaced and it looked like a terminal cosplaying as an app.

**The filmstrip is styled like a film rebate**, with frame numbers and stock names edge-printed in dim amber. A negative carries its own provenance there, so it seemed like the right place.

**Every grey is exactly neutral** (R = G = B), because a tinted interface quietly shifts how you judge white balance. Colour only turns up where it means something: histogram channels, a film base swatch, a label dot, a clipping warning.

---

## Film

<p align="center">
  <img src="docs/media/figures/film.jpg" alt="Film conversion sits at the top of the signal chain" width="100%">
</p>

Negative conversion is stage `01`, before anything else — on an un-inverted scan every other slider works backwards, so it has to go first.

The conversion divides out the film base, inverts, and rebalances in one GPU pass. It runs on gamma-encoded values rather than in linear light, which is the difference between a normal-looking conversion and a harsh one.

You can sample the film base automatically or click the clear border with the eyedropper. There are stock profiles for common C-41, ECN-2, B&W and slide films, but they're approximations and labelled as such — the reliable route is to calibrate: sample *your* base off *your* scanner and save the whole chain as a profile.

Stock matching ranks candidates by base chromaticity. It'll reliably tell colour negative from B&W from slide. Within C-41 it gives you candidates, not an answer, because most C-41 masks look nearly identical.

---

## Everything else

**Light and presence** — exposure, contrast, highlights, shadows, whites, blacks; white balance with a click-a-neutral eyedropper; texture, clarity, dehaze, vibrance.

**Colour** — 8-band HSL mixer, black & white with per-band channel mixing, three-way grading, RGB and per-channel curves, parametric tone regions, point colour, camera calibration, and imported `.cube` LUTs.

**Geometry and optics** — crop, rotate, straighten, flip, barrel and pincushion correction, keystone, and chromatic-aberration defringe that only touches hard edges.

**Retouch** — heal, clone, and content-aware remove, as spots or brush strokes, with opacity and feather. Heal picks its own source.

**Masks** — brush, linear and radial gradients, luminance and colour range, and on-device Vision masks for subject, person, background and sky. Combine them with add, subtract and intersect; refine, invert, and hit `⌘⇧M` to see the selection in red.

**Preview** — Metal canvas with EDR on displays that support it, frames coalesced while you scrub, and full-resolution rendering at 100 % and above. The drawable is always window-sized, so zooming into a 60-megapixel frame costs the same as zooming into a small one.

<p align="center">
  <img src="docs/media/figures/color.jpg" alt="The develop column with the colour tools open" width="100%">
</p>

**Library** — ratings, pick/reject, colour labels and search for culling; virtual copies; snapshots; presets; batch export straight from the full-resolution originals.

Tool shortcuts: `H` hand, `C` crop, `J` heal, `S` clone, `B` brush, `G` gradient, `I` eyedropper, `\` before/after. Everything else is in the menu bar.

---

## Install

Grab `PhotoEditor-2.1.0.zip` from the [latest release](https://github.com/ajaiupadhyaya/totallynotanopensourcelightroom/releases/latest), unzip it, drag `PhotoEditor.app` to `/Applications`.

It's signed and notarized, so it opens with a normal double-click. Needs macOS 14 or later.

## Build it yourself

You'll need Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). `project.yml` is the source of truth, so regenerate after changing it.

```sh
xcodegen generate
xcodebuild -project PhotoEditor.xcodeproj -scheme PhotoEditor \
  -destination 'platform=macOS' build
```

And the tests, of which there are 281:

```sh
xcodebuild -project PhotoEditor.xcodeproj -scheme PhotoEditor \
  -destination 'platform=macOS' test
```

---

## How it works

A few notes if you're reading the source.

`EditStack` is the entire edit state — one flat `Codable` value stored as JSON in the catalog. Every field decodes leniently, so adding a new control never invalidates someone's existing library.

`EditRenderer` replays that stack as a lazy `CIImage` chain in a deliberate order. The mixer, black & white, grading, calibration, point colour and channel curves all collapse into a single cached 32³ LUT rather than stacking filters. The "developed source" prefix — film, geometry, defringe, retouch — is memoized, so dragging a tone slider doesn't re-run a heal or a negative conversion.

There's exactly one render path. The preview builds the same chain the export replays, because a preview-only shortcut is a preview that can disagree with the file you ship. Masks, crops and retouch all live in unit coordinates so the two agree at any resolution. The canvas renders that graph into a window-sized Metal drawable and lets Core Image work out the region of interest backwards through the chain, which is why zoom is cheap.

Histograms and clipping warnings are measured in display space rather than the linear working space. Core Image works in linear light, where mid-grey sits about a fifth of the way up the scale — measure there and an ordinary photo looks like it's crushing its shadows. A histogram is for a person to read, so it should describe what they're looking at.

The catalog lives in `~/Library/Application Support/PhotoEditor/`. The app icon is drawn in code — `scripts/make-app-icon.sh` regenerates it.

---

## License

MIT, see [LICENSE](LICENSE).

<p align="center"><sub>The sample photographs in this README are synthetic stand-ins made for the docs — not real clients, not real rolls.</sub></p>
