import CoreImage
import XCTest
@testable import PhotoEditor

/// Verifies masked local adjustments: mask geometry, locality of effect,
/// inversion, ordering, and persistence.
final class LocalAdjustmentTests: XCTestCase {
    private let renderer = EditRenderer()

    /// A flat mid-gray frame; locality is judged by comparing regions.
    private func frame(size: CGFloat = 200) -> CIImage {
        TestSupport.solidImage(red: 0.5, green: 0.5, blue: 0.5, size: size)
    }

    private func brightness(_ image: CIImage, at rect: CGRect) -> Double {
        TestSupport.readColor(image.cropped(to: rect)).red
    }

    // MARK: Linear

    func testLinearMaskDarkensItsEndAndSparesTheOther() {
        var mask = LocalAdjustment(shape: .linear)
        // Full effect at the top of the frame, fading out by the middle.
        mask.startPoint = CGPoint(x: 0.5, y: 0.95)
        mask.endPoint = CGPoint(x: 0.5, y: 0.5)
        mask.exposure = -2.0

        var stack = EditStack()
        stack.localAdjustments = [mask]
        let result = renderer.render(source: frame(), stack: stack)

        // Remember: unit coords are bottom-left, so "top" is high y — which in
        // the rendered image's own coordinates is also high y.
        let top = brightness(result, at: CGRect(x: 80, y: 175, width: 40, height: 20))
        let bottom = brightness(result, at: CGRect(x: 80, y: 5, width: 40, height: 20))
        let plain = brightness(frame(), at: CGRect(x: 80, y: 5, width: 40, height: 20))

        XCTAssertLessThan(top, plain - 0.15, "The gradient's start should be darkened.")
        XCTAssertEqual(bottom, plain, accuracy: 0.02,
                       "Below the fade-out the image must be untouched.")
    }

    func testLinearMaskFadesMonotonically() {
        var mask = LocalAdjustment(shape: .linear)
        mask.startPoint = CGPoint(x: 0.5, y: 1.0)
        mask.endPoint = CGPoint(x: 0.5, y: 0.0)
        mask.exposure = -2.0

        var stack = EditStack()
        stack.localAdjustments = [mask]
        let result = renderer.render(source: frame(), stack: stack)

        let high = brightness(result, at: CGRect(x: 80, y: 170, width: 40, height: 16))
        let mid = brightness(result, at: CGRect(x: 80, y: 92, width: 40, height: 16))
        let low = brightness(result, at: CGRect(x: 80, y: 10, width: 40, height: 16))

        XCTAssertLessThan(high, mid, "Effect should weaken along the gradient.")
        XCTAssertLessThan(mid, low)
    }

    // MARK: Radial

    func testRadialMaskAffectsCenterNotCorners() {
        var mask = LocalAdjustment(shape: .radial)
        mask.center = CGPoint(x: 0.5, y: 0.5)
        mask.radiusX = 0.25
        mask.radiusY = 0.25
        mask.feather = 0.3
        mask.exposure = 1.5

        var stack = EditStack()
        stack.localAdjustments = [mask]
        let result = renderer.render(source: frame(), stack: stack)

        let center = brightness(result, at: CGRect(x: 90, y: 90, width: 20, height: 20))
        let corner = brightness(result, at: CGRect(x: 2, y: 2, width: 20, height: 20))
        let plain = brightness(frame(), at: CGRect(x: 90, y: 90, width: 20, height: 20))

        XCTAssertGreaterThan(center, plain + 0.15, "The ellipse interior should brighten.")
        XCTAssertEqual(corner, plain, accuracy: 0.02, "Corners are outside the ellipse.")
    }

    func testInvertedRadialAffectsCornersNotCenter() {
        var mask = LocalAdjustment(shape: .radial)
        mask.center = CGPoint(x: 0.5, y: 0.5)
        mask.radiusX = 0.3
        mask.radiusY = 0.3
        mask.isInverted = true
        mask.exposure = -1.5

        var stack = EditStack()
        stack.localAdjustments = [mask]
        let result = renderer.render(source: frame(), stack: stack)

        let center = brightness(result, at: CGRect(x: 90, y: 90, width: 20, height: 20))
        let corner = brightness(result, at: CGRect(x: 2, y: 2, width: 20, height: 20))
        let plain = brightness(frame(), at: CGRect(x: 90, y: 90, width: 20, height: 20))

        XCTAssertEqual(center, plain, accuracy: 0.03,
                       "Inverted, the ellipse interior is protected.")
        XCTAssertLessThan(corner, plain - 0.15, "Inverted, the surround takes the effect.")
    }

    func testAnisotropicRadiusMakesAnEllipseNotACircle() {
        var mask = LocalAdjustment(shape: .radial)
        mask.center = CGPoint(x: 0.5, y: 0.5)
        mask.radiusX = 0.45   // wide…
        mask.radiusY = 0.10   // …and short
        mask.feather = 0.2
        mask.exposure = 1.5

        var stack = EditStack()
        stack.localAdjustments = [mask]
        let result = renderer.render(source: frame(), stack: stack)

        // Same distance from center horizontally vs vertically: inside the
        // wide axis, outside the short one.
        let horizontal = brightness(result, at: CGRect(x: 155, y: 95, width: 10, height: 10))
        let vertical = brightness(result, at: CGRect(x: 95, y: 155, width: 10, height: 10))

        XCTAssertGreaterThan(horizontal, vertical + 0.1,
                             "The ellipse must be wider than it is tall.")
    }

    // MARK: Corrections

    func testWarmthShiftsTheMaskedRegionWarm() {
        var mask = LocalAdjustment(shape: .radial)
        mask.center = CGPoint(x: 0.5, y: 0.5)
        mask.radiusX = 0.4
        mask.radiusY = 0.4
        mask.warmth = 80

        var stack = EditStack()
        stack.localAdjustments = [mask]
        let result = renderer.render(source: frame(), stack: stack)

        let center = TestSupport.readColor(
            result.cropped(to: CGRect(x: 90, y: 90, width: 20, height: 20)))
        XCTAssertGreaterThan(center.red, center.blue + 0.02,
                             "Positive warmth should push the region toward red.")
    }

    func testDisabledAndNeutralMasksAreNoOps() {
        var disabled = LocalAdjustment(shape: .radial)
        disabled.exposure = 2
        disabled.isEnabled = false

        let neutral = LocalAdjustment(shape: .linear) // no corrections set

        var stack = EditStack()
        stack.localAdjustments = [disabled, neutral]
        let result = renderer.render(source: frame(), stack: stack)

        let color = TestSupport.readColor(result)
        XCTAssertEqual(color.red, 0.5, accuracy: 0.01)
    }

    func testMasksStack() {
        var burn = LocalAdjustment(shape: .linear)
        burn.startPoint = CGPoint(x: 0.5, y: 1.0)
        burn.endPoint = CGPoint(x: 0.5, y: 0.6)
        burn.exposure = -1.0

        var dodge = LocalAdjustment(shape: .linear)
        dodge.startPoint = CGPoint(x: 0.5, y: 0.0)
        dodge.endPoint = CGPoint(x: 0.5, y: 0.4)
        dodge.exposure = 1.0

        var stack = EditStack()
        stack.localAdjustments = [burn, dodge]
        let result = renderer.render(source: frame(), stack: stack)

        let top = brightness(result, at: CGRect(x: 80, y: 180, width: 40, height: 12))
        let bottom = brightness(result, at: CGRect(x: 80, y: 8, width: 40, height: 12))
        XCTAssertLessThan(top, 0.42, "The top burn should land.")
        XCTAssertGreaterThan(bottom, 0.58, "The bottom dodge should land independently.")
    }

    // MARK: Resolution independence

    func testMasksLandOnTheSameRegionAtAnyResolution() {
        var mask = LocalAdjustment(shape: .radial)
        mask.center = CGPoint(x: 0.25, y: 0.75)
        mask.radiusX = 0.15
        mask.radiusY = 0.15
        mask.exposure = 1.5

        var stack = EditStack()
        stack.localAdjustments = [mask]

        // Preview-sized and export-sized frames: the brightened spot must sit
        // at the same *relative* place in both.
        let small = renderer.render(source: frame(size: 200), stack: stack)
        let large = renderer.render(source: frame(size: 1000), stack: stack)

        let smallSpot = brightness(small, at: CGRect(x: 40, y: 140, width: 20, height: 20))
        let largeSpot = brightness(large, at: CGRect(x: 200, y: 700, width: 100, height: 100))
        XCTAssertEqual(smallSpot, largeSpot, accuracy: 0.03,
                       "Unit-coordinate masks must be resolution-independent.")
    }

    // MARK: Persistence

    func testLocalAdjustmentsSurviveACatalogRoundTrip() throws {
        let store = try TestSupport.inMemoryCatalog()
        var entry = TestSupport.makeEntry(fileURL: URL(fileURLWithPath: "/tmp/a.jpg"))

        var linear = LocalAdjustment(shape: .linear)
        linear.startPoint = CGPoint(x: 0.2, y: 0.9)
        linear.exposure = -0.7
        var radial = LocalAdjustment(shape: .radial)
        radial.center = CGPoint(x: 0.6, y: 0.4)
        radial.warmth = 25
        radial.isInverted = true
        entry.editStack.localAdjustments = [linear, radial]
        try store.save(entry)

        let fetched = try XCTUnwrap(store.entry(id: entry.id))
        XCTAssertEqual(fetched.editStack.localAdjustments, entry.editStack.localAdjustments)
        XCTAssertEqual(fetched.editStack.localAdjustments.count, 2)
    }

    func testLegacyStacksDecodeWithNoLocalAdjustments() throws {
        let legacy = """
        {"exposure":1.0,"contrast":0,"highlights":0,"shadows":0,
         "whiteBalanceTemp":6500,"whiteBalanceTint":0,"saturation":0,
         "toneCurvePoints":[]}
        """.data(using: .utf8)!

        let stack = try JSONDecoder().decode(EditStack.self, from: legacy)
        XCTAssertTrue(stack.localAdjustments.isEmpty)
    }
}
