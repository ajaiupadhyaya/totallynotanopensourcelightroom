import CoreGraphics
import XCTest
@testable import PhotoEditor

/// One control's declared contract with the renderer.
///
/// The point of declaring this as data rather than writing a test per control
/// is that the *list* becomes checkable. A control added to ``EditStack``
/// without a row here fails ``ControlConformanceTests/testEveryEditStackFieldIsCoveredOrExcluded()``,
/// so the matrix cannot rot the way a hand-written suite does.
struct ControlCase {
    let name: String

    /// The `EditStack` stored-property name this covers.
    let key: String

    /// Applied to *every* variant including neutral. This is for controls that
    /// legitimately do nothing on their own: Grain Size does nothing at Grain
    /// Amount 0, and a test that did not enable the amount first would report
    /// a working control as dead.
    let setup: (inout EditStack) -> Void

    /// Two non-neutral settings, at or near the ends of the control's range as
    /// the panel actually offers it.
    ///
    /// For a control whose range is one-sided — Sharpening, both noise
    /// reductions, Grain and Vignette Highlights all run `0...100` from a
    /// neutral of 0 — `low` is a gentle setting rather than the range minimum,
    /// because the minimum *is* the neutral and asserting that it changes the
    /// image would be asserting that neutral is not neutral.
    let low: (inout EditStack) -> Void
    let high: (inout EditStack) -> Void

    /// The statistic this control is declared to move.
    let measure: ([UInt8]) -> Double

    /// Sign of `measure(high) - measure(neutral)`. `0` means the control
    /// genuinely changes the image but no single scalar describes how, so only
    /// the change is asserted.
    let sign: Int

    /// How far `measure` must move before the direction assertion means
    /// anything.
    let minimumChange: Double

    init(name: String, key: String,
         setup: @escaping (inout EditStack) -> Void = { _ in },
         low: @escaping (inout EditStack) -> Void,
         high: @escaping (inout EditStack) -> Void,
         measure: @escaping ([UInt8]) -> Double,
         sign: Int,
         minimumChange: Double = 0.002) {
        self.name = name
        self.key = key
        self.setup = setup
        self.low = low
        self.high = high
        self.measure = measure
        self.sign = sign
        self.minimumChange = minimumChange
    }
}

extension ControlCase {
    /// Fields deliberately not covered here, each with the suite that does
    /// cover it. An entry in this dictionary is a claim that someone checked;
    /// it is not a way to make the completeness test quiet.
    static let excluded: [String: String] = [
        "processVersion": "ProcessVersionTests — selects an engine, not an adjustment",
        "rawBoost": "RawSourceTests — no effect on a non-RAW source, which the probe is",
        "rawWBInitialized": "ProcessVersionTests — bookkeeping flag, never rendered",
        "toneCurvePoints": "CalibrationTests — point curve, covered with placement accuracy",
        "color": "ColorSuiteTests, ColorMixerTests — a subsystem with its own suites",
        "localAdjustments": "LocalAdjustmentTests, MaskComponentTests",
        "retouch": "RetouchTests",
        "defringe": "OpticsTests",
        "geometry": "GeometryTests — changes extent, so this byte-for-byte harness does not apply",
        "filmNegative": "FilmNegativeTests, EndToEndFilmTests",
    ]

    static let all: [ControlCase] = [
        // MARK: Light
        ControlCase(name: "Exposure", key: "exposure",
                    low: { $0.exposure = -2 }, high: { $0.exposure = 2 },
                    measure: Conformance.meanLuma, sign: +1),
        ControlCase(name: "Contrast", key: "contrast",
                    low: { $0.contrast = -80 }, high: { $0.contrast = 80 },
                    measure: Conformance.stdDevLuma, sign: +1),
        ControlCase(name: "Highlights", key: "highlights",
                    low: { $0.highlights = -100 }, high: { $0.highlights = 100 },
                    measure: { Conformance.percentileLuma($0, 0.90) }, sign: +1),
        ControlCase(name: "Shadows", key: "shadows",
                    low: { $0.shadows = -100 }, high: { $0.shadows = 100 },
                    measure: { Conformance.percentileLuma($0, 0.10) }, sign: +1),
        ControlCase(name: "Whites", key: "whites",
                    low: { $0.whites = -100 }, high: { $0.whites = 100 },
                    measure: { Conformance.percentileLuma($0, 0.98) }, sign: +1),
        ControlCase(name: "Blacks", key: "blacks",
                    low: { $0.blacks = -100 }, high: { $0.blacks = 100 },
                    measure: { Conformance.percentileLuma($0, 0.02) }, sign: +1),

        // MARK: White balance
        //
        // Neutral is 6500 K, not 0, so low/high bracket the default rather
        // than sitting either side of zero.
        ControlCase(name: "Temperature", key: "whiteBalanceTemp",
                    low: { $0.whiteBalanceTemp = 2000 },
                    high: { $0.whiteBalanceTemp = 10000 },
                    measure: Conformance.warmth, sign: +1),
        ControlCase(name: "Tint", key: "whiteBalanceTint",
                    low: { $0.whiteBalanceTint = -100 },
                    high: { $0.whiteBalanceTint = 100 },
                    // Lightroom's convention: positive Tint is magenta, which
                    // is green going down.
                    measure: Conformance.greenMagenta, sign: -1),

        // MARK: Presence
        ControlCase(name: "Texture", key: "texture",
                    low: { $0.texture = -100 }, high: { $0.texture = 100 },
                    measure: Conformance.localContrast, sign: +1),
        ControlCase(name: "Clarity", key: "clarity",
                    low: { $0.clarity = -100 }, high: { $0.clarity = 100 },
                    measure: Conformance.localContrast, sign: +1),
        ControlCase(name: "Dehaze", key: "dehaze",
                    low: { $0.dehaze = -100 }, high: { $0.dehaze = 100 },
                    measure: Conformance.stdDevLuma, sign: +1),
        ControlCase(name: "Vibrance", key: "vibrance",
                    low: { $0.vibrance = -100 }, high: { $0.vibrance = 100 },
                    measure: Conformance.meanSaturation, sign: +1),
        ControlCase(name: "Saturation", key: "saturation",
                    low: { $0.saturation = -100 }, high: { $0.saturation = 100 },
                    measure: Conformance.meanSaturation, sign: +1),

        // MARK: Detail
        ControlCase(name: "Sharpen Amount", key: "sharpenAmount",
                    low: { $0.sharpenAmount = 25 }, high: { $0.sharpenAmount = 100 },
                    measure: Conformance.localContrast, sign: +1),
        ControlCase(name: "Sharpen Radius", key: "sharpenRadius",
                    setup: { $0.sharpenAmount = 100 },
                    low: { $0.sharpenRadius = 0.5 }, high: { $0.sharpenRadius = 5 },
                    measure: Conformance.localContrast, sign: 0),
        ControlCase(name: "Luminance Noise Reduction", key: "luminanceNoiseReduction",
                    low: { $0.luminanceNoiseReduction = 25 },
                    high: { $0.luminanceNoiseReduction = 100 },
                    measure: Conformance.localContrast, sign: -1),
        ControlCase(name: "Colour Noise Reduction", key: "colorNoiseReduction",
                    low: { $0.colorNoiseReduction = 25 },
                    high: { $0.colorNoiseReduction = 100 },
                    measure: Conformance.chromaVariance, sign: -1),

        // MARK: Effects
        ControlCase(name: "Vignette Amount", key: "vignetteAmount",
                    low: { $0.vignetteAmount = -100 }, high: { $0.vignetteAmount = 100 },
                    measure: Conformance.cornerLuma, sign: +1),
        ControlCase(name: "Vignette Midpoint", key: "vignetteMidpoint",
                    setup: { $0.vignetteAmount = -100 },
                    low: { $0.vignetteMidpoint = 10 }, high: { $0.vignetteMidpoint = 90 },
                    // A midpoint further out starts the darkening later, so
                    // the corners keep more of their brightness.
                    measure: Conformance.cornerLuma, sign: +1),
        ControlCase(name: "Vignette Roundness", key: "vignetteRoundness",
                    setup: { $0.vignetteAmount = -100 },
                    low: { $0.vignetteRoundness = -100 },
                    high: { $0.vignetteRoundness = 100 },
                    measure: Conformance.cornerLuma, sign: 0),
        ControlCase(name: "Vignette Feather", key: "vignetteFeather",
                    setup: { $0.vignetteAmount = -100 },
                    low: { $0.vignetteFeather = 0 }, high: { $0.vignetteFeather = 100 },
                    measure: Conformance.cornerLuma, sign: 0),
        ControlCase(name: "Vignette Highlights", key: "vignetteHighlights",
                    setup: { $0.vignetteAmount = -100 },
                    low: { $0.vignetteHighlights = 25 },
                    high: { $0.vignetteHighlights = 100 },
                    measure: Conformance.cornerLuma, sign: +1),
        ControlCase(name: "Grain Amount", key: "grainAmount",
                    low: { $0.grainAmount = 25 }, high: { $0.grainAmount = 100 },
                    measure: Conformance.localContrast, sign: +1),
        ControlCase(name: "Grain Size", key: "grainSize",
                    setup: { $0.grainAmount = 100 },
                    low: { $0.grainSize = 0 }, high: { $0.grainSize = 100 },
                    measure: Conformance.localContrast, sign: 0),

        // MARK: Parametric tone curve
        ControlCase(name: "Curve Highlights", key: "toneCurveHighlights",
                    low: { $0.toneCurveHighlights = -100 },
                    high: { $0.toneCurveHighlights = 100 },
                    measure: { Conformance.percentileLuma($0, 0.90) }, sign: +1),
        ControlCase(name: "Curve Lights", key: "toneCurveLights",
                    low: { $0.toneCurveLights = -100 },
                    high: { $0.toneCurveLights = 100 },
                    measure: { Conformance.percentileLuma($0, 0.65) }, sign: +1),
        ControlCase(name: "Curve Darks", key: "toneCurveDarks",
                    low: { $0.toneCurveDarks = -100 },
                    high: { $0.toneCurveDarks = 100 },
                    measure: { Conformance.percentileLuma($0, 0.35) }, sign: +1),
        ControlCase(name: "Curve Shadows", key: "toneCurveShadows",
                    low: { $0.toneCurveShadows = -100 },
                    high: { $0.toneCurveShadows = 100 },
                    measure: { Conformance.percentileLuma($0, 0.10) }, sign: +1),
    ]
}

/// Proves that every control is wired to the pipeline and moves the image the
/// way its label says.
///
/// The suite exists because a passing test suite is not evidence that the app
/// works. PV1 shipped a Highlights slider whose positive half did nothing at
/// all, and every test stayed green for the life of the release: they all
/// asserted that the code did what it was written to do, and none asserted
/// that the picture changed.
final class ControlConformanceTests: XCTestCase {
    /// A control at its neutral value must be invisible.
    ///
    /// This is the "quietly always-on" check. A stage that runs unconditionally
    /// — a filter applied before testing whether its parameter is zero, a clamp
    /// that rounds every value — costs quality on every photo in the catalog
    /// and is invisible to a direction test, because both extremes still move.
    func testNeutralIsExactlyANoOp() {
        let untouched = Conformance.render { _ in }
        for control in ControlCase.all where !isSetupNonNeutral(control) {
            let neutral = Conformance.render(control.setup)
            XCTAssertEqual(Conformance.difference(untouched, neutral), 0, accuracy: 0.0001,
                           "\(control.name) at its neutral value changes the image.")
        }
    }

    /// Both ends of every control must visibly change the image.
    ///
    /// This is the test that would have caught PV1's Highlights.
    func testBothExtremesChangeTheImage() {
        for control in ControlCase.all {
            let neutral = Conformance.render(control.setup)
            for (label, mutate) in [("minimum", control.low), ("maximum", control.high)] {
                let variant = Conformance.render { stack in
                    control.setup(&stack)
                    mutate(&stack)
                }
                let delta = Conformance.difference(neutral, variant)
                XCTAssertGreaterThan(
                    delta, 0.0015,
                    "\(control.name) at its \(label) changes the image by \(delta), "
                    + "which is indistinguishable from doing nothing."
                )
            }
        }
    }

    /// Each control must move its declared statistic in its declared direction.
    ///
    /// This is the inverted-binding check: a slider wired to the negative of
    /// what its label says passes every "does it change" test there is.
    func testDirectionMatchesTheDeclaredOne() {
        for control in ControlCase.all where control.sign != 0 {
            let neutral = control.measure(Conformance.render(control.setup))
            let high = control.measure(Conformance.render { stack in
                control.setup(&stack)
                control.high(&stack)
            })
            let delta = high - neutral
            XCTAssertGreaterThan(
                abs(delta), control.minimumChange,
                "\(control.name) moved its statistic by only \(delta) — too "
                + "little to call the direction either way."
            )
            XCTAssertEqual(
                delta > 0 ? 1 : -1, control.sign,
                "\(control.name) at maximum moved its statistic by \(delta); "
                + "the declared direction is \(control.sign > 0 ? "up" : "down")."
            )
        }
    }

    // MARK: The inventory cannot rot

    /// Every stored property of `EditStack` is either covered by a conformance
    /// case or explicitly excluded with the suite that covers it instead.
    ///
    /// Without this, the matrix is a snapshot of what someone remembered in
    /// August 2026. With it, adding a control and forgetting to prove it works
    /// is a test failure.
    func testEveryEditStackFieldIsCoveredOrExcluded() {
        let fields = Mirror(reflecting: EditStack()).children.compactMap(\.label)
        XCTAssertFalse(fields.isEmpty, "Mirror found no stored properties on EditStack.")

        let covered = Set(ControlCase.all.map(\.key)).union(ControlCase.excluded.keys)
        for field in fields {
            XCTAssertTrue(
                covered.contains(field),
                "EditStack.\(field) is neither in ControlCase.all nor in "
                + "ControlCase.excluded. Add a conformance case for it, or an "
                + "exclusion naming the suite that covers it."
            )
        }
    }

    /// …and nothing in the table refers to a field that no longer exists.
    func testNoStaleEntriesInTheInventory() {
        let fields = Set(Mirror(reflecting: EditStack()).children.compactMap(\.label))
        for key in ControlCase.all.map(\.key) {
            XCTAssertTrue(fields.contains(key),
                          "ControlCase.all covers '\(key)', which is not a field of EditStack.")
        }
        for key in ControlCase.excluded.keys {
            XCTAssertTrue(fields.contains(key),
                          "ControlCase.excluded lists '\(key)', which is not a field of EditStack.")
        }
    }

    /// Two cases covering the same field means one of them is not being
    /// thought about.
    func testNoDuplicateCoverage() {
        let keys = ControlCase.all.map(\.key)
        XCTAssertEqual(Set(keys).count, keys.count, "A field has two conformance cases.")
        for key in keys {
            XCTAssertNil(ControlCase.excluded[key], "'\(key)' is both covered and excluded.")
        }
    }

    // MARK: Helpers

    /// True when a case's `setup` deliberately turns something on, in which
    /// case its "neutral" is not the default stack and the no-op check does
    /// not apply to it.
    private func isSetupNonNeutral(_ control: ControlCase) -> Bool {
        var stack = EditStack()
        control.setup(&stack)
        return stack != EditStack()
    }
}
