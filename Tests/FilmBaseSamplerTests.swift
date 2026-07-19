import CoreImage
import XCTest
@testable import PhotoEditor

/// Verifies film-base sampling and stock matching.
final class FilmBaseSamplerTests: XCTestCase {
    private let mask = FilmColor(red: 1.00, green: 0.61, blue: 0.36)

    /// Builds a scan-like image: a dim image area with a bright film-base
    /// border around it, the way a scanned frame with rebate actually looks.
    private func scanWithBorder(border: FilmColor, image: FilmColor) -> CIImage {
        let borderLayer = TestSupport.solidImage(
            red: border.red, green: border.green, blue: border.blue, size: 200
        )
        let imageLayer = TestSupport
            .solidImage(red: image.red, green: image.green, blue: image.blue, size: 120)
            .transformed(by: CGAffineTransform(translationX: 40, y: 40))
        return imageLayer.composited(over: borderLayer)
    }

    func testSamplesTheBrightBaseBorderNotTheImageArea() throws {
        let scan = scanWithBorder(border: mask,
                                  image: FilmColor(red: 0.25, green: 0.16, blue: 0.10))
        let sampled = try XCTUnwrap(FilmBaseSampler.sampleBase(from: scan))

        XCTAssertEqual(sampled.red, mask.red, accuracy: 0.05)
        XCTAssertEqual(sampled.green, mask.green, accuracy: 0.05)
        XCTAssertEqual(sampled.blue, mask.blue, accuracy: 0.05)
    }

    func testSampleAverageReadsARegion() throws {
        let scan = scanWithBorder(border: mask,
                                  image: FilmColor(red: 0.2, green: 0.2, blue: 0.2))
        // A rect wholly inside the image area should read the image, not the base.
        let sampled = try XCTUnwrap(FilmBaseSampler.sampleAverage(
            from: scan, in: CGRect(x: 80, y: 80, width: 20, height: 20)
        ))
        XCTAssertEqual(sampled.red, 0.2, accuracy: 0.03)
        XCTAssertEqual(sampled.green, 0.2, accuracy: 0.03)
    }

    func testNormalizationIgnoresScannerBrightness() {
        // The same stock scanned twice at different brightnesses should match.
        let bright = FilmColor(red: 1.00, green: 0.61, blue: 0.36)
        let dim = FilmColor(red: 0.60, green: 0.366, blue: 0.216)
        XCTAssertEqual(bright.chromaticityDistance(to: dim), 0, accuracy: 1e-6,
                       "Matching must compare hue, not exposure.")
    }

    func testRankingPutsTheClosestStockFirst() throws {
        let ektar = try XCTUnwrap(FilmStock.builtIn(id: "kodak-ektar-100"))
        let ranked = FilmBaseSampler.rankStocks(matching: ektar.baseColor,
                                                type: .colorNegative)

        XCTAssertEqual(ranked.first?.stock.id, "kodak-ektar-100")
        XCTAssertEqual(ranked.first?.distance ?? 1, 0, accuracy: 1e-9)
        XCTAssertEqual(ranked.first?.confidence ?? 0, 1.0, accuracy: 1e-9)
        // Sorted ascending by distance.
        XCTAssertEqual(ranked.map(\.distance), ranked.map(\.distance).sorted())
    }

    func testRankingCanBeFilteredByFamily() {
        let ranked = FilmBaseSampler.rankStocks(matching: mask, type: .blackAndWhiteNegative)
        XCTAssertFalse(ranked.isEmpty)
        XCTAssertTrue(ranked.allSatisfy { $0.stock.type == .blackAndWhiteNegative })
    }

    func testFamilyInferenceSeparatesMaskedFromClearBases() {
        // This is the part of matching that is actually dependable.
        XCTAssertEqual(FilmBaseSampler.inferType(from: mask), .colorNegative)
        XCTAssertEqual(
            FilmBaseSampler.inferType(from: FilmColor(red: 0.98, green: 0.97, blue: 0.95)),
            .blackAndWhiteNegative
        )
    }

    func testSampledBaseFedBackThroughConversionNeutralizesTheScan() throws {
        // The whole point of sampling: sample the base off a real scan, feed it
        // straight into the converter, and a neutral subject comes back neutral.
        let subject = FilmColor(red: 0.5, green: 0.305, blue: 0.18) // == 0.5 * mask
        let scan = scanWithBorder(border: mask, image: subject)
        let sampled = try XCTUnwrap(FilmBaseSampler.sampleBase(from: scan))

        var settings = FilmNegativeSettings()
        settings.isEnabled = true
        settings.type = .colorNegative
        settings.baseColor = sampled

        let converted = FilmNegativeConverter.convert(
            TestSupport.solidImage(red: subject.red, green: subject.green, blue: subject.blue),
            settings: settings
        )
        let result = TestSupport.readColor(converted)
        XCTAssertEqual(result.red, result.green, accuracy: 0.03)
        XCTAssertEqual(result.green, result.blue, accuracy: 0.03)
        XCTAssertEqual(result.red, 0.5, accuracy: 0.05)
    }

    func testEveryBuiltInStockHasAUniqueID() {
        let ids = FilmStock.builtIn.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }
}
