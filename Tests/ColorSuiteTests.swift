import XCTest
@testable import PhotoEditor

final class ColorSuiteTests: XCTestCase {
    private let renderer = EditRenderer()

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

    func testPointColorShiftsSampledHue() {
        var stack = EditStack()
        var target = PointColorTarget()
        target.red = 0.8
        target.green = 0.2
        target.blue = 0.2
        target.hue = 80
        target.range = 0.3
        target.falloff = 0.1
        stack.color.pointColors = [target]

        let source = TestSupport.solidImage(red: 0.8, green: 0.2, blue: 0.2, size: 32)
        let result = TestSupport.readColor(renderer.render(source: source, stack: stack))
        XCTAssertGreaterThan(result.green, result.blue + 0.05)
    }

    func testParametricToneCurveLiftsShadows() {
        var stack = EditStack()
        stack.toneCurveShadows = 80
        let source = TestSupport.solidImage(red: 0.1, green: 0.1, blue: 0.1, size: 32)
        let result = TestSupport.readColor(renderer.render(source: source, stack: stack))
        XCTAssertGreaterThan(result.red, 0.15)
    }

    func testLUTImporterParsesMinimalCube() throws {
        let cube = """
        LUT_3D_SIZE 2
        0 0 0
        1 0 0
        0 1 0
        1 1 0
        0 0 1
        1 0 1
        0 1 1
        1 1 1
        """
        let parsed = try LUTImporter.parse(text: cube, name: "Test")
        XCTAssertEqual(parsed.dimension, 2)
        XCTAssertEqual(parsed.cubeData.count, 2 * 2 * 2 * 4 * MemoryLayout<Float>.size)
    }

    func testLocalColorGradingInsideMask() {
        let source = TestSupport.solidImage(red: 0.4, green: 0.4, blue: 0.4, size: 64)
        var mask = LocalAdjustment(shape: .radial)
        mask.only.center = CGPoint(x: 0.5, y: 0.5)
        mask.only.radiusX = 0.5
        mask.only.radiusY = 0.5
        mask.color.grading.midtones.saturation = 100
        mask.color.grading.midtones.hue = 120

        var stack = EditStack()
        stack.localAdjustments = [mask]
        let center = TestSupport.readColor(
            renderer.render(source: source, stack: stack)
                .cropped(to: CGRect(x: 28, y: 28, width: 8, height: 8))
        )
        let edge = TestSupport.readColor(
            renderer.render(source: source, stack: stack)
                .cropped(to: CGRect(x: 2, y: 2, width: 8, height: 8))
        )
        XCTAssertGreaterThan(abs(center.green - center.red), abs(edge.green - edge.red) + 0.02)
    }

    /// A large frame must develop to exactly the same picture as a small one.
    ///
    /// This is the contract a tiled preview path broke: splitting the frame and
    /// replaying the whole stack per tile makes every extent-dependent stage —
    /// crop, straighten, vignette, grain, masks — measure the tile instead of
    /// the photograph, so the tiles land in the wrong place and composite as
    /// offset bands. Per-pixel stages like exposure tile harmlessly, which is
    /// why this test exercises geometry and a vignette instead.
    func testLargeFrameDevelopsIdenticallyToSmallOne() {
        var stack = EditStack()
        stack.geometry.cropRect = CGRect(x: 0, y: 0, width: 0.5, height: 1)
        stack.vignetteAmount = -80
        stack.exposure = 0.4

        for size in [512.0, 2048.0] as [CGFloat] {
            let source = TestSupport.solidImage(red: 0.3, green: 0.5, blue: 0.7, size: size)
            let rendered = renderer.render(source: source, stack: stack)

            XCTAssertEqual(rendered.extent.width, size / 2, accuracy: 1,
                           "A half-width crop of a \(Int(size))px frame must be \(Int(size / 2))px wide.")
            XCTAssertEqual(rendered.extent.height, size, accuracy: 1)
            XCTAssertEqual(rendered.extent.origin.x, 0, accuracy: 1)

            // The vignette darkens the corner relative to the centre of the
            // *cropped* frame. Tiling breaks this because each tile vignettes
            // about its own centre.
            let inset = size * 0.04
            let centre = TestSupport.readColor(rendered.cropped(to: CGRect(
                x: size / 4 - inset, y: size / 2 - inset, width: inset * 2, height: inset * 2
            )))
            let corner = TestSupport.readColor(rendered.cropped(to: CGRect(
                x: 0, y: 0, width: inset, height: inset
            )))
            XCTAssertGreaterThan(centre.green, corner.green + 0.05,
                                 "The vignette must darken the corner of the cropped frame.")
        }
    }

    /// The live preview is what the develop stack says it is — no separate
    /// preview-only render path may disagree with `EditRenderer`.
    func testPreviewMatchesTheDevelopStackOnALargeFrame() throws {
        // Large enough that any size-triggered preview path would engage.
        let url = try TestSupport.makeTempPNG(gray: 160, size: 1400)
        defer { try? FileManager.default.removeItem(at: url) }

        let catalog = try TestSupport.inMemoryCatalog()
        let entry = TestSupport.makeEntry(fileURL: url)
        try catalog.save(entry)
        let editor = EditorModel(entry: entry, catalog: catalog,
                                 thumbnails: TestSupport.tempThumbnails(), commitDelay: 60)

        editor.editStack.geometry.cropRect = CGRect(x: 0, y: 0, width: 0.5, height: 1)

        let preview = try XCTUnwrap(editor.previewCIImage)
        XCTAssertEqual(preview.extent.width, 700, accuracy: 2,
                       "Cropping to half must halve the preview, not composite offset tiles.")
        XCTAssertEqual(preview.extent.height, 1400, accuracy: 2)
    }
}
