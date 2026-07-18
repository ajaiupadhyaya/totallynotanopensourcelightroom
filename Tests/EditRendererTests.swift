import CoreImage
import XCTest
@testable import PhotoEditor

/// Tests the pure edit math in ``EditRenderer`` by rendering solid-color test
/// images and reading back a pixel. These validate that each adjustment moves
/// the image in the right direction — the core promise of Phase 1.
final class EditRendererTests: XCTestCase {
    private let renderer = EditRenderer()

    // A finite, solid mid-gray source image.
    private func solidImage(gray: CGFloat, size: CGFloat = 8) -> CIImage {
        CIImage(color: CIColor(red: gray, green: gray, blue: gray))
            .cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
    }

    /// Reads one pixel back as sRGB-encoded RGBA floats.
    private func sample(_ image: CIImage) -> (r: Float, g: Float, b: Float, a: Float) {
        let context = CIContext(options: [.workingColorSpace: CGColorSpaceCreateDeviceRGB()])
        var pixel = [Float](repeating: 0, count: 4)
        context.render(
            image,
            toBitmap: &pixel,
            rowBytes: 16,
            bounds: CGRect(x: 2, y: 2, width: 1, height: 1),
            format: .RGBAf,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        )
        return (pixel[0], pixel[1], pixel[2], pixel[3])
    }

    func testIdentityEditLeavesImageUnchanged() {
        let source = solidImage(gray: 0.5)
        let rendered = renderer.render(source: source, stack: EditStack())

        // Identity edit should return the exact same CIImage instance.
        XCTAssertEqual(rendered, source)

        let px = sample(rendered)
        XCTAssertEqual(px.r, 0.5, accuracy: 0.02)
        XCTAssertEqual(px.g, 0.5, accuracy: 0.02)
        XCTAssertEqual(px.b, 0.5, accuracy: 0.02)
    }

    func testPositiveExposureBrightens() {
        let source = solidImage(gray: 0.4)
        let base = sample(renderer.render(source: source, stack: EditStack()))

        let brightened = sample(
            renderer.render(source: source, stack: EditStack(exposure: 1.5, contrast: 0))
        )

        XCTAssertGreaterThan(brightened.g, base.g,
                             "Positive exposure should brighten the image.")
    }

    func testNegativeExposureDarkens() {
        let source = solidImage(gray: 0.6)
        let base = sample(renderer.render(source: source, stack: EditStack()))

        let darkened = sample(
            renderer.render(source: source, stack: EditStack(exposure: -1.5, contrast: 0))
        )

        XCTAssertLessThan(darkened.g, base.g,
                          "Negative exposure should darken the image.")
    }

    func testContrastPushesBrightsBrighter() {
        // Contrast in Core Image pivots around mid-gray, so a light pixel should
        // get lighter as contrast increases.
        let source = solidImage(gray: 0.75)
        let base = sample(renderer.render(source: source, stack: EditStack()))

        let contrasted = sample(
            renderer.render(source: source, stack: EditStack(exposure: 0, contrast: 80))
        )

        XCTAssertGreaterThan(contrasted.g, base.g,
                             "Raising contrast should push a light tone lighter.")
    }

    func testRenderCGImagePreservesExtent() {
        let source = solidImage(gray: 0.5, size: 16)
        let cg = renderer.renderCGImage(source: source, stack: EditStack(exposure: 0.5))

        let unwrapped = try? XCTUnwrap(cg)
        XCTAssertEqual(unwrapped?.width, 16)
        XCTAssertEqual(unwrapped?.height, 16)
    }
}

// Convenience initializer so tests can build an EditStack in one line.
extension EditStack {
    init(exposure: Double = 0, contrast: Double = 0) {
        self.init()
        self.exposure = exposure
        self.contrast = contrast
    }
}
