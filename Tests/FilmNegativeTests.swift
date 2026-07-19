import CoreImage
import XCTest
@testable import PhotoEditor

/// Verifies the scanned-negative conversion.
///
/// The central test is a round trip: build a synthetic negative from a *known*
/// positive by applying the physical model (invert, then multiply by the film
/// base), then check the converter recovers the original positive. That pins
/// down the math end to end — mask removal, inversion direction, and the color
/// space the work happens in — rather than just asserting "it got brighter."
final class FilmNegativeTests: XCTestCase {
    /// The orange mask used throughout, in gamma-encoded sRGB.
    private let base = FilmColor(red: 1.00, green: 0.61, blue: 0.36)

    /// Synthesizes what a scanner would record for a given positive value:
    /// invert it, then attenuate by the film base.
    private func syntheticNegative(
        positive: (r: Double, g: Double, b: Double)
    ) -> CIImage {
        TestSupport.solidImage(
            red: (1 - positive.r) * base.red,
            green: (1 - positive.g) * base.green,
            blue: (1 - positive.b) * base.blue
        )
    }

    private func settings(_ mutate: (inout FilmNegativeSettings) -> Void = { _ in })
        -> FilmNegativeSettings {
        var settings = FilmNegativeSettings()
        settings.isEnabled = true
        settings.type = .colorNegative
        settings.baseColor = base
        mutate(&settings)
        return settings
    }

    // MARK: Round trip

    func testConversionRecoversTheOriginalPositive() {
        for positive in [(0.25, 0.5, 0.75), (0.5, 0.5, 0.5), (0.8, 0.2, 0.4)] {
            let negative = syntheticNegative(positive: positive)
            let converted = FilmNegativeConverter.convert(negative, settings: settings())
            let result = TestSupport.readColor(converted)

            XCTAssertEqual(result.red, positive.0, accuracy: 0.02,
                           "Red should invert back to the original positive.")
            XCTAssertEqual(result.green, positive.1, accuracy: 0.02,
                           "Green should invert back to the original positive.")
            XCTAssertEqual(result.blue, positive.2, accuracy: 0.02,
                           "Blue should invert back to the original positive.")
        }
    }

    func testFilmBaseBecomesBlack() {
        // Unexposed film base is the most transmissive part of a negative, so
        // it must map to the darkest part of the positive.
        let baseOnly = TestSupport.solidImage(
            red: base.red, green: base.green, blue: base.blue
        )
        let result = TestSupport.readColor(
            FilmNegativeConverter.convert(baseOnly, settings: settings())
        )

        XCTAssertEqual(result.red, 0, accuracy: 0.02)
        XCTAssertEqual(result.green, 0, accuracy: 0.02)
        XCTAssertEqual(result.blue, 0, accuracy: 0.02)
    }

    func testMaskRemovalNeutralizesTheOrangeCast() {
        // A neutral gray subject shot on masked film scans as an orange-tinted
        // negative. After conversion the channels should agree again.
        let negative = syntheticNegative(positive: (0.5, 0.5, 0.5))
        let raw = TestSupport.readColor(negative)
        XCTAssertGreaterThan(raw.red - raw.blue, 0.2,
                             "The synthetic negative should carry an orange cast.")

        let result = TestSupport.readColor(
            FilmNegativeConverter.convert(negative, settings: settings())
        )
        XCTAssertEqual(result.red, result.green, accuracy: 0.02,
                       "Mask removal should leave a neutral subject neutral.")
        XCTAssertEqual(result.green, result.blue, accuracy: 0.02)
    }

    func testDisabledConversionLeavesTheImageUntouched() {
        let negative = syntheticNegative(positive: (0.3, 0.6, 0.9))
        var disabled = settings()
        disabled.isEnabled = false

        let before = TestSupport.readColor(negative)
        let after = TestSupport.readColor(
            FilmNegativeConverter.convert(negative, settings: disabled)
        )
        XCTAssertEqual(after.red, before.red, accuracy: 0.001)
        XCTAssertEqual(after.green, before.green, accuracy: 0.001)
        XCTAssertEqual(after.blue, before.blue, accuracy: 0.001)
    }

    func testDenserNegativeAreasBecomeBrighterPositives() {
        // More silver/dye density == darker on the scan == brighter positive.
        let dense = syntheticNegative(positive: (0.9, 0.9, 0.9))   // dark negative
        let thin = syntheticNegative(positive: (0.1, 0.1, 0.1))    // bright negative

        let denseResult = TestSupport.readColor(
            FilmNegativeConverter.convert(dense, settings: settings())
        )
        let thinResult = TestSupport.readColor(
            FilmNegativeConverter.convert(thin, settings: settings())
        )
        XCTAssertGreaterThan(denseResult.red, thinResult.red)
    }

    func testSlideFilmIsNotInverted() {
        let positive = TestSupport.solidImage(red: 0.8, green: 0.4, blue: 0.2)
        var slide = settings()
        slide.type = .slide
        slide.stockContrast = 0
        slide.stockSaturation = 0

        let result = TestSupport.readColor(
            FilmNegativeConverter.convert(positive, settings: slide)
        )
        XCTAssertEqual(result.red, 0.8, accuracy: 0.02,
                       "Reversal film is already positive; it must not be inverted.")
    }

    func testBlackAndWhiteNegativeComesBackNeutral() {
        let negative = TestSupport.solidImage(red: 0.42, green: 0.40, blue: 0.37)
        var bw = settings()
        bw.type = .blackAndWhiteNegative
        bw.baseColor = FilmColor(red: 0.95, green: 0.95, blue: 0.95)

        let result = TestSupport.readColor(
            FilmNegativeConverter.convert(negative, settings: bw)
        )
        XCTAssertEqual(result.red, result.green, accuracy: 0.01)
        XCTAssertEqual(result.green, result.blue, accuracy: 0.01)
    }

    func testExposureLiftBrightensTheConvertedPositive() {
        let negative = syntheticNegative(positive: (0.4, 0.4, 0.4))
        let normal = TestSupport.readColor(
            FilmNegativeConverter.convert(negative, settings: settings())
        )
        let lifted = TestSupport.readColor(
            FilmNegativeConverter.convert(negative, settings: settings { $0.exposure = 1.0 })
        )
        XCTAssertGreaterThan(lifted.red, normal.red)
    }

    // MARK: Integration with the main render chain

    func testRenderChainInvertsBeforeTheOtherAdjustments() {
        // Raising exposure must brighten the *positive*. If inversion ran after
        // the tonal sliders, a brighter negative would come back darker.
        let renderer = EditRenderer()
        let negative = syntheticNegative(positive: (0.5, 0.5, 0.5))

        var stack = EditStack()
        stack.filmNegative = settings()
        let plain = TestSupport.readColor(renderer.render(source: negative, stack: stack))

        stack.exposure = 1.0
        let brightened = TestSupport.readColor(renderer.render(source: negative, stack: stack))

        XCTAssertGreaterThan(brightened.red, plain.red,
                             "Exposure must act on the converted positive.")
    }

    func testFilmSettingsSurviveACatalogRoundTrip() throws {
        let store = try TestSupport.inMemoryCatalog()
        var entry = TestSupport.makeEntry(fileURL: URL(fileURLWithPath: "/tmp/neg.tif"))
        entry.editStack.filmNegative = settings {
            $0.stockID = "kodak-portra-400"
            $0.stockName = "Kodak Portra 400"
            $0.exposure = 0.35
        }
        try store.save(entry)

        let fetched = try XCTUnwrap(store.entry(id: entry.id))
        XCTAssertEqual(fetched.editStack.filmNegative, entry.editStack.filmNegative)
    }

    func testFilmSettingsDecodeLenientlyRatherThanRevertingWholesale() throws {
        // A film section missing a newer key must keep every key it *does*
        // have. If it threw, EditStack's fallback would swap in disabled
        // defaults and the photo would render as an un-inverted negative.
        let json = """
        {"isEnabled":true,"type":"colorNegative",
         "baseColor":{"red":1.0,"green":0.61,"blue":0.36},
         "channelGains":{"red":1.0,"green":1.0,"blue":1.0},
         "exposure":0.5,"stockContrast":8,"stockSaturation":3}
        """.data(using: .utf8)!

        let settings = try JSONDecoder().decode(FilmNegativeSettings.self, from: json)
        XCTAssertTrue(settings.isEnabled)
        XCTAssertEqual(settings.exposure, 0.5, accuracy: 1e-9)
        XCTAssertEqual(settings.stockContrast, 8, accuracy: 1e-9)
        XCTAssertFalse(settings.isBaseSampled, "A missing flag defaults to false.")
    }

    func testSampledBaseFlagSurvivesReopening() throws {
        let store = try TestSupport.inMemoryCatalog()
        var entry = TestSupport.makeEntry(fileURL: URL(fileURLWithPath: "/tmp/neg.tif"))
        entry.editStack.filmNegative = settings { $0.isBaseSampled = true }
        try store.save(entry)

        let fetched = try XCTUnwrap(store.entry(id: entry.id))
        XCTAssertTrue(fetched.editStack.filmNegative.isBaseSampled,
                      "A sampled base must not report as assumed after a reload.")
    }

    /// Edit stacks written before the film fields existed must still decode —
    /// otherwise upgrading the app would silently drop everyone's edits.
    func testOlderEditStackJSONStillDecodes() throws {
        let legacy = """
        {"exposure":1.5,"contrast":20,"highlights":0,"shadows":0,
         "whiteBalanceTemp":7000,"whiteBalanceTint":-5,"saturation":10,
         "toneCurvePoints":[]}
        """.data(using: .utf8)!

        let stack = try JSONDecoder().decode(EditStack.self, from: legacy)
        XCTAssertEqual(stack.exposure, 1.5, accuracy: 1e-9)
        XCTAssertEqual(stack.whiteBalanceTemp, 7000, accuracy: 1e-9)
        XCTAssertFalse(stack.filmNegative.isEnabled,
                       "A missing film section should default to disabled.")
    }
}
