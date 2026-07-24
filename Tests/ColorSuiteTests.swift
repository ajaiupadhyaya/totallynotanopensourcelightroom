import XCTest
@testable import PhotoEditor

final class ColorSuiteTests: XCTestCase {
    private let renderer = EditRenderer()

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

    func testPreviewTileRendererMatchesSinglePass() {
        let source = TestSupport.solidImage(red: 0.3, green: 0.5, blue: 0.7, size: 1200)
        var stack = EditStack()
        stack.exposure = 0.4
        let ml = MLMaskEnvironment(entryID: UUID(), geometry: stack.geometry)
        let single = renderer.render(source: source, stack: stack, mlEnvironment: ml)
        let tiled = PreviewTileRenderer.render(
            source: source, stack: stack, renderer: renderer, mlEnvironment: ml
        )
        let a = TestSupport.readColor(single.cropped(to: CGRect(x: 600, y: 600, width: 8, height: 8)))
        let b = TestSupport.readColor(tiled.cropped(to: CGRect(x: 600, y: 600, width: 8, height: 8)))
        XCTAssertEqual(a.red, b.red, accuracy: 0.02)
        XCTAssertEqual(a.green, b.green, accuracy: 0.02)
    }
}
