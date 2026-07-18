import CoreImage
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import PhotoEditor

/// Exercises the full Phase 1 loop through ``EditorModel``: import a real image
/// file from disk, then confirm that mutating the edit stack actually changes
/// the rendered preview. This is the end-to-end proof that sliders drive Core
/// Image rendering — the whole point of Phase 1.
final class EditorModelTests: XCTestCase {
    /// Writes a solid mid-gray PNG to a temp file and returns its URL.
    private func makeTestPNG(gray: UInt8 = 128, size: Int = 32) throws -> URL {
        let bytesPerPixel = 4
        let rowBytes = size * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: size * rowBytes)
        for i in stride(from: 0, to: pixels.count, by: bytesPerPixel) {
            pixels[i] = gray       // R
            pixels[i + 1] = gray   // G
            pixels[i + 2] = gray   // B
            pixels[i + 3] = 255    // A
        }

        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: &pixels,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: rowBytes,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        let cgImage = try XCTUnwrap(ctx?.makeImage())

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("phototest-\(UUID().uuidString).png")
        let dest = try XCTUnwrap(
            CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(dest, cgImage, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    /// Average brightness of a CGImage by box-filtering it down to one pixel.
    private func averageBrightness(_ cg: CGImage) -> Double {
        var pixel = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (Double(pixel[0]) + Double(pixel[1]) + Double(pixel[2])) / (3.0 * 255.0)
    }

    func testImportProducesPreview() throws {
        let url = try makeTestPNG()
        defer { try? FileManager.default.removeItem(at: url) }

        let model = EditorModel()
        XCTAssertFalse(model.hasImage)

        model.importImage(from: url)

        XCTAssertTrue(model.hasImage)
        XCTAssertNotNil(model.displayImage)
        XCTAssertEqual(model.fileName, url.lastPathComponent)
    }

    func testExposureSliderBrightensPreview() throws {
        let url = try makeTestPNG()
        defer { try? FileManager.default.removeItem(at: url) }

        let model = EditorModel()
        model.importImage(from: url)
        let baseImage = try XCTUnwrap(model.displayImage)
        let baseBrightness = averageBrightness(baseImage)

        // Move the exposure "slider".
        model.editStack.exposure = 2.0

        let brightenedImage = try XCTUnwrap(model.displayImage)
        let brightenedBrightness = averageBrightness(brightenedImage)

        XCTAssertGreaterThan(brightenedBrightness, baseBrightness,
                             "Raising exposure should brighten the rendered preview.")
    }

    func testResetRestoresOriginalPreview() throws {
        let url = try makeTestPNG()
        defer { try? FileManager.default.removeItem(at: url) }

        let model = EditorModel()
        model.importImage(from: url)
        let originalBrightness = averageBrightness(try XCTUnwrap(model.displayImage))

        model.editStack.exposure = -2.0
        let darkenedBrightness = averageBrightness(try XCTUnwrap(model.displayImage))
        XCTAssertLessThan(darkenedBrightness, originalBrightness)

        model.editStack = EditStack() // reset
        let restoredBrightness = averageBrightness(try XCTUnwrap(model.displayImage))
        XCTAssertEqual(restoredBrightness, originalBrightness, accuracy: 0.01)
    }
}
