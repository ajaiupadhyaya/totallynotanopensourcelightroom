# Develop Grammar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the interaction-grammar gap with Lightroom's develop module — free zoom with a navigator, Y/⇧Y before-after modes, an interactive histogram, a free-point curve with a Targeted Adjustment Tool, color-grading wheels, preset hover-preview/amount/folders/import-export, scoped copy/paste with Previous, solo mode and lights-out — all drawn in the existing Theme language, with zero change to how any existing photo renders.

**Architecture:** Everything is view/interaction state layered onto the existing single truth: gestures write the same `editStack` fields the faders bind (the histogram drag *is* the Blacks slider), zoom/pan/compare/lights-out stay unpersisted view state on `EditorModel`/`WorkspaceModel`, and every geometric decision (zoom anchor, navigator rect, curve points, TAT weighting, scope algebra) is a pure function in a small model file with unit tests. The only renderer-visible changes are lenient-decoded and identity-at-default: a variable-length curve point list whose 5-point case still routes through `CIToneCurve` bit-for-bit, and a `ColorGrading.global` zone that decodes neutral. Spec: `docs/superpowers/specs/2026-08-05-develop-grammar-design.md`.

**Tech Stack:** Swift 5 / SwiftUI + AppKit event bridges (`NSViewRepresentable`, `NSEvent` monitors — the `ToolKeyMonitor` house pattern), Core Image, GRDB/SQLite catalog, XcodeGen, XCTest.

## Global Constraints

- **XcodeGen owns the project.** After creating or deleting ANY source/test file, run `xcodegen generate` before building. `project.yml` is the source of truth.
- **Build/test command** (from repo root `~/Documents/totallynotanopensourcelightroom`):
  `xcodebuild -project PhotoEditor.xcodeproj -scheme PhotoEditor -destination 'platform=macOS' -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO test -only-testing:PhotoEditorTests/<ClassName>`
  Run **scoped** (`-only-testing:`) per step; run the full suite (drop `-only-testing:`) at most once per task — repeated consecutive full runs can exhaust GPU/XPC services.
- SWIFT_VERSION is pinned 5.0; add **no** dependencies.
- **Commit per task**, message style `feat(canvas): …` / `test(develop): …`; the PreToolUse hook enforces the noreply git author — fix repo config, never route around it.
- **`editStack` gestures are single-assignment:** every gesture tick builds its result on a local value and writes exactly one `editStack` field (or `editStack` itself) once — one debounced undo step, one render. `EditorModel.autoConvertNegative` is the reference pattern. Histogram drags, TAT drags, curve edits and preset applies in this plan all follow it.
- **Every new persisted field decodes leniently** (`c.lenient(.key, fallback)` — `Sources/Models/LenientDecoding.swift`) with a fallback that reproduces pre-change rendering. This plan adds exactly two persisted things: `EditStack.toneCurvePoints` becomes variable-length (absent → `[]`, five points → the exact `CIToneCurve` path today's photos render through, bit-for-bit) and `ColorGrading.global` (decodes `ColorGradeZone()`, an exact no-op).
- **Every new EditStack scalar needs conformance coverage or an exclusion.** `Tests/ControlConformanceTests.swift`'s reflection completeness test walks `EditStack`'s top-level stored properties; `color` is excluded there in favor of `ColorSuiteTests` — so `ColorGrading.global` gets its render-conformance test in `Tests/ColorSuiteTests.swift` (Task 6). Nothing else in this plan adds an `EditStack` field.
- **Frozen forever:** PV1 (`LegacyToneRenderer`) and the `.matrix` engine. `LegacyToneRenderer.swift` is not touched by any task here — its `toneCurvePoints.count == 5` guard means a PV1 photo simply ignores a free point list, and the curve editor gates free-point editing on `processVersion >= 2`.
- **Bare-key shortcuts go through `ToolKeyMonitor` — NEVER SwiftUI `keyboardShortcut` or a menu key binding.** `Y`, `⇧Y`, `L`, `T` and `Esc` are bare keys: a SwiftUI key equivalent fires while the library search field or a naming field holds focus, and typing "yellow" into search must not flip compare modes. Menu items for bare-key commands carry the key in their **label** (`"Compare Side by Side  (Y)"`), exactly like the existing Develop ▸ Tool submenu.
- **Theme language only.** No stock controls (the one alert this plan touches gets *replaced* by a drawn `InstrumentField` sheet), no decorative gradients or shadows, colour only where it is data (histogram channels, the wheel interior, clip flags). Motion only from `Theme.quick/standard/expand`; compare transitions and lights-out are **instant**. Monospace only for measured values; labels in the text face.
- **View state is not persisted.** Zoom, pan, compare mode, split position, hover readouts, TAT state, preset preview and lights-out never touch the catalog and never reach export. The solo/expansion state persists the way it already does (`@AppStorage` keys `panel.v3.expanded.<title>`).
- Tests build editors with the `Tests/EditorModelTests.swift` / `Tests/CanvasToolTests.swift` pattern (`TestSupport.makeTempPNG`, `inMemoryCatalog`, `makeEntry`, `tempThumbnails`, `commitDelay: 60`); `EditorModel` renders synchronously under XCTest, so `displayImage` is inspectable immediately after a mutation.

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `Sources/Views/CanvasZoom.swift` | create | `ZoomMath` + `NavigatorMath` — pure anchor/detent/fit/navigator arithmetic |
| `Sources/Views/Controls/MouseEventView.swift` | create | Scroll-wheel / pinch / right-click NSView bridge that passes left clicks through |
| `Sources/Views/NavigatorPanel.swift` | create | The drawn navigator card |
| `Sources/Views/CanvasArea.swift` | modify | Gesture-zoom wiring, navigator overlay, compare layouts, TAT drag overlay, hover sampling |
| `Sources/Views/EditorModel.swift` | modify | Gesture zoom, compare mode, hover sampler, histogram drag, TAT drag, preset preview |
| `Sources/Views/ToolKeyMonitor.swift` | modify | `Y` / `⇧Y` / `Esc` / `L` routing |
| `Sources/App/EditorCommands.swift` | modify | Zoom In/Out, compare, lights-out, scoped copy, Previous, preset import menu items |
| `Sources/App/PhotoEditorApp.swift` | modify | Copy-settings sheet presentation + lights-out veils in `RootView` |
| `Sources/Models/WorkspaceState.swift` | modify | `EditorTool.targetedAdjustment` |
| `Sources/Views/WorkspaceModel.swift` | modify | `activate` case for TAT + lights-out state |
| `Sources/Pipeline/Histogram.swift` | modify | Per-channel clip flags |
| `Sources/Views/HistogramView.swift` | modify | `showsClipFlags` parameter (drawing unchanged) |
| `Sources/Views/HistogramInteraction.swift` | create | `HistogramRegion` mapping + `InteractiveHistogram` view |
| `Sources/Views/PixelSampler.swift` | create | Small-buffer CGImage colour sampling for readout/TAT |
| `Sources/Views/InspectorPanel.swift` | modify | Swap in `InteractiveHistogram` |
| `Sources/Models/CurvePointModel.swift` | create | Pure point-list editing (add/move/delete/seed) |
| `Sources/Views/SliderPanel/ToneCurveEditor.swift` | modify | Free points, right-click delete, in/out readout |
| `Sources/Views/SliderPanel/CurvePanel.swift` | modify | `allowsFreePoints` gate |
| `Sources/Pipeline/EditRenderer.swift` | modify | Free-point curve path (`CIColorCurves`); 5-point path byte-identical |
| `Sources/Models/TATMath.swift` | create | TAT curve/mixer weighting (pure) |
| `Sources/Views/ToolRail.swift` | modify | TAT options bar; `MiniContextFader` deleted (Task 8) |
| `Sources/Models/ColorSettings.swift` | modify | `ColorGrading.global` (lenient) |
| `Sources/Pipeline/ColorCubeBuilder.swift` | modify | Global zone summed into the grade |
| `Sources/Views/Controls/ColorWheel.swift` | create | Drawn hue/sat wheel + `ColorWheelMath` |
| `Sources/Views/SliderPanel/ColorMixerPanel.swift` | modify | `ColorGradingPanel` wheels + Global tab |
| `Sources/Models/DevelopPreset.swift` | modify | Amount blending, JSON import/export, folder-name parsing |
| `Sources/Views/SliderPanel/PresetPanel.swift` | modify | Hover preview, amount, folders, drawn naming sheet, import/export |
| `Sources/App/AppModel.swift` | modify | Scoped copy state, Previous, preset import/export, sheet flag |
| `Sources/Models/TransferScope.swift` | create | `PipelineSection` + `TransferScope` (scope algebra, pure) |
| `Sources/Views/CopySettingsSheet.swift` | create | Drawn scope-checkbox dialog |
| `Sources/Views/SliderPanel/AdjustmentSlider.swift` | modify | `.compact` style |
| `Sources/Views/SliderPanel/PanelSection.swift` | modify | Solo mode (`PanelExpansion`) |
| `Sources/Views/SliderPanel/SliderPanel.swift` | modify | Solo titles + `isModified` delegating to `PipelineSection` |
| `Sources/Views/Theme.swift` | modify | `lightsOutVeil(_:)` |
| `Tests/ZoomMathTests.swift` | create | Anchor invariance, detents, clamp, fit, navigator, model gesture zoom |
| `Tests/CompareModeTests.swift` | create | Y/⇧Y toggling, before render honesty |
| `Tests/HistogramInteractionTests.swift` | create | Region map, drag→field writes, per-channel clip flags, `PixelSampler` |
| `Tests/CurvePointModelTests.swift` | create | Point-list editing + decode fallback |
| `Tests/FreeCurveRenderTests.swift` | create | 5-point semantics pinned; free path renders; PV1 ignores free lists |
| `Tests/TATMathTests.swift` | create | Band weights, curve/mixer drags, tool activation |
| `Tests/ColorWheelTests.swift` | create | Wheel math round-trip + `ColorGrading.global` decode |
| `Tests/PresetWorkflowTests.swift` | create | Amount blending, hover preview, naming parse, JSON round-trip |
| `Tests/TransferScopeTests.swift` | create | Scope algebra, gap fixes, Previous |
| `Tests/PanelExpansionTests.swift` | create | Solo over `UserDefaults`; lights-out cycling |
| `Tests/ColorSuiteTests.swift` | modify | Global-grade render conformance |
| `CHANGELOG.md` | modify | Task 11 |

---

### Task 1: Free zoom + navigator

Continuous 25–400% zoom anchored at the pointer, with the four existing stops (Fit/50/100/200) as snap detents, gesture zoom keeping its anchored pan while stop-jumps keep today's centre-reset, and a drawn navigator card. All arithmetic is pure and mirrors `EditCanvas.imageRect(in:)`'s layout formula (drawn = `imageSize × scale`, centred plus `panOffset`, `fitInset = 28`); the viewport-sized Metal drawable (`MetalCanvasView`) makes this a transform change, and the existing `(zoomLevel ?? 0) >= 1.0` full-res trigger in `EditorModel.activeRenderSource()` keys off the same value it always did.

**Files:**
- Create: `Sources/Views/CanvasZoom.swift`, `Sources/Views/Controls/MouseEventView.swift`, `Sources/Views/NavigatorPanel.swift`, `Tests/ZoomMathTests.swift`
- Modify: `Sources/Views/EditorModel.swift`, `Sources/Views/CanvasArea.swift`, `Sources/App/EditorCommands.swift`

**Interfaces:**
- Consumes: `EditorModel.zoomLevel/panOffset/previewPixelSize/displayImage`, `EditCanvas.fitInset`, the `clampedPan` clamp formula.
- Produces (later tasks and the views rely on these exact names): `ZoomMath.fitScale/clamped/snapped/pan(anchoring:…)`, `NavigatorMath.visibleUnitRect/pan(centeringUnitPoint:…)`, `EditorModel.applyGestureZoom(scale:pan:)`, `EditorModel.zoomStep(_:)`, `MouseEventView` (reused for right-click in Task 4).

- [x] **Step 1: Write the failing tests**

Create `Tests/ZoomMathTests.swift`:

```swift
import XCTest
@testable import PhotoEditor

/// The free-zoom arithmetic: the anchor invariant, the detents, the clamp,
/// the fit law, and the navigator's geometry. All pure — no canvas needed.
final class ZoomMathTests: XCTestCase {
    private let viewport = CGSize(width: 800, height: 600)
    private let image = CGSize(width: 4000, height: 3000)

    /// The point under the pointer must not move when the scale changes —
    /// the entire reason gesture zoom exists. The layout formula here is the
    /// same one EditCanvas.imageRect(in:) uses: centred plus pan.
    func testAnchorStaysUnderThePointerAcrossAZoomStep() {
        let anchor = CGPoint(x: 530, y: 210)
        let s0 = 0.7, s1 = 1.13
        let pan0 = CGSize(width: -40, height: 25)
        func origin(_ scale: Double, _ pan: CGSize) -> CGPoint {
            CGPoint(x: (viewport.width - image.width * scale) / 2 + pan.width,
                    y: (viewport.height - image.height * scale) / 2 + pan.height)
        }
        let u = CGPoint(x: (anchor.x - origin(s0, pan0).x) / (image.width * s0),
                        y: (anchor.y - origin(s0, pan0).y) / (image.height * s0))
        let pan1 = ZoomMath.pan(anchoring: anchor, viewport: viewport, imageSize: image,
                                oldScale: s0, oldPan: pan0, newScale: s1)
        XCTAssertEqual(origin(s1, pan1).x + u.x * image.width * s1, anchor.x, accuracy: 1e-9)
        XCTAssertEqual(origin(s1, pan1).y + u.y * image.height * s1, anchor.y, accuracy: 1e-9)
    }

    func testSnappingCatchesTheFourStopsAndOnlyThem() {
        XCTAssertEqual(ZoomMath.snapped(1.01, fitScale: 0.18), 1.0)
        XCTAssertEqual(ZoomMath.snapped(0.505, fitScale: 0.18), 0.5)
        XCTAssertEqual(ZoomMath.snapped(1.98, fitScale: 0.18), 2.0)
        XCTAssertNil(ZoomMath.snapped(0.181, fitScale: 0.18),
                     "near the fit scale snaps to Fit — nil, the stop-jump value")
        XCTAssertEqual(ZoomMath.snapped(1.31, fitScale: 0.18), 1.31,
                       "between detents the zoom is genuinely continuous")
    }

    func testClampingBoundsTheGestureRange() {
        XCTAssertEqual(ZoomMath.clamped(0.01), 0.25)
        XCTAssertEqual(ZoomMath.clamped(11), 4.0)
    }

    /// The existing law restated over the extracted function: a frame smaller
    /// than the viewport shows at its own size, never interpolated up.
    func testFitNeverEnlarges() {
        XCTAssertEqual(ZoomMath.fitScale(imageSize: CGSize(width: 200, height: 100),
                                         viewport: viewport, inset: 28), 1.0)
        XCTAssertLessThan(ZoomMath.fitScale(imageSize: image, viewport: viewport, inset: 28), 1.0)
    }

    func testNavigatorRectAndCenteringRoundTrip() {
        let pan = NavigatorMath.pan(centeringUnitPoint: CGPoint(x: 0.7, y: 0.4),
                                    imageSize: image, scale: 2.0)
        let visible = NavigatorMath.visibleUnitRect(viewport: viewport, imageSize: image,
                                                    scale: 2.0, pan: pan)
        XCTAssertEqual(visible.midX, 0.7, accuracy: 1e-6)
        XCTAssertEqual(visible.midY, 0.4, accuracy: 1e-6)
    }

    func testNavigatorRectClampsLikeTheCanvasDoes() {
        let visible = NavigatorMath.visibleUnitRect(viewport: viewport, imageSize: image,
                                                    scale: 2.0,
                                                    pan: CGSize(width: 1e6, height: 0))
        XCTAssertEqual(visible.minX, 0, accuracy: 1e-9,
                       "an over-panned rect must clamp exactly where clampedPan clamps the image")
    }
}

/// Gesture zoom against the live model: the one behaviour the old didSet
/// forbade — a zoom that keeps its pan — plus proof the stop-jump reset stays.
@MainActor
final class GestureZoomModelTests: XCTestCase {
    private func makeEditor() throws -> (editor: EditorModel, url: URL) {
        let url = try TestSupport.makeTempPNG(gray: 128)
        let catalog = try TestSupport.inMemoryCatalog()
        let entry = TestSupport.makeEntry(fileURL: url)
        try catalog.save(entry)
        return (EditorModel(entry: entry, catalog: catalog,
                            thumbnails: TestSupport.tempThumbnails(), commitDelay: 60), url)
    }

    func testGestureZoomKeepsItsAnchoredPanAndStopJumpsStillRecentre() throws {
        let (editor, url) = try makeEditor()
        defer { try? FileManager.default.removeItem(at: url) }

        editor.applyGestureZoom(scale: 2.0, pan: CGSize(width: 33, height: -12))
        XCTAssertEqual(editor.zoomLevel, 2.0)
        XCTAssertEqual(editor.panOffset, CGSize(width: 33, height: -12),
                       "the anchored pan must survive the zoom write")

        editor.zoomLevel = 1.0 // menu / TabStrip / double-click path
        XCTAssertEqual(editor.panOffset, .zero, "stop-jumps keep today's centre-reset")
    }

    func testGestureZoomToFitClearsThePan() throws {
        let (editor, url) = try makeEditor()
        defer { try? FileManager.default.removeItem(at: url) }
        editor.applyGestureZoom(scale: 2.0, pan: CGSize(width: 33, height: 0))
        editor.applyGestureZoom(scale: nil, pan: CGSize(width: 99, height: 99))
        XCTAssertNil(editor.zoomLevel)
        XCTAssertEqual(editor.panOffset, .zero, "Fit is centred by definition")
    }

    func testZoomStepWalksTheLadder() throws {
        let (editor, url) = try makeEditor()
        defer { try? FileManager.default.removeItem(at: url) }
        editor.zoomStep(1)
        XCTAssertEqual(editor.zoomLevel, 1.0, "from Fit, zoom-in enters at 100% — the double-click convention")
        editor.zoomStep(1)
        XCTAssertEqual(editor.zoomLevel, 2.0)
        editor.zoomLevel = 0.7
        editor.zoomStep(-1)
        XCTAssertEqual(editor.zoomLevel, 0.5, "a free value steps to the nearest rung in the travel direction")
    }
}
```

- [x] **Step 2: Run to verify failure**

Run: `xcodegen generate`, then the build/test command with `-only-testing:PhotoEditorTests/ZoomMathTests`.
Expected: COMPILE FAILURE (`ZoomMath`, `applyGestureZoom` do not exist) — this cycle's red.

- [x] **Step 3: Implement `Sources/Views/CanvasZoom.swift`**

```swift
import CoreGraphics

/// The free-zoom arithmetic, kept pure so the anchor invariant is provable.
///
/// The canvas's layout contract (see `EditCanvas.imageRect(in:)`): the drawn
/// frame is `imageSize × scale`, centred in the viewport plus `panOffset`.
/// Every function here works against exactly that formula — change one side
/// and these tests and the canvas fail together, loudly.
enum ZoomMath {
    /// Continuous zoom bounds: 25%…400%.
    static let minimumZoom = 0.25
    static let maximumZoom = 4.0

    /// The classic stops stay as detents inside the continuous range. Fit is
    /// the fourth detent, expressed as `nil` (the stop-jump value).
    static let detents: [Double] = [0.5, 1.0, 2.0]

    /// Relative width of a detent's capture band. 3% feels magnetic without
    /// making 96% unreachable.
    static let detentTolerance = 0.03

    /// One point of precise scroll sweeps this fraction of an octave — a full
    /// flick is about a doubling. A taste constant; verified in-app.
    static let wheelOctavesPerPoint = 1.0 / 250.0

    /// Mirrors `EditCanvas.imageRect(in:)`'s fit computation exactly: fill
    /// the inset viewport, but never enlarge (`min(…, 1)`).
    static func fitScale(imageSize: CGSize, viewport: CGSize, inset: CGFloat) -> Double {
        guard imageSize.width > 0, imageSize.height > 0,
              viewport.width > 0, viewport.height > 0 else { return 1 }
        let available = CGSize(width: max(viewport.width - inset * 2, 40),
                               height: max(viewport.height - inset * 2, 40))
        return Double(min(available.width / imageSize.width,
                          available.height / imageSize.height, 1))
    }

    static func clamped(_ proposed: Double) -> Double {
        min(max(proposed, minimumZoom), maximumZoom)
    }

    /// Detent snapping. Returns `nil` for "snap to Fit" — the caller writes
    /// `zoomLevel = nil`, exactly the value the stop-jump paths use.
    static func snapped(_ proposed: Double, fitScale: Double) -> Double? {
        let scale = clamped(proposed)
        if fitScale > 0, abs(scale - fitScale) / fitScale < detentTolerance { return nil }
        for detent in detents where abs(scale - detent) / detent < detentTolerance {
            return detent
        }
        return scale
    }

    /// The pan that keeps the image point under `anchor` stationary across
    /// `oldScale → newScale`. Anchor and pans are in viewport points
    /// (top-left origin, the layout's own space).
    static func pan(anchoring anchor: CGPoint, viewport: CGSize, imageSize: CGSize,
                    oldScale: Double, oldPan: CGSize, newScale: Double) -> CGSize {
        let oldDrawn = CGSize(width: imageSize.width * oldScale,
                              height: imageSize.height * oldScale)
        let newDrawn = CGSize(width: imageSize.width * newScale,
                              height: imageSize.height * newScale)
        guard oldDrawn.width > 0, oldDrawn.height > 0 else { return oldPan }
        let oldOrigin = CGPoint(x: (viewport.width - oldDrawn.width) / 2 + oldPan.width,
                                y: (viewport.height - oldDrawn.height) / 2 + oldPan.height)
        // The image-relative point under the pointer…
        let u = CGPoint(x: (anchor.x - oldOrigin.x) / oldDrawn.width,
                        y: (anchor.y - oldOrigin.y) / oldDrawn.height)
        // …pinned in place at the new scale.
        return CGSize(
            width: anchor.x - u.x * newDrawn.width - (viewport.width - newDrawn.width) / 2,
            height: anchor.y - u.y * newDrawn.height - (viewport.height - newDrawn.height) / 2
        )
    }
}

/// The navigator's geometry: which part of the frame is on screen, and the
/// pan that centres a clicked point. Unit space is the frame's own, top-left
/// origin — the space the thumbnail is drawn in. Same layout contract as
/// `ZoomMath`, including the pan clamp `EditCanvas.clampedPan` applies.
enum NavigatorMath {
    static func visibleUnitRect(viewport: CGSize, imageSize: CGSize,
                                scale: Double, pan: CGSize) -> CGRect {
        let drawn = CGSize(width: imageSize.width * scale,
                           height: imageSize.height * scale)
        guard drawn.width > 0, drawn.height > 0 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        func limit(_ drawnLength: CGFloat, _ viewportLength: CGFloat) -> CGFloat {
            max((drawnLength - viewportLength) / 2, 0)
        }
        let clamped = CGSize(
            width: min(max(pan.width, -limit(drawn.width, viewport.width)),
                       limit(drawn.width, viewport.width)),
            height: min(max(pan.height, -limit(drawn.height, viewport.height)),
                        limit(drawn.height, viewport.height))
        )
        let origin = CGPoint(x: (viewport.width - drawn.width) / 2 + clamped.width,
                             y: (viewport.height - drawn.height) / 2 + clamped.height)
        return CGRect(x: (0 - origin.x) / drawn.width,
                      y: (0 - origin.y) / drawn.height,
                      width: viewport.width / drawn.width,
                      height: viewport.height / drawn.height)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// The pan that puts unit point `p` at the viewport's centre. Falls out
    /// of the layout formula as `drawn × (0.5 − p)`.
    static func pan(centeringUnitPoint p: CGPoint, imageSize: CGSize, scale: Double) -> CGSize {
        CGSize(width: imageSize.width * scale * (0.5 - p.x),
               height: imageSize.height * scale * (0.5 - p.y))
    }
}
```

- [x] **Step 4: `EditorModel` — the gesture entry point**

In `Sources/Views/EditorModel.swift`, replace the `zoomLevel` property (currently at the `// MARK: View state (not persisted)` section) and add the two methods:

```swift
    /// Zoom factor over image pixels; nil fits the frame to the viewport.
    /// Owned here so the top bar and the canvas share one value.
    var zoomLevel: Double? {
        didSet {
            guard zoomLevel != oldValue else { return }
            // Stop-jumps (menu, TabStrip, double-click) re-centre, as ever —
            // keeping an old pan across a jump routinely lands you on empty
            // canvas. Gesture zoom carries its own anchor-preserving pan and
            // must NOT be re-centred, or the point under the pointer walks.
            if !isGestureZoom { panOffset = .zero }
            renderPreview()
        }
    }

    /// True while `applyGestureZoom` is writing, so the observer above keeps
    /// the anchored pan the gesture just computed.
    private var isGestureZoom = false

    /// One tick of wheel/pinch zoom: the snapped scale and the pan that keeps
    /// the anchor stationary, written together. `nil` scale means the gesture
    /// landed on the Fit detent.
    func applyGestureZoom(scale: Double?, pan: CGSize) {
        isGestureZoom = true
        defer { isGestureZoom = false }
        panOffset = scale == nil ? .zero : pan
        zoomLevel = scale
    }

    /// ⌘+ / ⌘−: steps through the stop ladder, entering at 100% from Fit —
    /// the double-click convention. A stop-jump, so the centre-reset applies.
    func zoomStep(_ direction: Int) {
        let ladder = [ZoomMath.minimumZoom, 0.5, 1.0, 2.0, ZoomMath.maximumZoom]
        guard let current = zoomLevel else {
            zoomLevel = direction > 0 ? 1.0 : nil
            return
        }
        if let index = ladder.firstIndex(where: { abs($0 - current) / $0 < 0.001 }) {
            zoomLevel = ladder[min(max(index + direction, 0), ladder.count - 1)]
        } else {
            zoomLevel = direction > 0
                ? ladder.first { $0 > current } ?? ladder.last
                : ladder.last { $0 < current } ?? ladder.first
        }
    }
```

- [x] **Step 5: Run ZoomMathTests + GestureZoomModelTests** — expected PASS. Also run `-only-testing:PhotoEditorTests/CanvasToolTests` (placement + histogram untouched) — PASS.

- [x] **Step 6: The event bridge — `Sources/Views/Controls/MouseEventView.swift`**

```swift
import AppKit
import SwiftUI

/// The mouse events SwiftUI has no gesture for — scroll wheel, trackpad
/// magnification, right-click — reported from an NSView laid over a region.
///
/// The view claims ONLY the event types its callbacks handle: `hitTest`
/// inspects the current event and returns nil for everything else, so left
/// clicks and drags fall through to the SwiftUI gestures beneath it. That is
/// what lets it sit over the canvas without eating the pan gesture, and over
/// the curve editor without eating point drags.
struct MouseEventView: NSViewRepresentable {
    /// Precise scroll: location in this view's top-left coordinates + deltaY.
    var onScroll: ((CGPoint, CGFloat) -> Void)?
    /// Trackpad pinch: location + this event's magnification delta.
    var onMagnify: ((CGPoint, CGFloat) -> Void)?
    var onRightClick: ((CGPoint) -> Void)?

    func makeNSView(context: Context) -> EventView {
        let view = EventView()
        view.onScroll = onScroll
        view.onMagnify = onMagnify
        view.onRightClick = onRightClick
        return view
    }

    func updateNSView(_ view: EventView, context: Context) {
        view.onScroll = onScroll
        view.onMagnify = onMagnify
        view.onRightClick = onRightClick
    }

    final class EventView: NSView {
        var onScroll: ((CGPoint, CGFloat) -> Void)?
        var onMagnify: ((CGPoint, CGFloat) -> Void)?
        var onRightClick: ((CGPoint) -> Void)?

        // Top-left origin, matching the SwiftUI layout coordinates every
        // caller thinks in.
        override var isFlipped: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            switch NSApp.currentEvent?.type {
            case .scrollWheel: return onScroll != nil ? super.hitTest(point) : nil
            case .magnify: return onMagnify != nil ? super.hitTest(point) : nil
            case .rightMouseDown, .rightMouseUp:
                return onRightClick != nil ? super.hitTest(point) : nil
            default: return nil
            }
        }

        override func scrollWheel(with event: NSEvent) {
            guard let onScroll else { return super.scrollWheel(with: event) }
            onScroll(convert(event.locationInWindow, from: nil), event.scrollingDeltaY)
        }

        override func magnify(with event: NSEvent) {
            guard let onMagnify else { return }
            onMagnify(convert(event.locationInWindow, from: nil), event.magnification)
        }

        override func rightMouseDown(with event: NSEvent) {
            guard let onRightClick else { return }
            onRightClick(convert(event.locationInWindow, from: nil))
        }
    }
}
```

- [x] **Step 7: Wire the canvas**

In `Sources/Views/CanvasArea.swift`, inside `EditCanvas.viewport`'s `ZStack` (between `overlays(in: rect)` and the `Color.clear` gesture layer — the hitTest filter means order barely matters, but keeping it under the click layer is tidy):

```swift
                MouseEventView(
                    onScroll: { location, deltaY in
                        gestureZoom(factor: pow(2, Double(deltaY) * ZoomMath.wheelOctavesPerPoint),
                                    anchor: location, viewport: viewportSize)
                    },
                    onMagnify: { location, delta in
                        gestureZoom(factor: 1 + Double(delta),
                                    anchor: location, viewport: viewportSize)
                    }
                )
```

And add the helper to `EditCanvas`:

```swift
    /// Shared by wheel and pinch: scale about the pointer, snap to the
    /// detents, keep the anchored point still. One editor call per tick.
    private func gestureZoom(factor: Double, anchor: CGPoint, viewport: CGSize) {
        guard let size = editor.previewPixelSize else { return }
        let fit = ZoomMath.fitScale(imageSize: size, viewport: viewport, inset: fitInset)
        let oldScale = editor.zoomLevel ?? fit
        let snapped = ZoomMath.snapped(ZoomMath.clamped(oldScale * factor), fitScale: fit)
        let pan = ZoomMath.pan(anchoring: anchor, viewport: viewport, imageSize: size,
                               oldScale: oldScale, oldPan: editor.panOffset,
                               newScale: snapped ?? fit)
        editor.applyGestureZoom(scale: snapped, pan: pan)
    }
```

- [x] **Step 8: The navigator — `Sources/Views/NavigatorPanel.swift`**

```swift
import SwiftUI

/// The navigator: a fit-view thumbnail with the visible region marked and
/// click/drag-to-pan, shown only while the frame overflows the viewport —
/// the only time it has anything to say. Reuses the already-rendered preview
/// (`displayImage`); no extra render path. Drawn card, machined edge, no
/// drop shadow — the edge is the app's one depth device.
struct NavigatorPanel: View {
    @Bindable var editor: EditorModel
    let viewportSize: CGSize
    let fitInset: CGFloat

    private let cardWidth: CGFloat = 148

    var body: some View {
        if let image = editor.displayImage,
           let size = editor.previewPixelSize,
           let scale = editor.zoomLevel {
            let fit = ZoomMath.fitScale(imageSize: size, viewport: viewportSize, inset: fitInset)
            if scale > fit {
                let cardHeight = cardWidth * size.height / size.width
                let visible = NavigatorMath.visibleUnitRect(
                    viewport: viewportSize, imageSize: size,
                    scale: scale, pan: editor.panOffset)
                ZStack {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .frame(width: cardWidth, height: cardHeight)
                    Rectangle()
                        .stroke(Color.white.opacity(0.9), lineWidth: Theme.hairline * 1.5)
                        .frame(width: visible.width * cardWidth,
                               height: visible.height * cardHeight)
                        .position(x: visible.midX * cardWidth, y: visible.midY * cardHeight)
                }
                .frame(width: cardWidth, height: cardHeight)
                .clipped()
                .background(Theme.background)
                .machinedEdges(radius: Theme.radius)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0).onChanged { value in
                        let p = CGPoint(x: min(max(value.location.x / cardWidth, 0), 1),
                                        y: min(max(value.location.y / cardHeight, 0), 1))
                        editor.panOffset = NavigatorMath.pan(
                            centeringUnitPoint: p, imageSize: size, scale: scale)
                    }
                )
                .padding(Theme.space3)
                .accessibilityLabel("Navigator")
            }
        }
    }
}
```

Attach it in `EditCanvas.viewport` (the pan clamp in `imageRect` keeps whatever the navigator writes honest):

```swift
        .overlay(alignment: .bottomLeading) {
            NavigatorPanel(editor: editor, viewportSize: viewportSize, fitInset: fitInset)
        }
```

Note: this `.overlay` goes on the inner `ZStack` **inside** the `GeometryReader` (it needs `viewportSize`), above `.clipped()`.

- [x] **Step 9: Menu entries**

In `Sources/App/EditorCommands.swift`, extend the View `CommandGroup(after: .toolbar)` — after the existing "Zoom to 200%":

```swift
            Button("Zoom to 50%") { editor?.zoomLevel = 0.5 }
                .keyboardShortcut("5", modifiers: .command)
                .disabled(editor == nil)

            Divider()

            Button("Zoom In") { editor?.zoomStep(1) }
                .keyboardShortcut("=", modifiers: .command)
                .disabled(editor == nil)
            Button("Zoom Out") { editor?.zoomStep(-1) }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(editor == nil)
```

(⌘-modified keys are real menu shortcuts, not bare keys — the menu binding is correct here, matching ⌘0/⌘1/⌘2.)

- [x] **Step 10: Verify**

Run: `-only-testing:PhotoEditorTests/ZoomMathTests -only-testing:PhotoEditorTests/GestureZoomModelTests -only-testing:PhotoEditorTests/CanvasToolTests -only-testing:PhotoEditorTests/EditorModelTests`
Expected: ALL PASS. The status bar (`CanvasStatusBar`) already prints continuous values (`"\(Int($0 * 100))%"`), and the top-bar `TabStrip` simply shows no underline at a free value — both fine as-is.

- [x] **Step 11: Commit**

```bash
git add Sources/Views/CanvasZoom.swift Sources/Views/Controls/MouseEventView.swift Sources/Views/NavigatorPanel.swift Sources/Views/EditorModel.swift Sources/Views/CanvasArea.swift Sources/App/EditorCommands.swift Tests/ZoomMathTests.swift project.yml PhotoEditor.xcodeproj
git commit -m "feat(canvas): free zoom anchored at the pointer, detent stops, and a drawn navigator"
```

---

### Task 2: Before/after — Y side-by-side and ⇧Y split

`\` stays the momentary full-canvas Before. `Y` toggles side-by-side (before left, after right, shared zoom/pan), `⇧Y` toggles a one-image split with a draggable divider, `Esc` or the same key exits. Both keys are bare keys through `ToolKeyMonitor`. The before render reuses `EditorModel`'s existing `beforeStack` (geometry + film conversion kept, adjustments reset — exactly today's `\` semantics, which is what makes a negative's "before" the positive conversion). Transitions are instant.

**Files:**
- Create: `Tests/CompareModeTests.swift`
- Modify: `Sources/Views/EditorModel.swift`, `Sources/Views/CanvasArea.swift`, `Sources/Views/ToolKeyMonitor.swift`, `Sources/App/EditorCommands.swift`

**Interfaces:**
- Produces: `EditorModel.CompareMode { off, sideBySide, split }`, `EditorModel.compareMode`, `.splitPosition`, `.beforeCIImage`, `.toggleCompare(_:)`. Task 10 extends the same `Esc` branch in `ToolKeyMonitor`.

- [x] **Step 1: Write the failing tests**

Create `Tests/CompareModeTests.swift` (the `makeEditor` helper is the `EditorModelTests` pattern verbatim):

```swift
import CoreImage
import XCTest
@testable import PhotoEditor

@MainActor
final class CompareModeTests: XCTestCase {
    private func makeEditor() throws -> (editor: EditorModel, url: URL) {
        let url = try TestSupport.makeTempPNG(gray: 128)
        let catalog = try TestSupport.inMemoryCatalog()
        let entry = TestSupport.makeEntry(fileURL: url)
        try catalog.save(entry)
        return (EditorModel(entry: entry, catalog: catalog,
                            thumbnails: TestSupport.tempThumbnails(), commitDelay: 60), url)
    }

    func testYTogglesSideBySideAndTheSameKeyExits() throws {
        let (editor, url) = try makeEditor()
        defer { try? FileManager.default.removeItem(at: url) }

        editor.toggleCompare(.sideBySide)
        XCTAssertEqual(editor.compareMode, .sideBySide)
        editor.toggleCompare(.split)
        XCTAssertEqual(editor.compareMode, .split, "⇧Y switches modes directly")
        editor.toggleCompare(.split)
        XCTAssertEqual(editor.compareMode, .off, "repeating the key exits")
    }

    /// The before image must show the unedited interpretation — same source,
    /// adjustments reset — or the comparison lies.
    func testCompareRendersABeforeThatIgnoresTheEdit() throws {
        let (editor, url) = try makeEditor()
        defer { try? FileManager.default.removeItem(at: url) }

        editor.editStack.exposure = 2.0
        editor.toggleCompare(.sideBySide)

        let before = try XCTUnwrap(editor.beforeCIImage)
        let after = try XCTUnwrap(editor.previewCIImage)
        let beforeLuma = TestSupport.readColor(before)
        let afterLuma = TestSupport.readColor(after)
        XCTAssertGreaterThan(afterLuma.red, beforeLuma.red + 0.1,
                             "two stops of exposure must separate the panes")
    }

    /// "Before" keeps geometry: comparing a crop against an uncropped frame
    /// would just look like a different photo.
    func testBeforeKeepsTheCrop() throws {
        let (editor, url) = try makeEditor()
        defer { try? FileManager.default.removeItem(at: url) }

        editor.editStack.geometry.cropRect = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        editor.toggleCompare(.sideBySide)
        let before = try XCTUnwrap(editor.beforeCIImage)
        let after = try XCTUnwrap(editor.previewCIImage)
        XCTAssertEqual(before.extent, after.extent)
    }

    func testExitingCompareDropsTheBeforeRender() throws {
        let (editor, url) = try makeEditor()
        defer { try? FileManager.default.removeItem(at: url) }
        editor.toggleCompare(.sideBySide)
        XCTAssertNotNil(editor.beforeCIImage)
        editor.toggleCompare(.sideBySide)
        XCTAssertNil(editor.beforeCIImage, "no mode, no second render being paid for")
    }
}
```

- [x] **Step 2: Run** `-only-testing:PhotoEditorTests/CompareModeTests` — expected COMPILE FAILURE.

- [x] **Step 3: Implement the model**

In `Sources/Views/EditorModel.swift`, in the `// MARK: Before / after` section:

```swift
    /// The two-pane comparison grammar. View state, never persisted.
    enum CompareMode: Equatable {
        case off
        /// Before left, after right, shared zoom/pan (Y).
        case sideBySide
        /// One image, draggable divider — before left of it, after right (⇧Y).
        case split
    }

    var compareMode: CompareMode = .off {
        didSet {
            guard compareMode != oldValue else { return }
            renderPreview()
        }
    }

    /// The split divider, as a unit fraction of the viewport width.
    var splitPosition: Double = 0.5

    /// The "before" render while a compare mode is active; nil otherwise.
    private(set) var beforeCIImage: CIImage?

    /// One keystroke of the compare grammar: the key toggles its own mode,
    /// switches from the other, and exits when already showing.
    func toggleCompare(_ mode: CompareMode) {
        compareMode = compareMode == mode ? .off : mode
    }
```

In `renderPreviewNow()`, after `previewCIImage = shown` (and using the same `renderSource`):

```swift
        if compareMode != .off {
            var before = beforeStack
            if isCropping { before.geometry.cropRect = .unitFrame }
            beforeCIImage = renderEditedImage(from: renderSource, stack: before)
        } else {
            beforeCIImage = nil
        }
```

- [x] **Step 4: Run CompareModeTests** — expected PASS.

- [x] **Step 5: Key routing**

In `Sources/Views/ToolKeyMonitor.swift`, in `handle(_:)` after the `"\\"` branch (note `reserved` already lets ⇧ through, and `charactersIgnoringModifiers` gives `"y"` for both):

```swift
        if key == "y" {
            editor.toggleCompare(event.modifierFlags.contains(.shift) ? .split : .sideBySide)
            return true
        }

        // Escape backs out of the viewing states and is otherwise left alone:
        // crop's cancel button and sheets own it elsewhere, so it is consumed
        // ONLY when a viewing state is actually active.
        if event.keyCode == 53 {
            if editor.compareMode != .off {
                editor.compareMode = .off
                return true
            }
            return false
        }
```

- [x] **Step 6: The canvas layouts**

In `Sources/Views/CanvasArea.swift`, `EditCanvas.viewport`: replace the single `MetalCanvasView` line with a mode switch, and gate `overlays(in:)` on `editor.compareMode == .off` (mask/crop handles over half a comparison would address the wrong pixels):

```swift
                switch editor.compareMode {
                case .off:
                    MetalCanvasView(image: editor.previewCIImage,
                                    context: editor.renderContext,
                                    imageRect: rect)
                        .allowsHitTesting(false)
                case .sideBySide:
                    sideBySide(in: viewportSize)
                case .split:
                    splitView(rect: rect, in: viewportSize)
                }
```

Add to `EditCanvas`:

```swift
    /// Two half-viewports, each fitting the same frame with the shared
    /// zoom/pan — the halves compute their rects from the same state, so they
    /// stay in step by construction.
    private func sideBySide(in viewport: CGSize) -> some View {
        let half = CGSize(width: viewport.width / 2, height: viewport.height)
        let halfRect = imageRect(in: half)
        return HStack(spacing: 0) {
            ZStack {
                MetalCanvasView(image: editor.beforeCIImage,
                                context: editor.renderContext, imageRect: halfRect)
                paneLabel("BEFORE")
            }
            .frame(width: half.width)
            .clipped()
            Rule(axis: .vertical, color: Theme.strongSeparator)
            ZStack {
                MetalCanvasView(image: editor.previewCIImage,
                                context: editor.renderContext, imageRect: halfRect)
                paneLabel("AFTER")
            }
            .frame(width: half.width)
            .clipped()
        }
        .allowsHitTesting(false)
    }

    /// One image, one divider: the before render underneath, the after render
    /// masked to the divider's right. Pixel-aligned because both canvases get
    /// the SAME rect.
    private func splitView(rect: CGRect, in viewport: CGSize) -> some View {
        let dividerX = viewport.width * CGFloat(editor.splitPosition)
        return ZStack {
            MetalCanvasView(image: editor.beforeCIImage,
                            context: editor.renderContext, imageRect: rect)
                .allowsHitTesting(false)
            MetalCanvasView(image: editor.previewCIImage,
                            context: editor.renderContext, imageRect: rect)
                .allowsHitTesting(false)
                .mask(alignment: .topLeading) {
                    Rectangle()
                        .frame(width: max(viewport.width - dividerX, 0),
                               height: viewport.height)
                        .offset(x: dividerX)
                }
            // The divider: a hairline with a comfortable grab band.
            Rectangle()
                .fill(Color.white.opacity(0.85))
                .frame(width: Theme.hairline * 1.5, height: viewport.height)
                .position(x: dividerX, y: viewport.height / 2)
            Color.clear
                .frame(width: Theme.minimumHitTarget, height: viewport.height)
                .contentShape(Rectangle())
                .position(x: dividerX, y: viewport.height / 2)
                .gesture(
                    DragGesture(minimumDistance: 0).onChanged { value in
                        editor.splitPosition = min(max(
                            Double(value.location.x / viewport.width), 0.05), 0.95)
                    }
                )
        }
    }

    private func paneLabel(_ text: String) -> some View {
        VStack {
            HStack {
                Text(text)
                    .plateLabel()
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, Theme.space2)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.68), in: Capsule())
                Spacer()
            }
            Spacer()
        }
        .padding(Theme.space3)
    }
```

- [x] **Step 7: Menu entries** (bare keys → label hints only, no `keyboardShortcut`, per the house rule stated on `EditorCommands`)

In the View `CommandGroup(after: .toolbar)`, after the "Show Original" button:

```swift
            Button(editor?.compareMode == .sideBySide
                   ? "Exit Side by Side  (Y)" : "Compare Side by Side  (Y)") {
                editor?.toggleCompare(.sideBySide)
            }
            .disabled(editor == nil)

            Button(editor?.compareMode == .split
                   ? "Exit Split View  (⇧Y)" : "Compare Split View  (⇧Y)") {
                editor?.toggleCompare(.split)
            }
            .disabled(editor == nil)
```

- [x] **Step 8: Verify**

Run: `-only-testing:PhotoEditorTests/CompareModeTests -only-testing:PhotoEditorTests/EditorModelTests -only-testing:PhotoEditorTests/CanvasToolTests`
Expected: ALL PASS.

- [x] **Step 9: Commit**

```bash
git add Sources/Views/EditorModel.swift Sources/Views/CanvasArea.swift Sources/Views/ToolKeyMonitor.swift Sources/App/EditorCommands.swift Tests/CompareModeTests.swift project.yml PhotoEditor.xcodeproj
git commit -m "feat(compare): Y side-by-side and shift-Y split before/after, shared zoom, instant"
```

---

### Task 3: Interactive histogram — draggable regions, per-channel clip flags, RGB/Luma readout

The Inspector histogram becomes a control surface: five hover-highlighted regions (Blacks / Shadows / Exposure / Highlights / Whites) draggable left/right, writing **the same `editStack` fields the Light sliders bind** — the binding is a `WritableKeyPath<EditStack, Double>`, so the slider co-moves because there is only one value. Clipping triangles in the top corners light per channel and click-toggle `showsShadowClipping`/`showsHighlightClipping` — the exact state `ClippingDiagnostics` binds today (that row stays; the triangles are a second route to the same switch). An RGB%/Luma readout appears under the histogram while the cursor is over the canvas, sampled from `displayImage` (the developed preview — the picture the person is actually reading).

**Files:**
- Create: `Sources/Views/HistogramInteraction.swift`, `Sources/Views/PixelSampler.swift`, `Tests/HistogramInteractionTests.swift`
- Modify: `Sources/Pipeline/Histogram.swift`, `Sources/Views/HistogramView.swift`, `Sources/Views/InspectorPanel.swift`, `Sources/Views/EditorModel.swift`, `Sources/Views/CanvasArea.swift`

**Interfaces:**
- Consumes: `Histogram.red/green/blue`, `EditorModel.histogram/displayImage/showsShadowClipping/showsHighlightClipping`, `EditCanvas.imageRect(in:)`, `ColorScience.luminance(_:_:_:)`.
- Produces: `HistogramRegion` (`.blacks/.shadows/.exposure/.highlights/.whites`, `keyPath`, `range`, `region(atUnitX:)`, `value(startingFrom:draggedByUnitDelta:)`), `Histogram.ChannelClipFlags` + `.shadowClipFlags/.highlightClipFlags`, `PixelSampler`/`PixelReading` (**reused by Task 5's TAT**), `EditorModel.setLightValue(_:to:)`, `EditorModel.hoverReadout` + `updateHoverReadout(atUnitPoint:)`, `InteractiveHistogram`.

- [x] **Step 1: Write the failing tests**

Create `Tests/HistogramInteractionTests.swift`:

```swift
import CoreGraphics
import XCTest
@testable import PhotoEditor

/// The histogram-drag ↔ slider binding, as pure functions: region geometry,
/// the keyPath identity that makes co-movement structural, and the drag law.
final class HistogramRegionTests: XCTestCase {
    func testRegionsPartitionTheAxisInOrder() {
        XCTAssertEqual(HistogramRegion.region(atUnitX: 0.05), .blacks)
        XCTAssertEqual(HistogramRegion.region(atUnitX: 0.25), .shadows)
        XCTAssertEqual(HistogramRegion.region(atUnitX: 0.50), .exposure)
        XCTAssertEqual(HistogramRegion.region(atUnitX: 0.75), .highlights)
        XCTAssertEqual(HistogramRegion.region(atUnitX: 0.95), .whites)
        XCTAssertEqual(HistogramRegion.region(atUnitX: -1), .blacks, "clamped, never nil")
        XCTAssertEqual(HistogramRegion.region(atUnitX: 2), .whites)
    }

    /// The whole feature in one assertion: the drag writes the field the
    /// slider binds. Not "a similar field" — the same key path.
    func testRegionsBindTheLightPanelsOwnFields() {
        XCTAssertEqual(HistogramRegion.blacks.keyPath, \EditStack.blacks)
        XCTAssertEqual(HistogramRegion.shadows.keyPath, \EditStack.shadows)
        XCTAssertEqual(HistogramRegion.exposure.keyPath, \EditStack.exposure)
        XCTAssertEqual(HistogramRegion.highlights.keyPath, \EditStack.highlights)
        XCTAssertEqual(HistogramRegion.whites.keyPath, \EditStack.whites)
    }

    func testDragLawIsLinearRightwardPositiveAndClamped() {
        // A full-width sweep covers half the control's range — the taste
        // constant sweepFraction, verified in-app.
        let half = 100.0 * HistogramRegion.sweepFraction
        XCTAssertEqual(HistogramRegion.shadows.value(startingFrom: 0, draggedByUnitDelta: 1),
                       half, accuracy: 1e-9)
        XCTAssertLessThan(HistogramRegion.blacks.value(startingFrom: 0, draggedByUnitDelta: -0.3),
                          0, "dragging left must darken")
        XCTAssertEqual(HistogramRegion.exposure.value(startingFrom: 2.9, draggedByUnitDelta: 1),
                       3.0, "clamped to the slider's own range")
    }
}

@MainActor
final class HistogramDragModelTests: XCTestCase {
    func testDragWritesTheFieldOnceAndCommitsOneUndoStep() throws {
        let editor = try TestSupport.makeEditorModel()
        editor.setLightValue(.exposure, to: 0.8)
        editor.setLightValue(.exposure, to: 1.2) // second tick of the same gesture
        XCTAssertEqual(editor.editStack.exposure, 1.2)
        editor.commitEdit()
        XCTAssertEqual(editor.undoDepth, 1, "a drag burst is one undo step, like a slider")
    }
}

final class ChannelClipFlagTests: XCTestCase {
    private func spiked(_ spikeAtTop: Bool) -> [Float] {
        var bins = [Float](repeating: 0.1, count: 256)
        bins[spikeAtTop ? 255 : 0] = 40
        return bins
    }

    func testOnlyTheSpikedChannelLights() {
        let h = Histogram(red: spiked(false),
                          green: [Float](repeating: 0.1, count: 256),
                          blue: [Float](repeating: 0.1, count: 256))
        XCTAssertTrue(h.shadowClipFlags.red)
        XCTAssertFalse(h.shadowClipFlags.green)
        XCTAssertFalse(h.shadowClipFlags.blue)
        XCTAssertFalse(h.highlightClipFlags.any)
    }

    /// A blown red channel on a sunset must light the red flag even when the
    /// pooled three-channel diagnostic stays quiet — that is the point of
    /// per-channel flags. The pooled `isClippingHighlights` semantics are
    /// untouched (HistogramScaleTests keeps pinning them).
    func testAPerChannelClipCanLightWithoutThePooledDiagnostic() {
        var red = [Float](repeating: 0.1, count: 256)
        red[255] = 0.5 // ~2% of the red channel, ~0.65% pooled — under 0.5%? No:
        // 0.5 / (25.5 + 0.4) per-channel ≈ 1.9%; pooled edge over pooled mass
        // ≈ 0.65%. Use a flat green/blue heavy enough to dilute below 0.5%.
        let flat = [Float](repeating: 0.3, count: 256)
        let h = Histogram(red: red, green: flat, blue: flat)
        XCTAssertTrue(h.highlightClipFlags.red)
        XCTAssertFalse(h.isClippingHighlights,
                       "diluted below the pooled threshold — per-channel still reports")
    }
}

final class PixelSamplerTests: XCTestCase {
    /// A 2×2 image with distinct corners proves both axes and the y-flip:
    /// sampler unit points are bottom-left (the canvas's image convention),
    /// CGImage rows are top-down.
    private func cornerImage() throws -> CGImage {
        var pixels: [UInt8] = [
            255, 0, 0, 255,   0, 255, 0, 255,   // top row:    red, green
            0, 0, 255, 255,   255, 255, 255, 255, // bottom row: blue, white
        ]
        let context = CGContext(
            data: &pixels, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        return try XCTUnwrap(context?.makeImage())
    }

    func testSamplesTheRightPixelWithABottomLeftOrigin() throws {
        let sampler = try XCTUnwrap(PixelSampler(image: try cornerImage()))
        let bottomLeft = sampler.reading(atUnitPoint: CGPoint(x: 0.01, y: 0.01))
        XCTAssertGreaterThan(bottomLeft.blue, 0.9, "bottom-left is the blue pixel")
        let topLeft = sampler.reading(atUnitPoint: CGPoint(x: 0.01, y: 0.99))
        XCTAssertGreaterThan(topLeft.red, 0.9, "top-left is the red pixel")
    }

    func testLumaIsRec709OfTheSample() throws {
        let sampler = try XCTUnwrap(PixelSampler(image: try cornerImage()))
        let white = sampler.reading(atUnitPoint: CGPoint(x: 0.99, y: 0.01))
        XCTAssertEqual(white.luma, 1.0, accuracy: 0.02)
    }
}
```

- [x] **Step 2: Run** `xcodegen generate`, then `-only-testing:PhotoEditorTests/HistogramRegionTests -only-testing:PhotoEditorTests/HistogramDragModelTests -only-testing:PhotoEditorTests/ChannelClipFlagTests -only-testing:PhotoEditorTests/PixelSamplerTests` — expected COMPILE FAILURE.

- [x] **Step 3: The model pieces**

In `Sources/Pipeline/Histogram.swift`, after the existing clipping block:

```swift
    /// Which channels are clipping at one end. The pooled diagnostics above
    /// keep their exact semantics; these answer the finer question the corner
    /// triangles ask ("blown *where*?"), with the same 0.5% threshold applied
    /// per channel.
    struct ChannelClipFlags: Equatable {
        var red = false
        var green = false
        var blue = false
        var any: Bool { red || green || blue }
    }

    var shadowClipFlags: ChannelClipFlags { clipFlags(atTop: false) }
    var highlightClipFlags: ChannelClipFlags { clipFlags(atTop: true) }

    private func clipFlags(atTop: Bool) -> ChannelClipFlags {
        func clipped(_ channel: [Float]) -> Bool {
            guard let edge = atTop ? channel.last : channel.first else { return false }
            let total = channel.reduce(0.0) { $0 + Double($1) }
            return total > 0 && Double(edge) / total > 0.005
        }
        return ChannelClipFlags(red: clipped(red), green: clipped(green), blue: clipped(blue))
    }
```

Create `Sources/Views/HistogramInteraction.swift` — the region model first (pure), then the view:

```swift
import SwiftUI

/// The five draggable histogram regions and the fields they ARE. There is no
/// mapping layer to drift: each region carries the Light panel's own key path,
/// so the histogram drag and the slider are two handles on one value.
enum HistogramRegion: CaseIterable, Equatable {
    case blacks, shadows, exposure, highlights, whites

    /// Region boundaries on the display-referred axis, left to right. The
    /// middle band is widest because Exposure is the control most drags mean.
    /// Taste constants; verified in-app.
    static let boundaries: [Double] = [0.15, 0.35, 0.65, 0.85]

    /// A full-width drag sweeps this fraction of the bound control's range —
    /// coarse enough to matter, fine enough to steer.
    static let sweepFraction = 0.5

    static func region(atUnitX x: Double) -> HistogramRegion {
        let cases = allCases
        for (index, boundary) in boundaries.enumerated() where x < boundary {
            return cases[index]
        }
        return .whites
    }

    var keyPath: WritableKeyPath<EditStack, Double> {
        switch self {
        case .blacks: \.blacks
        case .shadows: \.shadows
        case .exposure: \.exposure
        case .highlights: \.highlights
        case .whites: \.whites
        }
    }

    /// The bound slider's own range, verbatim from `SliderPanel`.
    var range: ClosedRange<Double> {
        self == .exposure ? -3...3 : -100...100
    }

    var title: String {
        switch self {
        case .blacks: "Blacks"
        case .shadows: "Shadows"
        case .exposure: "Exposure"
        case .highlights: "Highlights"
        case .whites: "Whites"
        }
    }

    /// The drag law: linear, rightward-positive, clamped to the slider range.
    func value(startingFrom start: Double, draggedByUnitDelta delta: Double) -> Double {
        let span = range.upperBound - range.lowerBound
        let proposed = start + delta * span * Self.sweepFraction
        return min(max(proposed, range.lowerBound), range.upperBound)
    }
}
```

In `Sources/Views/EditorModel.swift`, under `// MARK: View state (not persisted)`:

```swift
    /// One tick of a histogram-region drag. Writes exactly one `editStack`
    /// field once (the single-assignment gesture rule); the Light slider
    /// co-moves because it binds the same field.
    func setLightValue(_ region: HistogramRegion, to value: Double) {
        let clamped = min(max(value, region.range.lowerBound), region.range.upperBound)
        guard editStack[keyPath: region.keyPath] != clamped else { return }
        editStack[keyPath: region.keyPath] = clamped
    }

    /// The colour under the canvas cursor, for the histogram readout. Nil when
    /// the cursor is off the photograph.
    private(set) var hoverReadout: PixelReading?

    /// Sampler cached per `displayImage` identity — rebuilt only when a new
    /// preview lands, not per mouse move.
    private var hoverSampler: (image: CGImage, sampler: PixelSampler)?

    func updateHoverReadout(atUnitPoint point: CGPoint?) {
        guard let point else {
            hoverReadout = nil
            return
        }
        hoverReadout = sample(atUnitPoint: point)
    }

    /// Shared with the TAT (Task 5): the developed preview's colour at a
    /// bottom-left unit point.
    func sample(atUnitPoint point: CGPoint) -> PixelReading? {
        guard let image = displayImage else { return nil }
        if hoverSampler?.image !== image {
            guard let sampler = PixelSampler(image: image) else { return nil }
            hoverSampler = (image, sampler)
        }
        return hoverSampler?.sampler.reading(atUnitPoint: point)
    }
```

Create `Sources/Views/PixelSampler.swift`:

```swift
import CoreGraphics

/// A sampled preview colour: display-referred sRGB components plus Rec. 709
/// luma, all 0…1.
struct PixelReading: Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var luma: Double
}

/// Nearest-pixel colour sampling over a CGImage, via one small RGBA8 redraw.
///
/// Built once per preview image and then read per mouse move — the redraw
/// (≤ 320 px) is the whole cost, and it happens off the per-event path. Unit
/// points are **bottom-left origin**, the canvas's image convention
/// (`EditCanvas.clickGesture` produces the same), so every caller passes the
/// point it already has; the row flip happens here, once.
struct PixelSampler {
    private let pixels: [UInt8]
    private let width: Int
    private let height: Int

    init?(image: CGImage, maxDimension: Int = 320) {
        let scale = min(1, Double(maxDimension) / Double(max(image.width, image.height, 1)))
        width = max(Int(Double(image.width) * scale), 1)
        height = max(Int(Double(image.height) * scale), 1)
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &buffer, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        pixels = buffer
    }

    func reading(atUnitPoint point: CGPoint) -> PixelReading {
        let x = Int((min(max(point.x, 0), 1) * CGFloat(width - 1)).rounded())
        // Unit y is bottom-up; rows are top-down.
        let row = (height - 1) - Int((min(max(point.y, 0), 1) * CGFloat(height - 1)).rounded())
        let i = (row * width + x) * 4
        let r = Double(pixels[i]) / 255
        let g = Double(pixels[i + 1]) / 255
        let b = Double(pixels[i + 2]) / 255
        return PixelReading(red: r, green: g, blue: b,
                            luma: ColorScience.luminance(r, g, b))
    }
}
```

- [x] **Step 4: Run the four test classes** — expected PASS (`HistogramRegionTests`, `HistogramDragModelTests`, `ChannelClipFlagTests`, `PixelSamplerTests`). Also `-only-testing:PhotoEditorTests/CanvasToolTests` (Histogram semantics untouched) — PASS.

- [x] **Step 5: The view**

In `Sources/Views/HistogramView.swift`, add one parameter — drawing unchanged:

```swift
    /// Off when a wrapper (InteractiveHistogram) draws richer per-channel
    /// flags of its own over this plot.
    var showsClipFlags: Bool = true
```

and gate the two existing `clipFlag` overlays on it (`if showsClipFlags && histogram.isClippingShadows { … }`).

Append to `Sources/Views/HistogramInteraction.swift`:

```swift
/// The Inspector histogram as a control surface: HistogramView's plot with a
/// drag/hover layer, per-channel clip triangles, and the cursor readout.
struct InteractiveHistogram: View {
    @Bindable var model: EditorModel

    @State private var hoverRegion: HistogramRegion?
    @State private var drag: (region: HistogramRegion, startValue: Double)?

    /// HistogramView's own plot inset and height — the two views must agree
    /// or the region bands sit beside the bins they claim. Change together.
    private let plotInset: CGFloat = 7
    private let plotHeight: CGFloat = 112

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .top) {
                HistogramView(histogram: model.histogram, showsClipFlags: false)
                if !model.histogram.isEmpty {
                    interactionLayer
                        .frame(height: plotHeight)
                        .padding(.horizontal, plotInset)
                }
            }
            .overlay(alignment: .topLeading) {
                clipCorner(model.histogram.shadowClipFlags,
                           isOn: $model.showsShadowClipping,
                           help: "shadow")
            }
            .overlay(alignment: .topTrailing) {
                clipCorner(model.histogram.highlightClipFlags,
                           isOn: $model.showsHighlightClipping,
                           help: "highlight")
            }

            if let reading = model.hoverReadout {
                readoutRow(reading)
            }
        }
    }

    private var interactionLayer: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let active = drag?.region ?? hoverRegion
            ZStack(alignment: .topLeading) {
                if let active {
                    let band = unitBand(of: active)
                    Rectangle()
                        .fill(Theme.text.opacity(0.05))
                        .frame(width: (band.upperBound - band.lowerBound) * width)
                        .offset(x: band.lowerBound * width)
                    Text("\(active.title.uppercased())  "
                         + String(format: active == .exposure ? "%+.2f" : "%+.0f",
                                  model.editStack[keyPath: active.keyPath]))
                        .font(Theme.valueFont)
                        .monospacedDigit()
                        .foregroundStyle(drag == nil ? Theme.secondaryText : Theme.accent)
                        .padding(4)
                }
            }
            .frame(width: width, height: geo.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    hoverRegion = HistogramRegion.region(atUnitX: location.x / width)
                case .ended:
                    hoverRegion = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if drag == nil {
                            let region = HistogramRegion.region(
                                atUnitX: value.startLocation.x / width)
                            drag = (region, model.editStack[keyPath: region.keyPath])
                        }
                        guard let drag else { return }
                        model.setLightValue(drag.region, to: drag.region.value(
                            startingFrom: drag.startValue,
                            draggedByUnitDelta: Double(value.translation.width / width)))
                    }
                    .onEnded { _ in drag = nil }
            )
        }
    }

    private func unitBand(of region: HistogramRegion) -> ClosedRange<CGFloat> {
        let edges = [0.0] + HistogramRegion.boundaries + [1.0]
        let index = HistogramRegion.allCases.firstIndex(of: region) ?? 0
        return CGFloat(edges[index])...CGFloat(edges[index + 1])
    }

    /// A corner triangle that lights per channel and toggles the existing
    /// clipping overlay — the very state ClippingDiagnostics binds (J stays
    /// the Heal key; the View-menu items stay the keyboard-free route).
    private func clipCorner(_ flags: Histogram.ChannelClipFlags,
                            isOn: Binding<Bool>, help: String) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            Icon.Filled(kind: .warningTriangle, size: 8)
                .foregroundStyle(tint(flags))
                .padding(6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Toggle the \(help) clipping overlay")
        .accessibilityLabel("\(help) clipping channels")
    }

    /// Colour is data here: the triangle takes the additive colour of the
    /// clipping channels (all three → white), quiet grey when clean.
    private func tint(_ flags: Histogram.ChannelClipFlags) -> Color {
        guard flags.any else { return Theme.tertiaryText.opacity(0.6) }
        if flags.red && flags.green && flags.blue { return Theme.text }
        return Color(red: flags.red ? 0.95 : 0.2,
                     green: flags.green ? 0.86 : 0.2,
                     blue: flags.blue ? 0.98 : 0.25)
    }

    /// The 2.0 reference-mock readout, finally built. Measured values,
    /// monospace, percent of full scale.
    private func readoutRow(_ reading: PixelReading) -> some View {
        HStack(spacing: 10) {
            readout("R", reading.red)
            readout("G", reading.green)
            readout("B", reading.blue)
            Rule(axis: .vertical).frame(height: 10)
            readout("L", reading.luma)
            Spacer()
        }
        .padding(.horizontal, plotInset)
    }

    private func readout(_ label: String, _ value: Double) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Theme.tertiaryText)
            Text(String(format: "%.1f", value * 100))
                .font(Theme.valueFont)
                .monospacedDigit()
                .foregroundStyle(Theme.secondaryText)
        }
    }
}
```

In `Sources/Views/InspectorPanel.swift`, swap the histogram line:

```swift
            InteractiveHistogram(model: model)
```

(replacing `HistogramView(histogram: model.histogram)`; padding modifiers stay).

- [x] **Step 6: Canvas hover sampling**

In `Sources/Views/CanvasArea.swift`, on `EditCanvas.viewport`'s inner `ZStack` (where `rect` is in scope, after the gesture layer):

```swift
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    // Only in normal viewing: in a compare mode the cursor sits
                    // over one of two renders and the sample would be ambiguous.
                    guard editor.compareMode == .off, rect.contains(location) else {
                        editor.updateHoverReadout(atUnitPoint: nil)
                        return
                    }
                    editor.updateHoverReadout(atUnitPoint: CGPoint(
                        x: (location.x - rect.minX) / rect.width,
                        y: 1 - (location.y - rect.minY) / rect.height))
                case .ended:
                    editor.updateHoverReadout(atUnitPoint: nil)
                }
            }
```

- [x] **Step 7: Verify**

Run: `-only-testing:PhotoEditorTests/HistogramRegionTests -only-testing:PhotoEditorTests/HistogramDragModelTests -only-testing:PhotoEditorTests/ChannelClipFlagTests -only-testing:PhotoEditorTests/PixelSamplerTests -only-testing:PhotoEditorTests/HistogramScaleTests -only-testing:PhotoEditorTests/HistogramSpaceTests -only-testing:PhotoEditorTests/EditorModelTests`
Expected: ALL PASS. No new menu entries: the clipping toggles already live in the View menu, and a readout is not a command.

- [x] **Step 8: Commit**

```bash
git add Sources/Pipeline/Histogram.swift Sources/Views/HistogramView.swift Sources/Views/HistogramInteraction.swift Sources/Views/PixelSampler.swift Sources/Views/InspectorPanel.swift Sources/Views/EditorModel.swift Sources/Views/CanvasArea.swift Tests/HistogramInteractionTests.swift project.yml PhotoEditor.xcodeproj
git commit -m "feat(histogram): draggable regions bound to the Light fields, per-channel clip flags, RGB/luma readout"
```

---

### Task 4: Tone curve — free points over lenient variable-length storage

`EditStack.toneCurvePoints` is *already* a leniently-decoded `[CGPoint]` (absent → `[]`); what changes is who accepts more than five. The renderer keeps `count == 5` routing through the exact `CIToneCurve` code it runs today — bit-for-bit, in both `EditRenderer` and the untouched `LegacyToneRenderer`, whose `count == 5` guard makes a PV1 photo simply ignore a free list — and gains a free-point path for any other count ≥ 2: 256 samples of `ColorScience.evaluateCurve` (the same Catmull-Rom the per-channel curves already render through in the LUT) fed to `CIColorCurves` in sRGB, matching `CIToneCurve`'s display-referred behaviour (the CalibrationTests peak-placement precedent). The editor gains click-to-add, 2-D drag, right-click delete (Task 1's `MouseEventView`, whose hitTest filter lets left-clicks fall through to the point drags), and a monospace in/out readout — all gated on `processVersion >= 2` via `allowsFreePoints`, so a PV1 photo keeps today's five-column editor.

**Files:**
- Create: `Sources/Models/CurvePointModel.swift`, `Tests/CurvePointModelTests.swift`, `Tests/FreeCurveRenderTests.swift`
- Modify: `Sources/Views/SliderPanel/ToneCurveEditor.swift`, `Sources/Views/SliderPanel/CurvePanel.swift`, `Sources/Pipeline/EditRenderer.swift`

**Interfaces:**
- Consumes: `ColorScience.evaluateCurve(_:at:)`, `MouseEventView.onRightClick`, `EditRenderer.applyToneCurve` as it stands.
- Produces: `CurvePointModel.identity/seeded/adding/moving/removing` (**reused by Task 5's TAT**), `ToneCurveEditor.allowsFreePoints`.

- [x] **Step 1: Write the failing model tests**

Create `Tests/CurvePointModelTests.swift`:

```swift
import CoreGraphics
import Foundation
import XCTest
@testable import PhotoEditor

/// The point-list model: pure editing operations plus the decode contract
/// that keeps every existing photo rendering unchanged.
final class CurvePointModelTests: XCTestCase {
    func testSeedingAnEmptyListYieldsTheFiveIdentityPoints() {
        XCTAssertEqual(CurvePointModel.seeded([]), CurvePointModel.identity)
        let custom = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)]
        XCTAssertEqual(CurvePointModel.seeded(custom), custom, "non-empty lists pass through")
    }

    func testAddingInsertsSortedByX() {
        let (points, index) = CurvePointModel.adding(CGPoint(x: 0.6, y: 0.4),
                                                     to: CurvePointModel.identity)
        XCTAssertEqual(points.count, 6)
        XCTAssertEqual(index, 3, "between 0.5 and 0.75")
        XCTAssertEqual(points.map(\.x), points.map(\.x).sorted(), "sorted invariant holds")
    }

    /// A click on top of an existing point must grab it, not stack a twin at
    /// the same x — twins make the interpolation vertical.
    func testAddingOnTopOfAPointReturnsThatPointInstead() {
        let (points, index) = CurvePointModel.adding(CGPoint(x: 0.505, y: 0.9),
                                                     to: CurvePointModel.identity)
        XCTAssertEqual(points.count, 5)
        XCTAssertEqual(index, 2)
    }

    func testMovingClampsBetweenNeighboursAndTheUnitSquare() {
        let moved = CurvePointModel.moving(index: 2, to: CGPoint(x: 0.9, y: 1.4),
                                           in: CurvePointModel.identity)
        XCTAssertLessThan(moved[2].x, moved[3].x, "cannot cross the next point")
        XCTAssertEqual(moved[2].y, 1.0, "y clamps to the unit square")
        XCTAssertEqual(moved.map(\.x), moved.map(\.x).sorted())
    }

    func testRemovingKeepsAtLeastTwoPoints() {
        var points: [CGPoint] = [CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0.7), CGPoint(x: 1, y: 1)]
        points = CurvePointModel.removing(index: 1, from: points)
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(CurvePointModel.removing(index: 0, from: points).count, 2,
                       "a curve needs two ends; the double-click reset clears the rest")
    }

    // MARK: The storage contract

    func testAbsentKeyDecodesToTodaysEmptyList() throws {
        let decoded = try JSONDecoder().decode(EditStack.self,
                                               from: Data("{}".utf8))
        XCTAssertEqual(decoded.toneCurvePoints, [], "absent → identity, exactly as today")
    }

    func testFivePointListsRoundTripBitExactly() throws {
        var stack = EditStack()
        stack.toneCurvePoints = [CGPoint(x: 0, y: 0.03), CGPoint(x: 0.25, y: 0.2),
                                 CGPoint(x: 0.5, y: 0.55), CGPoint(x: 0.75, y: 0.8),
                                 CGPoint(x: 1, y: 1)]
        let decoded = try JSONDecoder().decode(EditStack.self,
                                               from: JSONEncoder().encode(stack))
        XCTAssertEqual(decoded.toneCurvePoints, stack.toneCurvePoints)
    }

    func testSevenPointListsRoundTripToo() throws {
        var stack = EditStack()
        stack.toneCurvePoints = (0...6).map { CGPoint(x: Double($0) / 6, y: Double($0) / 6) }
        let decoded = try JSONDecoder().decode(EditStack.self,
                                               from: JSONEncoder().encode(stack))
        XCTAssertEqual(decoded.toneCurvePoints.count, 7)
    }
}
```

Create `Tests/FreeCurveRenderTests.swift`:

```swift
import CoreImage
import CoreImage.CIFilterBuiltins
import XCTest
@testable import PhotoEditor

/// The renderer's side of the contract: five points stay on the frozen
/// CIToneCurve path bit-for-bit, other counts render through the free path,
/// and PV1 ignores free lists entirely.
final class FreeCurveRenderTests: XCTestCase {
    private let renderer = EditRenderer()

    private func gray(_ value: Double) -> CIImage {
        TestSupport.solidImage(red: value, green: value, blue: value, size: 32)
    }

    /// Pins the 5-point semantics: the stack render equals CIToneCurve applied
    /// by hand to the same source — the exact filter, the exact points.
    func testFivePointsRenderThroughCIToneCurveUnchanged() {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 0.25, y: 0.4),
                      CGPoint(x: 0.5, y: 0.7), CGPoint(x: 0.75, y: 0.9),
                      CGPoint(x: 1, y: 1)]
        var stack = EditStack()
        stack.toneCurvePoints = points

        let viaStack = TestSupport.readColor(renderer.render(source: gray(0.5), stack: stack))

        let filter = CIFilter.toneCurve()
        filter.inputImage = gray(0.5)
        filter.point0 = points[0]; filter.point1 = points[1]; filter.point2 = points[2]
        filter.point3 = points[3]; filter.point4 = points[4]
        let direct = TestSupport.readColor(filter.outputImage!)

        XCTAssertEqual(viaStack.red, direct.red, accuracy: 1e-3)
    }

    /// The free path exists and places tones where the curve says — the
    /// peak-placement discipline from CalibrationTests, applied to a 3-point
    /// curve that lifts mid-grey to 0.8.
    func testAThreePointCurveLiftsMidGreyWhereItSays() {
        var stack = EditStack()
        stack.toneCurvePoints = [CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0.8),
                                 CGPoint(x: 1, y: 1)]
        let result = TestSupport.readColor(renderer.render(source: gray(0.5), stack: stack))
        XCTAssertEqual(result.red, 0.8, accuracy: 0.05,
                       "the curve is display-referred: input 0.5 lands near output 0.8")
    }

    func testASevenPointCurveRendersAndAnIdentityListIsANoOp() {
        var identity = EditStack()
        identity.toneCurvePoints = (0...6).map { CGPoint(x: Double($0) / 6, y: Double($0) / 6) }
        let flat = TestSupport.readColor(renderer.render(source: gray(0.4), stack: identity))
        let untouched = TestSupport.readColor(renderer.render(source: gray(0.4), stack: EditStack()))
        XCTAssertEqual(flat.red, untouched.red, accuracy: 0.01,
                       "identity points through the free path change nothing")
    }

    /// PV1 is frozen: LegacyToneRenderer's count == 5 guard means a free list
    /// renders as if there were no curve at all. Not a feature gap — the
    /// freeze guarantee (free editing is gated on PV2 in the panel).
    func testPV1IgnoresAFreePointList() {
        var withCurve = EditStack()
        withCurve.processVersion = 1
        withCurve.toneCurvePoints = [CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0.9),
                                     CGPoint(x: 1, y: 1)]
        var without = EditStack()
        without.processVersion = 1

        let a = TestSupport.readColor(renderer.render(source: gray(0.5), stack: withCurve))
        let b = TestSupport.readColor(renderer.render(source: gray(0.5), stack: without))
        XCTAssertEqual(a.red, b.red, accuracy: 1e-4)
    }
}
```

- [x] **Step 2: Run both classes** — expected COMPILE FAILURE (`CurvePointModel` does not exist), and `FreeCurveRenderTests.testAThreePointCurveLiftsMidGreyWhereItSays` would fail red even once compiling (today `count != 5` returns the input untouched).

- [x] **Step 3: Implement `Sources/Models/CurvePointModel.swift`**

```swift
import CoreGraphics

/// Pure editing operations on a tone-curve point list. The invariants every
/// caller relies on: sorted ascending by x, x and y inside the unit square,
/// no two points closer in x than `minimumSeparation`, never fewer than two
/// points once a list exists. `[]` remains the identity sentinel — the value
/// the double-click reset writes and absent storage decodes to.
enum CurvePointModel {
    /// The five identity points — the seed for first contact with an
    /// untouched curve, and exactly the columns today's editor shows.
    static let identity: [CGPoint] = [
        CGPoint(x: 0, y: 0), CGPoint(x: 0.25, y: 0.25), CGPoint(x: 0.5, y: 0.5),
        CGPoint(x: 0.75, y: 0.75), CGPoint(x: 1, y: 1),
    ]

    /// Closest two points may sit in x. Below this the spline turns vertical
    /// and the two pucks become one target.
    static let minimumSeparation: CGFloat = 0.02

    static func seeded(_ points: [CGPoint]) -> [CGPoint] {
        points.isEmpty ? identity : points
    }

    /// Inserts a point sorted by x — or, when one already lives within
    /// `minimumSeparation`, returns that point's index instead of stacking a
    /// twin. The returned index is the one to drag.
    static func adding(_ point: CGPoint, to points: [CGPoint]) -> (points: [CGPoint], index: Int) {
        let clamped = CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
        var list = seeded(points)
        if let existing = list.firstIndex(where: { abs($0.x - clamped.x) < minimumSeparation }) {
            return (list, existing)
        }
        let index = list.firstIndex { $0.x > clamped.x } ?? list.count
        list.insert(clamped, at: index)
        return (list, index)
    }

    /// Moves a point in both axes, clamped to the unit square and pinned
    /// between its neighbours so the list stays sorted.
    static func moving(index: Int, to point: CGPoint, in points: [CGPoint]) -> [CGPoint] {
        var list = seeded(points)
        guard list.indices.contains(index) else { return list }
        let lower = index > 0 ? list[index - 1].x + minimumSeparation : 0
        let upper = index < list.count - 1 ? list[index + 1].x - minimumSeparation : 1
        list[index] = CGPoint(x: min(max(point.x, lower), max(upper, lower)),
                              y: min(max(point.y, 0), 1))
        return list
    }

    /// Removes a point while more than two remain — a curve needs its ends;
    /// clearing the rest is the double-click reset's job.
    static func removing(index: Int, from points: [CGPoint]) -> [CGPoint] {
        var list = seeded(points)
        guard list.count > 2, list.indices.contains(index) else { return list }
        list.remove(at: index)
        return list
    }
}
```

- [x] **Step 4: The renderer's free path**

In `Sources/Pipeline/EditRenderer.swift`, replace the tail of `applyToneCurve` (from `guard stack.toneCurvePoints.count == 5 else { return result }` down) with:

```swift
        switch stack.toneCurvePoints.count {
        case 0, 1:
            return result
        case 5:
            // The frozen path, verbatim: every photo persisted to date has
            // exactly five points, and they must keep rendering bit-for-bit
            // through the same filter. (CIToneCurve interpolates
            // display-referred values internally — CalibrationTests.)
            let curve = CIFilter.toneCurve()
            curve.inputImage = result
            curve.point0 = stack.toneCurvePoints[0]
            curve.point1 = stack.toneCurvePoints[1]
            curve.point2 = stack.toneCurvePoints[2]
            curve.point3 = stack.toneCurvePoints[3]
            curve.point4 = stack.toneCurvePoints[4]
            return curve.outputImage ?? result
        default:
            return applyFreePointCurve(result, points: stack.toneCurvePoints)
        }
    }

    /// Any point count CIToneCurve can't take: 256 samples of the same
    /// Catmull-Rom the per-channel curves already render through
    /// (`ColorScience.evaluateCurve`), applied by CIColorCurves in sRGB so
    /// the free path is display-referred exactly like the 5-point path.
    private func applyFreePointCurve(_ image: CIImage, points: [CGPoint]) -> CIImage {
        let samples = 256
        var data = [Float]()
        data.reserveCapacity(samples * 3)
        for i in 0..<samples {
            let y = Float(ColorScience.evaluateCurve(points, at: Double(i) / Double(samples - 1)))
            data.append(y); data.append(y); data.append(y)
        }
        guard let filter = CIFilter(name: "CIColorCurves") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(data.withUnsafeBufferPointer { Data(buffer: $0) },
                        forKey: "inputCurvesData")
        filter.setValue(CIVector(x: 0, y: 1), forKey: "inputCurvesDomain")
        filter.setValue(CGColorSpace(name: CGColorSpace.sRGB)!, forKey: "inputColorSpace")
        return filter.outputImage ?? image
```

(`LegacyToneRenderer.swift` is **not** touched — its `count == 5` guard is the PV1 freeze.)

- [x] **Step 5: Run CurvePointModelTests + FreeCurveRenderTests** — expected PASS. Also `-only-testing:PhotoEditorTests/CalibrationTests -only-testing:PhotoEditorTests/ProcessVersionTests` (frozen paths undisturbed) — PASS.

- [x] **Step 6: The editor**

In `Sources/Views/SliderPanel/ToneCurveEditor.swift`:
- Add `var allowsFreePoints: Bool = false` and delete the private `identity` array in favour of `CurvePointModel.identity` (same five points, one owner).
- Free-mode gestures — replace `dragGesture(in:)`:

```swift
    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: allowsFreePoints ? 0 : 2)
            .onChanged { value in
                if allowsFreePoints {
                    if activeIndex == nil {
                        // Grab a nearby point, or add one where the click landed
                        // — click-to-add and drag-to-shape are one gesture.
                        let unit = unitPoint(value.startLocation, in: size)
                        if let hit = hitIndex(at: value.startLocation, in: size) {
                            activeIndex = hit
                        } else {
                            let (added, index) = CurvePointModel.adding(unit, to: currentPoints)
                            points = added
                            activeIndex = index
                        }
                    }
                    guard let index = activeIndex else { return }
                    points = CurvePointModel.moving(index: index,
                                                    to: unitPoint(value.location, in: size),
                                                    in: currentPoints)
                } else {
                    // The five-column legacy editor, verbatim: nearest column,
                    // vertical drag only.
                    var working = currentPoints
                    let index = activeIndex ?? nearestIndex(to: value.startLocation, in: size)
                    activeIndex = index
                    let normalizedY = 1 - Double(value.location.y / size.height)
                    working[index] = CGPoint(x: working[index].x,
                                             y: min(max(normalizedY, 0), 1))
                    points = working
                }
            }
            .onEnded { _ in activeIndex = nil }
    }

    /// The point under the pointer, within a comfortable grab radius — 2-D,
    /// unlike the legacy column search.
    private func hitIndex(at location: CGPoint, in size: CGSize) -> Int? {
        let grabRadius: CGFloat = 14
        return currentPoints.indices.min(by: {
            distance(currentPoints[$0], location, in: size)
                < distance(currentPoints[$1], location, in: size)
        }).flatMap { distance(currentPoints[$0], location, in: size) < grabRadius ? $0 : nil }
    }

    private func distance(_ unit: CGPoint, _ screen: CGPoint, in size: CGSize) -> CGFloat {
        let p = screenPoint(unit, in: size)
        return hypot(p.x - screen.x, p.y - screen.y)
    }

    private func unitPoint(_ screen: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: min(max(screen.x / size.width, 0), 1),
                y: min(max(1 - screen.y / size.height, 0), 1))
    }
```

- Right-click delete + in/out readout, inside the `ZStack` (the `MouseEventView` hitTest filter passes left-clicks through to the drag):

```swift
                if allowsFreePoints {
                    MouseEventView(onRightClick: { location in
                        if let index = hitIndex(at: location, in: size) {
                            points = CurvePointModel.removing(index: index, from: currentPoints)
                        }
                    })
                }
```

```swift
            .overlay(alignment: .topTrailing) {
                if let index = activeIndex, currentPoints.indices.contains(index) {
                    Text(String(format: "IN %.2f  OUT %.2f",
                                currentPoints[index].x, currentPoints[index].y))
                        .font(Theme.valueFont)
                        .monospacedDigit()
                        .foregroundStyle(Theme.secondaryText)
                        .padding(5)
                }
            }
```

In `Sources/Views/SliderPanel/CurvePanel.swift`: pass the gate and split the helper copy —

```swift
        ToneCurveEditor(points: pointsBinding, lineColor: channel.color,
                        allowsFreePoints: model.editStack.processVersion >= 2)
```

```swift
        Text(model.editStack.processVersion >= 2
             ? "Click the curve to add a point, drag to shape, right-click "
               + "a point to remove it. Double-click resets this channel."
             : "Drag a point vertically to reshape. Double-click to reset "
               + "this channel.")
```

(The per-channel R/G/B tabs get free points for free: `ChannelCurves` storage is already variable-length and already renders through `evaluateCurve` in the LUT.)

- [x] **Step 7: Verify**

Run: `-only-testing:PhotoEditorTests/CurvePointModelTests -only-testing:PhotoEditorTests/FreeCurveRenderTests -only-testing:PhotoEditorTests/ColorMixerTests -only-testing:PhotoEditorTests/EditorUndoTests`
Expected: ALL PASS. `ControlConformanceTests` needs no change: `toneCurvePoints` keeps its existing exclusion row ("CalibrationTests — point curve"), and this task adds no `EditStack` field.

- [x] **Step 8: Commit**

```bash
git add Sources/Models/CurvePointModel.swift Sources/Views/SliderPanel/ToneCurveEditor.swift Sources/Views/SliderPanel/CurvePanel.swift Sources/Pipeline/EditRenderer.swift Tests/CurvePointModelTests.swift Tests/FreeCurveRenderTests.swift project.yml PhotoEditor.xcodeproj
git commit -m "feat(curve): free points — variable-length list renders, 5-point path frozen bit-for-bit, PV2-gated editor"
```

---

### Task 5: Targeted Adjustment Tool — drag the image, move the curve or the mixer

A new `EditorTool.targetedAdjustment` (bare key `T` — resolved by `EditorTool(shortcutKey:)` from `shortcutHint`, so `ToolKeyMonitor` and the Develop ▸ Tool menu pick it up with **zero routing changes**). Arming it puts a drag overlay on the canvas, exactly the `retouchPaintOverlay` pattern: drag start samples the developed preview through Task 3's `PixelSampler`, vertical drag then edits the armed target — the RGB curve at the sampled luminance (through Task 4's `CurvePointModel`), or the hue-band mixer weighted by `ColorCubeBuilder.bandWeights` over the sampled hue (the LUT's own weighting, so the TAT moves exactly the bands that touch that colour). Every tick rebuilds from the stack captured at drag start and writes one `editStack` field once.

**Files:**
- Create: `Sources/Models/TATMath.swift`, `Tests/TATMathTests.swift`
- Modify: `Sources/Models/WorkspaceState.swift`, `Sources/Views/WorkspaceModel.swift`, `Sources/Views/EditorModel.swift`, `Sources/Views/CanvasArea.swift`, `Sources/Views/ToolRail.swift`

**Interfaces:**
- Consumes: `PixelSampler`/`EditorModel.sample(atUnitPoint:)` (Task 3), `CurvePointModel` (Task 4), `ColorCubeBuilder.bandWeights(for:)`, `ColorScience.rgbToHSL`.
- Produces: `EditorTool.targetedAdjustment`, `EditorModel.TATTarget`/`tatTarget`, `beginTATDrag(atUnitPoint:)`/`continueTATDrag(byPoints:)`/`endTATDrag()`, `TATMath.curveEdit/mixerEdit/blackAndWhiteEdit`.

- [x] **Step 1: Write the failing tests**

Create `Tests/TATMathTests.swift`:

```swift
import CoreGraphics
import XCTest
@testable import PhotoEditor

/// The TAT weighting as pure functions from gesture deltas to field values.
final class TATMathTests: XCTestCase {
    // MARK: Curve

    func testCurveDragAddsAPointAtTheSampledLuminanceAndLiftsIt() {
        let edit = TATMath.curveEdit(points: [], luma: 0.62, existingIndex: nil,
                                     deltaPoints: TATMath.pointsForFullSweep / 2)
        let point = edit.points[edit.index]
        XCTAssertEqual(point.x, 0.62, accuracy: 0.001)
        XCTAssertGreaterThan(point.y, 0.62, "an upward drag lifts the tone under the cursor")
        XCTAssertEqual(edit.points.map(\.x), edit.points.map(\.x).sorted())
    }

    func testCurveDragReusesTheAnchoredIndexAcrossTicks() {
        let first = TATMath.curveEdit(points: [], luma: 0.5, existingIndex: nil, deltaPoints: 30)
        let second = TATMath.curveEdit(points: [], luma: 0.5,
                                       existingIndex: first.index, deltaPoints: 60)
        XCTAssertEqual(second.index, first.index)
        XCTAssertGreaterThan(second.points[second.index].y, first.points[first.index].y)
        XCTAssertEqual(second.points.count, first.points.count, "no twin per tick")
    }

    func testCurveDragClampsAtTheUnitSquare() {
        let edit = TATMath.curveEdit(points: [], luma: 0.9, existingIndex: nil,
                                     deltaPoints: 10_000)
        XCTAssertEqual(edit.points[edit.index].y, 1.0)
    }

    // MARK: Mixer — weighted by the colours actually under the cursor

    func testMixerDragOnPureRedMovesTheRedBandAndLeavesAquaAlone() {
        let (hue, sat, _) = ColorScience.rgbToHSL(0.8, 0.15, 0.15)
        let mixer = TATMath.mixerEdit(ColorMixer(), hue: hue, saturation: sat,
                                      field: \.saturation,
                                      deltaPoints: TATMath.pointsForFullSweep / 2)
        XCTAssertGreaterThan(mixer[.red].saturation, 20)
        XCTAssertEqual(mixer[.aqua].saturation, 0, accuracy: 1e-9,
                       "bands that don't touch the sampled colour must not move")
    }

    func testMixerDragOnNearGreyBarelyMovesAnything() {
        let mixer = TATMath.mixerEdit(ColorMixer(), hue: 30, saturation: 0.03,
                                      field: \.luminance, deltaPoints: 200)
        let total = HueBand.allCases.reduce(0.0) { $0 + abs(mixer[$1].luminance) }
        XCTAssertLessThan(total, 2, "the saturation ramp — mirrored from the LUT — gates greys")
    }

    func testMixerValuesClampToTheSliderRange() {
        var mixer = ColorMixer()
        mixer[.red].saturation = 95
        let (hue, sat, _) = ColorScience.rgbToHSL(0.9, 0.1, 0.1)
        let moved = TATMath.mixerEdit(mixer, hue: hue, saturation: sat,
                                      field: \.saturation, deltaPoints: 10_000)
        XCTAssertEqual(moved[.red].saturation, 100)
    }

    func testBlackAndWhiteDragMovesTheMixNotTheBands() {
        let (hue, sat, _) = ColorScience.rgbToHSL(0.2, 0.3, 0.9)
        let mixer = TATMath.blackAndWhiteEdit(ColorMixer(), hue: hue, saturation: sat,
                                              deltaPoints: 150)
        XCTAssertGreaterThan(mixer.blackAndWhiteWeight(.blue), 10)
        XCTAssertTrue(mixer.bands.allSatisfy(\.isNeutral))
    }
}

@MainActor
final class TATModelTests: XCTestCase {
    func testTheToolExistsWithItsBareKey() {
        XCTAssertEqual(EditorTool(shortcutKey: "t"), .targetedAdjustment)
        XCTAssertEqual(EditorTool.targetedAdjustment.shortcutHint, "T")
        XCTAssertFalse(EditorTool.targetedAdjustment.isViewingAid)
    }

    func testActivationTidiesUpLikeEveryOtherTool() throws {
        let editor = try TestSupport.makeEditorModel()
        let workspace = WorkspaceModel()
        editor.canvasPicker = .whiteBalance
        workspace.activate(.targetedAdjustment, in: editor)
        XCTAssertEqual(workspace.activeTool, .targetedAdjustment)
        XCTAssertNil(editor.canvasPicker, "an armed eyedropper must not survive the switch")
        XCTAssertEqual(workspace.inspectorMode, .adjust)
    }

    /// The whole gesture against the live model: one field written, one undo
    /// step, and the curve point lands at the sampled luminance.
    func testACurveDragEditsTheStackOnceAndIsOneUndoStep() throws {
        let editor = try TestSupport.makeEditorModel(gray: 128)
        editor.tatTarget = .curve
        editor.beginTATDrag(atUnitPoint: CGPoint(x: 0.5, y: 0.5))
        editor.continueTATDrag(byPoints: 60)
        editor.continueTATDrag(byPoints: 120)
        XCTAssertFalse(editor.editStack.toneCurvePoints.isEmpty)
        editor.endTATDrag()
        editor.commitEdit()
        XCTAssertEqual(editor.undoDepth, 1)
    }

    func testAMixerDragWritesTheMixerNotTheCurve() throws {
        let editor = try TestSupport.makeEditorModel(gray: 128)
        editor.tatTarget = .saturation
        editor.beginTATDrag(atUnitPoint: CGPoint(x: 0.5, y: 0.5))
        editor.continueTATDrag(byPoints: 200)
        editor.endTATDrag()
        XCTAssertTrue(editor.editStack.toneCurvePoints.isEmpty)
        // A grey probe moves almost nothing (the saturation ramp) — the write
        // path, not the magnitude, is what this asserts.
    }
}
```

- [x] **Step 2: Run** `-only-testing:PhotoEditorTests/TATMathTests -only-testing:PhotoEditorTests/TATModelTests` — expected COMPILE FAILURE.

- [x] **Step 3: The tool**

In `Sources/Models/WorkspaceState.swift`, extend `EditorTool` — one case, three switch rows (the compiler walks you to each):

```swift
    case targetedAdjustment
```

`label`: `"Target"`. `symbolName`: `"target"` (a real pictogram at 15 pt — the SF Symbols rule on this type). `isViewingAid`: `false`. `shortcutHint`: `"T"`. `init?(shortcutKey:)` needs nothing: it derives from the table. (`ToolActivationTests.testEveryAdvertisedShortcutSelectsTheToolItNames` now covers the new key automatically.)

In `Sources/Views/WorkspaceModel.swift`, `activate(_:in:)`:

```swift
        case .targetedAdjustment:
            inspectorMode = .adjust
```

(The tidy-up guards above the switch already clear pickers and selections for any tool that is not heal/clone/brush/gradient — the test pins it.)

- [x] **Step 4: `TATMath` + the model entry points**

Create `Sources/Models/TATMath.swift`:

```swift
import CoreGraphics

/// The Targeted Adjustment Tool's weighting: pure functions from a sampled
/// colour and a vertical drag to field values. All taste constants live here.
enum TATMath {
    /// Vertical drag distance (points) that sweeps a control's full range —
    /// the same order as AdjustmentSlider's readout scrub (260).
    static let pointsForFullSweep = 300.0

    /// The mixer sliders' span (−100…100).
    private static let mixerSpan = 200.0

    /// The LUT's own near-grey ramp (`smoothstep(saturation / 0.2)`,
    /// `ColorCubeBuilder.applyMixer`) — mirrored so the TAT refuses to move
    /// bands for a colour the LUT would barely touch.
    static func strength(forSaturation s: Double) -> Double {
        let t = min(max(s / 0.2, 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// One curve tick: seed, find-or-add the point at the sampled luminance,
    /// lift it by the drag. `existingIndex` is the anchor from the first tick,
    /// so the whole gesture drags one point.
    static func curveEdit(points: [CGPoint], luma: Double, existingIndex: Int?,
                          deltaPoints: Double) -> (points: [CGPoint], index: Int) {
        var seeded = CurvePointModel.seeded(points)
        let index: Int
        if let existingIndex, seeded.indices.contains(existingIndex) {
            index = existingIndex
        } else {
            let y = ColorScience.evaluateCurve(seeded, at: luma)
            (seeded, index) = CurvePointModel.adding(CGPoint(x: luma, y: y), to: seeded)
        }
        let anchor = seeded[index]
        let lifted = CGPoint(x: anchor.x,
                             y: anchor.y + deltaPoints / pointsForFullSweep)
        return (CurvePointModel.moving(index: index, to: lifted, in: seeded), index)
    }

    /// One mixer tick: the drag lands on every band in proportion to the
    /// LUT's own weights for the sampled hue, gated by the near-grey ramp.
    static func mixerEdit(_ mixer: ColorMixer, hue: Double, saturation: Double,
                          field: WritableKeyPath<HSLAdjustment, Double>,
                          deltaPoints: Double) -> ColorMixer {
        var result = mixer
        let weights = ColorCubeBuilder.bandWeights(for: hue)
        let delta = deltaPoints / pointsForFullSweep * mixerSpan * strength(forSaturation: saturation)
        for (index, band) in HueBand.allCases.enumerated() where weights[index] > 0 {
            let moved = result[band][keyPath: field] + delta * weights[index]
            result[band][keyPath: field] = min(max(moved, -100), 100)
        }
        return result
    }

    /// The B&W variant: same weighting, writes the channel mix instead —
    /// dragging the sky darker is exactly "more red filter".
    static func blackAndWhiteEdit(_ mixer: ColorMixer, hue: Double, saturation: Double,
                                  deltaPoints: Double) -> ColorMixer {
        var result = mixer
        let weights = ColorCubeBuilder.bandWeights(for: hue)
        let delta = deltaPoints / pointsForFullSweep * mixerSpan * strength(forSaturation: saturation)
        for (index, band) in HueBand.allCases.enumerated() where weights[index] > 0 {
            let moved = result.blackAndWhiteWeight(band) + delta * weights[index]
            result.setBlackAndWhiteWeight(min(max(moved, -100), 100), for: band)
        }
        return result
    }
}
```

In `Sources/Views/EditorModel.swift` (view-state section, beside the canvas pickers):

```swift
    /// What a TAT drag edits. View state; the options bar binds it.
    enum TATTarget: String, CaseIterable, Identifiable {
        case curve, hue, saturation, luminance
        var id: String { rawValue }
        var label: String { rawValue == "curve" ? "CURVE" : String(rawValue.prefix(3)).uppercased() }
    }

    var tatTarget: TATTarget = .curve

    private struct TATDrag {
        var reading: PixelReading
        var hue: Double
        var saturation: Double
        var stackAtStart: EditStack
        var curveIndex: Int?
    }

    private var tatDrag: TATDrag?

    func beginTATDrag(atUnitPoint point: CGPoint) {
        guard let reading = sample(atUnitPoint: point) else { return }
        let (hue, saturation, _) = ColorScience.rgbToHSL(reading.red, reading.green, reading.blue)
        tatDrag = TATDrag(reading: reading, hue: hue, saturation: saturation,
                          stackAtStart: editStack, curveIndex: nil)
    }

    /// One drag tick, cumulative from the start (upward positive). Rebuilds
    /// from the stack captured at the start and writes ONE field once —
    /// `autoConvertNegative`'s single-assignment rule.
    func continueTATDrag(byPoints delta: Double) {
        guard var drag = tatDrag else { return }
        switch tatTarget {
        case .curve:
            // Free points are a PV2 grammar (Task 4's gate); on PV1 the drag
            // deliberately does nothing rather than corrupt a frozen look.
            guard editStack.processVersion >= 2 else { return }
            let edit = TATMath.curveEdit(points: drag.stackAtStart.toneCurvePoints,
                                         luma: drag.reading.luma,
                                         existingIndex: drag.curveIndex,
                                         deltaPoints: delta)
            drag.curveIndex = edit.index
            tatDrag = drag
            editStack.toneCurvePoints = edit.points
        case .hue, .saturation, .luminance:
            let field: WritableKeyPath<HSLAdjustment, Double> = switch tatTarget {
            case .hue: \.hue
            case .saturation: \.saturation
            default: \.luminance
            }
            editStack.color.mixer = editStack.color.treatment == .blackAndWhite
                ? TATMath.blackAndWhiteEdit(drag.stackAtStart.color.mixer,
                                            hue: drag.hue, saturation: drag.saturation,
                                            deltaPoints: delta)
                : TATMath.mixerEdit(drag.stackAtStart.color.mixer,
                                    hue: drag.hue, saturation: drag.saturation,
                                    field: field, deltaPoints: delta)
        }
    }

    func endTATDrag() {
        tatDrag = nil
    }
```

- [x] **Step 5: Run all of Step 1's classes** — expected PASS. Also `-only-testing:PhotoEditorTests/ToolActivationTests` — PASS (the new tool rides the existing table tests).

- [x] **Step 6: Canvas + options bar**

In `Sources/Views/CanvasArea.swift`, add to `EditCanvas` a `@State private var isTATDragging = false`, a branch in `overlays(in:)` before the retouch-paint branch:

```swift
            } else if workspace.activeTool == .targetedAdjustment {
                tatDragOverlay(displaySize: rect.size)
```

and the overlay (the `retouchPaintOverlay` pattern; upward drag is positive, hence the sign flip):

```swift
    private func tatDragOverlay(displaySize: CGSize) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if !isTATDragging {
                            isTATDragging = true
                            editor.beginTATDrag(atUnitPoint:
                                unitPoint(value.startLocation, displaySize: displaySize))
                        }
                        editor.continueTATDrag(byPoints: -Double(value.translation.height))
                    }
                    .onEnded { _ in
                        isTATDragging = false
                        editor.endTATDrag()
                    }
            )
    }
```

In `Sources/Views/ToolRail.swift`, `ToolOptionsBar.options` gains its case (the switch is exhaustive — the compiler demands it):

```swift
        case .targetedAdjustment:
            HStack(spacing: 14) {
                TabStrip(
                    options: EditorModel.TATTarget.allCases.map { ($0, $0.label) },
                    selection: Binding(get: { model.tatTarget },
                                       set: { model.tatTarget = $0 }),
                    spacing: Theme.space3
                )
                contextNote(model.editStack.color.treatment == .blackAndWhite
                            && model.tatTarget != .curve
                            ? "Drag the photograph up or down — edits the B&W mix"
                            : "Drag the photograph up or down")
            }
```

Menu: nothing to add — the Develop ▸ Tool submenu iterates `EditorTool.allCases` and already prints `"Target  (T)"` with no key equivalent, per the house rule.

- [x] **Step 7: Verify**

Run: `-only-testing:PhotoEditorTests/TATMathTests -only-testing:PhotoEditorTests/TATModelTests -only-testing:PhotoEditorTests/ToolActivationTests -only-testing:PhotoEditorTests/CanvasToolTests`
Expected: ALL PASS.

- [x] **Step 8: Commit**

```bash
git add Sources/Models/TATMath.swift Sources/Models/WorkspaceState.swift Sources/Views/WorkspaceModel.swift Sources/Views/EditorModel.swift Sources/Views/CanvasArea.swift Sources/Views/ToolRail.swift Tests/TATMathTests.swift project.yml PhotoEditor.xcodeproj
git commit -m "feat(tat): targeted adjustment tool — curve at the sampled luminance, mixer by the LUT's own band weights"
```

---

### Task 6: Color grading wheels + the Global zone

The Color Grade panel's slider triplets become drawn hue/saturation wheels — puck at angle = hue, radius = saturation, luminance micro-slider beneath, Blending/Balance unchanged — and the model gains the one new `EditStack`-reachable field in this plan: `ColorGrading.global`, a fourth `ColorGradeZone` decoding `ColorGradeZone()` (an exact no-op) and summed into `ColorCubeBuilder.applyGrading` at weight 1 regardless of luminance. Wheel values map onto the existing zone fields — **no render change for any existing photo**, proven bit-for-bit at the cube-data level. Per the Global Constraints, `color` stays excluded in `ControlConformanceTests` and the render conformance lands in `Tests/ColorSuiteTests.swift` here.

**Files:**
- Create: `Sources/Views/Controls/ColorWheel.swift`, `Tests/ColorWheelTests.swift`
- Modify: `Sources/Models/ColorSettings.swift`, `Sources/Pipeline/ColorCubeBuilder.swift`, `Sources/Views/SliderPanel/ColorMixerPanel.swift`, `Tests/ColorSuiteTests.swift`

**Interfaces:**
- Consumes: `ColorGradeZone`, `ColorScience.hslToRGB/wrapHue`, `ColorCubeBuilder.applyGrading/zoneWeights`, `Theme.hairline/strongSeparator`.
- Produces: `ColorGrading.global`, `ColorWheelMath.puckOffset/value`, `ColorWheel`.

- [x] **Step 1: Write the failing tests**

Create `Tests/ColorWheelTests.swift`:

```swift
import CoreGraphics
import Foundation
import XCTest
@testable import PhotoEditor

/// The wheel's geometry (pure) and the Global zone's decode contract.
final class ColorWheelTests: XCTestCase {
    func testPuckRoundTripsHueAndSaturation() {
        let offset = ColorWheelMath.puckOffset(hue: 137, saturation: 62, radius: 60)
        let value = ColorWheelMath.value(atOffset: offset, radius: 60)
        XCTAssertEqual(value.hue, 137, accuracy: 0.01)
        XCTAssertEqual(value.saturation, 62, accuracy: 0.01)
    }

    func testDraggingPastTheRimClampsSaturationAtFull() {
        let value = ColorWheelMath.value(atOffset: CGSize(width: 500, height: 0), radius: 60)
        XCTAssertEqual(value.saturation, 100)
        XCTAssertEqual(value.hue, 0, accuracy: 0.01)
    }

    func testTheCentreIsSaturationZero() {
        XCTAssertEqual(ColorWheelMath.value(atOffset: .zero, radius: 60).saturation, 0)
    }

    // MARK: Global zone — the plan's one new persisted colour field

    func testAStackWrittenBeforeGlobalDecodesToANeutralGlobalZone() throws {
        // Exactly what an existing catalog row contains: a grading dict with
        // three zones and no "global" key.
        let json = """
        {"shadows": {"hue": 220, "saturation": 30, "luminance": 0},
         "midtones": {"hue": 0, "saturation": 0, "luminance": 0},
         "highlights": {"hue": 40, "saturation": 20, "luminance": 0},
         "blending": 50, "balance": 0}
        """
        let grading = try JSONDecoder().decode(ColorGrading.self, from: Data(json.utf8))
        XCTAssertEqual(grading.global, ColorGradeZone(), "absent → exact no-op")
        XCTAssertEqual(grading.shadows.hue, 220)
    }

    /// Bit-for-bit, CPU-side: the LUT built for an old-decoded grading equals
    /// the LUT built for the same grading constructed today. Byte equality of
    /// cube data is the strongest render-identity proof available without a GPU.
    func testGlobalAtDefaultLeavesTheCubeDataByteIdentical() throws {
        var settings = ColorSettings()
        settings.grading.shadows.hue = 220
        settings.grading.shadows.saturation = 30

        var withExplicitNeutralGlobal = settings
        withExplicitNeutralGlobal.grading.global = ColorGradeZone()

        XCTAssertEqual(ColorCubeBuilder.cubeData(for: settings),
                       ColorCubeBuilder.cubeData(for: withExplicitNeutralGlobal))
    }
}
```

In `Tests/ColorSuiteTests.swift`, add the render conformance (this is the Global-Constraints Task 6 obligation):

```swift
    /// ColorGrading.global's conformance home (ControlConformanceTests
    /// excludes `color` in favour of this suite): the Global zone tints the
    /// whole frame — including tones the three-zone weights would split.
    func testGlobalGradeTintsAMidGreyFrame() {
        var stack = EditStack()
        stack.color.grading.global.hue = 120
        stack.color.grading.global.saturation = 100

        let source = TestSupport.solidImage(red: 0.5, green: 0.5, blue: 0.5, size: 32)
        let result = TestSupport.readColor(renderer.render(source: source, stack: stack))
        XCTAssertGreaterThan(result.green, result.red + 0.03,
                             "a green Global grade must reach a midtone")
    }

    func testGlobalGradeLuminanceLiftsShadowsAndHighlightsAlike() {
        var stack = EditStack()
        stack.color.grading.global.luminance = 80

        let dark = TestSupport.solidImage(red: 0.15, green: 0.15, blue: 0.15, size: 32)
        let bright = TestSupport.solidImage(red: 0.8, green: 0.8, blue: 0.8, size: 32)
        let liftedDark = TestSupport.readColor(renderer.render(source: dark, stack: stack))
        let liftedBright = TestSupport.readColor(renderer.render(source: bright, stack: stack))
        XCTAssertGreaterThan(liftedDark.red, 0.17, "weight 1 in the shadows")
        XCTAssertGreaterThan(liftedBright.red, 0.82, "and weight 1 in the highlights")
    }
```

- [x] **Step 2: Run** `-only-testing:PhotoEditorTests/ColorWheelTests -only-testing:PhotoEditorTests/ColorSuiteTests` — expected COMPILE FAILURE.

- [x] **Step 3: Model + LUT**

In `Sources/Models/ColorSettings.swift`, `ColorGrading` gains the zone — decoded leniently, folded into `isNeutral` so the LUT skip stays honest:

```swift
    /// A tint over the whole tonal range, summed with the three zones at
    /// weight 1 — split toning's "and also everything". Decodes neutral, so
    /// every stack written before it existed renders identically.
    var global = ColorGradeZone()
```

```swift
    var isNeutral: Bool {
        shadows.isNeutral && midtones.isNeutral && highlights.isNeutral && global.isNeutral
    }
```

```swift
        global = c.lenient(.global, ColorGradeZone())
```

In `Sources/Pipeline/ColorCubeBuilder.swift`, `applyGrading`'s zone list grows one row — global at constant weight, before the weighted three:

```swift
        let zones = [
            (grading.global, 1.0),
            (grading.shadows, weights.shadows),
            (grading.midtones, weights.midtones),
            (grading.highlights, weights.highlights),
        ]
```

(`zoneWeights` is untouched; Blending/Balance keep governing only the three-zone split.)

- [x] **Step 4: The wheel**

Create `Sources/Views/Controls/ColorWheel.swift`:

```swift
import AppKit
import SwiftUI

/// The wheel's geometry, kept pure so the puck round-trip is provable.
/// Hue 0° sits at 3 o'clock and increases counter-clockwise (the colour-science
/// convention `hslToRGB` uses); view y grows downward, hence the sign flips.
enum ColorWheelMath {
    static func puckOffset(hue: Double, saturation: Double, radius: CGFloat) -> CGSize {
        let angle = hue * .pi / 180
        let r = radius * CGFloat(min(max(saturation / 100, 0), 1))
        return CGSize(width: cos(angle) * r, height: -sin(angle) * r)
    }

    static func value(atOffset offset: CGSize, radius: CGFloat) -> (hue: Double, saturation: Double) {
        let r = hypot(offset.width, offset.height)
        guard r > 0.5 else { return (0, 0) }
        let hue = ColorScience.wrapHue(Double(atan2(-offset.height, offset.width)) * 180 / .pi)
        return (hue, Double(min(r / radius, 1)) * 100)
    }
}

/// A drawn hue/saturation wheel for one grading zone. The interior is the one
/// place in this panel colour legitimately appears — it is data, a
/// colour-selection surface — ringed by the same hairline as every instrument.
/// ⌥-drag is 10× finer (read live, like AdjustmentSlider); double-click
/// resets the zone.
struct ColorWheel: View {
    @Binding var zone: ColorGradeZone
    var diameter: CGFloat = 132

    @State private var dragAnchor: CGSize?

    private var radius: CGFloat { diameter / 2 }

    var body: some View {
        ZStack {
            Circle()
                .fill(AngularGradient(
                    colors: stride(from: 0.0, through: 360.0, by: 30.0).map {
                        let rgb = ColorScience.hslToRGB(360 - $0, 0.8, 0.5)
                        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
                    },
                    center: .center))
            Circle()
                .fill(RadialGradient(colors: [Color(white: 0.5), .clear],
                                     center: .center, startRadius: 0, endRadius: radius))
            Circle()
                .strokeBorder(Theme.strongSeparator, lineWidth: Theme.hairline)

            // The puck: the mask-pin language, no colour of its own.
            Circle()
                .fill(Theme.text)
                .frame(width: 11, height: 11)
                .overlay { Circle().strokeBorder(Theme.canvas, lineWidth: 1.5) }
                .shadow(color: .black.opacity(0.6), radius: 2)
                .offset(ColorWheelMath.puckOffset(hue: zone.hue,
                                                  saturation: zone.saturation,
                                                  radius: radius))
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle().scale(1.1))
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let centre = CGSize(width: value.location.x - radius,
                                        height: value.location.y - radius)
                    let anchor = dragAnchor ?? ColorWheelMath.puckOffset(
                        hue: zone.hue, saturation: zone.saturation, radius: radius)
                    if dragAnchor == nil { dragAnchor = anchor }
                    // ⌥ read live: relative from the puck at 10× finer.
                    let offset: CGSize
                    if NSEvent.modifierFlags.contains(.option) {
                        offset = CGSize(width: anchor.width + value.translation.width / 10,
                                        height: anchor.height + value.translation.height / 10)
                    } else {
                        offset = centre
                    }
                    let picked = ColorWheelMath.value(atOffset: offset, radius: radius)
                    zone.hue = picked.saturation > 0 ? picked.hue : zone.hue
                    zone.saturation = picked.saturation
                }
                .onEnded { _ in dragAnchor = nil }
        )
        .onTapGesture(count: 2) { zone = ColorGradeZone() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Colour wheel")
        .accessibilityValue(String(format: "hue %.0f°, saturation %.0f",
                                   zone.hue, zone.saturation))
    }
}
```

- [x] **Step 5: The panel**

In `Sources/Views/SliderPanel/ColorMixerPanel.swift`, `ColorGradingPanel`: extend the zone enum and swap the Hue/Saturation sliders for the wheel (Luminance stays as the micro-slider; Blending/Balance unchanged):

```swift
    enum Zone: String, CaseIterable, Identifiable {
        case shadows, midtones, highlights, global
        var id: String { rawValue }
        var displayName: String { rawValue.capitalized }
    }
```

```swift
            TabStrip(
                options: Zone.allCases.map { ($0, $0.displayName) },
                selection: $selectedZone,
                spacing: Theme.space3
            )

            HStack {
                Spacer()
                ColorWheel(zone: zoneBinding)
                Spacer()
            }

            AdjustmentSlider(title: "Luminance", value: zoneBinding(\.luminance),
                             range: -100...100, format: "%.0f", neutral: 0)
```

with the zone path switch gaining `case .global: \.global`, and a whole-zone binding:

```swift
    private var zoneBinding: Binding<ColorGradeZone> {
        let zonePath: WritableKeyPath<ColorGrading, ColorGradeZone> = switch selectedZone {
        case .shadows: \.shadows
        case .midtones: \.midtones
        case .highlights: \.highlights
        case .global: \.global
        }
        return Binding(
            get: { model.editStack.color.grading[keyPath: zonePath] },
            set: { model.editStack.color.grading[keyPath: zonePath] = $0 }
        )
    }
```

`SliderPanel`'s Color Grade section needs no change: `isModified: !grading.isNeutral` now covers Global through the extended `isNeutral`, and its reset (`grading = ColorGrading()`) already clears the new zone.

- [x] **Step 6: Verify**

Run: `-only-testing:PhotoEditorTests/ColorWheelTests -only-testing:PhotoEditorTests/ColorSuiteTests -only-testing:PhotoEditorTests/ColorMixerTests -only-testing:PhotoEditorTests/ControlConformanceTests`
Expected: ALL PASS — `ControlConformanceTests` in particular: `color` keeps its exclusion, and no `EditStack` top-level field was added, so the completeness walk is untouched.

- [x] **Step 7: Commit**

```bash
git add Sources/Models/ColorSettings.swift Sources/Pipeline/ColorCubeBuilder.swift Sources/Views/Controls/ColorWheel.swift Sources/Views/SliderPanel/ColorMixerPanel.swift Tests/ColorWheelTests.swift Tests/ColorSuiteTests.swift project.yml PhotoEditor.xcodeproj
git commit -m "feat(grade): drawn hue/sat wheels for the grading zones, plus a lenient Global zone summed in the LUT"
```

---

### Task 7: Presets — hover preview, amount, folders, import/export, drawn naming

Hovering a preset row renders the candidate stack to the canvas through the existing debounced `renderPreview()` path — `editStack` and the undo history untouched, mouse-out reverts. An Amount slider scales the preset's deltas (`EditStack.interpolated(toward:amount:)`: every `Double` lerps, everything discrete applies whole). Folders come from parsing `/` in the existing `group` column — no schema change. Import/export is JSON over the same `Codable` the catalog already uses. And the stock `alert` naming flow — the one recorded design-language break this plan touches — becomes a drawn `InstrumentField` sheet.

**Files:**
- Create: `Tests/PresetWorkflowTests.swift`
- Modify: `Sources/Models/DevelopPreset.swift`, `Sources/Views/SliderPanel/PresetPanel.swift`, `Sources/Views/EditorModel.swift`, `Sources/App/AppModel.swift`, `Sources/App/EditorCommands.swift`

**Interfaces:**
- Consumes: `DevelopPreset`, `EditStack.applying(_:options:)`, `AppModel.savePreset/deletePreset/reloadPresets`, `catalog.savePreset`, `RenderScheduler` (implicitly, via `renderPreview()`).
- Produces: `EditStack.interpolated(toward:amount:)`, `DevelopPreset.folderPath`, `EditorModel.beginPresetPreview(_:amount:)/endPresetPreview(_:)/applyPreset(_:amount:)`, `AppModel.exportedPresetData()/importPresetData(_:)/importPresets(from:)/exportPresets()`.

- [x] **Step 1: Write the failing tests**

Create `Tests/PresetWorkflowTests.swift`:

```swift
import CoreGraphics
import Foundation
import XCTest
@testable import PhotoEditor

final class PresetAmountTests: XCTestCase {
    private func look() -> EditStack {
        var stack = EditStack()
        stack.exposure = 2.0
        stack.contrast = 40
        stack.color.treatment = .blackAndWhite
        stack.color.grading.shadows.saturation = 60
        return stack
    }

    func testAmountOneIsExactlyTheFullApply() {
        let base = EditStack()
        XCTAssertEqual(base.interpolated(toward: base.applying(look()), amount: 1),
                       base.applying(look()))
    }

    func testAmountZeroIsExactlyTheBase() {
        var base = EditStack()
        base.exposure = -1
        XCTAssertEqual(base.interpolated(toward: base.applying(look()), amount: 0), base)
    }

    func testHalfAmountLandsScalarsHalfway() {
        let base = EditStack()
        let half = base.interpolated(toward: base.applying(look()), amount: 0.5)
        XCTAssertEqual(half.exposure, 1.0, accuracy: 1e-9)
        XCTAssertEqual(half.contrast, 20, accuracy: 1e-9)
        XCTAssertEqual(half.color.grading.shadows.saturation, 30, accuracy: 1e-9)
        XCTAssertEqual(half.color.treatment, .blackAndWhite,
                       "discrete settings apply whole at any non-zero amount")
    }
}

@MainActor
final class PresetPreviewTests: XCTestCase {
    func testHoverPreviewShowsTheLookWithoutTouchingTheStack() throws {
        let editor = try TestSupport.makeEditorModel(gray: 100)
        let before = TestSupport.averageBrightness(try XCTUnwrap(editor.displayImage))

        var look = EditStack()
        look.exposure = 2
        let preset = DevelopPreset(name: "Bright", editStack: look)

        editor.beginPresetPreview(preset, amount: 1)
        let during = TestSupport.averageBrightness(try XCTUnwrap(editor.displayImage))
        XCTAssertGreaterThan(during, before + 0.05, "the canvas shows the candidate")
        XCTAssertEqual(editor.editStack.exposure, 0, "the stack is untouched")

        editor.endPresetPreview(preset)
        let after = TestSupport.averageBrightness(try XCTUnwrap(editor.displayImage))
        XCTAssertEqual(after, before, accuracy: 0.01, "mouse-out reverts")
    }

    /// Rapid row-to-row hovers deliver end(old) after begin(new) in no
    /// guaranteed order; ending a preview that is not the current one must
    /// not kill the current one.
    func testEndingAStalePreviewDoesNotClearTheCurrentOne() throws {
        let editor = try TestSupport.makeEditorModel(gray: 100)
        let a = DevelopPreset(name: "A", editStack: EditStack())
        var brightLook = EditStack(); brightLook.exposure = 2
        let b = DevelopPreset(name: "B", editStack: brightLook)

        editor.beginPresetPreview(a, amount: 1)
        editor.beginPresetPreview(b, amount: 1)
        editor.endPresetPreview(a) // the stale end arrives late
        let shown = TestSupport.averageBrightness(try XCTUnwrap(editor.displayImage))
        XCTAssertGreaterThan(shown, 0.45, "B's preview survives A's late mouse-out")
    }

    func testClickApplyIsOneUndoableStep() throws {
        let editor = try TestSupport.makeEditorModel(gray: 100)
        var look = EditStack(); look.exposure = 1.5
        editor.applyPreset(DevelopPreset(name: "P", editStack: look), amount: 0.5)
        XCTAssertEqual(editor.editStack.exposure, 0.75, accuracy: 1e-9)
        editor.commitEdit()
        XCTAssertEqual(editor.undoDepth, 1)
    }
}

final class PresetStorageTests: XCTestCase {
    func testFolderPathParsesSlashesAndIgnoresBlanks() {
        XCTAssertEqual(DevelopPreset(name: "x", group: "Portra/Warm",
                                     editStack: EditStack()).folderPath, ["Portra", "Warm"])
        XCTAssertEqual(DevelopPreset(name: "x", group: "User Presets",
                                     editStack: EditStack()).folderPath, ["User Presets"])
        XCTAssertEqual(DevelopPreset(name: "x", group: "  ",
                                     editStack: EditStack()).folderPath, ["User Presets"])
    }

    @MainActor
    func testExportImportRoundTripsThroughJSONWithFreshIdentities() throws {
        let app = AppModel(catalog: try TestSupport.inMemoryCatalog(),
                           thumbnails: TestSupport.tempThumbnails())
        var look = EditStack(); look.exposure = 1.2; look.color.grading.global.saturation = 15
        app.savePreset(named: "Roll Look", from: look, group: "Rolls/2026")

        let data = try XCTUnwrap(app.exportedPresetData())
        let other = AppModel(catalog: try TestSupport.inMemoryCatalog(),
                             thumbnails: TestSupport.tempThumbnails())
        XCTAssertEqual(other.importPresetData(data), 1)
        let imported = try XCTUnwrap(other.presets.first)
        XCTAssertEqual(imported.name, "Roll Look")
        XCTAssertEqual(imported.editStack, look, "the EditStack coding is shared verbatim")
        XCTAssertNotEqual(imported.id, app.presets.first?.id,
                          "imports mint fresh ids so re-import never clobbers")
    }
}
```

- [x] **Step 2: Run the three classes** — expected COMPILE FAILURE.

- [x] **Step 3: The model pieces**

In `Sources/Models/DevelopPreset.swift`:

```swift
extension DevelopPreset {
    /// The group column parsed as a folder path: "Portra/Warm" nests Warm
    /// under Portra. Pure presentation — the catalog schema is untouched.
    var folderPath: [String] {
        let parts = group.split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? ["User Presets"] : parts
    }
}

extension EditStack {
    /// `self` moved `amount` of the way toward `target`: every `Double` in
    /// the stack lerps; everything discrete (treatments, point lists, LUT
    /// data, spot arrays) takes `target`'s value whole for any amount > 0 —
    /// half a curve point list is not a meaningful object. Callers produce
    /// `target` via `applying(_:options:)`, so the per-frame exclusions
    /// (crop, film base) are already respected before interpolation.
    func interpolated(toward target: EditStack, amount: Double) -> EditStack {
        let t = min(max(amount, 0), 1)
        if t <= 0 { return self }
        if t >= 1 { return target }
        var result = target
        func lerp(_ path: WritableKeyPath<EditStack, Double>) {
            result[keyPath: path] = self[keyPath: path]
                + (target[keyPath: path] - self[keyPath: path]) * t
        }
        // Light, WB, presence, detail, effects, parametric curve — the same
        // field inventory ControlConformanceTests walks; keep the two lists
        // in sight of each other when adding a slider.
        for path: WritableKeyPath<EditStack, Double> in [
            \.exposure, \.contrast, \.highlights, \.shadows, \.whites, \.blacks,
            \.whiteBalanceTemp, \.whiteBalanceTint,
            \.texture, \.clarity, \.dehaze, \.vibrance, \.saturation,
            \.sharpenAmount, \.sharpenRadius, \.luminanceNoiseReduction, \.colorNoiseReduction,
            \.vignetteAmount, \.vignetteMidpoint, \.vignetteRoundness,
            \.vignetteFeather, \.vignetteHighlights, \.grainAmount, \.grainSize,
            \.toneCurveHighlights, \.toneCurveLights, \.toneCurveDarks, \.toneCurveShadows,
        ] { lerp(path) }
        // Colour scalars: mixer bands, B&W mix, grading zones lerp per field.
        for (index, band) in target.color.mixer.bands.enumerated() {
            let mine = color.mixer.bands[index]
            result.color.mixer.bands[index].hue = mine.hue + (band.hue - mine.hue) * t
            result.color.mixer.bands[index].saturation =
                mine.saturation + (band.saturation - mine.saturation) * t
            result.color.mixer.bands[index].luminance =
                mine.luminance + (band.luminance - mine.luminance) * t
        }
        for index in target.color.mixer.blackAndWhiteMix.indices {
            let mine = color.mixer.blackAndWhiteMix[index]
            result.color.mixer.blackAndWhiteMix[index] =
                mine + (target.color.mixer.blackAndWhiteMix[index] - mine) * t
        }
        for path: WritableKeyPath<EditStack, ColorGradeZone> in [
            \.color.grading.shadows, \.color.grading.midtones,
            \.color.grading.highlights, \.color.grading.global,
        ] {
            let mine = self[keyPath: path]
            let theirs = target[keyPath: path]
            result[keyPath: path].saturation = mine.saturation
                + (theirs.saturation - mine.saturation) * t
            result[keyPath: path].luminance = mine.luminance
                + (theirs.luminance - mine.luminance) * t
        }
        return result
    }
}
```

In `Sources/Views/EditorModel.swift` — the preview is view state riding the existing debounced render, and the apply is one assignment:

```swift
    // MARK: Preset preview (view state, never persisted)

    /// The candidate stack shown while a preset row is hovered, keyed by the
    /// preset so a stale mouse-out cannot clear a newer hover.
    private(set) var presetPreview: (presetID: String, stack: EditStack)?

    func beginPresetPreview(_ preset: DevelopPreset, amount: Double) {
        presetPreview = (preset.id, candidateStack(for: preset, amount: amount))
        renderPreview()
    }

    func endPresetPreview(_ preset: DevelopPreset) {
        guard presetPreview?.presetID == preset.id else { return }
        presetPreview = nil
        renderPreview()
    }

    /// Applies a preset at an amount — one stack assignment, one undo step.
    func applyPreset(_ preset: DevelopPreset, amount: Double) {
        presetPreview = nil
        editStack = candidateStack(for: preset, amount: amount)
    }

    private func candidateStack(for preset: DevelopPreset, amount: Double) -> EditStack {
        editStack.interpolated(toward: editStack.applying(preset.editStack), amount: amount)
    }
```

and in `renderPreviewNow()`, the stack pick becomes:

```swift
        var stack = isShowingBefore ? beforeStack : editStack
        if let presetPreview { stack = presetPreview.stack }
```

(The existing `applyPreset(_:options:)` stays for callers that want the un-scaled apply; the panel now routes through the amount version.)

In `Sources/App/AppModel.swift` — panels thin, logic testable:

```swift
    /// All presets as a JSON array — the same Codable the catalog stores.
    func exportedPresetData() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(presets)
    }

    /// Decodes a preset file (a single object or an array), minting fresh ids
    /// so importing twice duplicates rather than silently clobbers. Returns
    /// the count imported.
    @discardableResult
    func importPresetData(_ data: Data) -> Int {
        let decoder = JSONDecoder()
        let decoded: [DevelopPreset]
        if let list = try? decoder.decode([DevelopPreset].self, from: data) {
            decoded = list
        } else if let one = try? decoder.decode(DevelopPreset.self, from: data) {
            decoded = [one]
        } else {
            errorMessage = "That file is not a preset export."
            return 0
        }
        var imported = 0
        for preset in decoded {
            var fresh = preset
            fresh.id = UUID().uuidString
            if (try? catalog.savePreset(fresh)) != nil { imported += 1 }
        }
        reloadPresets()
        return imported
    }
```

plus the two `NSOpenPanel`/`NSSavePanel` wrappers `importPresets()` / `exportPresets()` (the `ColorMixerPanel.importLUT` pattern: allowed type `json`, then call the data methods).

- [x] **Step 4: Run the three classes** — expected PASS.

- [x] **Step 5: The panel**

In `Sources/Views/SliderPanel/PresetPanel.swift`:
- Add `@State private var presetAmount = 100.0` and `@State private var presetGroup = ""`; an `AdjustmentSlider(title: "Amount", value: $presetAmount, range: 0...100, format: "%.0f", neutral: 100)` above the list.
- Group rows by `folderPath`: outer `Text(path[0].uppercased()).sectionLabel()`, deeper components as an indented quieter label — folders are typography, not chrome.
- `PresetRow`'s hover handler drives the preview and the click applies at amount:

```swift
        .onHover { hovering in
            isHovering = hovering
            if hovering { model.beginPresetPreview(preset, amount: amount / 100) }
            else { model.endPresetPreview(preset) }
        }
```

(`PresetRow` gains `let amount: Double`; the apply button calls `model.applyPreset(preset, amount: amount / 100)`.)
- Replace the `.alert` with a drawn sheet — the design-language fix:

```swift
        .sheet(isPresented: $isNaming) {
            VStack(alignment: .leading, spacing: Theme.space4) {
                Text("SAVE PRESET").sectionLabel(Theme.text)
                InstrumentField(placeholder: "Preset name", text: $presetName)
                InstrumentField(placeholder: "Folder  (use / to nest)", text: $presetGroup)
                HStack {
                    Spacer()
                    PlateButton(title: "Cancel") { isNaming = false }
                    PlateButton(title: "Save", emphasis: .prominent) {
                        let name = presetName.trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty else { return }
                        app.savePreset(named: name, from: model.editStack,
                                       group: presetGroup.trimmingCharacters(in: .whitespaces)
                                           .isEmpty ? "User Presets" : presetGroup)
                        isNaming = false
                    }
                }
            }
            .padding(Theme.space5)
            .frame(width: 320)
            .background(Theme.surface)
        }
```

- Two `PlateButton`s under the list: "Import…" → `app.importPresets()`, "Export All…" → `app.exportPresets()`.

In `Sources/App/EditorCommands.swift`, File group (after "Export…"):

```swift
            Button("Import Presets…") { app.importPresets() }
            Button("Export Presets…") { app.exportPresets() }
                .disabled(app.presets.isEmpty)
```

(No key equivalents — infrequent commands do not spend shortcuts.)

- [x] **Step 6: Verify**

Run: `-only-testing:PhotoEditorTests/PresetAmountTests -only-testing:PhotoEditorTests/PresetPreviewTests -only-testing:PhotoEditorTests/PresetStorageTests -only-testing:PhotoEditorTests/WorkflowTests -only-testing:PhotoEditorTests/EditorUndoTests`
Expected: ALL PASS (`WorkflowTests` proves `applying(_:options:)` semantics undisturbed).

- [x] **Step 7: Commit**

```bash
git add Sources/Models/DevelopPreset.swift Sources/Views/SliderPanel/PresetPanel.swift Sources/Views/EditorModel.swift Sources/App/AppModel.swift Sources/App/EditorCommands.swift Tests/PresetWorkflowTests.swift project.yml PhotoEditor.xcodeproj
git commit -m "feat(presets): hover preview on the real image, amount blending, slash folders, JSON import/export, drawn naming sheet"
```

---

### Task 8: One fader grammar — `MiniContextFader` becomes `AdjustmentSlider.compact`

`MiniContextFader` looks like the panel fader but behaves like a toy: no delta bar, no scrubby readout, no ⌥-precision, no keyboard, no double-click reset. `AdjustmentSlider` gains a `.compact` style — the same state, gestures, focus and reset machinery, laid out on one row at options-bar height — and the five `MiniContextFader` call sites in `ToolOptionsBar` switch over, with `neutral` set to each field's model default (`RetouchSpot`: radius 0.025, feather 0.5; `MaskComponent`: brushSize 0.04, brushFeather 0.65, brushFlow 0.8 — the values in those files' initializers). Then `MiniContextFader` is deleted. A view-layout refactor with no model surface: no new tests — the fader's behaviour set is already exercised through the develop panel, and the verification is the build plus the existing canvas/tool suites.

**Files:**
- Modify: `Sources/Views/SliderPanel/AdjustmentSlider.swift`, `Sources/Views/ToolRail.swift`

**Interfaces:**
- Produces: `AdjustmentSlider.Style` (`.panel` default — every existing call site compiles unchanged; `.compact`).

- [x] **Step 1: The style**

In `Sources/Views/SliderPanel/AdjustmentSlider.swift`:

```swift
    /// Where the fader lives. `.panel` is the develop column's two-line form;
    /// `.compact` is the options bar's one-line form — same behaviour set
    /// (delta bar, scrub, ⌥-precision, keyboard, double-click reset), only
    /// the layout differs. One fader grammar everywhere.
    enum Style { case panel, compact }
    var style: Style = .panel
```

`body` switches on it — `.panel` keeps the current `VStack { header; track }`; `.compact` is:

```swift
        HStack(spacing: Theme.space2) {
            Text(title.uppercased()).sectionLabel()
            track.frame(width: 92)
            readout
        }
```

with every existing row modifier (`onTapGesture(count: 2)`, `onHover`, `focusable`, key presses, the focus edge, accessibility) applied to the common container so both styles share them verbatim. The compact readout keeps its scrub gesture — that is the point.

- [x] **Step 2: Swap the call sites and delete the old fader**

In `Sources/Views/ToolRail.swift`, replace each `MiniContextFader` with the compact fader — retouch:

```swift
                    AdjustmentSlider(title: "Size", value: spotBinding(index, \.radius),
                                     range: 0.004...0.15, format: "%.3f",
                                     neutral: 0.025, style: .compact)
                    AdjustmentSlider(title: "Feather", value: spotBinding(index, \.feather),
                                     range: 0...1, format: "%.2f",
                                     neutral: 0.5, style: .compact)
```

brush:

```swift
                    AdjustmentSlider(title: "Size", value: maskBinding(index, \.brushSize),
                                     range: 0.005...0.2, format: "%.3f",
                                     neutral: 0.04, style: .compact)
                    AdjustmentSlider(title: "Feather", value: maskBinding(index, \.brushFeather),
                                     range: 0...1, format: "%.2f",
                                     neutral: 0.65, style: .compact)
                    AdjustmentSlider(title: "Flow", value: maskBinding(index, \.brushFlow),
                                     range: 0.05...1, format: "%.2f",
                                     neutral: 0.8, style: .compact)
```

Delete the `MiniContextFader` struct at the bottom of the file. Nothing else references it (it was `private`).

- [x] **Step 3: Verify**

Run: `-only-testing:PhotoEditorTests/CanvasToolTests -only-testing:PhotoEditorTests/ToolActivationTests -only-testing:PhotoEditorTests/RetouchTests -only-testing:PhotoEditorTests/MaskComponentTests` (plus the build itself — the deleted type is the regression trap).
Expected: ALL PASS.

- [x] **Step 4: Commit**

```bash
git add Sources/Views/SliderPanel/AdjustmentSlider.swift Sources/Views/ToolRail.swift
git commit -m "refactor(controls): MiniContextFader becomes AdjustmentSlider.compact — one fader grammar everywhere"
```

---

### Task 9: Copy/paste scoping + Previous

⇧⌘C opens a drawn checkbox dialog organised by the numbered pipeline sections — `PipelineSection`, a new pure model that owns each section's index, `isModified(in:)` predicate (lifted verbatim from `SliderPanel`'s private helpers, which now delegate to it — one truth for the spine, the sheet's Modified button, and the scope), and a **complete** per-section field copy. Complete is the point: the section copy carries the fields the old `EditTransferOptions` path silently dropped (`vignetteRoundness/Feather/Highlights`, the four parametric curve values), and those same four options-path gaps get fixed too so presets stop dropping them. ⇧⌘V pastes the remembered scope; targeting rules (selection-or-all-visible in the sidebar, open frame from the menu) are unchanged. **Previous** (⌥⌘V) applies the last-edited photo's settings — captured in `AppModel.open(_:)`, which now also flushes the outgoing editor's pending commit — through the same remembered scope. Per-frame honesty holds: the film base is never carried, and Frame (crop) and Retouch (spot positions) default off.

**Files:**
- Create: `Sources/Models/TransferScope.swift`, `Sources/Views/CopySettingsSheet.swift`, `Tests/TransferScopeTests.swift`
- Modify: `Sources/Models/DevelopPreset.swift` (the options-path gap fixes), `Sources/App/AppModel.swift`, `Sources/App/EditorCommands.swift`, `Sources/App/PhotoEditorApp.swift`, `Sources/Views/SliderPanel/SliderPanel.swift`

**Interfaces:**
- Consumes: `EditStack`, `EditTransferOptions`, `AppModel.copiedStack/copiedFromName/apply`, `LampToggle`, `PlateButton`.
- Produces: `PipelineSection` (`.film … .effects`, `index/title/isModified(in:)/copied(from:onto:)`), `TransferScope` (`sections`, `.all/.none/.default/modified(in:)`), `EditStack.applying(_:scope:)`, `AppModel.copiedScope/isShowingCopySettingsSheet/copySettings(from:scope:)/applyPreviousSettings()`, `CopySettingsSheet`.

- [x] **Step 1: Write the failing tests**

Create `Tests/TransferScopeTests.swift`:

```swift
import CoreGraphics
import Foundation
import XCTest
@testable import PhotoEditor

final class PipelineSectionTests: XCTestCase {
    func testTheFourteenSectionsCarryTheirPanelIndices() {
        XCTAssertEqual(PipelineSection.allCases.count, 14)
        XCTAssertEqual(PipelineSection.film.index, "01")
        XCTAssertEqual(PipelineSection.toneCurve.index, "11")
        XCTAssertEqual(PipelineSection.effects.index, "14")
    }

    func testIsModifiedMatchesThePanelSpineSemantics() {
        var stack = EditStack()
        XCTAssertTrue(PipelineSection.allCases.allSatisfy { !$0.isModified(in: stack) })
        stack.sharpenRadius = 3 // non-zero neutral: 1.5, the Detail predicate's edge
        XCTAssertTrue(PipelineSection.detail.isModified(in: stack))
        stack = EditStack()
        stack.vignetteFeather = 80 // neutral 50
        XCTAssertTrue(PipelineSection.effects.isModified(in: stack))
        stack = EditStack()
        stack.whiteBalanceTemp = 5000
        XCTAssertTrue(PipelineSection.whiteBalance.isModified(in: stack))
    }

    /// The gap fixes, asserted where they used to lie: the section copy
    /// carries every Effects field and the parametric curve — fields the old
    /// options path dropped on the floor.
    func testSectionCopyCarriesTheFieldsTheOldPathDropped() {
        var source = EditStack()
        source.vignetteRoundness = -60
        source.vignetteFeather = 90
        source.vignetteHighlights = 40
        source.toneCurveDarks = -30

        let scoped = EditStack().applying(source, scope: TransferScope.all)
        XCTAssertEqual(scoped.vignetteRoundness, -60)
        XCTAssertEqual(scoped.vignetteFeather, 90)
        XCTAssertEqual(scoped.vignetteHighlights, 40)
        XCTAssertEqual(scoped.toneCurveDarks, -30)

        // …and the options path is fixed too, so presets stop dropping them.
        let viaOptions = EditStack().applying(source, options: .init())
        XCTAssertEqual(viaOptions.vignetteFeather, 90)
        XCTAssertEqual(viaOptions.toneCurveDarks, -30)
    }

    func testScopingActuallyScopes() {
        var source = EditStack()
        source.exposure = 1.5
        source.saturation = 40
        let scoped = EditStack().applying(source,
                                          scope: TransferScope(sections: [.light]))
        XCTAssertEqual(scoped.exposure, 1.5)
        XCTAssertEqual(scoped.saturation, 0, "Presence was not in scope")
    }

    func testFilmCarriesTheLookButNeverTheScansOwnMeasurements() {
        var source = EditStack()
        source.filmNegative.isEnabled = true
        source.filmNegative.print.contrast = 3.2
        source.filmNegative.print.punch = 40
        source.filmNegative.print.castRed = 12
        source.filmNegative.baseColor = FilmColor(red: 0.9, green: 0.5, blue: 0.3)
        source.filmNegative.print.dmax = DensityTriple(red: 2.4, green: 2.2, blue: 1.9)
        source.filmNegative.print.exposure = 0.7

        let target = EditStack().applying(source, scope: TransferScope(sections: [.film]))
        XCTAssertTrue(target.filmNegative.isEnabled)
        XCTAssertEqual(target.filmNegative.print.contrast, 3.2)
        XCTAssertEqual(target.filmNegative.print.punch, 40)
        XCTAssertEqual(target.filmNegative.print.castRed, 12)
        XCTAssertEqual(target.filmNegative.baseColor, FilmNegativeSettings().baseColor,
                       "the base is measured from THIS scan — never pasted")
        XCTAssertEqual(target.filmNegative.print.dmax, PrintSettings().dmax,
                       "per-scan solve stays per-scan")
        XCTAssertEqual(target.filmNegative.print.exposure, 0)
    }

    func testDefaultScopeLeavesTheFrameAndRetouchAlone() {
        XCTAssertFalse(TransferScope.default.sections.contains(.frame))
        XCTAssertFalse(TransferScope.default.sections.contains(.retouch))
        XCTAssertEqual(TransferScope.all.sections.count, 14)
        XCTAssertTrue(TransferScope.none.sections.isEmpty)
    }

    func testModifiedScopeIsExactlyTheLitSpineSections() {
        var stack = EditStack()
        stack.exposure = 1
        stack.color.grading.global.saturation = 10
        XCTAssertEqual(TransferScope.modified(in: stack).sections, [.light, .colorGrade])
    }
}

@MainActor
final class PreviousCommandTests: XCTestCase {
    func testPreviousAppliesTheLastEditedFramesLookThroughTheRememberedScope() throws {
        let catalog = try TestSupport.inMemoryCatalog()
        let urlA = try TestSupport.makeTempPNG(gray: 100)
        let urlB = try TestSupport.makeTempPNG(gray: 180)
        defer {
            try? FileManager.default.removeItem(at: urlA)
            try? FileManager.default.removeItem(at: urlB)
        }
        let a = TestSupport.makeEntry(fileURL: urlA)
        let b = TestSupport.makeEntry(fileURL: urlB)
        try catalog.save(a)
        try catalog.save(b)
        let app = AppModel(catalog: catalog, thumbnails: TestSupport.tempThumbnails())

        app.open(a)
        app.editor?.editStack.exposure = 1.4
        app.editor?.editStack.geometry.cropRect = CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)
        app.open(b) // capture point — and the pending commit flush

        XCTAssertEqual(app.applyPreviousSettings(), 1)
        XCTAssertEqual(app.editor?.editStack.exposure ?? 0, 1.4, accuracy: 1e-9)
        XCTAssertEqual(app.editor?.editStack.geometry.cropRect, .unitFrame,
                       "the default scope leaves B's framing alone")
    }

    func testPreviousWithNoHistoryDoesNothing() throws {
        let app = AppModel(catalog: try TestSupport.inMemoryCatalog(),
                           thumbnails: TestSupport.tempThumbnails())
        XCTAssertEqual(app.applyPreviousSettings(), 0)
    }
}
```

- [x] **Step 2: Run both classes** — expected COMPILE FAILURE.

- [x] **Step 3: Implement `Sources/Models/TransferScope.swift`**

`PipelineSection` — 14 cases in panel order, `index` = the two-digit string the panel prints, `title` = the panel's own title. `isModified(in:)` is `SliderPanel`'s private predicates moved verbatim (Film: `filmNegative != FilmNegativeSettings()`; Frame/Optics split exactly as `isFrameModified`/`isOpticsModified` split `geometry`; White Balance: `temp != 6500 || tint != 0`; Light includes `rawBoost != 100`; Tone Curve includes points, channel curves and the four parametric values; Color Mixer includes `treatment`; etc.). `copied(from:onto:)` copies **every** field its panel section binds:

- `.film` — the look, never the scan: `isEnabled, type, stockID, stockName, channelGains, exposure, stockContrast, stockSaturation, conversionModel`, and of `print`: `contrast, shoulder, toe, saturation, warmth, tint, toneProfile, punch, fade, glow, toeChroma, castRed/Green/Blue, shadowTrim, midTrim, highTrim`. **Never**: `baseColor, isBaseSampled, baseOrigin, print.dmax, print.gamma, print.exposure, print.gradePivot, print.renderVersion` (per-scan solve and engine provenance — copying `renderVersion` would thaw a freeze).
- `.frame` — `geometry.cropRect/rotation/straightenAngle/flipHorizontal/flipVertical`; `.optics` — `geometry.distortion/perspectiveVertical/perspectiveHorizontal` + `defringe` (the same split the two panels draw).
- `.retouch` — `retouch`; `.masks` — `localAdjustments`; `.pointColor` — `color.pointColors`.
- `.whiteBalance/.light/.presence/.detail` — their slider fields (Light includes `rawBoost`).
- `.colorMixer` — `color.treatment, color.mixer, color.calibration, color.creativeLUT` (everything that panel binds); `.colorGrade` — `color.grading`; `.toneCurve` — `toneCurvePoints, color.channelCurves`, and the four parametric fields.
- `.effects` — all seven: `vignetteAmount/Midpoint/Roundness/Feather/Highlights, grainAmount, grainSize`.

`TransferScope`:

```swift
struct TransferScope: Equatable {
    var sections: Set<PipelineSection>

    static let all = TransferScope(sections: Set(PipelineSection.allCases))
    static let none = TransferScope(sections: [])
    /// The old default's spirit, stated in sections: everything except the
    /// per-frame ones — Frame (this photo's composition) and Retouch (this
    /// photo's dust).
    static let `default` = TransferScope(
        sections: Set(PipelineSection.allCases).subtracting([.frame, .retouch]))

    static func modified(in stack: EditStack) -> TransferScope {
        TransferScope(sections: Set(PipelineSection.allCases.filter { $0.isModified(in: stack) }))
    }
}

extension EditStack {
    func applying(_ other: EditStack, scope: TransferScope) -> EditStack {
        var result = self
        for section in PipelineSection.allCases where scope.sections.contains(section) {
            result = section.copied(from: other, onto: result)
        }
        return result
    }
}
```

Also in `Sources/Models/DevelopPreset.swift`, the two options-path gap fixes: `options.effects` additionally copies `vignetteRoundness/vignetteFeather/vignetteHighlights`; `options.toneCurve` additionally copies the four `toneCurve*` parametric fields.

- [x] **Step 4: `AppModel` + run the model tests**

In `Sources/App/AppModel.swift`:

```swift
    var isShowingCopySettingsSheet = false

    /// The last scope chosen in the copy dialog — remembered so paste,
    /// sidebar copies and Previous all mean the same thing until changed.
    private(set) var copiedScope: TransferScope = .default

    func copySettings(from entry: CatalogEntry, scope: TransferScope? = nil) {
        if let scope { copiedScope = scope }
        copiedStack = entry.editStack
        copiedFromName = entry.fileName
    }
```

`pasteSettings(to:)` drops its `options` parameter and calls `apply(copiedStack, to: targets, scope: copiedScope)`; `apply(_:to:options:)` becomes `apply(_:to:scope:)` (same body, `applying(stack, scope: scope)`; no other caller existed). Previous:

```swift
    /// The stack of the photo edited before this one, captured on navigation.
    private(set) var previousStack: EditStack?
    private(set) var previousName: String?

    @discardableResult
    func applyPreviousSettings() -> Int {
        guard let previousStack, let entry = editor?.entry else { return 0 }
        return apply(previousStack, to: [entry], scope: copiedScope)
    }
```

and at the top of `open(_:)` — the capture, which also flushes the pending debounce the old code silently dropped on navigation:

```swift
        if let editor {
            editor.commitEdit()
            previousStack = editor.editStack
            previousName = editor.fileName
        }
```

Run: `-only-testing:PhotoEditorTests/PipelineSectionTests -only-testing:PhotoEditorTests/PreviousCommandTests -only-testing:PhotoEditorTests/WorkflowTests` — expected PASS.

- [x] **Step 5: The sheet, the menu, the panel delegation**

Create `Sources/Views/CopySettingsSheet.swift` — a drawn card, no stock controls:

```swift
import SwiftUI

/// The scoped-copy dialog: one lamp per numbered pipeline section, with the
/// modified ones flagged the same way the panel spine flags them.
struct CopySettingsSheet: View {
    let app: AppModel

    @State private var sections = TransferScope.default.sections

    private var stack: EditStack? { app.editor?.editStack }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space4) {
            Text("COPY SETTINGS").sectionLabel(Theme.text)

            HStack(spacing: Theme.space2) {
                PlateButton(title: "All") { sections = TransferScope.all.sections }
                PlateButton(title: "None") { sections = TransferScope.none.sections }
                PlateButton(title: "Modified") {
                    if let stack { sections = TransferScope.modified(in: stack).sections }
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                ForEach(PipelineSection.allCases, id: \.self) { section in
                    HStack(spacing: Theme.space2) {
                        Text(section.index)
                            .font(Theme.indexFont)
                            .foregroundStyle(Theme.tertiaryText)
                            .frame(width: 20, alignment: .trailing)
                        LampToggle(label: section.title, isOn: Binding(
                            get: { sections.contains(section) },
                            set: { if $0 { sections.insert(section) } else { sections.remove(section) } }
                        ))
                        Spacer()
                        if let stack, section.isModified(in: stack) {
                            Circle().fill(Theme.accent).frame(width: 4, height: 4)
                        }
                    }
                }
            }

            Text("Film carries the stock's character and the print look — "
                 + "never the sampled base or the scan's own solve. Frame and "
                 + "Retouch belong to the individual photograph.")
                .font(Theme.caption)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                PlateButton(title: "Cancel") { app.isShowingCopySettingsSheet = false }
                PlateButton(title: "Copy", emphasis: .prominent) {
                    if let entry = app.editor?.entry {
                        app.copySettings(from: entry, scope: TransferScope(sections: sections))
                    }
                    app.isShowingCopySettingsSheet = false
                }
            }
        }
        .padding(Theme.space5)
        .frame(width: 300)
        .background(Theme.surface)
        .onAppear { sections = app.copiedScope.sections }
    }
}
```

In `Sources/App/PhotoEditorApp.swift`, `RootView` gains the sheet beside the export one:

```swift
        .sheet(isPresented: $app.isShowingCopySettingsSheet) {
            CopySettingsSheet(app: app)
        }
```

In `Sources/App/EditorCommands.swift`, the pasteboard group: ⇧⌘C now opens the dialog, and Previous lands under paste (⌘-modified equivalents — real menu shortcuts, not bare keys):

```swift
            Button("Copy Settings…") { app.isShowingCopySettingsSheet = true }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(editor == nil)

            Button(app.copiedFromName.map { "Paste Settings from \($0)" } ?? "Paste Settings") {
                if let entry = editor?.entry { app.pasteSettings(to: [entry]) }
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])
            .disabled(!app.canPasteSettings || editor == nil)

            Button(app.previousName.map { "Paste from Previous (\($0))" } ?? "Paste from Previous") {
                app.applyPreviousSettings()
            }
            .keyboardShortcut("v", modifiers: [.command, .option])
            .disabled(app.previousStack == nil || editor == nil)
```

(The sidebar's context-menu Copy/Paste keep calling `copySettings(from:)`/`pasteSettings(to:)` — unchanged signatures, now scope-aware through `copiedScope`; targeting rules untouched.)

In `Sources/Views/SliderPanel/SliderPanel.swift`, delete the private `is*Modified` computed properties and pass `PipelineSection.<section>.isModified(in: model.editStack)` to each numbered `PanelSection` — the spine and the sheet now read one predicate. (Reset closures stay as they are.)

- [x] **Step 6: Verify**

Run: `-only-testing:PhotoEditorTests/PipelineSectionTests -only-testing:PhotoEditorTests/PreviousCommandTests -only-testing:PhotoEditorTests/TransferScopeTests -only-testing:PhotoEditorTests/WorkflowTests -only-testing:PhotoEditorTests/PresetAmountTests`
Expected: ALL PASS.

- [x] **Step 7: Commit**

```bash
git add Sources/Models/TransferScope.swift Sources/Views/CopySettingsSheet.swift Sources/Models/DevelopPreset.swift Sources/App/AppModel.swift Sources/App/EditorCommands.swift Sources/App/PhotoEditorApp.swift Sources/Views/SliderPanel/SliderPanel.swift Tests/TransferScopeTests.swift project.yml PhotoEditor.xcodeproj
git commit -m "feat(workflow): scoped copy/paste over the numbered pipeline sections, plus Paste from Previous"
```

---

### Task 10: Solo mode + lights-out

⌥-click on a section header opens that section and folds the rest — written through the exact `@AppStorage` keys the sections already persist (`panel.v3.expanded.<title>`), via a small pure `PanelExpansion` helper so the behaviour is testable over a scratch `UserDefaults`. `L` cycles two achromatic dim stages over all chrome (the canvas untouched, the status bar deliberately kept lit — it is the "what am I looking at" honesty readout); `Esc` restores, extending Task 2's branch in `ToolKeyMonitor`: Esc peels the outermost viewing layer first — lights-out, then compare. Both `L` and `Esc` are bare keys through the monitor; the menu item carries `(L)` in its label only. Veils are instant (motion law) and never hit-testable — the chrome recedes but stays operable.

**Files:**
- Create: `Tests/PanelExpansionTests.swift`
- Modify: `Sources/Views/SliderPanel/PanelSection.swift`, `Sources/Views/SliderPanel/SliderPanel.swift`, `Sources/Views/WorkspaceModel.swift`, `Sources/Views/Theme.swift`, `Sources/Views/ToolKeyMonitor.swift`, `Sources/App/EditorCommands.swift`, `Sources/App/PhotoEditorApp.swift`

**Interfaces:**
- Consumes: the `panel.v3.expanded.<title>` `@AppStorage` keys, Task 2's `Esc` branch, `RootView`'s pane layout.
- Produces: `PanelExpansion.key/solo/isSolo`, `PanelSection.soloTitles`, `SliderPanel.soloTitles`, `WorkspaceModel.LightsOut` + `lightsOut/cycleLightsOut()`, `View.lightsOutVeil(_:)`.

- [x] **Step 1: Write the failing tests**

Create `Tests/PanelExpansionTests.swift`:

```swift
import Foundation
import XCTest
@testable import PhotoEditor

final class PanelExpansionTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "petest-solo-\(UUID().uuidString)"
    private let titles = ["Film", "Light", "Effects"]

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testSoloOpensTheChosenSectionAndFoldsTheRest() {
        PanelExpansion.solo("Light", among: titles, defaults: defaults)
        XCTAssertTrue(defaults.bool(forKey: PanelExpansion.key("Light")))
        XCTAssertFalse(defaults.bool(forKey: PanelExpansion.key("Film")))
        XCTAssertFalse(defaults.bool(forKey: PanelExpansion.key("Effects")))
        XCTAssertTrue(PanelExpansion.isSolo("Light", among: titles, defaults: defaults))
    }

    func testSoloingAnotherSectionMovesTheSolo() {
        PanelExpansion.solo("Light", among: titles, defaults: defaults)
        PanelExpansion.solo("Effects", among: titles, defaults: defaults)
        XCTAssertFalse(PanelExpansion.isSolo("Light", among: titles, defaults: defaults))
        XCTAssertTrue(PanelExpansion.isSolo("Effects", among: titles, defaults: defaults))
    }

    func testTheKeysAreTheSectionsOwnPersistenceKeys() {
        XCTAssertEqual(PanelExpansion.key("Tone Curve"), "panel.v3.expanded.Tone Curve",
                       "solo writes the exact keys PanelSection's @AppStorage reads")
    }

    func testTwoOpenSectionsAreNotASolo() {
        PanelExpansion.solo("Light", among: titles, defaults: defaults)
        defaults.set(true, forKey: PanelExpansion.key("Film"))
        XCTAssertFalse(PanelExpansion.isSolo("Light", among: titles, defaults: defaults))
    }
}

@MainActor
final class LightsOutTests: XCTestCase {
    func testLCyclesOffDimDarkOff() {
        let workspace = WorkspaceModel()
        XCTAssertEqual(workspace.lightsOut, .off)
        workspace.cycleLightsOut()
        XCTAssertEqual(workspace.lightsOut, .dim)
        workspace.cycleLightsOut()
        XCTAssertEqual(workspace.lightsOut, .dark)
        workspace.cycleLightsOut()
        XCTAssertEqual(workspace.lightsOut, .off)
    }

    func testVeilOpacityIsMonotoneAndAchromaticZeroAtOff() {
        XCTAssertEqual(WorkspaceModel.LightsOut.off.veilOpacity, 0)
        XCTAssertLessThan(WorkspaceModel.LightsOut.dim.veilOpacity,
                          WorkspaceModel.LightsOut.dark.veilOpacity)
        XCTAssertLessThan(WorkspaceModel.LightsOut.dark.veilOpacity, 1,
                          "dark dims the chrome; it does not delete it")
    }
}
```

- [x] **Step 2: Run both classes** — expected COMPILE FAILURE.

- [x] **Step 3: Solo**

In `Sources/Views/SliderPanel/PanelSection.swift`, add the helper and the header behaviour:

```swift
/// Solo over the sections' own persistence: writes the same
/// `panel.v3.expanded.<title>` keys every `PanelSection.@AppStorage` reads,
/// so soloing IS expansion state and survives relaunch like any fold.
enum PanelExpansion {
    static func key(_ title: String) -> String { "panel.v3.expanded.\(title)" }

    /// Opens `title`, folds every other listed section. Writes every key, so
    /// the state is fully materialised afterwards.
    static func solo(_ title: String, among titles: [String],
                     defaults: UserDefaults = .standard) {
        for t in titles { defaults.set(t == title, forKey: key(t)) }
    }

    /// True only for a materialised solo: this section open, all others shut.
    static func isSolo(_ title: String, among titles: [String],
                       defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key(title))
            && titles.allSatisfy { $0 == title || !defaults.bool(forKey: key($0)) }
    }
}
```

`PanelSection` gains `var soloTitles: [String]? = nil` (an init parameter, default nil — every existing call site compiles). The header button's action becomes:

```swift
            if let soloTitles, NSEvent.modifierFlags.contains(.option) {
                withAnimation(Theme.expand) {
                    PanelExpansion.solo(title, among: soloTitles)
                }
            } else {
                withAnimation(Theme.expand) { isExpanded.toggle() }
            }
```

(`@AppStorage` observes external `UserDefaults` writes, so the other sections fold live.) The disclosure affordance says so: compute `isSoloed` from `PanelExpansion.isSolo`, draw the chevron in `Theme.accent` while soloed, and extend the header's `.help` to `"Click to fold · ⌥-click to solo"`.

In `Sources/Views/SliderPanel/SliderPanel.swift`:

```swift
    /// Every section the develop column shows, in order — the solo group.
    /// ("Process" is an action prompt, not a browsable stage; it is not in
    /// the group and cannot be folded away by a solo.)
    static let soloTitles = [
        "Film", "Frame", "Optics", "Retouch", "White Balance", "Light",
        "Presence", "Color Mixer", "Color Grade", "Point Color", "Tone Curve",
        "Local Masks", "Detail", "Effects", "Snapshots", "Presets", "Info",
    ]
```

and pass `soloTitles: Self.soloTitles` to each of those seventeen `PanelSection`s.

- [x] **Step 4: Lights-out**

In `Sources/Views/WorkspaceModel.swift`:

```swift
    /// The lights-out ladder: two dim stages over all chrome, canvas
    /// untouched. Window state, never persisted.
    enum LightsOut: Int, CaseIterable {
        case off, dim, dark

        /// Achromatic veil strengths — taste constants, verified in-app.
        /// Dark stops short of 1: the chrome recedes, it does not vanish.
        var veilOpacity: Double {
            switch self {
            case .off: 0
            case .dim: 0.55
            case .dark: 0.88
            }
        }
    }

    var lightsOut: LightsOut = .off

    func cycleLightsOut() {
        lightsOut = LightsOut(rawValue: lightsOut.rawValue + 1) ?? .off
    }
```

In `Sources/Views/Theme.swift`, with the other shared treatments:

```swift
    /// The lights-out veil for a chrome region. Black only (the achromatic
    /// law), instant (the motion law — no animation), and never hit-testable:
    /// the controls underneath keep working, they just recede.
    func lightsOutVeil(_ stage: WorkspaceModel.LightsOut) -> some View {
        overlay {
            if stage != .off {
                Rectangle()
                    .fill(.black.opacity(stage.veilOpacity))
                    .allowsHitTesting(false)
            }
        }
    }
```

In `Sources/App/PhotoEditorApp.swift`, `RootView`: append `.lightsOutVeil(workspace.lightsOut)` to `TopBar`, `LibrarySidebar`, `ToolOptionsBar`, `ToolRail`, and `InspectorPanel`. The canvas gets nothing; `CanvasStatusBar` gets nothing on purpose — it is the readout that says whether the canvas shows Before, and dimming the honesty light defeats it.

In `Sources/Views/ToolKeyMonitor.swift`, before the `EditorTool(shortcutKey:)` lookup:

```swift
        if key == "l" {
            workspace.cycleLightsOut()
            return true
        }
```

and extend Task 2's `Esc` branch — outermost viewing layer first:

```swift
        if event.keyCode == 53 {
            if workspace.lightsOut != .off {
                workspace.lightsOut = .off
                return true
            }
            if editor.compareMode != .off {
                editor.compareMode = .off
                return true
            }
            return false
        }
```

In `Sources/App/EditorCommands.swift`, View menu after the compare buttons (bare key → label hint only):

```swift
            Button("Lights Out  (L)") { workspace.cycleLightsOut() }
                .disabled(editor == nil)
```

- [x] **Step 5: Verify**

Run: `-only-testing:PhotoEditorTests/PanelExpansionTests -only-testing:PhotoEditorTests/LightsOutTests -only-testing:PhotoEditorTests/CompareModeTests -only-testing:PhotoEditorTests/ToolActivationTests`
Expected: ALL PASS (`CompareModeTests` proves the extended Esc branch didn't disturb compare's own exit).

- [x] **Step 6: Commit**

```bash
git add Sources/Views/SliderPanel/PanelSection.swift Sources/Views/SliderPanel/SliderPanel.swift Sources/Views/WorkspaceModel.swift Sources/Views/Theme.swift Sources/Views/ToolKeyMonitor.swift Sources/App/EditorCommands.swift Sources/App/PhotoEditorApp.swift Tests/PanelExpansionTests.swift project.yml PhotoEditor.xcodeproj
git commit -m "feat(panel): option-click solo over the sections' own expansion keys, and L-cycled lights-out"
```

---

### Task 11: Full verification + CHANGELOG + the feel pass

- [ ] **Step 1: Full suite once**

Run: `xcodebuild -project PhotoEditor.xcodeproj -scheme PhotoEditor -destination 'platform=macOS' -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO test`
Expected: everything green (corpus-gated suites skip or pass per machine). Fix anything that isn't before proceeding — no green claim without this output in hand.

- [ ] **Step 2: CHANGELOG**

Add under `Unreleased` in `CHANGELOG.md`: the Develop Grammar — free zoom anchored at the pointer with detent stops and a drawn navigator; Y / ⇧Y before-after (side-by-side, split); the interactive histogram (draggable regions bound to the Light sliders, per-channel clip flags, RGB/luma readout); free-point tone curve (5-point storage frozen bit-for-bit, PV1 untouched) with the Targeted Adjustment Tool (T); colour-grading wheels plus a lenient Global zone; preset hover-preview / amount / folders / JSON import-export and the drawn naming sheet; scoped copy/paste over the numbered pipeline sections with Paste from Previous; solo mode and lights-out. Note the freeze guarantees explicitly: PV1 and `.matrix` untouched, 5-point curves and pre-Global grades render bit-identically.

- [ ] **Step 3: Commit, then hand to the user**

```bash
git add CHANGELOG.md
git commit -m "docs: changelog for the develop grammar"
```

The final gate is human, exactly as the spec says: interaction feel — gesture friction on wheel and pinch zoom, navigator behaviour, split-divider grab, hover-preview latency, TAT sensitivity, wheel puck feel, lights-out levels — is verified in-app by the user. Expect taste-constant tuning from that pass (`ZoomMath.wheelOctavesPerPoint/detentTolerance`, `HistogramRegion.boundaries/sweepFraction`, `TATMath.pointsForFullSweep`, `LightsOut.veilOpacity`, the wheel diameter); each lives as a named constant beside its logic, so tuning cannot change behaviour shape — re-run that constant's owning test class after any change. **Do not claim the grammar "feels like Lightroom" — hand the build over and let the user say it.**

---

## Execution notes

- Tasks are strictly ordered 1→11 and follow the spec's own sequencing: 1–3 the judgment loop (zoom/navigator, before-after, histogram), 4–6 editing depth (curve, TAT, wheels), 7–10 workflow (presets, fader unification, copy/paste, solo/lights-out), 11 verification. Task 5 consumes Task 3's `PixelSampler` and Task 4's `CurvePointModel` — do not reorder around it.
- Nothing user-visible changes how an existing photo renders at any point. The plan's only two renderer-adjacent changes are pinned by tests the moment they land: `FreeCurveRenderTests` holds 5-point curves on the exact `CIToneCurve` path (and PV1's indifference to free lists), and `ColorWheelTests` holds `ColorGrading.global`'s decode-neutral no-op at cube-data byte equality. PV1 (`LegacyToneRenderer`) and the `.matrix` engine are never edited.
- If any measured direction contradicts what this plan declares — a histogram drag that reads backwards, a TAT weight with the wrong sign — trust the measurement, fix the table, and record the sweep in the case comment (house precedent: Print Contrast, Phase C warmth).
- Bare keys (`Y`, `⇧Y`, `T`, `L`, `Esc`) live in `ToolKeyMonitor.handle(_:)` and nowhere else; menu items carry the key in their label. If a later change wants a new bare key, it extends that one function — never `keyboardShortcut`.
- This plan runs **after** the Minilab engine plan ships (`2026-08-05-minilab-engine.md`). Task 9's film-section field list was written against `PrintSettings` as of the minilab tasks landed to date; if the remaining minilab tasks add print-look fields before this plan executes, extend `PipelineSection.film`'s copy list (and its test) in the same commit that starts Task 9.
- After the user's feel pass accepts the grammar, the next sub-projects per the roadmap are Phase 3 (scanning workflow: rolls, frame detection) and Phase 4 (library) — neither starts until the user has accepted this plan's interaction feel in-app.
