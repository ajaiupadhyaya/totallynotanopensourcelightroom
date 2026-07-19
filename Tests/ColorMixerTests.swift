import CoreImage
import XCTest
@testable import PhotoEditor

/// Verifies the color LUT: hue-band mixer, black-and-white treatment,
/// three-way grading, and per-channel curves.
final class ColorMixerTests: XCTestCase {
    private let renderer = EditRenderer()

    private func render(_ red: Double, _ green: Double, _ blue: Double,
                        _ mutate: (inout EditStack) -> Void)
        -> (red: Double, green: Double, blue: Double) {
        var stack = EditStack()
        mutate(&stack)
        let source = TestSupport.solidImage(red: red, green: green, blue: blue, size: 32)
        return TestSupport.readColor(renderer.render(source: source, stack: stack))
    }

    // MARK: Band weighting

    func testBandWeightsSumToOne() {
        for hue in stride(from: 0.0, to: 360.0, by: 7.0) {
            let weights = ColorCubeBuilder.bandWeights(for: hue)
            XCTAssertEqual(weights.reduce(0, +), 1.0, accuracy: 1e-9,
                           "Weights must be normalized at hue \(hue).")
        }
    }

    func testABandCenterIsDominatedByItsOwnBand() {
        for (index, band) in HueBand.allCases.enumerated() {
            let weights = ColorCubeBuilder.bandWeights(for: band.centerHue)
            let winner = weights.firstIndex(of: weights.max() ?? 0)
            XCTAssertEqual(winner, index,
                           "\(band.displayName)'s center should belong to \(band.displayName).")
        }
    }

    func testHueDistanceWrapsAroundTheColorWheel() {
        // Red is at 0 degrees, so 355 is 10 away -- not 355.
        XCTAssertEqual(ColorScience.hueDistance(355, 5), 10, accuracy: 1e-9)
        XCTAssertEqual(ColorScience.hueDistance(10, 350), 20, accuracy: 1e-9)
        XCTAssertEqual(ColorScience.hueDistance(0, 180), 180, accuracy: 1e-9)
    }

    func testHSLRoundTrips() {
        for (r, g, b) in [(0.8, 0.2, 0.3), (0.1, 0.6, 0.9), (0.5, 0.5, 0.5), (1.0, 1.0, 0.0)] {
            let hsl = ColorScience.rgbToHSL(r, g, b)
            let rgb = ColorScience.hslToRGB(hsl.hue, hsl.saturation, hsl.lightness)
            XCTAssertEqual(rgb.red, r, accuracy: 1e-6)
            XCTAssertEqual(rgb.green, g, accuracy: 1e-6)
            XCTAssertEqual(rgb.blue, b, accuracy: 1e-6)
        }
    }

    // MARK: Mixer

    func testNeutralSettingsProduceNoFilterAtAll() {
        XCTAssertNil(ColorCubeBuilder.makeFilter(for: ColorSettings()),
                     "Neutral color settings should skip the LUT pass entirely.")
    }

    func testSaturationOfOneBandLeavesOtherBandsAlone() {
        // Drop red saturation to zero; a blue subject must be untouched.
        let mutate: (inout EditStack) -> Void = {
            $0.color.mixer[.red].saturation = -100
        }

        let red = render(0.8, 0.15, 0.15, mutate)
        let blue = render(0.15, 0.2, 0.8, mutate)
        let bluePlain = render(0.15, 0.2, 0.8) { _ in }

        XCTAssertLessThan(red.red - red.blue, 0.3,
                          "The red band should have lost its saturation.")
        XCTAssertEqual(blue.blue, bluePlain.blue, accuracy: 0.02,
                       "Adjusting red must not touch blue.")
        XCTAssertEqual(blue.red, bluePlain.red, accuracy: 0.02)
    }

    func testLuminanceOfOneBandBrightensThatBand() {
        let plain = render(0.15, 0.2, 0.8) { _ in }
        let lifted = render(0.15, 0.2, 0.8) { $0.color.mixer[.blue].luminance = 100 }

        XCTAssertGreaterThan(
            ColorScience.luminance(lifted.red, lifted.green, lifted.blue),
            ColorScience.luminance(plain.red, plain.green, plain.blue)
        )
    }

    func testHueShiftMovesAColorAroundTheWheel() {
        let plain = render(0.8, 0.15, 0.15) { _ in }
        let shifted = render(0.8, 0.15, 0.15) { $0.color.mixer[.red].hue = 100 }

        let plainHue = ColorScience.rgbToHSL(plain.red, plain.green, plain.blue).hue
        let shiftedHue = ColorScience.rgbToHSL(shifted.red, shifted.green, shifted.blue).hue
        XCTAssertGreaterThan(ColorScience.hueDistance(plainHue, shiftedHue), 5)
    }

    func testMixerLeavesGrayAlone() {
        // A gray pixel has no hue to assign to a band, so no amount of mixer
        // adjustment should tint it.
        let result = render(0.5, 0.5, 0.5) {
            $0.color.mixer[.red].saturation = 100
            $0.color.mixer[.blue].hue = 100
            $0.color.mixer[.green].luminance = -100
        }
        XCTAssertEqual(result.red, 0.5, accuracy: 0.02)
        XCTAssertEqual(result.green, 0.5, accuracy: 0.02)
        XCTAssertEqual(result.blue, 0.5, accuracy: 0.02)
    }

    // MARK: Black and white

    func testBlackAndWhiteTreatmentRemovesAllColor() {
        let result = render(0.8, 0.2, 0.3) { $0.color.treatment = .blackAndWhite }
        XCTAssertEqual(result.red, result.green, accuracy: 0.02)
        XCTAssertEqual(result.green, result.blue, accuracy: 0.02)
    }

    func testBlackAndWhiteMixDarkensTheChosenBand() {
        // The classic red filter: push the blue band down and a blue sky goes
        // dark, while a red subject is unaffected.
        let skyPlain = render(0.2, 0.35, 0.8) { $0.color.treatment = .blackAndWhite }
        let skyFiltered = render(0.2, 0.35, 0.8) {
            $0.color.treatment = .blackAndWhite
            $0.color.mixer.setBlackAndWhiteWeight(-100, for: .blue)
        }
        XCTAssertLessThan(skyFiltered.red, skyPlain.red)

        let subjectPlain = render(0.8, 0.2, 0.2) { $0.color.treatment = .blackAndWhite }
        let subjectFiltered = render(0.8, 0.2, 0.2) {
            $0.color.treatment = .blackAndWhite
            $0.color.mixer.setBlackAndWhiteWeight(-100, for: .blue)
        }
        XCTAssertEqual(subjectFiltered.red, subjectPlain.red, accuracy: 0.06,
                       "A red subject shouldn't move when the blue band does.")
    }

    // MARK: Color grading

    func testShadowTintAffectsShadowsMoreThanHighlights() {
        // Push a strong blue into the shadows.
        let mutate: (inout EditStack) -> Void = {
            $0.color.grading.shadows.hue = 240
            $0.color.grading.shadows.saturation = 100
        }

        let darkPlain = render(0.12, 0.12, 0.12) { _ in }
        let darkGraded = render(0.12, 0.12, 0.12, mutate)
        let brightPlain = render(0.9, 0.9, 0.9) { _ in }
        let brightGraded = render(0.9, 0.9, 0.9, mutate)

        let darkShift = (darkGraded.blue - darkGraded.red) - (darkPlain.blue - darkPlain.red)
        let brightShift = (brightGraded.blue - brightGraded.red) - (brightPlain.blue - brightPlain.red)

        XCTAssertGreaterThan(darkShift, 0.02, "Shadows should pick up the blue tint.")
        XCTAssertGreaterThan(darkShift, brightShift,
                             "Shadows should be tinted more than highlights.")
    }

    func testHighlightTintAffectsHighlightsMoreThanShadows() {
        let mutate: (inout EditStack) -> Void = {
            $0.color.grading.highlights.hue = 40
            $0.color.grading.highlights.saturation = 100
        }

        let darkPlain = render(0.12, 0.12, 0.12) { _ in }
        let darkGraded = render(0.12, 0.12, 0.12, mutate)
        let brightPlain = render(0.85, 0.85, 0.85) { _ in }
        let brightGraded = render(0.85, 0.85, 0.85, mutate)

        let darkShift = (darkGraded.red - darkGraded.blue) - (darkPlain.red - darkPlain.blue)
        let brightShift = (brightGraded.red - brightGraded.blue) - (brightPlain.red - brightPlain.blue)

        XCTAssertGreaterThan(brightShift, darkShift)
    }

    func testZoneWeightsAlwaysSumToOne() {
        let grading = ColorGrading()
        for luminance in stride(from: 0.0, through: 1.0, by: 0.05) {
            let weights = ColorCubeBuilder.zoneWeights(luminance: luminance, grading: grading)
            XCTAssertEqual(weights.shadows + weights.midtones + weights.highlights,
                           1.0, accuracy: 1e-9)
        }
    }

    func testZeroSaturationGradingIsANoOp() {
        // Hue alone must do nothing -- otherwise moving the hue wheel with
        // saturation at zero would surprise the user.
        let plain = render(0.5, 0.45, 0.4) { _ in }
        let hueOnly = render(0.5, 0.45, 0.4) {
            $0.color.grading.shadows.hue = 200
            $0.color.grading.highlights.hue = 90
        }
        XCTAssertEqual(hueOnly.red, plain.red, accuracy: 0.01)
        XCTAssertEqual(hueOnly.blue, plain.blue, accuracy: 0.01)
    }

    // MARK: Per-channel curves

    func testRedCurveOnlyAffectsRed() {
        let plain = render(0.5, 0.5, 0.5) { _ in }
        let curved = render(0.5, 0.5, 0.5) {
            $0.color.channelCurves.red = [
                CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0.8), CGPoint(x: 1, y: 1),
            ]
        }

        XCTAssertGreaterThan(curved.red, plain.red + 0.1)
        XCTAssertEqual(curved.green, plain.green, accuracy: 0.02)
        XCTAssertEqual(curved.blue, plain.blue, accuracy: 0.02)
    }

    func testEmptyCurveIsTheIdentity() {
        for x in stride(from: 0.0, through: 1.0, by: 0.1) {
            XCTAssertEqual(ColorScience.evaluateCurve([], at: x), x, accuracy: 1e-9)
        }
    }

    func testCurveEvaluationPassesThroughItsControlPoints() {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0.75), CGPoint(x: 1, y: 1)]
        XCTAssertEqual(ColorScience.evaluateCurve(points, at: 0), 0, accuracy: 1e-6)
        XCTAssertEqual(ColorScience.evaluateCurve(points, at: 0.5), 0.75, accuracy: 1e-6)
        XCTAssertEqual(ColorScience.evaluateCurve(points, at: 1), 1, accuracy: 1e-6)
    }

    // MARK: Caching and persistence

    func testCacheReturnsTheSameFilterForUnchangedSettings() {
        let cache = ColorCubeCache()
        var settings = ColorSettings()
        settings.mixer[.red].saturation = 50

        let first = cache.filter(for: settings)
        let second = cache.filter(for: settings)
        XCTAssertNotNil(first)
        XCTAssertTrue(first === second,
                      "An unchanged settings value should reuse the built LUT.")

        settings.mixer[.red].saturation = 60
        XCTAssertFalse(first === cache.filter(for: settings),
                       "Changed settings must rebuild the LUT.")
    }

    func testColorSettingsSurviveACatalogRoundTrip() throws {
        let store = try TestSupport.inMemoryCatalog()
        var entry = TestSupport.makeEntry(fileURL: URL(fileURLWithPath: "/tmp/a.jpg"))
        entry.editStack.color.treatment = .blackAndWhite
        entry.editStack.color.mixer[.orange].luminance = 42
        entry.editStack.color.mixer.setBlackAndWhiteWeight(-30, for: .blue)
        entry.editStack.color.grading.shadows.hue = 210
        entry.editStack.color.grading.shadows.saturation = 25
        entry.editStack.color.grading.balance = -15
        entry.editStack.color.channelCurves.green = [
            CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1),
        ]
        try store.save(entry)

        let fetched = try XCTUnwrap(store.entry(id: entry.id))
        XCTAssertEqual(fetched.editStack.color, entry.editStack.color)
    }

    func testShortBandArraysArePaddedRatherThanCrashing() throws {
        // A stack written when the band list was shorter must not produce an
        // out-of-range subscript in the renderer.
        let json = """
        {"treatment":"color","mixer":{"bands":[],"blackAndWhiteMix":[1,2]},
         "grading":{},"channelCurves":{}}
        """.data(using: .utf8)!

        let settings = try JSONDecoder().decode(ColorSettings.self, from: json)
        XCTAssertEqual(settings.mixer.bands.count, HueBand.allCases.count)
        XCTAssertEqual(settings.mixer.blackAndWhiteMix.count, HueBand.allCases.count)
        XCTAssertEqual(settings.mixer.blackAndWhiteWeight(.red), 1)
        XCTAssertEqual(settings.mixer.blackAndWhiteWeight(.magenta), 0)
    }
}
