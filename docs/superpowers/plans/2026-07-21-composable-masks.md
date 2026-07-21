# Composable Masks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn each local adjustment's single-shape mask into a *built* selection — a list of components combined with add/subtract/intersect, where components can be generated from the image's own content (a luminance band or a sampled color range) rather than only drawn as shapes.

**Architecture:** A new `MaskComponent` value type becomes the unit of selection. `MaskCompositor` folds a component list into one grayscale mask; `RangeMaskBuilder` supplies the two content-derived generators; `LocalAdjustmentRenderer` keeps the corrections and the final blend. `LocalAdjustment`'s per-shape fields move into its first component, with a hand-written decoder migrating every stack written by 1.2.x.

**Tech Stack:** Swift 5, SwiftUI, Core Image (`CIFilter`/`CIImage`), GRDB (edit stacks persist as JSON in SQLite), XcodeGen, XCTest.

## Global Constraints

- **No machine learning.** `handoff.md` forbids AI masking and subject selection. Both generators here are classical (a luminance transfer curve and a color-distance LUT). Do not add quick-select, subject-detect, or sky-detect.
- **Non-destructive.** Never bake edits into pixels before export. Masks are numbers in the `EditStack`, replayed through Core Image.
- **Unit coordinates, origin bottom-left.** Every mask parameter is stored relative to the frame so one stored mask lands identically on the preview proxy and the full-resolution export. Any pixel radius is derived at render time from `extent`.
- **Lenient decoding is mandatory on every nested `Codable`.** Edit stacks are JSON in SQLite. A missing key inside a nested type throws and makes the *parent's* fallback swap in defaults for the whole sub-struct — silently discarding a mask instead of one field. Every new type gets its own `init(from:)` using `KeyedDecodingContainer.lenient`.
- **Preview-only aids never reach export.** The mask overlay must not change exported pixels.
- **Zero stock macOS controls in UI.** Follow the existing `PanelSection` / engraved-label / drawn-fader vocabulary in `Sources/Views/Theme.swift` and `Sources/Views/Controls/InstrumentControls.swift`.
- **Regenerate the project after adding files:** `xcodegen generate`. `project.yml` is the source of truth.
- **Baseline:** 200 tests green at commit `e62d67d`. Every task ends green.

**Build and test command** (used in every task):

```bash
cd ~/Documents/totallynotanopensourcelightroom && xcodebuild test -project PhotoEditor.xcodeproj -scheme PhotoEditor -destination 'platform=macOS' 2>&1 | grep -E "error:|Executed [0-9]+ tests|TEST SUCCEEDED|TEST FAILED" | tail -5
```

Run a single suite by appending `-only-testing:PhotoEditorTests/<SuiteName>`.

## File Structure

**Create:**
- `Sources/Models/MaskComponent.swift` — `MaskColor`, `MaskRefinement`, `MaskComponent`. Pure value types, no Core Image.
- `Sources/Pipeline/MaskCompositor.swift` — spatial generators, refinement, set algebra. Owns "component list → one grayscale mask".
- `Sources/Pipeline/RangeMaskBuilder.swift` — the luminance and color-range generators plus their LUT construction.
- `Sources/Pipeline/RangeMaskCubeCache.swift` — memoizes color-range colour cubes on their parameters.
- `Sources/Views/SliderPanel/MaskComponentPanel.swift` — the component list and per-component controls.
- `Tests/MaskComponentTests.swift`, `Tests/MaskCompositorTests.swift`, `Tests/MaskMigrationTests.swift`, `Tests/RangeMaskTests.swift`.

**Modify:**
- `Sources/Models/LocalAdjustment.swift` — gains `components`, loses the flat shape fields, gains an explicit `CodingKeys` + `encode(to:)`.
- `Sources/Pipeline/LocalAdjustmentRenderer.swift` — delegates mask building to `MaskCompositor`, keeps corrections and blend.
- `Sources/Pipeline/EditRenderer.swift` — passes the pre-local-adjustment image as the mask source.
- `Sources/Views/EditorModel.swift` — component selection, brush routing, overlay flag.
- `Sources/Views/CanvasArea.swift` — handles bind to the selected component.
- `Sources/Views/SliderPanel/LocalAdjustmentPanel.swift`, `Sources/Views/ToolRail.swift`, `Sources/Views/WorkspaceModel.swift` — component-aware.
- `Tests/TestSupport.swift`, `Tests/LocalAdjustmentTests.swift`, `Tests/ToolActivationTests.swift`.

Ordering rationale: tasks 1–3 build the new machinery in isolation with nothing wired in (build stays green trivially). Task 4 is the single atomic flip of the data model. Tasks 5–7 add the content-derived generators. Tasks 8–11 add overlay, UI, and docs.

---

### Task 1: `MaskComponent` model

**Files:**
- Create: `Sources/Models/MaskComponent.swift`
- Test: `Tests/MaskComponentTests.swift`

**Interfaces:**
- Consumes: `KeyedDecodingContainer.lenient` from `Sources/Models/LenientDecoding.swift`; `BrushStroke` from `Sources/Models/LocalAdjustment.swift`.
- Produces: `MaskColor(red:green:blue:)`; `MaskRefinement(blur:shift:)` with `isNeutral: Bool`; `MaskComponent(shape:)` with nested `MaskComponent.Shape` (`.linear .radial .brush .luminance .colorRange`) and `MaskComponent.Combine` (`.add .subtract .intersect`), plus `displayName: String` and `isContributing: Bool`.

- [ ] **Step 1: Write the failing test**

Create `Tests/MaskComponentTests.swift`:

```swift
import CoreGraphics
import XCTest
@testable import PhotoEditor

/// Verifies the mask component value type: its defaults, and that it decodes
/// leniently. Stacks are JSON in SQLite, so a component written by an older
/// build must never throw on the way back in.
final class MaskComponentTests: XCTestCase {
    func testDefaultsAreNeutral() {
        let component = MaskComponent(shape: .linear)
        XCTAssertEqual(component.combine, .add)
        XCTAssertTrue(component.isEnabled)
        XCTAssertFalse(component.isInverted)
        XCTAssertTrue(component.refine.isNeutral)
        XCTAssertNil(component.sampledColor)
    }

    func testRoundTripsThroughCodable() throws {
        var component = MaskComponent(shape: .colorRange)
        component.combine = .intersect
        component.isInverted = true
        component.refine = MaskRefinement(blur: 0.3, shift: -0.2)
        component.sampledColor = MaskColor(red: 0.2, green: 0.6, blue: 0.3)
        component.colorTolerance = 0.4
        component.luminanceMin = 0.25
        component.brushStrokes = [BrushStroke(points: [CGPoint(x: 0.1, y: 0.2)])]

        let data = try JSONEncoder().encode(component)
        let decoded = try JSONDecoder().decode(MaskComponent.self, from: data)
        XCTAssertEqual(decoded, component)
    }

    /// An almost-empty object must come back with every field at its default
    /// rather than throwing.
    func testDecodesLenientlyFromASparseObject() throws {
        let json = Data(#"{"shape":"radial"}"#.utf8)
        let decoded = try JSONDecoder().decode(MaskComponent.self, from: json)

        XCTAssertEqual(decoded.shape, .radial)
        XCTAssertEqual(decoded.combine, .add)
        XCTAssertEqual(decoded.radiusX, 0.3, accuracy: 1e-9)
        XCTAssertEqual(decoded.luminanceMax, 1.0, accuracy: 1e-9)
        XCTAssertTrue(decoded.refine.isNeutral)
    }

    func testRefinementDecodesLenientlyInsideAComponent() throws {
        let json = Data(#"{"shape":"brush","refine":{"blur":0.5}}"#.utf8)
        let decoded = try JSONDecoder().decode(MaskComponent.self, from: json)

        XCTAssertEqual(decoded.refine.blur, 0.5, accuracy: 1e-9)
        XCTAssertEqual(decoded.refine.shift, 0.0, accuracy: 1e-9,
                       "A missing key inside a nested Codable must not discard the sibling.")
    }

    func testUnsampledColorRangeDoesNotContribute() {
        var component = MaskComponent(shape: .colorRange)
        XCTAssertFalse(component.isContributing,
                       "An unsampled colour range must be skipped, not treated as empty.")
        component.sampledColor = MaskColor(red: 0.5, green: 0.5, blue: 0.5)
        XCTAssertTrue(component.isContributing)
    }

    func testDisabledComponentDoesNotContribute() {
        var component = MaskComponent(shape: .linear)
        component.isEnabled = false
        XCTAssertFalse(component.isContributing)
    }

    func testEmptyBrushDoesNotContribute() {
        let component = MaskComponent(shape: .brush)
        XCTAssertFalse(component.isContributing,
                       "A brush with no strokes selects nothing and must be skipped.")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd ~/Documents/totallynotanopensourcelightroom && xcodegen generate && xcodebuild test -project PhotoEditor.xcodeproj -scheme PhotoEditor -destination 'platform=macOS' -only-testing:PhotoEditorTests/MaskComponentTests 2>&1 | grep -E "error:|TEST" | head -5
```

Expected: FAIL — `cannot find 'MaskComponent' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/Models/MaskComponent.swift`:

```swift
import CoreGraphics
import Foundation

/// An RGB sample in `0...1`, stored alongside the mask that references it.
///
/// Deliberately not ``FilmColor``: that type carries the film subsystem's
/// negative math, and reusing it here would drag film concerns into local
/// adjustments for the sake of three doubles.
struct MaskColor: Codable, Equatable {
    var red = 0.5
    var green = 0.5
    var blue = 0.5

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        red = c.lenient(.red, 0.5)
        green = c.lenient(.green, 0.5)
        blue = c.lenient(.blue, 0.5)
    }
}

/// Softening and grow/shrink applied to one component before it is combined.
///
/// Per component rather than per mask because edge character differs by kind:
/// a brush is already soft, a luminance band is not. Both values are stored
/// unit-relative and scaled by the frame's short side at render time, so
/// refinement survives the trip from preview proxy to full-resolution export.
struct MaskRefinement: Codable, Equatable {
    /// Gaussian softening. `0...1` maps to 0…10% of the frame's short side.
    var blur = 0.0

    /// Grow (positive) or shrink (negative). `-1...1` maps to ∓5% of the
    /// frame's short side.
    var shift = 0.0

    init(blur: Double = 0, shift: Double = 0) {
        self.blur = blur
        self.shift = shift
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        blur = c.lenient(.blur, 0)
        shift = c.lenient(.shift, 0)
    }

    var isNeutral: Bool { blur == 0 && shift == 0 }
}

/// One piece of a built selection.
///
/// A mask is no longer a single shape. It is a list of these, folded together
/// with set algebra, which is what lets a tonal range be intersected with a
/// gradient and have a painted area subtracted from the result.
struct MaskComponent: Codable, Equatable, Identifiable {
    enum Shape: String, Codable, CaseIterable {
        /// A gradient band: full effect at ``startPoint``, gone by ``endPoint``.
        case linear
        /// An ellipse centred on ``center``, feathered at its edge.
        case radial
        /// Hand-painted, resolution-independent strokes.
        case brush
        /// Everything within a luminance band of the photograph itself.
        case luminance
        /// Everything within a colour distance of a sampled colour.
        case colorRange
    }

    /// How this component folds into the components before it.
    enum Combine: String, Codable, CaseIterable {
        case add
        case subtract
        case intersect
    }

    var id = UUID()
    var shape: Shape = .linear
    var combine: Combine = .add
    var isEnabled = true

    /// Inverts *this component* only. The whole composed mask has its own
    /// invert on ``LocalAdjustment`` — the same distinction Photoshop draws
    /// between inverting a channel and inverting a selection.
    var isInverted = false

    var refine = MaskRefinement()

    // MARK: Linear (unit coordinates, origin bottom-left)

    var startPoint = CGPoint(x: 0.5, y: 0.85)
    var endPoint = CGPoint(x: 0.5, y: 0.45)

    // MARK: Radial

    var center = CGPoint(x: 0.5, y: 0.5)
    var radiusX = 0.3
    var radiusY = 0.25
    /// Edge softness, `0...1`. 0 is a hard ellipse edge.
    var feather = 0.5

    // MARK: Brush

    var brushStrokes: [BrushStroke] = []
    var brushSize = 0.04
    var brushFeather = 0.65
    var brushFlow = 0.8

    // MARK: Luminance range

    /// Band bounds on the mask source's luminance, `0...1`.
    var luminanceMin = 0.0
    var luminanceMax = 1.0
    /// Smoothstep shoulder width at each edge of the band.
    var luminanceFalloff = 0.15

    // MARK: Colour range

    /// Nil until the photographer samples a colour. A component with no
    /// sample selects nothing and is skipped entirely.
    var sampledColor: MaskColor?
    var colorTolerance = 0.25
    var colorFalloff = 0.15

    var displayName: String {
        switch shape {
        case .linear: "Linear"
        case .radial: "Radial"
        case .brush: "Brush"
        case .luminance: "Luminance"
        case .colorRange: "Colour Range"
        }
    }

    /// False when this component cannot select anything, so the compositor
    /// skips it rather than folding in an empty selection. That matters most
    /// for `intersect`, where an empty piece would blank the whole mask before
    /// the photographer has finished setting it up.
    var isContributing: Bool {
        guard isEnabled else { return false }
        switch shape {
        case .brush: return !brushStrokes.isEmpty
        case .colorRange: return sampledColor != nil
        case .linear, .radial, .luminance: return true
        }
    }

    init(shape: Shape = .linear) {
        self.shape = shape
    }

    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(.id, UUID())
        shape = c.lenient(.shape, .linear)
        combine = c.lenient(.combine, .add)
        isEnabled = c.lenient(.isEnabled, true)
        isInverted = c.lenient(.isInverted, false)
        refine = c.lenient(.refine, MaskRefinement())
        startPoint = c.lenient(.startPoint, CGPoint(x: 0.5, y: 0.85))
        endPoint = c.lenient(.endPoint, CGPoint(x: 0.5, y: 0.45))
        center = c.lenient(.center, CGPoint(x: 0.5, y: 0.5))
        radiusX = c.lenient(.radiusX, 0.3)
        radiusY = c.lenient(.radiusY, 0.25)
        feather = c.lenient(.feather, 0.5)
        brushStrokes = c.lenient(.brushStrokes, [])
        brushSize = c.lenient(.brushSize, 0.04)
        brushFeather = c.lenient(.brushFeather, 0.65)
        brushFlow = c.lenient(.brushFlow, 0.8)
        luminanceMin = c.lenient(.luminanceMin, 0.0)
        luminanceMax = c.lenient(.luminanceMax, 1.0)
        luminanceFalloff = c.lenient(.luminanceFalloff, 0.15)
        sampledColor = c.lenient(.sampledColor, nil as MaskColor?)
        colorTolerance = c.lenient(.colorTolerance, 0.25)
        colorFalloff = c.lenient(.colorFalloff, 0.15)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd ~/Documents/totallynotanopensourcelightroom && xcodegen generate && xcodebuild test -project PhotoEditor.xcodeproj -scheme PhotoEditor -destination 'platform=macOS' 2>&1 | grep -E "error:|Executed [0-9]+ tests|TEST" | tail -4
```

Expected: PASS. 7 new tests in `MaskComponentTests`, full suite green.

- [ ] **Step 5: Commit**

```bash
git add Sources/Models/MaskComponent.swift Tests/MaskComponentTests.swift PhotoEditor.xcodeproj
git commit -m "Add MaskComponent, the unit of a built selection"
```

---

### Task 2: `MaskCompositor` — spatial generators and set algebra

**Files:**
- Create: `Sources/Pipeline/MaskCompositor.swift`
- Test: `Tests/MaskCompositorTests.swift`

**Interfaces:**
- Consumes: `MaskComponent`, `MaskComponent.Combine` from Task 1.
- Produces: `MaskCompositor.composedMask(_ components: [MaskComponent], source: CIImage, extent: CGRect) -> CIImage?` returning a **grayscale** image (not alpha). Returns nil when no component contributes.

`source` is accepted but unused by the three spatial shapes; tasks 6 and 7 use it. Declaring the final signature now avoids churning every call site later.

- [ ] **Step 1: Write the failing test**

Create `Tests/MaskCompositorTests.swift`:

```swift
import CoreImage
import XCTest
@testable import PhotoEditor

/// Verifies that a component list folds into one selection correctly: the set
/// algebra, the skip rules, and per-component inversion.
final class MaskCompositorTests: XCTestCase {
    private let extent = CGRect(x: 0, y: 0, width: 200, height: 200)

    private func source() -> CIImage {
        TestSupport.solidImage(red: 0.5, green: 0.5, blue: 0.5, size: 200)
    }

    /// Mask coverage at a point, 0 (unselected) … 1 (fully selected).
    private func coverage(_ mask: CIImage?, at point: CGPoint) -> Double {
        guard let mask else { return 0 }
        let probe = CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)
        return TestSupport.readColor(mask.cropped(to: probe)).red
    }

    /// A radial covering the left half's centre.
    private func leftRadial() -> MaskComponent {
        var c = MaskComponent(shape: .radial)
        c.center = CGPoint(x: 0.25, y: 0.5)
        c.radiusX = 0.2
        c.radiusY = 0.2
        c.feather = 0.1
        return c
    }

    /// A radial covering the right half's centre.
    private func rightRadial() -> MaskComponent {
        var c = MaskComponent(shape: .radial)
        c.center = CGPoint(x: 0.75, y: 0.5)
        c.radiusX = 0.2
        c.radiusY = 0.2
        c.feather = 0.1
        return c
    }

    private let leftPoint = CGPoint(x: 50, y: 100)
    private let rightPoint = CGPoint(x: 150, y: 100)

    func testNoComponentsSelectNothing() {
        XCTAssertNil(MaskCompositor.composedMask([], source: source(), extent: extent))
    }

    func testAddUnionsTwoComponents() {
        var second = rightRadial()
        second.combine = .add
        let mask = MaskCompositor.composedMask([leftRadial(), second],
                                               source: source(), extent: extent)

        XCTAssertGreaterThan(coverage(mask, at: leftPoint), 0.9)
        XCTAssertGreaterThan(coverage(mask, at: rightPoint), 0.9)
    }

    func testIntersectKeepsOnlyTheOverlap() {
        var second = rightRadial()
        second.combine = .intersect
        let mask = MaskCompositor.composedMask([leftRadial(), second],
                                               source: source(), extent: extent)

        XCTAssertLessThan(coverage(mask, at: leftPoint), 0.1,
                          "The left disc is outside the right one, so nothing survives.")
        XCTAssertLessThan(coverage(mask, at: rightPoint), 0.1)
    }

    func testIntersectWithAnOverlappingComponentSurvives() {
        var second = leftRadial()
        second.combine = .intersect
        second.radiusX = 0.3
        second.radiusY = 0.3
        let mask = MaskCompositor.composedMask([leftRadial(), second],
                                               source: source(), extent: extent)

        XCTAssertGreaterThan(coverage(mask, at: leftPoint), 0.9)
    }

    func testSubtractRemovesTheSecondFromTheFirst() {
        var wide = MaskComponent(shape: .radial)
        wide.center = CGPoint(x: 0.5, y: 0.5)
        wide.radiusX = 0.45
        wide.radiusY = 0.45
        wide.feather = 0.05

        var bite = leftRadial()
        bite.combine = .subtract

        let mask = MaskCompositor.composedMask([wide, bite],
                                               source: source(), extent: extent)

        XCTAssertLessThan(coverage(mask, at: leftPoint), 0.1,
                          "The subtracted disc must be cut out.")
        XCTAssertGreaterThan(coverage(mask, at: rightPoint), 0.9,
                             "The rest of the wide disc must survive.")
    }

    func testFirstComponentSeedsTheSelectionRegardlessOfItsMode() {
        var only = leftRadial()
        only.combine = .intersect
        let mask = MaskCompositor.composedMask([only], source: source(), extent: extent)

        XCTAssertGreaterThan(coverage(mask, at: leftPoint), 0.9,
                             "Intersecting against an empty selection would select nothing forever.")
    }

    func testComponentInversionFlipsOnlyThatComponent() {
        var inverted = leftRadial()
        inverted.isInverted = true
        let mask = MaskCompositor.composedMask([inverted], source: source(), extent: extent)

        XCTAssertLessThan(coverage(mask, at: leftPoint), 0.1)
        XCTAssertGreaterThan(coverage(mask, at: rightPoint), 0.9)
    }

    func testDisabledAndEmptyComponentsAreSkipped() {
        var disabled = rightRadial()
        disabled.isEnabled = false
        disabled.combine = .intersect

        var emptyBrush = MaskComponent(shape: .brush)
        emptyBrush.combine = .intersect

        let mask = MaskCompositor.composedMask([leftRadial(), disabled, emptyBrush],
                                               source: source(), extent: extent)

        XCTAssertGreaterThan(coverage(mask, at: leftPoint), 0.9,
                             "A skipped intersect must not blank the selection.")
    }

    func testLinearComponentStillGradesAcrossTheFrame() {
        var linear = MaskComponent(shape: .linear)
        linear.startPoint = CGPoint(x: 0.5, y: 0.95)
        linear.endPoint = CGPoint(x: 0.5, y: 0.5)
        let mask = MaskCompositor.composedMask([linear], source: source(), extent: extent)

        XCTAssertGreaterThan(coverage(mask, at: CGPoint(x: 100, y: 190)), 0.8)
        XCTAssertLessThan(coverage(mask, at: CGPoint(x: 100, y: 20)), 0.2)
    }

    func testBrushComponentSelectsWhereItIsPainted() {
        var brush = MaskComponent(shape: .brush)
        brush.brushStrokes = [BrushStroke(points: [CGPoint(x: 0.25, y: 0.5)],
                                          radius: 0.15, feather: 0.3, flow: 1)]
        let mask = MaskCompositor.composedMask([brush], source: source(), extent: extent)

        XCTAssertGreaterThan(coverage(mask, at: leftPoint), 0.8)
        XCTAssertLessThan(coverage(mask, at: rightPoint), 0.1)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd ~/Documents/totallynotanopensourcelightroom && xcodegen generate && xcodebuild test -project PhotoEditor.xcodeproj -scheme PhotoEditor -destination 'platform=macOS' -only-testing:PhotoEditorTests/MaskCompositorTests 2>&1 | grep -E "error:|TEST" | head -5
```

Expected: FAIL — `cannot find 'MaskCompositor' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/Pipeline/MaskCompositor.swift`. The three spatial generators are moved here from `LocalAdjustmentRenderer` and retyped to `MaskComponent`; that file keeps only corrections and the blend (Task 4 deletes its copies).

```swift
import CoreImage
import CoreImage.CIFilterBuiltins

/// Folds a list of ``MaskComponent`` into one grayscale selection.
///
/// White is fully selected, black is untouched. Everything here stays lazy
/// `CIImage` graph-building — nothing rasterises, so the same graph serves a
/// small preview proxy and a full-resolution export.
///
/// Callers convert the result to alpha before `CIBlendWithMask`, which reads
/// alpha rather than luminance.
enum MaskCompositor {
    /// The composed selection, or nil when no component contributes.
    ///
    /// `source` is the image the generated components measure. Spatial
    /// components ignore it.
    static func composedMask(
        _ components: [MaskComponent], source: CIImage, extent: CGRect
    ) -> CIImage? {
        guard !extent.isInfinite, extent.width >= 1, extent.height >= 1 else { return nil }

        var result: CIImage?
        for component in components where component.isContributing {
            guard let piece = componentMask(component, source: source, extent: extent) else {
                continue
            }
            guard let current = result else {
                // The first contributing component seeds the selection whatever
                // its mode says. Intersecting or subtracting against nothing
                // would select nothing forever, which reads as a broken mask.
                result = piece
                continue
            }
            result = combine(current, piece, using: component.combine, extent: extent)
        }
        return result
    }

    // MARK: Set algebra

    private static func combine(
        _ base: CIImage, _ piece: CIImage,
        using mode: MaskComponent.Combine, extent: CGRect
    ) -> CIImage {
        switch mode {
        case .add:
            return composite(CIFilter.maximumCompositing(),
                             piece, over: base, extent: extent) ?? base
        case .intersect:
            return composite(CIFilter.multiplyCompositing(),
                             piece, over: base, extent: extent) ?? base
        case .subtract:
            // Multiply by the inverse rather than CISubtractBlendMode, so
            // partial coverage thins out smoothly instead of clipping to zero.
            return composite(CIFilter.multiplyCompositing(),
                             inverted(piece, extent: extent),
                             over: base, extent: extent) ?? base
        }
    }

    private static func composite(
        _ filter: CICompositeOperation,
        _ input: CIImage, over background: CIImage, extent: CGRect
    ) -> CIImage? {
        filter.inputImage = input
        filter.backgroundImage = background
        return filter.outputImage?.cropped(to: extent)
    }

    private static func inverted(_ image: CIImage, extent: CGRect) -> CIImage {
        let invert = CIFilter.colorInvert()
        invert.inputImage = image
        return invert.outputImage?.cropped(to: extent) ?? image
    }

    // MARK: One component

    private static func componentMask(
        _ component: MaskComponent, source: CIImage, extent: CGRect
    ) -> CIImage? {
        let raw: CIImage?
        switch component.shape {
        case .linear:
            raw = linearGradient(component, extent: extent)
        case .radial:
            raw = radialGradient(component, extent: extent)
        case .brush:
            raw = brushMask(component, extent: extent)
        case .luminance, .colorRange:
            // Supplied by RangeMaskBuilder in a later task.
            raw = nil
        }
        guard var mask = raw?.cropped(to: extent) else { return nil }

        mask = refined(mask, component.refine, extent: extent)
        if component.isInverted { mask = inverted(mask, extent: extent) }
        return mask
    }

    // MARK: Refinement

    /// Blur first, then grow/shrink, so the morphology works on a softened
    /// edge and produces a smooth spread rather than a stair-stepped one.
    private static func refined(
        _ mask: CIImage, _ refine: MaskRefinement, extent: CGRect
    ) -> CIImage {
        guard !refine.isNeutral else { return mask }
        let short = min(extent.width, extent.height)
        var result = mask

        if refine.blur > 0 {
            let blur = CIFilter.gaussianBlur()
            // Clamp first: blurring a cropped image pulls transparent black in
            // from beyond the edge and eats away at the selection's border.
            blur.inputImage = result.clampedToExtent()
            blur.radius = Float(max(refine.blur * 0.10 * short, 1))
            result = blur.outputImage?.cropped(to: extent) ?? result
        }

        if refine.shift != 0 {
            let radius = Float(max(abs(refine.shift) * 0.05 * short, 1))
            if refine.shift > 0 {
                let grow = CIFilter.morphologyMaximum()
                grow.inputImage = result.clampedToExtent()
                grow.radius = radius
                result = grow.outputImage?.cropped(to: extent) ?? result
            } else {
                let shrink = CIFilter.morphologyMinimum()
                shrink.inputImage = result.clampedToExtent()
                shrink.radius = radius
                result = shrink.outputImage?.cropped(to: extent) ?? result
            }
        }
        return result
    }

    // MARK: Spatial generators

    private static func linearGradient(
        _ component: MaskComponent, extent: CGRect
    ) -> CIImage? {
        let filter = CIFilter.smoothLinearGradient()
        filter.point0 = pixelPoint(component.startPoint, in: extent)
        filter.point1 = pixelPoint(component.endPoint, in: extent)
        filter.color0 = .white
        filter.color1 = .black
        return filter.outputImage
    }

    /// A circular gradient scaled anisotropically into the requested ellipse.
    private static func radialGradient(
        _ component: MaskComponent, extent: CGRect
    ) -> CIImage? {
        let radiusX = max(component.radiusX * extent.width, 1)
        let radiusY = max(component.radiusY * extent.height, 1)
        let reference = max(radiusX, radiusY)

        let feather = min(max(component.feather, 0), 1)
        // Keep at least half a pixel between the radii — CIRadialGradient with
        // radius0 == radius1 degenerates into a soft cone, not a hard edge.
        let inner = max(min(reference * (1 - feather), reference - 0.5), 0)

        let filter = CIFilter.radialGradient()
        filter.center = .zero
        filter.radius0 = Float(inner)
        filter.radius1 = Float(reference)
        filter.color0 = .white
        filter.color1 = .black
        guard let circle = filter.outputImage else { return nil }

        let center = pixelPoint(component.center, in: extent)
        let transform = CGAffineTransform(translationX: center.x, y: center.y)
            .scaledBy(x: radiusX / reference, y: radiusY / reference)
        return circle.transformed(by: transform)
    }

    /// The maximum of soft radial dabs along each stroke. Points are
    /// interpolated so a fast pointer drag cannot leave holes.
    private static func brushMask(
        _ component: MaskComponent, extent: CGRect
    ) -> CIImage? {
        var result = CIImage(color: .black).cropped(to: extent)
        for stroke in component.brushStrokes where !stroke.points.isEmpty {
            let radius = max(stroke.radius * min(extent.width, extent.height), 1)
            let feather = min(max(stroke.feather, 0), 1)
            let inner = max(min(radius * (1 - feather), radius - 0.5), 0)
            let flow = CGFloat(min(max(stroke.flow, 0.02), 1))

            for point in interpolatedPoints(stroke.points,
                                            unitStep: max(stroke.radius * 0.45, 0.002)) {
                let dab = CIFilter.radialGradient()
                dab.center = pixelPoint(point, in: extent)
                dab.radius0 = Float(inner)
                dab.radius1 = Float(radius)
                dab.color0 = CIColor(red: flow, green: flow, blue: flow, alpha: 1)
                dab.color1 = .black
                guard let image = dab.outputImage?.cropped(to: extent) else { continue }
                result = composite(CIFilter.maximumCompositing(),
                                   image, over: result, extent: extent) ?? result
            }
        }
        return result
    }

    private static func interpolatedPoints(
        _ points: [CGPoint], unitStep: Double
    ) -> [CGPoint] {
        guard var previous = points.first else { return [] }
        var output = [previous]
        for point in points.dropFirst() {
            let distance = hypot(point.x - previous.x, point.y - previous.y)
            let segments = max(Int(ceil(distance / unitStep)), 1)
            for index in 1...segments {
                let t = CGFloat(index) / CGFloat(segments)
                output.append(CGPoint(
                    x: previous.x + (point.x - previous.x) * t,
                    y: previous.y + (point.y - previous.y) * t
                ))
            }
            previous = point
        }
        return output
    }

    static func pixelPoint(_ unit: CGPoint, in extent: CGRect) -> CGPoint {
        CGPoint(
            x: extent.origin.x + unit.x * extent.width,
            y: extent.origin.y + unit.y * extent.height
        )
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd ~/Documents/totallynotanopensourcelightroom && xcodegen generate && xcodebuild test -project PhotoEditor.xcodeproj -scheme PhotoEditor -destination 'platform=macOS' 2>&1 | grep -E "error:|Executed [0-9]+ tests|TEST" | tail -4
```

Expected: PASS. 10 new tests in `MaskCompositorTests`, full suite green.

- [ ] **Step 5: Commit**

```bash
git add Sources/Pipeline/MaskCompositor.swift Tests/MaskCompositorTests.swift PhotoEditor.xcodeproj
git commit -m "Add MaskCompositor: fold mask components with add/subtract/intersect"
```

---

### Task 3: Refinement behaviour tests

Task 2 shipped the refinement code. This task proves it, separately, because blur-then-morphology ordering and the clamp-before-blur rule are both easy to regress silently.

**Files:**
- Modify: `Tests/MaskCompositorTests.swift`

**Interfaces:**
- Consumes: `MaskCompositor.composedMask`, `MaskRefinement` from Tasks 1–2.
- Produces: nothing new.

- [ ] **Step 1: Write the failing test**

Append inside `MaskCompositorTests`:

```swift
    // MARK: Refinement

    /// A hard-edged disc for measuring what refinement does to a boundary.
    private func hardDisc() -> MaskComponent {
        var c = MaskComponent(shape: .radial)
        c.center = CGPoint(x: 0.5, y: 0.5)
        c.radiusX = 0.25
        c.radiusY = 0.25
        c.feather = 0.0
        return c
    }

    func testBlurSoftensTheEdge() {
        // 0.6 → a 12px blur radius on a 200px frame, comfortably wider than
        // the 6px probe sits beyond the hard edge.
        var soft = hardDisc()
        soft.refine = MaskRefinement(blur: 0.6)

        // Just outside the hard boundary, where only a softened edge reaches.
        let outside = CGPoint(x: 100, y: 156)

        let hardCoverage = coverage(
            MaskCompositor.composedMask([hardDisc()], source: source(), extent: extent),
            at: outside)
        let softCoverage = coverage(
            MaskCompositor.composedMask([soft], source: source(), extent: extent),
            at: outside)

        XCTAssertLessThan(hardCoverage, 0.1, "A hard edge selects nothing out here.")
        XCTAssertGreaterThan(softCoverage, hardCoverage + 0.10,
                             "Blur must carry partial selection past the hard boundary.")
        XCTAssertLessThan(softCoverage, 0.95, "…but it must fade, not select fully.")
    }

    /// Blurring a cropped image without clamping pulls transparent black in
    /// from beyond the frame and eats the selection at the border.
    func testBlurDoesNotEatTheSelectionAtTheFrameEdge() {
        var wide = MaskComponent(shape: .radial)
        wide.center = CGPoint(x: 0.5, y: 0.5)
        wide.radiusX = 0.9
        wide.radiusY = 0.9
        wide.feather = 0.0
        wide.refine = MaskRefinement(blur: 0.5)

        let mask = MaskCompositor.composedMask([wide], source: source(), extent: extent)
        // Measured: 0.9995 with the clamp, 0.7212 without it. A threshold of
        // 0.5 passes in BOTH cases — it would not catch the regression this
        // test exists for.
        XCTAssertGreaterThan(coverage(mask, at: CGPoint(x: 6, y: 100)), 0.9,
                             "The frame edge must stay selected.")
    }

    func testPositiveShiftGrowsAndNegativeShrinks() {
        // The disc's edge is 50px from centre on a 200px frame, and shift 0.8
        // moves it 8px. Probe just past the original edge — far enough out that
        // the unshifted disc reads zero, close enough that the growth reaches.
        // Each direction needs its own probe: growth is only observable
        // outside the original edge and shrink only inside it, so probing one
        // side alone leaves the other assertion vacuous — it would pass with
        // that branch of the morphology deleted outright.
        let justOutside = CGPoint(x: 100, y: 154)
        let justInside = CGPoint(x: 100, y: 146)

        var grown = hardDisc()
        grown.refine = MaskRefinement(shift: 0.8)
        var shrunk = hardDisc()
        shrunk.refine = MaskRefinement(shift: -0.8)

        func mask(_ component: MaskComponent) -> CIImage? {
            MaskCompositor.composedMask([component], source: source(), extent: extent)
        }

        XCTAssertLessThan(coverage(mask(hardDisc()), at: justOutside), 0.05,
                          "Nothing is selected past the hard edge to begin with.")
        XCTAssertGreaterThan(coverage(mask(grown), at: justOutside), 0.8,
                             "Expand must carry the selection past the original edge.")

        XCTAssertGreaterThan(coverage(mask(hardDisc()), at: justInside), 0.9,
                             "Inside the edge is fully selected to begin with.")
        XCTAssertLessThan(coverage(mask(shrunk), at: justInside), 0.1,
                          "Contract must pull the selection back off this point.")
    }

    func testNeutralRefinementChangesNothing() {
        let point = CGPoint(x: 100, y: 100)
        var explicit = hardDisc()
        explicit.refine = MaskRefinement(blur: 0, shift: 0)

        let plain = coverage(
            MaskCompositor.composedMask([hardDisc()], source: source(), extent: extent),
            at: point)
        let same = coverage(
            MaskCompositor.composedMask([explicit], source: source(), extent: extent),
            at: point)

        XCTAssertEqual(plain, same, accuracy: 1e-6)
    }
```

- [ ] **Step 2: Run tests**

```bash
cd ~/Documents/totallynotanopensourcelightroom && xcodebuild test -project PhotoEditor.xcodeproj -scheme PhotoEditor -destination 'platform=macOS' -only-testing:PhotoEditorTests/MaskCompositorTests 2>&1 | grep -E "error:|Executed [0-9]+ tests|TEST" | tail -3
```

Expected: PASS. If `testBlurDoesNotEatTheSelectionAtTheFrameEdge` fails, the `.clampedToExtent()` calls in `refined(_:_:extent:)` are missing — add them rather than loosening the assertion.

- [ ] **Step 3: Commit**

```bash
git add Tests/MaskCompositorTests.swift
git commit -m "Test mask refinement: blur softens, shift grows and shrinks"
```

---

### Task 4: Flip `LocalAdjustment` to components, with migration

The atomic change. `LocalAdjustment` loses its flat shape fields and gains `components`; every call site moves in the same commit so the build never breaks in between.

**Files:**
- Modify: `Sources/Models/LocalAdjustment.swift`
- Modify: `Sources/Pipeline/LocalAdjustmentRenderer.swift`
- Modify: `Sources/Views/EditorModel.swift:223-258`
- Modify: `Sources/Views/CanvasArea.swift:505-645`
- Modify: `Sources/Views/SliderPanel/LocalAdjustmentPanel.swift:14-145`
- Modify: `Sources/Views/ToolRail.swift:129-153`
- Modify: `Sources/Views/WorkspaceModel.swift:56-68`
- Modify: `Tests/TestSupport.swift`, `Tests/LocalAdjustmentTests.swift`, `Tests/ToolActivationTests.swift`
- Create: `Tests/MaskMigrationTests.swift`

**Interfaces:**
- Consumes: `MaskComponent`, `MaskCompositor.composedMask` from Tasks 1–2.
- Produces:
  - `LocalAdjustment.components: [MaskComponent]`; `LocalAdjustment.init(shape: MaskComponent.Shape)`; `displayName: String`.
  - `LocalAdjustmentRenderer.grayscaleMask(for:source:extent:) -> CIImage?` (grayscale, whole-mask invert applied) and `LocalAdjustmentRenderer.mask(for:source:extent:) -> CIImage?` (the same, converted to alpha).
  - `EditorModel.selectedComponentID: UUID?`, `EditorModel.selectedComponentIndex: Int?`, `EditorModel.addMaskComponent(_ shape: MaskComponent.Shape)`, `EditorModel.removeMaskComponent(id: UUID)`.
  - `LocalAdjustment.only` test accessor in `TestSupport.swift`.

- [ ] **Step 1: Write the failing migration test**

Create `Tests/MaskMigrationTests.swift`. The blob is a real 1.2.x local adjustment — flat fields, no `components` key.

```swift
import CoreGraphics
import XCTest
@testable import PhotoEditor

/// Edit stacks are JSON in SQLite. Every mask written by 1.2.x has its shape
/// stored flat on the adjustment, with no `components` key at all. Those rows
/// must come back as one-component masks with their geometry intact — a
/// regression here silently destroys real edits on upgrade.
final class MaskMigrationTests: XCTestCase {
    private func decodeStack(_ json: String) throws -> EditStack {
        try JSONDecoder().decode(EditStack.self, from: Data(json.utf8))
    }

    func testLegacyRadialMaskBecomesOneComponent() throws {
        let stack = try decodeStack("""
        {"exposure":0.5,"localAdjustments":[{
          "id":"11111111-1111-1111-1111-111111111111",
          "shape":"radial","isEnabled":true,"isInverted":true,
          "center":{"x":0.3,"y":0.7},"radiusX":0.4,"radiusY":0.15,"feather":0.8,
          "exposure":-1.25,"warmth":30
        }]}
        """)

        let adjustment = try XCTUnwrap(stack.localAdjustments.first)
        XCTAssertEqual(adjustment.components.count, 1)

        let component = try XCTUnwrap(adjustment.components.first)
        XCTAssertEqual(component.shape, .radial)
        XCTAssertEqual(component.center.x, 0.3, accuracy: 1e-9)
        XCTAssertEqual(component.center.y, 0.7, accuracy: 1e-9)
        XCTAssertEqual(component.radiusX, 0.4, accuracy: 1e-9)
        XCTAssertEqual(component.radiusY, 0.15, accuracy: 1e-9)
        XCTAssertEqual(component.feather, 0.8, accuracy: 1e-9)

        XCTAssertTrue(adjustment.isInverted, "Whole-mask invert stays on the adjustment.")
        XCTAssertFalse(component.isInverted, "It must not be copied onto the component too.")
        XCTAssertEqual(adjustment.exposure, -1.25, accuracy: 1e-9)
        XCTAssertEqual(adjustment.warmth, 30, accuracy: 1e-9)
    }

    func testLegacyLinearMaskKeepsItsEndpoints() throws {
        let stack = try decodeStack("""
        {"localAdjustments":[{
          "shape":"linear",
          "startPoint":{"x":0.5,"y":0.95},"endPoint":{"x":0.5,"y":0.35}
        }]}
        """)

        let component = try XCTUnwrap(stack.localAdjustments.first?.components.first)
        XCTAssertEqual(component.shape, .linear)
        XCTAssertEqual(component.startPoint.y, 0.95, accuracy: 1e-9)
        XCTAssertEqual(component.endPoint.y, 0.35, accuracy: 1e-9)
    }

    func testLegacyBrushMaskKeepsItsStrokes() throws {
        let stack = try decodeStack("""
        {"localAdjustments":[{
          "shape":"brush","brushSize":0.09,"brushFeather":0.4,"brushFlow":0.55,
          "brushStrokes":[{"points":[{"x":0.2,"y":0.3},{"x":0.4,"y":0.5}],
                           "radius":0.09,"feather":0.4,"flow":0.55}]
        }]}
        """)

        let component = try XCTUnwrap(stack.localAdjustments.first?.components.first)
        XCTAssertEqual(component.shape, .brush)
        XCTAssertEqual(component.brushSize, 0.09, accuracy: 1e-9)
        XCTAssertEqual(component.brushStrokes.count, 1)
        XCTAssertEqual(component.brushStrokes.first?.points.count, 2)
    }

    /// A stack already written in the new format must be left alone.
    func testModernStackIsNotOverwrittenByTheLegacyPath() throws {
        let stack = try decodeStack("""
        {"localAdjustments":[{
          "shape":"linear",
          "components":[
            {"shape":"luminance","luminanceMin":0.6,"combine":"add"},
            {"shape":"radial","combine":"intersect"}
          ]
        }]}
        """)

        let adjustment = try XCTUnwrap(stack.localAdjustments.first)
        XCTAssertEqual(adjustment.components.count, 2,
                       "The legacy shape key must not clobber a real component list.")
        XCTAssertEqual(adjustment.components[0].shape, .luminance)
        XCTAssertEqual(adjustment.components[0].luminanceMin, 0.6, accuracy: 1e-9)
        XCTAssertEqual(adjustment.components[1].combine, .intersect)
    }

    /// Encoding must not write the legacy keys back out.
    func testEncodingOmitsLegacyKeys() throws {
        var adjustment = LocalAdjustment(shape: .radial)
        adjustment.exposure = 1
        let data = try JSONEncoder().encode(adjustment)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(json.contains("components"))
        XCTAssertFalse(json.contains("\"radiusX\""),
                       "Legacy keys are read on the way in and never written back.")
    }

    func testMigratedMaskStillRenders() throws {
        let stack = try decodeStack("""
        {"localAdjustments":[{
          "shape":"radial","center":{"x":0.5,"y":0.5},
          "radiusX":0.3,"radiusY":0.3,"feather":0.2,"exposure":-2.0
        }]}
        """)

        let source = TestSupport.solidImage(red: 0.5, green: 0.5, blue: 0.5, size: 200)
        let result = EditRenderer().render(source: source, stack: stack)

        let inside = TestSupport.readColor(
            result.cropped(to: CGRect(x: 94, y: 94, width: 12, height: 12))).red
        let outside = TestSupport.readColor(
            result.cropped(to: CGRect(x: 4, y: 4, width: 12, height: 12))).red

        XCTAssertLessThan(inside, outside - 0.15,
                          "A migrated mask must still darken where it always did.")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd ~/Documents/totallynotanopensourcelightroom && xcodegen generate && xcodebuild test -project PhotoEditor.xcodeproj -scheme PhotoEditor -destination 'platform=macOS' -only-testing:PhotoEditorTests/MaskMigrationTests 2>&1 | grep -E "error:|TEST" | head -5
```

Expected: FAIL — `value of type 'LocalAdjustment' has no member 'components'`.

- [ ] **Step 3: Rewrite `LocalAdjustment`**

In `Sources/Models/LocalAdjustment.swift`, keep `BrushStroke` exactly as it is. Replace the `LocalAdjustment` struct (its `Shape` enum, all geometry/brush properties, `displayName`, `init`, and `init(from:)`) with:

```swift
/// One masked local adjustment: a built selection plus the corrections applied
/// inside it.
///
/// The selection lives in ``components`` — a list folded together with set
/// algebra by ``MaskCompositor``. Before 1.3 an adjustment carried exactly one
/// shape; those stacks migrate to a one-component list on decode.
struct LocalAdjustment: Codable, Equatable, Identifiable {
    var id = UUID()
    var isEnabled = true

    /// Inverts the *composed* mask — a radial becomes a burn of everything but
    /// the subject. Individual components have their own invert.
    var isInverted = false

    /// The pieces this selection is built from, folded in order.
    var components: [MaskComponent] = []

    // MARK: Corrections

    /// EV stops, the classic dodge/burn.
    var exposure: Double = 0

    /// `-100...100`.
    var contrast: Double = 0

    /// `-100...100`, negative recovers.
    var highlights: Double = 0

    /// `-100...100`, positive lifts.
    var shadows: Double = 0

    /// `-100...100`.
    var saturation: Double = 0

    /// Warmth shift, `-100...100`. Positive warms the masked area.
    var warmth: Double = 0

    /// True when the corrections would change nothing.
    var isNeutral: Bool {
        exposure == 0 && contrast == 0 && highlights == 0
            && shadows == 0 && saturation == 0 && warmth == 0
    }

    /// True when the selection cannot select anything.
    var isEmpty: Bool { !components.contains(where: \.isContributing) }

    var displayName: String {
        guard let first = components.first else { return "Empty" }
        return components.count == 1 ? first.displayName : "\(first.displayName) +\(components.count - 1)"
    }

    init(shape: MaskComponent.Shape = .linear) {
        components = [MaskComponent(shape: shape)]
    }

    // Current keys plus the pre-1.3 flat mask keys. The legacy ones no longer
    // map to properties, so both the decoder and the encoder are written by
    // hand: legacy keys are read on the way in and never written back.
    enum CodingKeys: String, CodingKey {
        case id, isEnabled, isInverted, components
        case exposure, contrast, highlights, shadows, saturation, warmth
        case shape, startPoint, endPoint, center, radiusX, radiusY, feather
        case brushStrokes, brushSize, brushFeather, brushFlow
    }

    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(.id, UUID())
        isEnabled = c.lenient(.isEnabled, true)
        isInverted = c.lenient(.isInverted, false)

        let stored: [MaskComponent] = c.lenient(.components, [])
        components = stored.isEmpty ? [Self.migratedComponent(from: c)] : stored

        exposure = c.lenient(.exposure, 0)
        contrast = c.lenient(.contrast, 0)
        highlights = c.lenient(.highlights, 0)
        shadows = c.lenient(.shadows, 0)
        saturation = c.lenient(.saturation, 0)
        warmth = c.lenient(.warmth, 0)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(isEnabled, forKey: .isEnabled)
        try c.encode(isInverted, forKey: .isInverted)
        try c.encode(components, forKey: .components)
        try c.encode(exposure, forKey: .exposure)
        try c.encode(contrast, forKey: .contrast)
        try c.encode(highlights, forKey: .highlights)
        try c.encode(shadows, forKey: .shadows)
        try c.encode(saturation, forKey: .saturation)
        try c.encode(warmth, forKey: .warmth)
    }

    /// Rebuilds the single component a pre-1.3 adjustment described with flat
    /// fields. `isInverted` is deliberately not copied down: it inverted the
    /// whole mask then and still does now.
    private static func migratedComponent(
        from c: KeyedDecodingContainer<CodingKeys>
    ) -> MaskComponent {
        var component = MaskComponent(shape: c.lenient(.shape, MaskComponent.Shape.linear))
        component.startPoint = c.lenient(.startPoint, CGPoint(x: 0.5, y: 0.85))
        component.endPoint = c.lenient(.endPoint, CGPoint(x: 0.5, y: 0.45))
        component.center = c.lenient(.center, CGPoint(x: 0.5, y: 0.5))
        component.radiusX = c.lenient(.radiusX, 0.3)
        component.radiusY = c.lenient(.radiusY, 0.25)
        component.feather = c.lenient(.feather, 0.5)
        component.brushStrokes = c.lenient(.brushStrokes, [])
        component.brushSize = c.lenient(.brushSize, 0.04)
        component.brushFeather = c.lenient(.brushFeather, 0.65)
        component.brushFlow = c.lenient(.brushFlow, 0.8)
        return component
    }
}
```

- [ ] **Step 4: Point the renderer at the compositor**

In `Sources/Pipeline/LocalAdjustmentRenderer.swift`, delete `linearGradient`, `radialGradient`, `brushMask`, `interpolatedPoints`, and `pixelPoint` (they now live in `MaskCompositor`). Replace the `apply` and `mask` functions with:

```swift
    /// Applies every enabled, non-neutral adjustment in order.
    ///
    /// `maskSource` is the image generated components measure — the frame as it
    /// entered this stage, *not* the running result, so masks do not cascade
    /// into one another.
    static func apply(
        _ adjustments: [LocalAdjustment], to image: CIImage, maskSource: CIImage
    ) -> CIImage {
        var result = image
        for adjustment in adjustments
        where adjustment.isEnabled && !adjustment.isNeutral && !adjustment.isEmpty {
            result = apply(adjustment, to: result, maskSource: maskSource)
        }
        return result
    }

    static func apply(
        _ adjustment: LocalAdjustment, to image: CIImage, maskSource: CIImage
    ) -> CIImage {
        let extent = image.extent
        guard !extent.isInfinite, extent.width >= 1, extent.height >= 1 else { return image }

        let corrected = corrections(of: adjustment, applied: image)
        guard let mask = mask(for: adjustment, source: maskSource, extent: extent) else {
            return image
        }

        let blend = CIFilter.blendWithMask()
        blend.inputImage = corrected
        blend.backgroundImage = image
        blend.maskImage = mask
        return blend.outputImage?.cropped(to: extent) ?? image
    }

    /// The adjustment's composed mask as **grayscale**, with the whole-mask
    /// invert applied. The overlay draws this directly; the blend converts it.
    static func grayscaleMask(
        for adjustment: LocalAdjustment, source: CIImage, extent: CGRect
    ) -> CIImage? {
        guard var grayscale = MaskCompositor.composedMask(
            adjustment.components, source: source, extent: extent
        ) else { return nil }

        if adjustment.isInverted {
            let invert = CIFilter.colorInvert()
            invert.inputImage = grayscale
            grayscale = invert.outputImage?.cropped(to: extent) ?? grayscale
        }
        return grayscale
    }

    /// The composed mask as **alpha**, which is what `CIBlendWithMask` reads.
    static func mask(
        for adjustment: LocalAdjustment, source: CIImage, extent: CGRect
    ) -> CIImage? {
        guard let grayscale = grayscaleMask(for: adjustment, source: source, extent: extent)
        else { return nil }
        let toAlpha = CIFilter.maskToAlpha()
        toAlpha.inputImage = grayscale
        return toAlpha.outputImage
    }
```

In `Sources/Pipeline/EditRenderer.swift:71`, change the call site to pass the pre-local-adjustment image as the mask source:

```swift
        let maskSource = image
        image = LocalAdjustmentRenderer.apply(stack.localAdjustments, to: image,
                                              maskSource: maskSource)
```

- [ ] **Step 5: Update `EditorModel`**

In `Sources/Views/EditorModel.swift`, add component selection next to `selectedMaskID` (line 214):

```swift
    /// The component of the selected mask that canvas handles and the options
    /// bar act on.
    var selectedComponentID: UUID?

    /// Index of the selected component inside the selected mask.
    var selectedComponentIndex: Int? {
        guard let maskIndex = selectedMaskIndex, let id = selectedComponentID else { return nil }
        return editStack.localAdjustments[maskIndex].components.firstIndex { $0.id == id }
    }
```

Replace `addLocalAdjustment` (line 223) and the three brush methods (lines 233–258) with:

```swift
    func addLocalAdjustment(_ shape: MaskComponent.Shape) {
        let adjustment = LocalAdjustment(shape: shape)
        editStack.localAdjustments.append(adjustment)
        selectedMaskID = adjustment.id
        selectedComponentID = adjustment.components.first?.id
    }

    /// Adds a component to the selected mask, or starts a new mask when none
    /// is selected.
    func addMaskComponent(_ shape: MaskComponent.Shape) {
        guard let index = selectedMaskIndex else {
            addLocalAdjustment(shape)
            return
        }
        let component = MaskComponent(shape: shape)
        editStack.localAdjustments[index].components.append(component)
        selectedComponentID = component.id
    }

    func removeMaskComponent(id: UUID) {
        guard let index = selectedMaskIndex else { return }
        editStack.localAdjustments[index].components.removeAll { $0.id == id }
        if selectedComponentID == id {
            selectedComponentID = editStack.localAdjustments[index].components.first?.id
        }
    }

    /// The selected brush component, if the selection is on one.
    private var selectedBrushIndices: (mask: Int, component: Int)? {
        guard let mask = selectedMaskIndex, let component = selectedComponentIndex,
              editStack.localAdjustments[mask].components[component].shape == .brush
        else { return nil }
        return (mask, component)
    }

    /// Begins a new painted stroke in the selected brush component.
    func beginBrushStroke(at point: CGPoint) {
        guard let (mask, component) = selectedBrushIndices else { return }
        let settings = editStack.localAdjustments[mask].components[component]
        let stroke = BrushStroke(points: [point], radius: settings.brushSize,
                                 feather: settings.brushFeather, flow: settings.brushFlow)
        editStack.localAdjustments[mask].components[component].brushStrokes.append(stroke)
    }

    /// Extends the active stroke, dropping redundant sub-pixel points.
    func continueBrushStroke(to point: CGPoint) {
        guard let (mask, component) = selectedBrushIndices,
              let strokeIndex = editStack.localAdjustments[mask]
                .components[component].brushStrokes.indices.last,
              let previous = editStack.localAdjustments[mask]
                .components[component].brushStrokes[strokeIndex].points.last else { return }
        let minimum = max(editStack.localAdjustments[mask]
            .components[component].brushSize * 0.12, 0.001)
        guard hypot(point.x - previous.x, point.y - previous.y) >= minimum else { return }
        editStack.localAdjustments[mask].components[component]
            .brushStrokes[strokeIndex].points.append(point)
    }

    func removeLastBrushStroke() {
        guard let (mask, component) = selectedBrushIndices,
              !editStack.localAdjustments[mask].components[component].brushStrokes.isEmpty
        else { return }
        editStack.localAdjustments[mask].components[component].brushStrokes.removeLast()
    }
```

In `removeLocalAdjustment(id:)` (line 261), also clear the component selection:

```swift
        if selectedMaskID == id {
            selectedMaskID = nil
            selectedComponentID = nil
        }
```

- [ ] **Step 6: Update the views**

`Sources/Views/CanvasArea.swift` — at the `MaskHandles` call site (line 169), bind to the selected *component* instead of the adjustment:

```swift
                } else if let maskIndex = editor.selectedMaskIndex,
                          let componentIndex = editor.selectedComponentIndex {
                    MaskHandles(
                        component: $editor.editStack
                            .localAdjustments[maskIndex].components[componentIndex],
                        displaySize: displaySize
                    )
                    .frame(width: displaySize.width, height: displaySize.height)
                }
```

In `MaskHandles` (line ~505), rename the binding and add the two new shapes to the switch. Generated masks have no on-canvas geometry, so they draw nothing:

```swift
private struct MaskHandles: View {
    @Binding var component: MaskComponent
    let displaySize: CGSize

    var body: some View {
        ZStack {
            switch component.shape {
            case .linear: linearHandles
            case .radial: radialHandles
            case .brush: brushOverlay
            case .luminance, .colorRange: EmptyView()
            }
        }
        .allowsHitTesting(true)
    }
```

Then rename every remaining `adjustment.` reference inside `MaskHandles` to `component.` — lines 526, 555–564 (brush overlay), 588–589, 599, 602 (linear pins), 611–612, 630, 639 (radial pins). The properties have identical names on `MaskComponent`, so this is a pure receiver rename.

`Sources/Views/SliderPanel/LocalAdjustmentPanel.swift` — lines 14–16 keep calling `model.addLocalAdjustment(.brush/.linear/.radial)` (unchanged signature, now `MaskComponent.Shape`). Lines 42, 112, 118, 143 read `adjustment.shape`; change each to read the selected component. Add near the top of the type:

```swift
    /// The component whose controls this panel shows.
    private func component(_ index: Int) -> MaskComponent? {
        let components = model.editStack.localAdjustments[index].components
        guard let id = model.selectedComponentID,
              let match = components.first(where: { $0.id == id }) else { return components.first }
        return match
    }
```

and replace `adjustment.shape == .radial` with `component(index)?.shape == .radial`, `adjustment.shape == .brush` with `component(index)?.shape == .brush`, and `adjustment.brushStrokes` with `component(index)?.brushStrokes ?? []`. Change `maskBinding` (used at lines 120–126) to address the component:

```swift
    private func maskBinding(
        _ index: Int, _ keyPath: WritableKeyPath<MaskComponent, Double>
    ) -> Binding<Double> {
        Binding(
            get: {
                guard let componentIndex = model.selectedComponentIndex else { return 0 }
                return model.editStack.localAdjustments[index]
                    .components[componentIndex][keyPath: keyPath]
            },
            set: {
                guard let componentIndex = model.selectedComponentIndex else { return }
                model.editStack.localAdjustments[index]
                    .components[componentIndex][keyPath: keyPath] = $0
            }
        )
    }
```

`Sources/Views/ToolRail.swift` — apply the same two changes: line 129 becomes a component-shape check, lines 132–142 use the component-addressed `maskBinding` (copy the implementation above into `ToolOptionsBar`), and lines 152–153 stay as they are.

`Sources/Views/WorkspaceModel.swift` lines 56–68 — search components rather than the adjustment's shape:

```swift
        case .brush:
            if let existing = model.editStack.localAdjustments.last(where: { adjustment in
                adjustment.components.contains { $0.shape == .brush }
            }) {
                model.selectedMaskID = existing.id
                model.selectedComponentID = existing.components.first { $0.shape == .brush }?.id
            } else {
                model.addLocalAdjustment(.brush)
            }
            inspectorMode = .masks
        case .gradient:
            if let existing = model.editStack.localAdjustments.last(where: { adjustment in
                adjustment.components.contains { $0.shape == .linear || $0.shape == .radial }
            }) {
                model.selectedMaskID = existing.id
                model.selectedComponentID = existing.components
                    .first { $0.shape == .linear || $0.shape == .radial }?.id
            } else {
                model.addLocalAdjustment(.linear)
            }
            inspectorMode = .masks
```

Also clear `selectedComponentID` wherever `selectedMaskID` is cleared in `activate` (line 38).

- [ ] **Step 7: Update the tests**

Add to `Tests/TestSupport.swift`:

```swift
extension LocalAdjustment {
    /// Test convenience for the common single-component case.
    var only: MaskComponent {
        get { components[0] }
        set { components[0] = newValue }
    }
}
```

In `Tests/LocalAdjustmentTests.swift`, apply one mechanical rule to all 22 sites: a mask's geometry and brush properties now live on its component, so `mask.<field> = x` becomes `mask.only.<field> = x` for `startPoint`, `endPoint`, `center`, `radiusX`, `radiusY`, `feather`, `brushStrokes`, `brushSize`, `brushFeather`, `brushFlow`. Corrections (`exposure`, `warmth`, `saturation`, …), `isEnabled`, and `isInverted` stay on the adjustment. For example:

```swift
        var mask = LocalAdjustment(shape: .linear)
        mask.only.startPoint = CGPoint(x: 0.5, y: 0.95)
        mask.only.endPoint = CGPoint(x: 0.5, y: 0.5)
        mask.exposure = -2.0
```

and

```swift
        var mask = LocalAdjustment(shape: .brush)
        mask.exposure = 1.5
        mask.only.brushStrokes = [BrushStroke(
            points: [CGPoint(x: 0.25, y: 0.25), CGPoint(x: 0.5, y: 0.5),
                     CGPoint(x: 0.75, y: 0.75)],
            radius: 0.07, feather: 0.4, flow: 1
        )]
```

In `Tests/ToolActivationTests.swift`, `testBrushCreatesThenReusesOneMask` asserts `editor.editStack.localAdjustments.first?.shape == .brush`. Change it to:

```swift
        XCTAssertEqual(editor.editStack.localAdjustments.first?.components.first?.shape, .brush)
```

- [ ] **Step 8: Build, fix, and run the whole suite**

```bash
cd ~/Documents/totallynotanopensourcelightroom && xcodegen generate && xcodebuild test -project PhotoEditor.xcodeproj -scheme PhotoEditor -destination 'platform=macOS' 2>&1 | grep -E "error:|Executed [0-9]+ tests|TEST" | tail -6
```

Expected: PASS. 6 new tests in `MaskMigrationTests`, full suite green. Compiler errors here are the point of the atomic commit — work through them until the build is clean.

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "Masks become built selections: LocalAdjustment holds components

Every 1.2.x stack migrates to a one-component mask on decode, with an
explicit CodingKeys listing the legacy flat keys so they can be read on the
way in and never written back."
```

---

### Task 5: Masks read a stable source, not the running result

Task 4 already threads `maskSource` through. This task proves masks do not cascade, which is the whole reason that parameter exists.

**Files:**
- Modify: `Tests/LocalAdjustmentTests.swift`

**Interfaces:**
- Consumes: `LocalAdjustmentRenderer.apply(_:to:maskSource:)` from Task 4.
- Produces: nothing new.

- [ ] **Step 1: Write the test**

Append to `LocalAdjustmentTests`:

```swift
    // MARK: Mask source

    /// Generated masks measure the frame as it entered the local-adjustment
    /// stage, so editing one mask cannot move another one underneath it.
    func testASecondMaskIsNotAffectedByTheFirstOnesCorrections() {
        var darkener = LocalAdjustment(shape: .radial)
        darkener.only.center = CGPoint(x: 0.25, y: 0.5)
        darkener.only.radiusX = 0.2
        darkener.only.radiusY = 0.2
        darkener.exposure = -3.0

        var second = LocalAdjustment(shape: .radial)
        second.only.center = CGPoint(x: 0.75, y: 0.5)
        second.only.radiusX = 0.2
        second.only.radiusY = 0.2
        second.exposure = 1.0

        var withBoth = EditStack()
        withBoth.localAdjustments = [darkener, second]
        var secondOnly = EditStack()
        secondOnly.localAdjustments = [second]

        let probe = CGRect(x: 144, y: 94, width: 12, height: 12)
        let both = brightness(renderer.render(source: frame(), stack: withBoth), at: probe)
        let alone = brightness(renderer.render(source: frame(), stack: secondOnly), at: probe)

        XCTAssertEqual(both, alone, accuracy: 0.01,
                       "The first mask must not change what the second one selects or does.")
    }
```

- [ ] **Step 2: Run it**

```bash
cd ~/Documents/totallynotanopensourcelightroom && xcodebuild test -project PhotoEditor.xcodeproj -scheme PhotoEditor -destination 'platform=macOS' -only-testing:PhotoEditorTests/LocalAdjustmentTests 2>&1 | grep -E "error:|Executed [0-9]+ tests|TEST" | tail -3
```

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add Tests/LocalAdjustmentTests.swift
git commit -m "Test that masks do not cascade into one another"
```

---

### Task 6: Luminance generator

**Files:**
- Create: `Sources/Pipeline/RangeMaskBuilder.swift`
- Modify: `Sources/Pipeline/MaskCompositor.swift`
- Test: `Tests/RangeMaskTests.swift`

**Interfaces:**
- Consumes: `MaskComponent` from Task 1.
- Produces: `RangeMaskBuilder.luminanceMask(_ component: MaskComponent, source: CIImage, extent: CGRect) -> CIImage?`, and `RangeMaskBuilder.smoothstep(_:) -> Double`.

- [ ] **Step 1: Write the failing test**

Create `Tests/RangeMaskTests.swift`:

```swift
import CoreImage
import CoreImage.CIFilterBuiltins
import XCTest
@testable import PhotoEditor

/// Verifies the two content-derived mask generators — a luminance band and a
/// colour distance. Both are classical; there is deliberately no ML here.
final class RangeMaskTests: XCTestCase {
    private let extent = CGRect(x: 0, y: 0, width: 200, height: 200)

    /// A horizontal black-to-white ramp: dark at x=0, bright at x=200.
    private func ramp() -> CIImage {
        let gradient = CIFilter.linearGradient()
        gradient.point0 = CGPoint(x: 0, y: 0)
        gradient.point1 = CGPoint(x: 200, y: 0)
        gradient.color0 = .black
        gradient.color1 = .white
        return gradient.outputImage!.cropped(to: extent)
    }

    private func coverage(_ mask: CIImage?, atX x: CGFloat) -> Double {
        guard let mask else { return 0 }
        return TestSupport.readColor(
            mask.cropped(to: CGRect(x: x - 3, y: 97, width: 6, height: 6))).red
    }

    // MARK: Luminance

    func testHighBandSelectsTheBrightEndOnly() {
        var component = MaskComponent(shape: .luminance)
        component.luminanceMin = 0.7
        component.luminanceMax = 1.0
        component.luminanceFalloff = 0.05

        let mask = MaskCompositor.composedMask([component], source: ramp(), extent: extent)

        XCTAssertGreaterThan(coverage(mask, atX: 190), 0.8, "The bright end must be selected.")
        XCTAssertLessThan(coverage(mask, atX: 20), 0.1, "The dark end must be spared.")
    }

    func testLowBandSelectsTheDarkEndOnly() {
        var component = MaskComponent(shape: .luminance)
        component.luminanceMin = 0.0
        component.luminanceMax = 0.3
        component.luminanceFalloff = 0.05

        let mask = MaskCompositor.composedMask([component], source: ramp(), extent: extent)

        XCTAssertGreaterThan(coverage(mask, atX: 10), 0.8)
        XCTAssertLessThan(coverage(mask, atX: 190), 0.1)
    }

    func testMidBandSparesBothEnds() {
        var component = MaskComponent(shape: .luminance)
        component.luminanceMin = 0.4
        component.luminanceMax = 0.6
        component.luminanceFalloff = 0.05

        let mask = MaskCompositor.composedMask([component], source: ramp(), extent: extent)

        XCTAssertGreaterThan(coverage(mask, atX: 100), 0.7, "The middle must be selected.")
        XCTAssertLessThan(coverage(mask, atX: 10), 0.1)
        XCTAssertLessThan(coverage(mask, atX: 190), 0.1)
    }

    func testFalloffSoftensTheBandEdge() {
        var hard = MaskComponent(shape: .luminance)
        hard.luminanceMin = 0.5
        hard.luminanceMax = 1.0
        hard.luminanceFalloff = 0.01

        var soft = hard
        soft.luminanceFalloff = 0.35

        // Just below the band, where only a wide falloff reaches.
        let x: CGFloat = 85
        let hardCoverage = coverage(
            MaskCompositor.composedMask([hard], source: ramp(), extent: extent), atX: x)
        let softCoverage = coverage(
            MaskCompositor.composedMask([soft], source: ramp(), extent: extent), atX: x)

        XCTAssertGreaterThan(softCoverage, hardCoverage + 0.15,
                             "A wider falloff must reach further below the band.")
    }

    /// The mask is derived from tone, not position, so it must not depend on
    /// how many pixels the frame happens to have.
    func testLuminanceMaskIsResolutionIndependent() {
        var component = MaskComponent(shape: .luminance)
        component.luminanceMin = 0.6
        component.luminanceMax = 1.0
        component.luminanceFalloff = 0.05

        func rampMask(size: CGFloat) -> Double {
            let box = CGRect(x: 0, y: 0, width: size, height: size)
            let gradient = CIFilter.linearGradient()
            gradient.point0 = CGPoint(x: 0, y: 0)
            gradient.point1 = CGPoint(x: size, y: 0)
            gradient.color0 = .black
            gradient.color1 = .white
            let source = gradient.outputImage!.cropped(to: box)
            let mask = MaskCompositor.composedMask([component], source: source, extent: box)
            // Sample at 90% across in both cases.
            let probe = CGRect(x: size * 0.9 - 3, y: size * 0.5 - 3, width: 6, height: 6)
            return TestSupport.readColor(mask!.cropped(to: probe)).red
        }

        XCTAssertEqual(rampMask(size: 200), rampMask(size: 1000), accuracy: 0.05)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd ~/Documents/totallynotanopensourcelightroom && xcodegen generate && xcodebuild test -project PhotoEditor.xcodeproj -scheme PhotoEditor -destination 'platform=macOS' -only-testing:PhotoEditorTests/RangeMaskTests 2>&1 | grep -E "error:|failed|TEST" | head -8
```

Expected: FAIL — the `luminance` case still returns nil, so `composedMask` returns nil and every coverage reads 0.

- [ ] **Step 3: Write the implementation**

Create `Sources/Pipeline/RangeMaskBuilder.swift`:

```swift
import CoreImage
import CoreImage.CIFilterBuiltins

/// Builds masks from the photograph's own content: a band of tones, or a
/// distance from a sampled colour.
///
/// Both are classical image processing — a transfer curve and a colour-distance
/// lookup. There is deliberately no model here; `handoff.md` rules out AI
/// masking and subject selection.
enum RangeMaskBuilder {
    /// Selects everything whose luminance falls inside the component's band,
    /// with smoothstep shoulders of `luminanceFalloff` at each edge.
    static func luminanceMask(
        _ component: MaskComponent, source: CIImage, extent: CGRect
    ) -> CIImage? {
        // Measure tone the way the photographer sees it. Core Image works in
        // linear space, where 0.5 is not middle grey — a band picked against
        // the histogram would land somewhere else entirely.
        let encoded = source
            .clampedToExtent()
            .applyingFilter("CILinearToSRGBToneCurve")
            .cropped(to: extent)

        let luma = CIFilter.colorMatrix()
        luma.inputImage = encoded
        let weights = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
        luma.rVector = weights
        luma.gVector = weights
        luma.bVector = weights
        luma.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        luma.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        guard let gray = luma.outputImage?.cropped(to: extent) else { return nil }

        let curve = CIFilter.colorCurves()
        curve.inputImage = gray
        curve.curvesDomain = CIVector(x: 0, y: 1)
        curve.curvesData = bandCurveData(
            lower: component.luminanceMin,
            upper: component.luminanceMax,
            falloff: component.luminanceFalloff
        )
        curve.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        return curve.outputImage?.cropped(to: extent)
    }

    /// A 256-sample transfer curve: 0 outside the band, 1 inside, smoothstep
    /// shoulders of `falloff` on each side.
    static func bandCurveData(lower: Double, upper: Double, falloff: Double) -> Data {
        let samples = 256
        var values = [Float]()
        values.reserveCapacity(samples * 3)
        for index in 0..<samples {
            let x = Double(index) / Double(samples - 1)
            let value = Float(band(x, lower: lower, upper: upper, falloff: falloff))
            values.append(value)
            values.append(value)
            values.append(value)
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func band(_ x: Double, lower: Double, upper: Double, falloff: Double) -> Double {
        let width = Swift.max(falloff, 0.0001)
        let rise = smoothstep((x - (lower - width)) / width)
        let fall = 1 - smoothstep((x - upper) / width)
        return Swift.max(0, Swift.min(rise, fall))
    }

    static func smoothstep(_ t: Double) -> Double {
        let c = Swift.min(Swift.max(t, 0), 1)
        return c * c * (3 - 2 * c)
    }
}
```

In `Sources/Pipeline/MaskCompositor.swift`, wire the case in `componentMask`:

```swift
        case .luminance:
            raw = RangeMaskBuilder.luminanceMask(component, source: source, extent: extent)
        case .colorRange:
            raw = nil
```

- [ ] **Step 4: Run tests**

```bash
cd ~/Documents/totallynotanopensourcelightroom && xcodegen generate && xcodebuild test -project PhotoEditor.xcodeproj -scheme PhotoEditor -destination 'platform=macOS' 2>&1 | grep -E "error:|Executed [0-9]+ tests|TEST" | tail -4
```

Expected: PASS. 5 new tests in `RangeMaskTests`, full suite green.

- [ ] **Step 5: Commit**

```bash
git add Sources/Pipeline/RangeMaskBuilder.swift Sources/Pipeline/MaskCompositor.swift Tests/RangeMaskTests.swift PhotoEditor.xcodeproj
git commit -m "Add luminance range masks"
```

---

### Task 7: Colour-range generator

**Files:**
- Modify: `Sources/Pipeline/RangeMaskBuilder.swift`
- Create: `Sources/Pipeline/RangeMaskCubeCache.swift`
- Modify: `Sources/Pipeline/MaskCompositor.swift`
- Test: `Tests/RangeMaskTests.swift`

**Interfaces:**
- Consumes: `MaskColor`, `MaskComponent`, `RangeMaskBuilder.smoothstep`.
- Produces: `RangeMaskBuilder.colorRangeMask(_:source:extent:) -> CIImage?`; `RangeMaskBuilder.colorCubeData(color:tolerance:falloff:dimension:) -> Data`; `RangeMaskCubeCache.shared.filter(color:tolerance:falloff:) -> CIFilter?`.

- [ ] **Step 1: Write the failing test**

Append to `RangeMaskTests`:

```swift
    // MARK: Colour range

    /// Three vertical bands: red on the left, green in the middle, blue right.
    private func colorBands() -> CIImage {
        let red = CIImage(color: CIColor(red: 0.85, green: 0.12, blue: 0.12))
            .cropped(to: CGRect(x: 0, y: 0, width: 66, height: 200))
        let green = CIImage(color: CIColor(red: 0.12, green: 0.72, blue: 0.20))
            .cropped(to: CGRect(x: 66, y: 0, width: 68, height: 200))
        let blue = CIImage(color: CIColor(red: 0.14, green: 0.20, blue: 0.80))
            .cropped(to: CGRect(x: 134, y: 0, width: 66, height: 200))
        return green.composited(over: red).composited(over: blue).cropped(to: extent)
    }

    func testColorRangeSelectsTheSampledColorAndSparesOthers() {
        var component = MaskComponent(shape: .colorRange)
        component.sampledColor = MaskColor(red: 0.12, green: 0.72, blue: 0.20)
        component.colorTolerance = 0.2
        component.colorFalloff = 0.1

        let mask = MaskCompositor.composedMask([component], source: colorBands(), extent: extent)

        XCTAssertGreaterThan(coverage(mask, atX: 100), 0.8, "The sampled green must be selected.")
        XCTAssertLessThan(coverage(mask, atX: 30), 0.15, "Red must be spared.")
        XCTAssertLessThan(coverage(mask, atX: 170), 0.15, "Blue must be spared.")
    }

    func testWiderToleranceSelectsMore() {
        var narrow = MaskComponent(shape: .colorRange)
        narrow.sampledColor = MaskColor(red: 0.12, green: 0.72, blue: 0.20)
        narrow.colorTolerance = 0.05
        narrow.colorFalloff = 0.02

        var wide = narrow
        wide.colorTolerance = 0.9
        wide.colorFalloff = 0.2

        let narrowMask = MaskCompositor.composedMask([narrow], source: colorBands(), extent: extent)
        let wideMask = MaskCompositor.composedMask([wide], source: colorBands(), extent: extent)

        XCTAssertLessThan(coverage(narrowMask, atX: 30), 0.15)
        XCTAssertGreaterThan(coverage(wideMask, atX: 30), coverage(narrowMask, atX: 30) + 0.3,
                             "Widening tolerance must pull in neighbouring colours.")
    }

    /// An unsampled colour range selects nothing, so an intersect against it
    /// must not blank a selection that was otherwise fine.
    func testUnsampledColorRangeIsSkipped() {
        var radial = MaskComponent(shape: .radial)
        radial.center = CGPoint(x: 0.5, y: 0.5)
        radial.radiusX = 0.4
        radial.radiusY = 0.4

        var unsampled = MaskComponent(shape: .colorRange)
        unsampled.combine = .intersect

        let mask = MaskCompositor.composedMask([radial, unsampled],
                                               source: colorBands(), extent: extent)
        XCTAssertGreaterThan(coverage(mask, atX: 100), 0.8)
    }

    func testCubeIsReusedForIdenticalParameters() {
        let color = MaskColor(red: 0.2, green: 0.5, blue: 0.7)
        let first = RangeMaskCubeCache.shared.filter(color: color, tolerance: 0.3, falloff: 0.1)
        let second = RangeMaskCubeCache.shared.filter(color: color, tolerance: 0.3, falloff: 0.1)

        XCTAssertNotNil(first)
        XCTAssertTrue(first === second, "Rebuilding a 64³ cube per slider tick is wasted work.")
    }
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd ~/Documents/totallynotanopensourcelightroom && xcodebuild test -project PhotoEditor.xcodeproj -scheme PhotoEditor -destination 'platform=macOS' -only-testing:PhotoEditorTests/RangeMaskTests 2>&1 | grep -E "error:|TEST" | head -5
```

Expected: FAIL — `cannot find 'RangeMaskCubeCache' in scope`.

- [ ] **Step 3: Write the cube builder**

Append to `Sources/Pipeline/RangeMaskBuilder.swift`:

```swift
extension RangeMaskBuilder {
    /// Selects everything within `colorTolerance` of the sampled colour,
    /// fading out across `colorFalloff`.
    static func colorRangeMask(
        _ component: MaskComponent, source: CIImage, extent: CGRect
    ) -> CIImage? {
        guard let color = component.sampledColor else { return nil }
        guard let filter = RangeMaskCubeCache.shared.filter(
            color: color,
            tolerance: component.colorTolerance,
            falloff: component.colorFalloff
        ) else { return nil }

        // Judge colour as displayed, matching what the eyedropper sampled.
        let encoded = source
            .clampedToExtent()
            .applyingFilter("CILinearToSRGBToneCurve")
            .cropped(to: extent)

        filter.setValue(encoded, forKey: kCIInputImageKey)
        return (filter.outputImage)?.cropped(to: extent)
    }

    /// A cube mapping every colour to its mask value.
    ///
    /// Distance weights chroma above luminance, so sampling a green leaf
    /// selects greens across a range of brightness rather than only the leaves
    /// at that exact exposure.
    static func colorCubeData(
        color: MaskColor, tolerance: Double, falloff: Double, dimension: Int = 64
    ) -> Data {
        let target = opponent(red: color.red, green: color.green, blue: color.blue)
        let width = Swift.max(falloff, 0.0001)
        var values = [Float]()
        values.reserveCapacity(dimension * dimension * dimension * 4)

        // Core Image expects red varying fastest, then green, then blue.
        for blueIndex in 0..<dimension {
            let blue = Double(blueIndex) / Double(dimension - 1)
            for greenIndex in 0..<dimension {
                let green = Double(greenIndex) / Double(dimension - 1)
                for redIndex in 0..<dimension {
                    let red = Double(redIndex) / Double(dimension - 1)
                    let point = opponent(red: red, green: green, blue: blue)
                    let distance = sqrt(
                        pow((point.luma - target.luma) * 0.5, 2)
                            + pow(point.cb - target.cb, 2)
                            + pow(point.cr - target.cr, 2)
                    )
                    let value = Float(1 - smoothstep((distance - tolerance) / width))
                    // Grey mask value, opaque. Alpha 1 makes premultiplication
                    // an identity, which is what CIColorCube expects.
                    values.append(value)
                    values.append(value)
                    values.append(value)
                    values.append(1)
                }
            }
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func opponent(
        red: Double, green: Double, blue: Double
    ) -> (luma: Double, cb: Double, cr: Double) {
        let luma = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        return (luma, blue - luma, red - luma)
    }
}
```

Create `Sources/Pipeline/RangeMaskCubeCache.swift`:

```swift
import CoreImage

/// Memoises colour-range cubes.
///
/// A 64³ cube is 262,144 entries built on the CPU. Dragging the tolerance
/// slider would otherwise rebuild it on every tick, which is the difference
/// between a live control and a stuttering one. Mirrors ``ColorCubeCache``.
final class RangeMaskCubeCache {
    static let shared = RangeMaskCubeCache()

    private struct Key: Hashable {
        let red, green, blue: Double
        let tolerance, falloff: Double
    }

    private var cache: [Key: CIFilter] = [:]
    private let lock = NSLock()
    private let limit = 24

    func filter(color: MaskColor, tolerance: Double, falloff: Double) -> CIFilter? {
        let key = Key(red: color.red, green: color.green, blue: color.blue,
                      tolerance: tolerance, falloff: falloff)
        lock.lock()
        defer { lock.unlock() }

        if let cached = cache[key] { return cached }

        guard let filter = CIFilter(name: "CIColorCube") else { return nil }
        let dimension = 64
        filter.setValue(dimension, forKey: "inputCubeDimension")
        filter.setValue(
            RangeMaskBuilder.colorCubeData(color: color, tolerance: tolerance,
                                           falloff: falloff, dimension: dimension),
            forKey: "inputCubeData"
        )

        // Bounded so a long session of sampling cannot grow without limit.
        if cache.count >= limit { cache.removeAll() }
        cache[key] = filter
        return filter
    }
}
```

In `Sources/Pipeline/MaskCompositor.swift`, wire the case:

```swift
        case .colorRange:
            raw = RangeMaskBuilder.colorRangeMask(component, source: source, extent: extent)
```

- [ ] **Step 4: Run tests**

```bash
cd ~/Documents/totallynotanopensourcelightroom && xcodegen generate && xcodebuild test -project PhotoEditor.xcodeproj -scheme PhotoEditor -destination 'platform=macOS' 2>&1 | grep -E "error:|Executed [0-9]+ tests|TEST" | tail -4
```

Expected: PASS. 4 more tests in `RangeMaskTests`, full suite green.

- [ ] **Step 5: Commit**

```bash
git add Sources/Pipeline/RangeMaskBuilder.swift Sources/Pipeline/RangeMaskCubeCache.swift Sources/Pipeline/MaskCompositor.swift Tests/RangeMaskTests.swift PhotoEditor.xcodeproj
git commit -m "Add colour-range masks via a cached 64-cube"
```

---

### Task 8: Mask overlay

**Files:**
- Modify: `Sources/Views/EditorModel.swift`
- Test: `Tests/MaskOverlayTests.swift` (create)

**Interfaces:**
- Consumes: `LocalAdjustmentRenderer.grayscaleMask(for:source:extent:)` from Task 4.
- Produces: `EditorModel.isShowingMaskOverlay: Bool`; `MaskOverlay.tinted(_ image: CIImage, mask: CIImage, extent: CGRect) -> CIImage` in `Sources/Pipeline/MaskCompositor.swift`.

- [ ] **Step 1: Write the failing test**

Create `Tests/MaskOverlayTests.swift`:

```swift
import CoreImage
import XCTest
@testable import PhotoEditor

/// The overlay is a viewing aid. It must be obvious on screen and absent from
/// every exported pixel.
final class MaskOverlayTests: XCTestCase {
    private let extent = CGRect(x: 0, y: 0, width: 100, height: 100)

    private func source() -> CIImage {
        TestSupport.solidImage(red: 0.5, green: 0.5, blue: 0.5, size: 100)
    }

    private func fullMask() -> CIImage {
        CIImage(color: .white).cropped(to: extent)
    }

    func testOverlayTintsTowardRed() {
        let tinted = MaskOverlay.tinted(source(), mask: fullMask(), extent: extent)
        let color = TestSupport.readColor(tinted.cropped(to: CGRect(x: 40, y: 40, width: 20, height: 20)))

        XCTAssertGreaterThan(color.red, color.green + 0.1, "A selected area must read red.")
        XCTAssertGreaterThan(color.red, color.blue + 0.1)
    }

    func testUnselectedAreasAreLeftAlone() {
        let empty = CIImage(color: .black).cropped(to: extent)
        let tinted = MaskOverlay.tinted(source(), mask: empty, extent: extent)
        let color = TestSupport.readColor(tinted.cropped(to: CGRect(x: 40, y: 40, width: 20, height: 20)))

        XCTAssertEqual(color.red, 0.5, accuracy: 0.02)
        XCTAssertEqual(color.green, 0.5, accuracy: 0.02)
    }

    /// The important one. Export renders through `EditRenderer` from the edit
    /// stack, so proving the overlay changes neither is proving it can never
    /// reach an exported pixel.
    func testOverlayChangesNeitherTheEditStackNorTheRenderer() throws {
        let url = try TestSupport.makeTempPNG()
        defer { try? FileManager.default.removeItem(at: url) }
        let catalog = try TestSupport.inMemoryCatalog()
        let entry = TestSupport.makeEntry(fileURL: url)
        try catalog.save(entry)

        let editor = EditorModel(entry: entry, catalog: catalog,
                                 thumbnails: TestSupport.tempThumbnails(), commitDelay: 60)
        editor.addLocalAdjustment(.radial)
        editor.editStack.localAdjustments[0].exposure = -1

        let renderer = EditRenderer()
        let stackBefore = editor.editStack
        let plain = renderer.render(source: source(), stack: editor.editStack)

        editor.isShowingMaskOverlay = true

        XCTAssertEqual(editor.editStack, stackBefore,
                       "Toggling a viewing aid must not touch the edit stack.")

        let withOverlay = renderer.render(source: source(), stack: editor.editStack)
        let probe = CGRect(x: 40, y: 40, width: 20, height: 20)
        XCTAssertEqual(TestSupport.readColor(plain.cropped(to: probe)).red,
                       TestSupport.readColor(withOverlay.cropped(to: probe)).red,
                       accuracy: 1e-6,
                       "The renderer export uses must be blind to the overlay.")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd ~/Documents/totallynotanopensourcelightroom && xcodegen generate && xcodebuild test -project PhotoEditor.xcodeproj -scheme PhotoEditor -destination 'platform=macOS' -only-testing:PhotoEditorTests/MaskOverlayTests 2>&1 | grep -E "error:|TEST" | head -5
```

Expected: FAIL — `cannot find 'MaskOverlay' in scope`.

- [ ] **Step 3: Write the implementation**

Append to `Sources/Pipeline/MaskCompositor.swift`:

```swift
/// Draws a selection on top of the preview so a generated mask can be tuned.
///
/// A luminance band is invisible on the photograph itself — you can only judge
/// it by seeing the selection — so this is required for the feature to be
/// usable, not a convenience. It is a viewing aid and never touches export.
enum MaskOverlay {
    static func tinted(_ image: CIImage, mask: CIImage, extent: CGRect) -> CIImage {
        let red = CIImage(color: CIColor(red: 0.85, green: 0.12, blue: 0.15))
            .cropped(to: extent)

        // Half-strength so the photograph stays readable underneath.
        let damped = CIFilter.colorMatrix()
        damped.inputImage = mask
        damped.rVector = CIVector(x: 0.55, y: 0, z: 0, w: 0)
        damped.gVector = CIVector(x: 0, y: 0.55, z: 0, w: 0)
        damped.bVector = CIVector(x: 0, y: 0, z: 0.55, w: 0)
        damped.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        guard let scaled = damped.outputImage?.cropped(to: extent) else { return image }

        let toAlpha = CIFilter.maskToAlpha()
        toAlpha.inputImage = scaled
        guard let alpha = toAlpha.outputImage else { return image }

        let blend = CIFilter.blendWithMask()
        blend.inputImage = red
        blend.backgroundImage = image
        blend.maskImage = alpha
        return blend.outputImage?.cropped(to: extent) ?? image
    }
}
```

In `Sources/Views/EditorModel.swift`, add next to `isFocusPeakingEnabled` (line ~294):

```swift
    /// Tints the selected mask red over the preview. A viewing aid only — it
    /// never affects the edit stack or what gets exported.
    var isShowingMaskOverlay = false {
        didSet { renderPreview() }
    }
```

In `renderPreview()` (line 623), replace the last three lines of the function — currently:

```swift
        let shown = isFocusPeakingEnabled
            ? FocusPeaking.overlay(on: edited)
            : edited
        displayImage = renderer.makeCGImage(shown)
```

with:

```swift
        var shown = isFocusPeakingEnabled
            ? FocusPeaking.overlay(on: edited)
            : edited

        // Chrome, like peaking: drawn after the histogram is measured so it
        // cannot pollute the reading, and never folded into the edit stack.
        if isShowingMaskOverlay, let index = selectedMaskIndex,
           let mask = LocalAdjustmentRenderer.grayscaleMask(
               for: editStack.localAdjustments[index],
               source: edited, extent: edited.extent
           ) {
            shown = MaskOverlay.tinted(shown, mask: mask, extent: edited.extent)
        }

        displayImage = renderer.makeCGImage(shown)
```

- [ ] **Step 4: Run tests**

```bash
cd ~/Documents/totallynotanopensourcelightroom && xcodegen generate && xcodebuild test -project PhotoEditor.xcodeproj -scheme PhotoEditor -destination 'platform=macOS' 2>&1 | grep -E "error:|Executed [0-9]+ tests|TEST" | tail -4
```

Expected: PASS. 3 new tests in `MaskOverlayTests`, full suite green.

- [ ] **Step 5: Commit**

```bash
git add Sources/Pipeline/MaskCompositor.swift Sources/Views/EditorModel.swift Tests/MaskOverlayTests.swift PhotoEditor.xcodeproj
git commit -m "Add the red mask overlay, preview only"
```

---

### Task 9: Component list UI

**Files:**
- Create: `Sources/Views/SliderPanel/MaskComponentPanel.swift`
- Modify: `Sources/Views/SliderPanel/LocalAdjustmentPanel.swift`

**Interfaces:**
- Consumes: `EditorModel.selectedComponentID/.selectedComponentIndex/.addMaskComponent/.removeMaskComponent`; `Theme`; `PlateButton` from `Sources/Views/Controls/InstrumentControls.swift`.
- Produces: `MaskComponentList(model:maskIndex:)` and `MaskComponentControls(model:maskIndex:)` SwiftUI views.

- [ ] **Step 1: Write the component list**

Create `Sources/Views/SliderPanel/MaskComponentPanel.swift`:

```swift
import SwiftUI

/// The pieces the selected mask is built from, in the order they fold
/// together. A selection is read top to bottom: the first row starts it, each
/// row after it adds to, cuts from, or narrows what came before.
struct MaskComponentList: View {
    @Bindable var model: EditorModel
    let maskIndex: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(components.enumerated()), id: \.element.id) { position, component in
                row(component, isFirst: position == 0)
            }
            addRow
        }
    }

    private var components: [MaskComponent] {
        model.editStack.localAdjustments[maskIndex].components
    }

    private func row(_ component: MaskComponent, isFirst: Bool) -> some View {
        let isSelected = component.id == model.selectedComponentID
        return HStack(spacing: 8) {
            // The first component starts the selection, so its combine mode
            // would be a lie — show a neutral marker instead.
            Text(isFirst ? "·" : glyph(component.combine))
                .font(Theme.valueFont)
                .foregroundStyle(isFirst ? Theme.tertiaryText : Theme.accent)
                .frame(width: 12)

            Text(component.displayName.uppercased())
                .font(Theme.engravedLabel)
                .kerning(Theme.engravedTracking)
                .foregroundStyle(isSelected ? Theme.text : Theme.secondaryText)

            Spacer()

            Button {
                model.editStack.localAdjustments[maskIndex]
                    .components[indexOf(component)].isEnabled.toggle()
            } label: {
                Circle()
                    .fill(component.isEnabled ? Theme.accent : Theme.separator)
                    .frame(width: 6, height: 6)
            }
            .buttonStyle(.plain)
            .help(component.isEnabled ? "Disable this piece" : "Enable this piece")

            Button {
                model.removeMaskComponent(id: component.id)
            } label: {
                Text("×").font(Theme.valueFont).foregroundStyle(Theme.tertiaryText)
            }
            .buttonStyle(.plain)
            .help("Remove this piece")
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(isSelected ? Theme.control : .clear)
        .contentShape(Rectangle())
        .onTapGesture { model.selectedComponentID = component.id }
    }

    private var addRow: some View {
        HStack(spacing: 6) {
            Text("ADD").engraved()
            PlateButton(title: "Lum") { model.addMaskComponent(.luminance) }
            PlateButton(title: "Color") { model.addMaskComponent(.colorRange) }
            PlateButton(title: "Grad") { model.addMaskComponent(.linear) }
            PlateButton(title: "Rad") { model.addMaskComponent(.radial) }
            PlateButton(title: "Brush") { model.addMaskComponent(.brush) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func glyph(_ combine: MaskComponent.Combine) -> String {
        switch combine {
        case .add: "+"
        case .subtract: "−"
        case .intersect: "∩"
        }
    }

    private func indexOf(_ component: MaskComponent) -> Int {
        components.firstIndex { $0.id == component.id } ?? 0
    }
}
```

- [ ] **Step 2: Wire it into the mask panel**

In `Sources/Views/SliderPanel/LocalAdjustmentPanel.swift`, inside the block that renders the selected mask's controls (around line 112, before the shape-specific controls), insert:

```swift
                MaskComponentList(model: model, maskIndex: index)
                Rectangle().fill(Theme.separator).frame(height: Theme.hairline)
```

- [ ] **Step 3: Build and run the suite**

```bash
cd ~/Documents/totallynotanopensourcelightroom && xcodegen generate && xcodebuild test -project PhotoEditor.xcodeproj -scheme PhotoEditor -destination 'platform=macOS' 2>&1 | grep -E "error:|Executed [0-9]+ tests|TEST" | tail -4
```

Expected: PASS. This task adds no tests; every existing one must stay green.

- [ ] **Step 4: Launch and confirm visually**

```bash
cd ~/Documents/totallynotanopensourcelightroom && xcodebuild build -project PhotoEditor.xcodeproj -scheme PhotoEditor -destination 'platform=macOS' 2>&1 | tail -2
open -a "$(find ~/Library/Developer/Xcode/DerivedData/PhotoEditor-*/Build/Products/Debug -maxdepth 1 -name 'PhotoEditor.app' | head -1)"
sleep 4 && screencapture -o -x /tmp/masks-ui.png
```

Open a photo, add a mask, and confirm the component list renders with the add row. Read `/tmp/masks-ui.png` to check. Quit with `pkill -x PhotoEditor`.

- [ ] **Step 5: Commit**

```bash
git add Sources/Views/SliderPanel/MaskComponentPanel.swift Sources/Views/SliderPanel/LocalAdjustmentPanel.swift PhotoEditor.xcodeproj
git commit -m "Add the mask component list UI"
```

---

### Task 10: Per-component controls and colour sampling

**Files:**
- Modify: `Sources/Views/SliderPanel/MaskComponentPanel.swift`
- Modify: `Sources/Views/EditorModel.swift`
- Modify: `Sources/Views/CanvasArea.swift`

**Interfaces:**
- Consumes: `MaskComponentList` from Task 9; `EditorModel.canvasPicker`; `AdjustmentSlider` from `Sources/Views/SliderPanel/AdjustmentSlider.swift`.
- Produces: `MaskComponentControls(model:maskIndex:)`; `EditorModel.CanvasPicker.colorRangeSample`; `EditorModel.sampleColorRange(at:)`.

- [ ] **Step 1: Add the picker case and the sampling entry point**

In `Sources/Views/EditorModel.swift`, extend the `CanvasPicker` enum (line 108):

```swift
        /// Click a colour; the selected colour-range component samples it.
        case colorRangeSample
```

Add the handler next to the other picker handlers:

```swift
    /// Samples the photograph at `point` into the selected colour-range
    /// component. Reads the developed image, so the sample matches the colour
    /// the photographer actually clicked rather than the raw original.
    func sampleColorRange(at point: CGPoint) {
        guard let mask = selectedMaskIndex, let component = selectedComponentIndex,
              editStack.localAdjustments[mask].components[component].shape == .colorRange,
              let source else { return }

        let developed = renderer.render(source: source, stack: editStack)
        let extent = developed.extent
        guard !extent.isInfinite else { return }

        // FilmBaseSampler enforces a ≥4px integral sample: CIAreaAverage
        // silently returns zeros for tiny non-integral extents.
        let side = max(min(extent.width, extent.height) * 0.02, 4)
        let rect = CGRect(
            x: extent.origin.x + point.x * extent.width - side / 2,
            y: extent.origin.y + point.y * extent.height - side / 2,
            width: side, height: side
        )
        guard let sampled = FilmBaseSampler.sampleAverage(
            from: developed, in: rect, context: renderer.context
        ) else { return }

        editStack.localAdjustments[mask].components[component].sampledColor =
            MaskColor(red: sampled.red, green: sampled.green, blue: sampled.blue)
        canvasPicker = nil
    }
```

In `Sources/Views/CanvasArea.swift`, in the single-click handler that dispatches on `editor.canvasPicker`, add:

```swift
            case .colorRangeSample:
                editor.sampleColorRange(at: unitPoint(location))
```

- [ ] **Step 2: Add the controls view**

Append to `Sources/Views/SliderPanel/MaskComponentPanel.swift`:

```swift
/// Controls for the selected component. Only one component's controls are on
/// screen at a time — the inspector is 320pt wide and a list of every piece's
/// parameters would not fit or read.
struct MaskComponentControls: View {
    @Bindable var model: EditorModel
    let maskIndex: Int

    var body: some View {
        if let index = model.selectedComponentIndex {
            VStack(alignment: .leading, spacing: 8) {
                combineRow(index)
                shapeControls(index)
                refineControls(index)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
    }

    private func binding(
        _ index: Int, _ keyPath: WritableKeyPath<MaskComponent, Double>
    ) -> Binding<Double> {
        Binding(
            get: { model.editStack.localAdjustments[maskIndex].components[index][keyPath: keyPath] },
            set: { model.editStack.localAdjustments[maskIndex].components[index][keyPath: keyPath] = $0 }
        )
    }

    private func component(_ index: Int) -> MaskComponent {
        model.editStack.localAdjustments[maskIndex].components[index]
    }

    private func combineRow(_ index: Int) -> some View {
        HStack(spacing: 6) {
            Text("MODE").engraved()
            ForEach(MaskComponent.Combine.allCases, id: \.self) { mode in
                PlateButton(title: label(mode),
                            isEnabled: true) {
                    model.editStack.localAdjustments[maskIndex].components[index].combine = mode
                }
            }
            Spacer()
            PlateButton(title: component(index).isInverted ? "Inverted" : "Invert") {
                model.editStack.localAdjustments[maskIndex].components[index].isInverted.toggle()
            }
        }
    }

    private func label(_ mode: MaskComponent.Combine) -> String {
        switch mode {
        case .add: "Add"
        case .subtract: "Subtract"
        case .intersect: "Intersect"
        }
    }

    @ViewBuilder
    private func shapeControls(_ index: Int) -> some View {
        switch component(index).shape {
        case .luminance:
            LuminanceRangeControl(histogram: model.histogram,
                                  lower: binding(index, \.luminanceMin),
                                  upper: binding(index, \.luminanceMax))
            AdjustmentSlider(title: "Falloff", value: binding(index, \.luminanceFalloff),
                             range: 0.01...0.5, format: "%.2f", neutral: 0.15)
        case .colorRange:
            HStack(spacing: 8) {
                Text("SAMPLE").engraved()
                swatch(index)
                PlateButton(title: model.canvasPicker == .colorRangeSample
                            ? "Click the photo" : "Sample") {
                    model.canvasPicker = .colorRangeSample
                }
            }
            AdjustmentSlider(title: "Tolerance", value: binding(index, \.colorTolerance),
                             range: 0.01...1, format: "%.2f", neutral: 0.25)
            AdjustmentSlider(title: "Falloff", value: binding(index, \.colorFalloff),
                             range: 0.01...0.5, format: "%.2f", neutral: 0.15)
        case .radial:
            AdjustmentSlider(title: "Feather", value: binding(index, \.feather),
                             range: 0...1, format: "%.2f", neutral: 0.5)
        case .brush:
            AdjustmentSlider(title: "Size", value: binding(index, \.brushSize),
                             range: 0.005...0.2, format: "%.3f", neutral: 0.04)
            AdjustmentSlider(title: "Feather", value: binding(index, \.brushFeather),
                             range: 0...1, format: "%.2f", neutral: 0.65)
            AdjustmentSlider(title: "Flow", value: binding(index, \.brushFlow),
                             range: 0.05...1, format: "%.2f", neutral: 0.8)
        case .linear:
            Text("Drag the on-canvas pins to place the gradient")
                .font(Theme.readableFont)
                .foregroundStyle(Theme.secondaryText)
        }
    }

    private func swatch(_ index: Int) -> some View {
        let sampled = component(index).sampledColor
        return Rectangle()
            .fill(sampled.map {
                Color(red: $0.red, green: $0.green, blue: $0.blue)
            } ?? Color.clear)
            .frame(width: 22, height: 14)
            .overlay(Rectangle().stroke(Theme.separator, lineWidth: Theme.hairline))
    }

    private func refineControls(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            AdjustmentSlider(title: "Refine Blur",
                             value: binding(index, \.refine.blur),
                             range: 0...1, format: "%.2f", neutral: 0)
            AdjustmentSlider(title: "Expand",
                             value: binding(index, \.refine.shift),
                             range: -1...1, format: "%.2f", neutral: 0)
        }
    }
}

/// The luminance band drawn over the photograph's own tone distribution.
///
/// A band picked against numbers alone is guesswork. Against the histogram you
/// can see which tones you are actually selecting — which is the whole reason
/// the control exists rather than two more faders.
private struct LuminanceRangeControl: View {
    let histogram: Histogram
    @Binding var lower: Double
    @Binding var upper: Double

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.black.opacity(0.85))

                if !histogram.isEmpty {
                    Path { path in
                        let bins = histogram.green
                        let peak = CGFloat(histogram.peak)
                        for (index, value) in bins.enumerated() {
                            let x = width * CGFloat(index) / CGFloat(max(bins.count - 1, 1))
                            let y = height - height * CGFloat(value) / peak
                            if index == 0 {
                                path.move(to: CGPoint(x: x, y: y))
                            } else {
                                path.addLine(to: CGPoint(x: x, y: y))
                            }
                        }
                    }
                    .stroke(Theme.secondaryText, lineWidth: 1)
                }

                Rectangle()
                    .fill(Theme.accent.opacity(0.22))
                    .frame(width: max(width * CGFloat(upper - lower), 1))
                    .offset(x: width * CGFloat(lower))

                handle(at: lower, width: width, height: height) {
                    lower = min(max($0, 0), upper)
                }
                handle(at: upper, width: width, height: height) {
                    upper = min(max($0, lower), 1)
                }
            }
        }
        .frame(height: 54)
    }

    /// A hairline marker with a wider invisible grab area — one pixel is not
    /// a pointer target.
    private func handle(
        at position: Double, width: CGFloat, height: CGFloat,
        set: @escaping (Double) -> Void
    ) -> some View {
        Color.clear
            .frame(width: 16, height: height)
            .contentShape(Rectangle())
            .overlay(Rectangle().fill(Theme.accent).frame(width: 1))
            .offset(x: width * CGFloat(position) - 8)
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    let x = value.location.x + width * CGFloat(position) - 8
                    set(Double(min(max(x / width, 0), 1)))
                }
            )
    }
}
```

- [ ] **Step 3: Wire the controls in**

In `LocalAdjustmentPanel.swift`, immediately after `MaskComponentList(...)`:

```swift
                MaskComponentControls(model: model, maskIndex: index)
```

- [ ] **Step 4: Build and run the suite**

```bash
cd ~/Documents/totallynotanopensourcelightroom && xcodegen generate && xcodebuild test -project PhotoEditor.xcodeproj -scheme PhotoEditor -destination 'platform=macOS' 2>&1 | grep -E "error:|Executed [0-9]+ tests|TEST" | tail -4
```

Expected: PASS. This task adds no tests; every existing one must stay green.

- [ ] **Step 5: Confirm sampling works in the app**

Launch as in Task 9, add a colour-range component, click Sample, click the photograph, and confirm the swatch fills and the overlay (toggle it on) shows the selection. Screenshot to verify.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "Add per-component mask controls and canvas colour sampling"
```

---

### Task 11: Tool rail routing, overlay toggle, docs, release

**Files:**
- Modify: `Sources/Views/WorkspaceModel.swift`
- Modify: `Sources/Views/ToolRail.swift`
- Modify: `Sources/App/PhotoEditorApp.swift`
- Modify: `README.md`, `CHANGELOG.md`, `project.yml`

**Interfaces:**
- Consumes: everything above.
- Produces: no new API.

- [ ] **Step 1: Route the rail's Brush and Gradient to components**

In `Sources/Views/WorkspaceModel.swift`, change `.brush` and `.gradient` so that when a mask is already selected they add a component to it rather than hunting for an old mask:

```swift
        case .brush:
            if model.selectedMaskID != nil {
                if let existing = selectedComponent(in: model, shape: .brush) {
                    model.selectedComponentID = existing
                } else {
                    model.addMaskComponent(.brush)
                }
            } else {
                model.addLocalAdjustment(.brush)
            }
            inspectorMode = .masks
        case .gradient:
            if model.selectedMaskID != nil {
                if let existing = selectedComponent(in: model, shapes: [.linear, .radial]) {
                    model.selectedComponentID = existing
                } else {
                    model.addMaskComponent(.linear)
                }
            } else {
                model.addLocalAdjustment(.linear)
            }
            inspectorMode = .masks
```

Add the two helpers:

```swift
    private func selectedComponent(
        in model: EditorModel, shape: MaskComponent.Shape
    ) -> UUID? {
        selectedComponent(in: model, shapes: [shape])
    }

    private func selectedComponent(
        in model: EditorModel, shapes: Set<MaskComponent.Shape>
    ) -> UUID? {
        guard let index = model.selectedMaskIndex else { return nil }
        return model.editStack.localAdjustments[index]
            .components.last { shapes.contains($0.shape) }?.id
    }
```

- [ ] **Step 2: Add the overlay toggle**

In `Sources/App/PhotoEditorApp.swift`, add a shortcut alongside the existing focus-peaking one:

```swift
                Button("") { editor.isShowingMaskOverlay.toggle() }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
```

In `Sources/Views/ToolRail.swift`, in `ToolOptionsBar`'s `.brush` and `.gradient` cases, add:

```swift
                    PlateButton(title: model.isShowingMaskOverlay ? "Hide Mask" : "Show Mask") {
                        model.isShowingMaskOverlay.toggle()
                    }
```

- [ ] **Step 3: Update the tool activation test**

In `Tests/ToolActivationTests.swift`, `testBrushCreatesThenReusesOneMask` now describes different behaviour: with a mask selected, Brush adds a component. Replace its body with:

```swift
    func testBrushCreatesAMaskThenAddsComponentsToIt() throws {
        let (workspace, editor, url) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: url) }

        workspace.activate(.brush, in: editor)
        XCTAssertEqual(editor.editStack.localAdjustments.count, 1)
        XCTAssertEqual(editor.editStack.localAdjustments[0].components.first?.shape, .brush)
        XCTAssertEqual(workspace.inspectorMode, .masks)

        workspace.activate(.gradient, in: editor)
        XCTAssertEqual(editor.editStack.localAdjustments.count, 1,
                       "With a mask selected, a tool adds to it rather than starting a new one.")
        XCTAssertEqual(editor.editStack.localAdjustments[0].components.count, 2)
        XCTAssertEqual(editor.editStack.localAdjustments[0].components[1].shape, .linear)
    }
```

- [ ] **Step 4: Update docs and version**

`project.yml`: set `MARKETING_VERSION: "1.3.0"` and `CURRENT_PROJECT_VERSION: "5"`.

`CHANGELOG.md`, above the 1.2.1 entry:

```markdown
## 1.3.0 — 2026-07-21

### Added

- Masks are now built from components combined with add, subtract, and
  intersect, so a tonal range can be intersected with a gradient and a painted
  area subtracted from the result.
- Luminance range masks: select a band of tones with an adjustable falloff.
- Colour range masks: sample a colour on the photograph and select everything
  within a tolerance of it.
- Per-component refinement — blur, and expand or contract — plus per-component
  invert alongside the existing whole-mask invert.
- A red mask overlay (⌘⇧M) for tuning a selection you would otherwise not be
  able to see.

### Changed

- With a mask selected, the Brush and Gradient tools add a component to it
  instead of always starting a new mask.

### Notes

- Masks from earlier versions load unchanged as single-component selections.
```

`README.md`: extend the local-adjustments paragraph to name the two generated
mask types, the combine modes, and the overlay shortcut.

- [ ] **Step 5: Full verification**

```bash
cd ~/Documents/totallynotanopensourcelightroom && xcodegen generate && xcodebuild test -project PhotoEditor.xcodeproj -scheme PhotoEditor -destination 'platform=macOS' 2>&1 | grep -E "error:|Executed [0-9]+ tests|TEST" | tail -4
```

Expected: PASS. Full suite green (240 tests: 200 baseline + 40 added across tasks 1-8).

Then verify against the real catalog — the migration's true test is a stack written by 1.2.x on disk:

```bash
open -a "$(find ~/Library/Developer/Xcode/DerivedData/PhotoEditor-*/Build/Products/Debug -maxdepth 1 -name 'PhotoEditor.app' | head -1)"
sleep 5 && screencapture -o -x /tmp/masks-final.png
```

Open a photo that already had a mask before this change and confirm the mask is intact and still renders. Quit with `pkill -x PhotoEditor`.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "1.3.0: composable masks with luminance and colour range selection"
```

---

## Verification Summary

At completion:

- 240 tests green (200 baseline + 40 new).
- Every 1.2.x mask loads as a one-component selection with geometry intact, proven by `MaskMigrationTests` and confirmed against the real catalog.
- Luminance and colour-range masks select by content, resolution independently.
- Set algebra, refinement, and per-component invert all covered.
- The overlay is proven not to reach exported pixels.
- No ML anywhere in the pipeline.
