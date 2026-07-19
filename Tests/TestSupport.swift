import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
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

    // MARK: Color helpers
    //
    // Film math happens on gamma-encoded sRGB values, so these deliberately
    // build and read back images in sRGB rather than the linear working space.
    // Sampling in the wrong space is exactly the bug these tests exist to catch.

    static var sRGBSpace: CGColorSpace {
        CGColorSpace(name: CGColorSpace.sRGB)!
    }

    /// A solid-color image filling `rect`, whose sRGB-encoded components are
    /// the values given.
    ///
    /// Note this crops an *infinite* color image, so `rect` may be anywhere and
    /// any size. Cropping an already-finite image can only ever shrink it —
    /// which is a very easy way to write a test that silently measures a 1×1
    /// image instead of the one it meant to.
    static func solidImage(
        red: Double, green: Double, blue: Double, in rect: CGRect
    ) -> CIImage {
        let color = CIColor(red: red, green: green, blue: blue, colorSpace: sRGBSpace)!
        return CIImage(color: color).cropped(to: rect)
    }

    /// A square solid-color image anchored at the origin.
    static func solidImage(
        red: Double, green: Double, blue: Double, size: CGFloat = 32
    ) -> CIImage {
        solidImage(red: red, green: green, blue: blue,
                   in: CGRect(x: 0, y: 0, width: size, height: size))
    }

    /// Reads the **average** sRGB-encoded color over an image's whole extent.
    ///
    /// Genuinely averaging (rather than sampling the center pixel) matters for
    /// any region that isn't uniform — an edge, a gradient, a grain overlay.
    /// Center sampling silently answers a different question than the call site
    /// is asking.
    static func readColor(
        _ image: CIImage, context: CIContext = CIContext()
    ) -> (red: Double, green: Double, blue: Double) {
        let extent = image.extent
        guard !extent.isInfinite, extent.width >= 1, extent.height >= 1 else {
            return (0, 0, 0)
        }

        let average = CIFilter.areaAverage()
        average.inputImage = image
        average.extent = extent
        guard let output = average.outputImage else { return (0, 0, 0) }

        var buffer = [Float](repeating: 0, count: 4)
        context.render(
            output,
            toBitmap: &buffer,
            rowBytes: 4 * MemoryLayout<Float>.stride,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBAf,
            colorSpace: sRGBSpace
        )
        return (Double(buffer[0]), Double(buffer[1]), Double(buffer[2]))
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
