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

    /// A generated mask measures the frame as it entered the local-adjustment
    /// stage, not the running result, so editing one mask cannot move what a
    /// later one selects.
    ///
    /// Built to fail on a cascade: adjustment 1 drives its region far darker
    /// than the band adjustment 2 selects. Reading the running result would
    /// push that region out of the band and adjustment 2 would skip it.
    func testAGeneratedMaskReadsTheFrameBeforeLocalAdjustments() {
        let flat = TestSupport.solidImage(red: 0.5, green: 0.5, blue: 0.5, size: 200)

        var darkener = LocalAdjustment(shape: .radial)
        darkener.only.center = CGPoint(x: 0.25, y: 0.5)
        darkener.only.radiusX = 0.2
        darkener.only.radiusY = 0.2
        darkener.only.feather = 0.1
        darkener.exposure = -3

        var band = LocalAdjustment(shape: .luminance)
        band.only.luminanceMin = 0.35
        band.only.luminanceMax = 0.65
        band.only.luminanceFalloff = 0.05
        band.exposure = 1

        var bandOnly = EditStack()
        bandOnly.localAdjustments = [band]
        var both = EditStack()
        both.localAdjustments = [darkener, band]

        // Inside the darkened disc, where a cascade would change the answer.
        let probe = CGRect(x: 44, y: 94, width: 12, height: 12)
        let renderer = EditRenderer()

        let darkenedThenBanded = TestSupport.readColor(
            renderer.render(source: flat, stack: both).cropped(to: probe)).red
        let darkenedOnly = TestSupport.readColor(
            renderer.render(source: flat, stack: {
                var s = EditStack(); s.localAdjustments = [darkener]; return s
            }()).cropped(to: probe)).red

        XCTAssertGreaterThan(darkenedThenBanded, darkenedOnly * 1.5,
                             "The band must still select the darkened region, because it "
                             + "measures the frame as it was before any local adjustment.")
        XCTAssertGreaterThan(
            TestSupport.readColor(
                renderer.render(source: flat, stack: bandOnly).cropped(to: probe)).red,
            0.6, "Sanity: the band selects this region on the untouched frame.")
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
