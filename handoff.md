# Project handoff: native photo editor (Lightroom-style, no AI/social)

## What this is

A macOS desktop app for non-destructive photo editing — RAW/JPEG import, edit sliders (exposure, contrast, curves, HSL, etc.), a library catalog, and export. Explicitly **not** building: cloud sync, mobile companion, AI masking/subject select, social feed, plugin marketplace.

Target user: a photographer (also the developer) who wants full control over their own edit pipeline, on their own hardware, with no vendor lock-in on file formats.

## Platform & stack decision (already made — don't relitigate)

- **Platform:** macOS only, native app.
- **UI:** SwiftUI.
- **Image pipeline:** Core Image (`CIFilter`, `CIRAWFilter`, `CIContext`), GPU-backed via Metal automatically.
- **Preview rendering:** `MTKView` or `CIContext` rendering into an `NSImage`/`CGImage` for a SwiftUI `Image` view — start with the simpler CGImage path, optimize to MTKView only if preview lag becomes a real problem.
- **Catalog storage:** SQLite via `GRDB.swift` (preferred over raw Core Data for simplicity and portability of the schema).
- **RAW decoding:** `CIRAWFilter` (built into Core Image, no external dependency needed initially).

Rationale (for context, not to be re-derived): Core Image's filter chaining IS a non-destructive edit graph for free, and its RAW filter handles demosaicing/white balance without hand-rolling that math. This collapses most of the "hard" GPU work into API calls, leaving the actual engineering effort on the edit-stack data model, UI, and catalog.

## Core architectural principle: non-destructive editing

**Never bake edits into pixels until export.** The source of truth for an edited photo is:
1. The original file, untouched, on disk.
2. A JSON-serializable list of edit operations (the "edit stack") associated with that file's ID in the catalog.

Every preview render replays the edit stack against the original via a fresh `CIImage` filter chain. Undo/redo, before-after toggling, and re-editing later are then trivial — they're just stack manipulation, not pixel manipulation.

## Data model (write this first)

```swift
struct EditStack: Codable {
    var exposure: Double = 0       // EV stops, e.g. -2.0...+2.0
    var contrast: Double = 0       // -100...100
    var whiteBalanceTemp: Double = 6500  // Kelvin
    var whiteBalanceTint: Double = 0
    var saturation: Double = 0     // -100...100
    var highlights: Double = 0
    var shadows: Double = 0
    var toneCurvePoints: [CGPoint] = []  // control points, identity by default
    // add fields incrementally — don't pre-build fields for features not yet implemented
}

struct CatalogEntry: Codable, Identifiable {
    let id: UUID
    let fileURL: URL
    let dateImported: Date
    var editStack: EditStack
    var thumbnailPath: URL?
}
```

Keep `EditStack` flat and simple at first. Resist adding masks/local-adjustment fields until the global sliders work end to end.

## Suggested project structure

```
PhotoEditor/
  App/
    PhotoEditorApp.swift          # @main entry point
  Models/
    EditStack.swift
    CatalogEntry.swift
  Pipeline/
    ImageDecoder.swift            # wraps CIRAWFilter + plain image loading
    EditRenderer.swift            # EditStack -> CIImage filter chain
    Exporter.swift                # full-res render to disk, color profile handling
  Catalog/
    CatalogStore.swift            # GRDB wrapper: CRUD for CatalogEntry
    ThumbnailGenerator.swift
  Views/
    LibraryView.swift             # grid of thumbnails
    EditView.swift                # main editing screen: image + slider panel
    SliderPanel/
      ExposureSlider.swift
      ToneCurveEditor.swift
      ...
  Resources/
```

## Phased milestones (build in this order — each should be a working, demoable state)

**Phase 0 — skeleton**
- SwiftUI app opens, shows an empty window with a "Import Photo" button.
- File picker loads a JPEG, displays it unmodified in the view.

**Phase 1 — first edit**
- Add exposure and contrast sliders.
- Build `EditRenderer`: takes a `CIImage` + `EditStack`, applies `CIExposureAdjust` and `CIColorControls`, returns a rendered `CGImage` for display.
- Confirm the preview updates live as sliders move. This proves the whole render loop.

**Phase 2 — full slider set + histogram**
- Add white balance, saturation, highlights/shadows, tone curve.
- Add a live histogram view (read pixel buffer, bin into 256 buckets, draw as a simple bar view).

**Phase 3 — persistence & catalog**
- Wire up GRDB. On import, create a `CatalogEntry`. On edit, persist the `EditStack` (debounce writes — don't hit SQLite on every slider tick).
- Build `LibraryView`: grid of thumbnails from the catalog, click to open in `EditView`.
- Add undo/redo (should be near-free if EditStack mutations go through a single update function).

**Phase 4 — RAW support**
- Swap the plain image loader for `CIRAWFilter` when the file extension is a RAW format (start with one camera's format you actually shoot, e.g. whatever your own camera produces, rather than trying to support all RAW variants at once).

**Phase 5 — export**
- Full-resolution render path (separate from the preview path — preview can be downsampled for speed, export must not be).
- Correct color profile embedding on write (sRGB minimum; consider Display P3 as an option later).

**Phase 6 (stretch, do last, may not be needed for v1)**
- Local adjustments: brush/gradient masks. This is the genuinely hard part — a `CIImage` masked blend of two filter chains. Don't attempt until phases 0–5 are solid.

## Explicit non-goals (repeat to avoid scope creep)

- No AI subject selection, no auto-enhance, no cloud anything.
- No cross-platform requirement — macOS-only is fine.
- No plugin system.
- No attempt to match Adobe's UI pixel-for-pixel — functional parity on the core edit loop is the goal.

## Immediate first task for Claude Code

Scaffold the Xcode project structure above, implement Phase 0 and Phase 1 fully (import a JPEG, exposure + contrast sliders driving a live Core Image render), and stop there for review before continuing to Phase 2.