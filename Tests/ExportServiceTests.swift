import CoreImage
import ImageIO
import XCTest
@testable import PhotoEditor

/// Verifies that export renders from the full-resolution original (not the
/// downsampled preview), honors format/size settings, embeds a color profile,
/// and never modifies the source file.
final class ExportServiceTests: XCTestCase {
    private let service = ExportService()

    private func tempURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("peexport-\(UUID().uuidString).\(ext)")
    }

    func testExportsAtFullResolutionNotPreviewSize() throws {
        // 2400px source: larger than the 1600px preview cap, so if export
        // rendered from the preview the output would come back at 1600.
        let source = try TestSupport.makeTempPNG(gray: 120, size: 2400)
        defer { try? FileManager.default.removeItem(at: source) }
        let destination = tempURL("jpg")
        defer { try? FileManager.default.removeItem(at: destination) }

        try service.export(sourceURL: source, stack: EditStack(),
                           settings: ExportSettings(), to: destination)

        let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(destination as CFURL, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
        )
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 2400,
                       "Export must render the full-resolution original.")
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 2400)
    }

    func testExportAppliesTheEditStack() throws {
        let source = try TestSupport.makeTempPNG(gray: 100, size: 64)
        defer { try? FileManager.default.removeItem(at: source) }
        let plain = tempURL("png")
        let brightened = tempURL("png")
        defer {
            try? FileManager.default.removeItem(at: plain)
            try? FileManager.default.removeItem(at: brightened)
        }

        var settings = ExportSettings()
        settings.format = .png

        try service.export(sourceURL: source, stack: EditStack(),
                           settings: settings, to: plain)
        var stack = EditStack()
        stack.exposure = 2.0
        try service.export(sourceURL: source, stack: stack,
                           settings: settings, to: brightened)

        let plainBrightness = TestSupport.averageBrightness(try loadCGImage(plain))
        let brightBrightness = TestSupport.averageBrightness(try loadCGImage(brightened))
        XCTAssertGreaterThan(brightBrightness, plainBrightness,
                             "The exported file should reflect the edit stack.")
    }

    func testMaxDimensionResizesButNeverUpscales() throws {
        let source = try TestSupport.makeTempPNG(gray: 128, size: 800)
        defer { try? FileManager.default.removeItem(at: source) }

        let shrunk = tempURL("png")
        let untouched = tempURL("png")
        defer {
            try? FileManager.default.removeItem(at: shrunk)
            try? FileManager.default.removeItem(at: untouched)
        }

        var settings = ExportSettings()
        settings.format = .png
        settings.maxDimension = 400
        try service.export(sourceURL: source, stack: EditStack(),
                           settings: settings, to: shrunk)
        XCTAssertEqual(try loadCGImage(shrunk).width, 400)

        settings.maxDimension = 4000 // larger than the source
        try service.export(sourceURL: source, stack: EditStack(),
                           settings: settings, to: untouched)
        XCTAssertEqual(try loadCGImage(untouched).width, 800,
                       "Export should never upscale beyond the original.")
    }

    func testEmbedsTheChosenColorProfile() throws {
        let source = try TestSupport.makeTempPNG(gray: 128, size: 64)
        defer { try? FileManager.default.removeItem(at: source) }
        let destination = tempURL("jpg")
        defer { try? FileManager.default.removeItem(at: destination) }

        var settings = ExportSettings()
        settings.colorProfile = .displayP3
        try service.export(sourceURL: source, stack: EditStack(),
                           settings: settings, to: destination)

        let cgImage = try loadCGImage(destination)
        let name = try XCTUnwrap(cgImage.colorSpace?.name) as String
        XCTAssertTrue(name.contains("P3"),
                      "Expected a Display P3 profile, got \(name).")
    }

    func testOriginalFileIsNeverModified() throws {
        let source = try TestSupport.makeTempPNG(gray: 90, size: 128)
        defer { try? FileManager.default.removeItem(at: source) }
        let before = try Data(contentsOf: source)

        let destination = tempURL("jpg")
        defer { try? FileManager.default.removeItem(at: destination) }
        var stack = EditStack()
        stack.exposure = 1.5
        stack.saturation = 60
        try service.export(sourceURL: source, stack: stack,
                           settings: ExportSettings(), to: destination)

        XCTAssertEqual(try Data(contentsOf: source), before,
                       "Export must never write back to the original.")
    }

    func testEveryFormatEncodes() throws {
        let source = try TestSupport.makeTempPNG(gray: 128, size: 64)
        defer { try? FileManager.default.removeItem(at: source) }

        for format in ExportSettings.Format.allCases {
            let destination = tempURL(format.fileExtension)
            defer { try? FileManager.default.removeItem(at: destination) }
            var settings = ExportSettings()
            settings.format = format
            try service.export(sourceURL: source, stack: EditStack(),
                               settings: settings, to: destination)
            let size = try FileManager.default
                .attributesOfItem(atPath: destination.path)[.size] as? Int ?? 0
            XCTAssertGreaterThan(size, 0, "\(format.displayName) produced an empty file.")
        }
    }

    func testSuggestedFileNameUsesTheFormatExtension() {
        var settings = ExportSettings()
        settings.format = .tiff
        XCTAssertEqual(
            ExportService.suggestedFileName(
                for: URL(fileURLWithPath: "/photos/IMG_0042.CR3"), settings: settings
            ),
            "IMG_0042.tiff"
        )
    }

    func testRAWDetectionByFileType() {
        XCTAssertTrue(ImageDecoder.isRAW(URL(fileURLWithPath: "/a/shot.dng")))
        XCTAssertTrue(ImageDecoder.isRAW(URL(fileURLWithPath: "/a/shot.CR2")))
        XCTAssertFalse(ImageDecoder.isRAW(URL(fileURLWithPath: "/a/scan.tif")))
        XCTAssertFalse(ImageDecoder.isRAW(URL(fileURLWithPath: "/a/scan.jpg")))
    }

    private func loadCGImage(_ url: URL) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }
}
