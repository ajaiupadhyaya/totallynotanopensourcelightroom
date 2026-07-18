import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import PhotoEditor

/// Shared helpers for the catalog/editor tests.
enum TestSupport {
    /// Writes a solid-gray PNG to a temp file and returns its URL.
    static func makeTempPNG(gray: UInt8 = 128, size: Int = 32) throws -> URL {
        let bytesPerPixel = 4
        let rowBytes = size * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: size * rowBytes)
        for i in stride(from: 0, to: pixels.count, by: bytesPerPixel) {
            pixels[i] = gray
            pixels[i + 1] = gray
            pixels[i + 2] = gray
            pixels[i + 3] = 255
        }
        let context = CGContext(
            data: &pixels, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: rowBytes, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        let cgImage = try XCTUnwrap(context?.makeImage())

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("petest-\(UUID().uuidString).png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, cgImage, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    /// Average brightness of a CGImage by box-filtering it down to one pixel.
    static func averageBrightness(_ cgImage: CGImage) -> Double {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (Double(pixel[0]) + Double(pixel[1]) + Double(pixel[2])) / (3.0 * 255.0)
    }

    static func inMemoryCatalog() throws -> CatalogStore {
        try CatalogStore()
    }

    static func tempThumbnails() -> ThumbnailGenerator {
        ThumbnailGenerator(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("petest-thumbs-\(UUID().uuidString)", isDirectory: true)
        )
    }

    static func makeEntry(fileURL: URL, editStack: EditStack = EditStack()) -> CatalogEntry {
        CatalogEntry(
            id: UUID(), fileURL: fileURL, dateImported: Date(),
            editStack: editStack, thumbnailPath: nil
        )
    }
}
