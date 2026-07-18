import CoreImage
import CoreImage.CIFilterBuiltins
import XCTest
@testable import PhotoEditor

/// Phase 2 coverage: white balance, saturation, highlights/shadows, tone curve,
/// and the histogram pass. Each test renders a controlled test image and reads
/// pixels/bins back to assert the adjustment moves the image the right way.
final class Phase2Tests: XCTestCase {
    private let renderer = EditRenderer()

    // MARK: Test images

    private func solidImage(red: CGFloat, green: CGFloat, blue: CGFloat,
                            size: CGFloat = 8) -> CIImage {
        CIImage(color: CIColor(red: red, green: green, blue: blue))
            .cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
    }

    /// A horizontal black→white gradient, `width` × `height`.
    private func gradientImage(width: CGFloat = 64, height: CGFloat = 16) -> CIImage {
        let gradient = CIFilter.linearGradient()
        gradient.point0 = CGPoint(x: 0, y: 0)
        gradient.point1 = CGPoint(x: width, y: 0)
        gradient.color0 = CIColor(red: 0, green: 0, blue: 0)
        gradient.color1 = CIColor(red: 1, green: 1, blue: 1)
        let output = gradient.outputImage ?? CIImage.empty()
        return output.cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    // MARK: Readback

    private func sample(_ image: CIImage, at point: CGPoint)
        -> (r: Float, g: Float, b: Float, a: Float) {
        let context = CIContext(options: [.workingColorSpace: CGColorSpaceCreateDeviceRGB()])
        var pixel = [Float](repeating: 0, count: 4)
        context.render(
            image,
            toBitmap: &pixel,
            rowBytes: 16,
            bounds: CGRect(x: point.x, y: point.y, width: 1, height: 1),
            format: .RGBAf,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        )
        return (pixel[0], pixel[1], pixel[2], pixel[3])
    }

    private func argmax(_ bins: [Float]) -> Int {
        bins.enumerated().max(by: { $0.element < $1.element })?.offset ?? -1
    }

    // MARK: White balance

    func testWarmerTemperatureShiftsTowardRed() {
        let source = solidImage(red: 0.5, green: 0.5, blue: 0.5)
        let neutral = sample(renderer.render(source: source, stack: EditStack()),
                             at: CGPoint(x: 2, y: 2))

        var warm = EditStack()
        warm.whiteBalanceTemp = 9000
        let warmed = sample(renderer.render(source: source, stack: warm),
                            at: CGPoint(x: 2, y: 2))

        XCTAssertGreaterThan(warmed.r - warmed.b, neutral.r - neutral.b,
                             "A warmer temperature should push red above blue.")
    }

    // MARK: Saturation

    func testFullDesaturationYieldsGray() {
        let source = solidImage(red: 0.8, green: 0.25, blue: 0.2)
        var stack = EditStack()
        stack.saturation = -100
        let px = sample(renderer.render(source: source, stack: stack),
                        at: CGPoint(x: 2, y: 2))

        XCTAssertEqual(px.r, px.g, accuracy: 0.05, "Desaturated pixel should be gray.")
        XCTAssertEqual(px.g, px.b, accuracy: 0.05, "Desaturated pixel should be gray.")
    }

    func testPositiveSaturationWidensChannelSpread() {
        let source = solidImage(red: 0.7, green: 0.45, blue: 0.4)
        let baseSpread = channelSpread(renderer.render(source: source, stack: EditStack()))

        var stack = EditStack()
        stack.saturation = 80
        let boostedSpread = channelSpread(renderer.render(source: source, stack: stack))

        XCTAssertGreaterThan(boostedSpread, baseSpread,
                             "Raising saturation should widen the channel spread.")
    }

    private func channelSpread(_ image: CIImage) -> Float {
        let px = sample(image, at: CGPoint(x: 2, y: 2))
        return max(px.r, px.g, px.b) - min(px.r, px.g, px.b)
    }

    // MARK: Highlights & shadows

    func testHighlightRecoveryDarkensBrightTones() {
        let source = gradientImage()
        let brightPoint = CGPoint(x: 56, y: 8) // near the white end
        let base = sample(renderer.render(source: source, stack: EditStack()), at: brightPoint)

        var stack = EditStack()
        stack.highlights = -100
        let recovered = sample(renderer.render(source: source, stack: stack), at: brightPoint)

        XCTAssertLessThan(recovered.g, base.g,
                          "Negative highlights should darken bright tones.")
    }

    func testShadowLiftBrightensDarkTones() {
        let source = gradientImage()
        let darkPoint = CGPoint(x: 8, y: 8) // near the black end
        let base = sample(renderer.render(source: source, stack: EditStack()), at: darkPoint)

        var stack = EditStack()
        stack.shadows = 100
        let lifted = sample(renderer.render(source: source, stack: stack), at: darkPoint)

        XCTAssertGreaterThan(lifted.g, base.g,
                             "Positive shadows should lighten dark tones.")
    }

    // MARK: Tone curve

    func testMidtoneLiftCurveBrightensMidGray() {
        let source = solidImage(red: 0.5, green: 0.5, blue: 0.5)
        let base = sample(renderer.render(source: source, stack: EditStack()),
                          at: CGPoint(x: 2, y: 2))

        var stack = EditStack()
        stack.toneCurvePoints = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 0.25, y: 0.4),
            CGPoint(x: 0.5, y: 0.72),
            CGPoint(x: 0.75, y: 0.88),
            CGPoint(x: 1, y: 1),
        ]
        let lifted = sample(renderer.render(source: source, stack: stack),
                            at: CGPoint(x: 2, y: 2))

        XCTAssertGreaterThan(lifted.g, base.g,
                             "A midtone-lifting curve should brighten mid gray.")
    }

    func testEmptyToneCurveIsIdentity() {
        let source = solidImage(red: 0.5, green: 0.5, blue: 0.5)
        let rendered = renderer.render(source: source, stack: EditStack())
        // No adjustments at all -> the chain returns the source untouched.
        XCTAssertEqual(rendered, source)
    }

    // MARK: Histogram

    func testHistogramReflectsTone() {
        let dark = renderer.histogram(of: solidImage(red: 0.2, green: 0.2, blue: 0.2, size: 64))
        let bright = renderer.histogram(of: solidImage(red: 0.8, green: 0.8, blue: 0.8, size: 64))

        XCTAssertFalse(dark.isEmpty)
        XCTAssertFalse(bright.isEmpty)
        XCTAssertEqual(dark.red.count, 256)

        XCTAssertGreaterThan(argmax(bright.red), argmax(dark.red),
                             "A brighter image's histogram peak should sit at a higher bin.")
    }

    func testHistogramEmptyForInfiniteExtent() {
        let infinite = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
        XCTAssertTrue(renderer.histogram(of: infinite).isEmpty,
                      "An infinite-extent image should yield an empty histogram.")
    }
}
