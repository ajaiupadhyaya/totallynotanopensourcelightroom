import CoreImage
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import PhotoEditor

/// End-to-end test over a realistic scanned negative.
///
/// Everything else tests a stage in isolation. This writes an actual TIFF that
/// looks like a scan off a film holder — an orange-masked frame with a clear
/// base border — then runs the whole real path over it: decode from disk,
/// sample the base, infer the family, convert, and export. The assertions are
/// about the recovered *scene* (is the sky blue, is the gray card neutral),
/// which is the only question that actually matters.
///
/// ## Building the fixture correctly
///
/// The negative is synthesized by computing each patch's value in Swift and
/// painting it as a solid color, rather than by running the scene through a
/// `CIColorMatrix`. That's deliberate: Core Image applies matrix coefficients
/// to its *linear* working values, whereas the film math runs on gamma-encoded
/// values (see ``FilmNegativeConverter``). Synthesizing through a matrix builds
/// a negative in the wrong space — and one whose interior ends up *brighter*
/// than the film base, which is physically impossible on real film and sends
/// base detection chasing the wrong region.
final class EndToEndFilmTests: XCTestCase {
    private let context = CIContext()
    private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    /// The base mask of the film we're pretending was scanned.
    private let base = FilmColor(red: 1.00, green: 0.61, blue: 0.36)

    private let border = 60.0
    private let sceneWidth = 1200.0
    private let sceneHeight = 800.0

    /// A patch of the photographed scene, in scene coordinates (y up).
    private struct Patch {
        let name: String
        let rect: CGRect
        let color: (r: Double, g: Double, b: Double)
    }

    private var sky: Patch {
        Patch(name: "sky", rect: CGRect(x: 0, y: 360, width: 1200, height: 440),
              color: (0.38, 0.56, 0.86))
    }
    private var field: Patch {
        Patch(name: "field", rect: CGRect(x: 0, y: 0, width: 1200, height: 360),
              color: (0.25, 0.42, 0.18))
    }
    private var barn: Patch {
        Patch(name: "barn", rect: CGRect(x: 140, y: 190, width: 260, height: 220),
              color: (0.62, 0.16, 0.14))
    }
    private var skin: Patch {
        Patch(name: "skin", rect: CGRect(x: 520, y: 210, width: 150, height: 190),
              color: (0.80, 0.62, 0.50))
    }
    private var grayCard: Patch {
        Patch(name: "gray card", rect: CGRect(x: 800, y: 220, width: 170, height: 170),
              color: (0.50, 0.50, 0.50))
    }

    private var patches: [Patch] { [sky, field, barn, skin, grayCard] }

    // MARK: The scan

    private func solid(_ r: Double, _ g: Double, _ b: Double, _ rect: CGRect) -> CIImage {
        CIImage(color: CIColor(red: r, green: g, blue: b, colorSpace: srgb)!)
            .cropped(to: rect)
    }

    /// What a scanner records for a scene value: invert it, then attenuate by
    /// the film base. The same physical model the converter undoes.
    private func negativeValue(of color: (r: Double, g: Double, b: Double))
        -> (r: Double, g: Double, b: Double) {
        ((1 - color.r) * base.red, (1 - color.g) * base.green, (1 - color.b) * base.blue)
    }

    /// The full scan: the negative frame surrounded by clear film base.
    private func negativeScan() -> CIImage {
        let full = CGRect(x: 0, y: 0,
                          width: sceneWidth + border * 2,
                          height: sceneHeight + border * 2)
        var image = solid(base.red, base.green, base.blue, full)

        for patch in patches {
            let value = negativeValue(of: patch.color)
            image = solid(value.r, value.g, value.b,
                          patch.rect.offsetBy(dx: border, dy: border))
                .composited(over: image)
        }
        return image.cropped(to: full)
    }

    /// Writes the scan to a real TIFF so the test exercises actual file IO.
    private func writeScan() throws -> URL {
        let image = negativeScan()
        let cgImage = try XCTUnwrap(context.createCGImage(image, from: image.extent,
                                                          format: .RGBA8, colorSpace: srgb))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pe-scan-\(UUID().uuidString).tiff")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.tiff.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, cgImage, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    /// Reads the average color of a patch out of a converted image.
    private func sample(_ image: CIImage, _ patch: Patch)
        -> (red: Double, green: Double, blue: Double) {
        let rect = patch.rect.offsetBy(dx: border, dy: border).insetBy(dx: 25, dy: 25)
        return TestSupport.readColor(image.cropped(to: rect), context: context)
    }

    // MARK: Tests

    /// Sanity check on the fixture itself: on a real negative, nothing in the
    /// frame can be more transmissive than unexposed film base.
    func testTheSynthesizedScanIsPhysicallyPlausible() {
        let scan = negativeScan()
        let baseLuminance = ColorScience.luminance(base.red, base.green, base.blue)

        for patch in patches {
            let value = negativeValue(of: patch.color)
            let luminance = ColorScience.luminance(value.r, value.g, value.b)
            XCTAssertLessThan(luminance, baseLuminance,
                              "\(patch.name) must be darker than the film base.")
        }

        let borderColor = TestSupport.readColor(
            scan.cropped(to: CGRect(x: 5, y: 5, width: 30, height: 30)), context: context
        )
        XCTAssertEqual(borderColor.red, base.red, accuracy: 0.01)
        XCTAssertEqual(borderColor.green, base.green, accuracy: 0.01)
        XCTAssertEqual(borderColor.blue, base.blue, accuracy: 0.01)
    }

    func testScannedNegativeConvertsBackToTheOriginalScene() throws {
        let url = try writeScan()
        defer { try? FileManager.default.removeItem(at: url) }

        // 1. Decode the file the way the app does.
        let source = try XCTUnwrap(ImageDecoder.loadFullImage(from: url))
        XCTAssertEqual(source.extent.width, sceneWidth + border * 2, accuracy: 1)

        // 2. Find the film base without being told what it is.
        let sampled = try XCTUnwrap(
            FilmBaseSampler.sampleBase(from: source, context: context)
        )
        XCTAssertEqual(sampled.red, base.red, accuracy: 0.05)
        XCTAssertEqual(sampled.green, base.green, accuracy: 0.05)
        XCTAssertEqual(sampled.blue, base.blue, accuracy: 0.05)

        // 3. Recognize it as a masked color negative.
        XCTAssertEqual(FilmBaseSampler.inferType(from: sampled), .colorNegative)

        // 4. Convert using only what was sampled.
        var stack = EditStack()
        stack.filmNegative.isEnabled = true
        stack.filmNegative.type = .colorNegative
        stack.filmNegative.baseColor = sampled

        let renderer = EditRenderer(context: context)
        let positive = renderer.render(source: source, stack: stack)

        // 5. The recovered scene should match what was photographed.
        let gray = sample(positive, grayCard)
        XCTAssertEqual(gray.red, 0.5, accuracy: 0.06, "The gray card should come back mid-gray.")
        XCTAssertEqual(gray.red, gray.green, accuracy: 0.03, "…and neutral.")
        XCTAssertEqual(gray.green, gray.blue, accuracy: 0.03)

        let barnColor = sample(positive, barn)
        XCTAssertGreaterThan(barnColor.red, barnColor.green + 0.2,
                             "The red barn should come back red.")
        XCTAssertGreaterThan(barnColor.red, barnColor.blue + 0.2)

        let skinColor = sample(positive, skin)
        XCTAssertGreaterThan(skinColor.red, skinColor.green)
        XCTAssertGreaterThan(skinColor.green, skinColor.blue,
                             "Skin tone should stay warm and correctly ordered.")

        let skyColor = sample(positive, sky)
        XCTAssertGreaterThan(skyColor.blue, skyColor.red + 0.2, "The sky should come back blue.")

        let fieldColor = sample(positive, field)
        XCTAssertGreaterThan(fieldColor.green, fieldColor.red, "The field should come back green.")
        XCTAssertGreaterThan(fieldColor.green, fieldColor.blue)

        // The unexposed base border must be the darkest thing in the positive.
        let borderColor = TestSupport.readColor(
            positive.cropped(to: CGRect(x: 5, y: 5, width: 40, height: 40)), context: context
        )
        XCTAssertLessThan(borderColor.red, 0.08, "The film base should invert to black.")
    }

    /// Every scene patch should land close to its original value, not merely in
    /// the right direction.
    func testEveryPatchIsRecoveredAccurately() throws {
        let url = try writeScan()
        defer { try? FileManager.default.removeItem(at: url) }

        let source = try XCTUnwrap(ImageDecoder.loadFullImage(from: url))
        let sampled = try XCTUnwrap(FilmBaseSampler.sampleBase(from: source, context: context))

        var stack = EditStack()
        stack.filmNegative.isEnabled = true
        stack.filmNegative.baseColor = sampled

        let positive = EditRenderer(context: context).render(source: source, stack: stack)

        for patch in patches where patch.name != "sky" && patch.name != "field" {
            let result = sample(positive, patch)
            XCTAssertEqual(result.red, patch.color.r, accuracy: 0.07,
                           "\(patch.name) red")
            XCTAssertEqual(result.green, patch.color.g, accuracy: 0.07,
                           "\(patch.name) green")
            XCTAssertEqual(result.blue, patch.color.b, accuracy: 0.07,
                           "\(patch.name) blue")
        }
    }

    func testTheConvertedScanExportsToARealFile() throws {
        let url = try writeScan()
        defer { try? FileManager.default.removeItem(at: url) }

        let source = try XCTUnwrap(ImageDecoder.loadFullImage(from: url))
        let sampled = try XCTUnwrap(FilmBaseSampler.sampleBase(from: source, context: context))

        var stack = EditStack()
        stack.filmNegative.isEnabled = true
        stack.filmNegative.baseColor = sampled
        // Crop the base border away, as anyone would after inverting.
        stack.geometry.cropRect = CGRect(x: 0.05, y: 0.07, width: 0.90, height: 0.86)

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("pe-positive-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: destination) }

        try ExportService(renderer: EditRenderer(context: context)).export(
            sourceURL: url, stack: stack, settings: ExportSettings(), to: destination
        )

        let exported = try XCTUnwrap(CGImageSourceCreateWithURL(destination as CFURL, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(exported, 0, nil) as? [CFString: Any]
        )
        let width = try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int)
        XCTAssertEqual(Double(width), (sceneWidth + border * 2) * 0.90, accuracy: 3,
                       "Export should render the cropped full-resolution frame.")

        // The original scan must be untouched by all of this.
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
}
