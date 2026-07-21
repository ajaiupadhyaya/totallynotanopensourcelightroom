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
