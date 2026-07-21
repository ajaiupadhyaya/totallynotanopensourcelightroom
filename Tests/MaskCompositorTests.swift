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
        let edge = CGPoint(x: 100, y: 150)   // right at the disc's boundary

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
        XCTAssertGreaterThan(coverage(mask, at: CGPoint(x: 6, y: 100)), 0.5,
                             "The frame edge must stay selected.")
    }

    func testPositiveShiftGrowsAndNegativeShrinks() {
        // The disc's edge is 50px from centre on a 200px frame, and shift 0.8
        // moves it 8px. Probe just past the original edge — far enough out that
        // the unshifted disc reads zero, close enough that the growth reaches.
        let justOutside = CGPoint(x: 100, y: 154)

        var grown = hardDisc()
        grown.refine = MaskRefinement(shift: 0.8)
        var shrunk = hardDisc()
        shrunk.refine = MaskRefinement(shift: -0.8)

        let base = coverage(
            MaskCompositor.composedMask([hardDisc()], source: source(), extent: extent),
            at: justOutside)
        let grownCoverage = coverage(
            MaskCompositor.composedMask([grown], source: source(), extent: extent),
            at: justOutside)
        let shrunkCoverage = coverage(
            MaskCompositor.composedMask([shrunk], source: source(), extent: extent),
            at: justOutside)

        XCTAssertGreaterThan(grownCoverage, base + 0.3, "Expand must reach further out.")
        XCTAssertLessThanOrEqual(shrunkCoverage, base + 0.01, "Contract must not grow.")
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
}
