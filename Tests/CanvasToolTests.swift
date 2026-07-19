import CoreImage
import XCTest
@testable import PhotoEditor

/// Verifies the canvas tools: the white-balance neutral picker, the film-base
/// eyedropper routing, crop-mode rendering, and histogram clipping detection.
@MainActor
final class CanvasToolTests: XCTestCase {
    // MARK: Color temperature estimation

    func testNeutralGrayReadsAsD65() throws {
        let wb = try XCTUnwrap(ColorScience.temperatureAndTint(ofRed: 0.5, green: 0.5, blue: 0.5))
        XCTAssertEqual(wb.temperature, 6500, accuracy: 350,
                       "sRGB's white point is D65; gray should read near 6500 K.")
        XCTAssertEqual(wb.tint, 0, accuracy: 12)
    }

    func testWarmColorsReadWarmerThanCoolColors() throws {
        let warm = try XCTUnwrap(ColorScience.temperatureAndTint(
            ofRed: 0.62, green: 0.5, blue: 0.38))
        let cool = try XCTUnwrap(ColorScience.temperatureAndTint(
            ofRed: 0.38, green: 0.5, blue: 0.62))
        XCTAssertLessThan(warm.temperature, cool.temperature,
                          "A warm cast means a low-CCT illuminant.")
    }

    func testNearBlackYieldsNothing() {
        XCTAssertNil(ColorScience.temperatureAndTint(ofRed: 0.001, green: 0.001, blue: 0.002),
                     "Colors too dark to carry chromaticity must not produce a guess.")
    }

    // MARK: The picker end to end

    private func makeEditor(imageColor: (Double, Double, Double)) throws
        -> (editor: EditorModel, url: URL) {
        // Write a solid-color PNG of the given color.
        let size = 64
        var pixels = [UInt8](repeating: 255, count: size * size * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = UInt8(imageColor.0 * 255)
            pixels[i + 1] = UInt8(imageColor.1 * 255)
            pixels[i + 2] = UInt8(imageColor.2 * 255)
        }
        let context = CGContext(
            data: &pixels, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let cgImage = context.makeImage()!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pewb-\(UUID().uuidString).png")
        let dest = CGImageDestinationCreateWithURL(
            url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cgImage, nil)
        CGImageDestinationFinalize(dest)

        let catalog = try TestSupport.inMemoryCatalog()
        let entry = TestSupport.makeEntry(fileURL: url)
        try catalog.save(entry)
        let editor = EditorModel(entry: entry, catalog: catalog,
                                 thumbnails: TestSupport.tempThumbnails(), commitDelay: 60)
        return (editor, url)
    }

    func testPickingAWarmGrayNeutralizesIt() throws {
        // The photo is a gray card shot under warm light.
        let (editor, url) = try makeEditor(imageColor: (0.62, 0.52, 0.40))
        defer { try? FileManager.default.removeItem(at: url) }

        editor.canvasPicker = .whiteBalance
        editor.handleCanvasClick(atUnitPoint: CGPoint(x: 0.5, y: 0.5))

        XCTAssertNil(editor.canvasPicker, "A completed pick should end picker mode.")
        XCTAssertLessThan(editor.editStack.whiteBalanceTemp, 6200,
                          "A warm cast must set a warm illuminant estimate.")

        // The corrected render should be far more neutral than the original.
        let corrected = TestSupport.readColor(
            CIImage(cgImage: try XCTUnwrap(editor.displayImage))
        )
        let castBefore = 0.62 - 0.40
        let castAfter = abs(corrected.red - corrected.blue)
        XCTAssertLessThan(castAfter, castBefore / 2,
                          "Picking the neutral should remove most of the cast.")
    }

    func testFilmBasePickRoutesToSampling() throws {
        let (editor, url) = try makeEditor(imageColor: (1.0, 0.61, 0.36))
        defer { try? FileManager.default.removeItem(at: url) }

        editor.editStack.filmNegative.isEnabled = true
        editor.canvasPicker = .filmBase
        editor.handleCanvasClick(atUnitPoint: CGPoint(x: 0.5, y: 0.5))

        XCTAssertNil(editor.canvasPicker)
        XCTAssertTrue(editor.hasSampledBase)
        XCTAssertEqual(editor.editStack.filmNegative.baseColor.red, 1.0, accuracy: 0.05)
        XCTAssertEqual(editor.editStack.filmNegative.baseColor.green, 0.61, accuracy: 0.05)
    }

    func testClickWithNoActivePickerDoesNothing() throws {
        let (editor, url) = try makeEditor(imageColor: (0.5, 0.5, 0.5))
        defer { try? FileManager.default.removeItem(at: url) }

        let before = editor.editStack
        editor.handleCanvasClick(atUnitPoint: CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(editor.editStack, before)
    }

    // MARK: Crop mode

    func testCropModeShowsTheFullFrame() throws {
        let (editor, url) = try makeEditor(imageColor: (0.5, 0.5, 0.5))
        defer { try? FileManager.default.removeItem(at: url) }

        editor.editStack.geometry.cropRect = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let croppedWidth = try XCTUnwrap(editor.displayImage).width

        editor.isCropping = true
        let fullWidth = try XCTUnwrap(editor.displayImage).width

        XCTAssertEqual(fullWidth, croppedWidth * 2,
                       "Crop mode must render the uncropped frame for recomposing.")

        editor.isCropping = false
        XCTAssertEqual(try XCTUnwrap(editor.displayImage).width, croppedWidth,
                       "Leaving crop mode restores the cropped view.")
    }

    // MARK: Histogram clipping

    func testCrushedShadowsTripTheShadowIndicator() {
        let renderer = EditRenderer()
        var stack = EditStack()
        stack.exposure = -6 // crush everything to black

        let source = TestSupport.solidImage(red: 0.3, green: 0.3, blue: 0.3, size: 64)
        let histogram = renderer.histogram(of: renderer.render(source: source, stack: stack))

        XCTAssertTrue(histogram.isClippingShadows)
        XCTAssertFalse(histogram.isClippingHighlights)
    }

    func testBlownHighlightsTripTheHighlightIndicator() {
        let renderer = EditRenderer()
        var stack = EditStack()
        stack.exposure = 6 // blow everything out

        let source = TestSupport.solidImage(red: 0.7, green: 0.7, blue: 0.7, size: 64)
        let histogram = renderer.histogram(of: renderer.render(source: source, stack: stack))

        XCTAssertTrue(histogram.isClippingHighlights)
        XCTAssertFalse(histogram.isClippingShadows)
    }

    func testAWellExposedFrameTripsNeither() {
        let renderer = EditRenderer()
        let source = TestSupport.solidImage(red: 0.45, green: 0.5, blue: 0.55, size: 64)
        let histogram = renderer.histogram(of: renderer.render(source: source, stack: EditStack()))

        XCTAssertFalse(histogram.isClippingShadows)
        XCTAssertFalse(histogram.isClippingHighlights)
    }
}
