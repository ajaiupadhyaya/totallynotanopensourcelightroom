import CoreGraphics
import XCTest
@testable import PhotoEditor

final class CalibrationTests: XCTestCase {
    /// Dragging the curve's midpoint up must lift DISPLAY midtones most.
    /// PV1 applied CIToneCurve in the linear working space, which put the
    /// peak of the lift near display 0.74 instead of 0.50.
    func testPointCurveMidtoneLiftPeaksAtDisplayMidtone() {
        let inputs = stride(from: 0.1, through: 0.9, by: 0.1).map { $0 }
        let outputs = Calibration.displaySweep(inputs: inputs) {
            $0.toneCurvePoints = [CGPoint(x: 0, y: 0), CGPoint(x: 0.25, y: 0.25),
                                  CGPoint(x: 0.5, y: 0.6), CGPoint(x: 0.75, y: 0.75),
                                  CGPoint(x: 1, y: 1)]
        }
        let deltas = zip(outputs, inputs).map { $0 - $1 }
        let peakInput = inputs[deltas.firstIndex(of: deltas.max()!)!]
        XCTAssertEqual(peakInput, 0.5, accuracy: 0.11,
                       "midtone lift peaked at display \(peakInput), deltas \(deltas)")
        XCTAssertEqual(outputs[4], 0.6, accuracy: 0.03,
                       "display 0.5 through a 0.5→0.6 curve point must land near 0.6")
    }

    func testContrastPivotsAtDisplayMiddleGrey() {
        let out = Calibration.displaySweep(inputs: [0.5]) { $0.contrast = 60 }
        XCTAssertEqual(out[0], 0.5, accuracy: 0.02,
                       "contrast must pivot at display 0.5, not linear 0.5 (display 0.74)")
    }

    func testContrastNeverCrushesMidRampToBlackOrWhite() {
        let inputs = [0.1, 0.2, 0.3, 0.4, 0.6, 0.7, 0.8, 0.9]
        let out = Calibration.displaySweep(inputs: inputs) { $0.contrast = 100 }
        for (i, v) in out.enumerated() {
            XCTAssertGreaterThan(v, 0.004, "display \(inputs[i]) crushed to black at +100")
            XCTAssertLessThan(v, 0.996, "display \(inputs[i]) blown to white at +100")
        }
        // PV1 sent display 0.10–0.40 to exactly 0.0 at +50. Never again:
        let legacyVictims = Calibration.displaySweep(inputs: [0.1, 0.25, 0.4]) { $0.contrast = 50 }
        XCTAssertGreaterThan(legacyVictims[0], 0.01)
        XCTAssertGreaterThan(legacyVictims[1], 0.08)
        XCTAssertGreaterThan(legacyVictims[2], 0.2)
    }

    func testContrastIsMonotonicAndDirectional() {
        let inputs = stride(from: 0.05, through: 0.95, by: 0.05).map { $0 }
        let plus = Calibration.displaySweep(inputs: inputs) { $0.contrast = 70 }
        let minus = Calibration.displaySweep(inputs: inputs) { $0.contrast = -70 }
        for i in 1..<plus.count {
            XCTAssertGreaterThanOrEqual(plus[i] + 0.002, plus[i - 1], "not monotonic at +70")
            XCTAssertGreaterThanOrEqual(minus[i] + 0.002, minus[i - 1], "not monotonic at −70")
        }
        XCTAssertLessThan(plus[2], inputs[2])       // + steepens: shadows darker
        XCTAssertGreaterThan(plus[16], inputs[16])  //              highlights brighter
        XCTAssertGreaterThan(minus[2], inputs[2])   // − flattens: shadows lifted
    }

    func testWhitesMoveTheWhiteClippingPoint() {
        // PV1's pinned curve mapped display 1.0 → 1.0 at ANY whites value and
        // could never clip. Whites +100 must drive the top of the range to white.
        let top = Calibration.displaySweep(inputs: [0.85, 1.0]) { $0.whites = 100 }
        XCTAssertGreaterThan(top[0], 0.97, "near-white must reach white at whites +100")
        XCTAssertGreaterThanOrEqual(top[1], 0.995)
        // …while barely moving a quarter-tone (that's contrast's job).
        let quarter = Calibration.displaySweep(inputs: [0.25]) { $0.whites = 100 }
        XCTAssertEqual(quarter[0], 0.25 / 0.7, accuracy: 0.06)
        // Negative whites pulls the top down without touching shadows.
        let pulled = Calibration.displaySweep(inputs: [0.15, 1.0]) { $0.whites = -100 }
        XCTAssertLessThan(pulled[1], 0.75)
        XCTAssertEqual(pulled[0], 0.15, accuracy: 0.03)
    }

    func testBlacksMoveTheBlackClippingPoint() {
        let bottom = Calibration.displaySweep(inputs: [0.0, 0.15]) { $0.blacks = -100 }
        XCTAssertLessThan(bottom[1], 0.03, "near-black must crush at blacks −100")
        let high = Calibration.displaySweep(inputs: [0.85]) { $0.blacks = -100 }
        XCTAssertEqual(high[0], (0.85 - 0.3) / 0.7, accuracy: 0.06)
        // Positive blacks lifts the floor (the faded look).
        let lifted = Calibration.displaySweep(inputs: [0.0]) { $0.blacks = 100 }
        XCTAssertGreaterThan(lifted[0], 0.1)
    }

    func testWhitesAndBlacksComposeMonotonically() {
        let inputs = stride(from: 0.0, through: 1.0, by: 0.1).map { $0 }
        let out = Calibration.displaySweep(inputs: inputs) { $0.whites = 60; $0.blacks = -60 }
        for i in 1..<out.count {
            XCTAssertGreaterThanOrEqual(out[i] + 0.002, out[i - 1])
        }
    }

    func testParametricRegionsPeakInTheirOwnQuartiles() {
        // 0.9 not 0.95: at +100 the highlight lift saturates at 1.0, and probing
        // too close to white would let the unclamped 0.7 delta win.
        let inputs = [0.05, 0.3, 0.7, 0.9]
        // Swift can't treat an inline array literal of `(inout EditStack) -> Void`
        // closures as escaping (needed by .enumerated()); bind it to a typed
        // variable first so the closures are escaping from the start.
        let mutators: [(inout EditStack) -> Void] = [
            { (s: inout EditStack) in s.toneCurveShadows = 100 },
            { (s: inout EditStack) in s.toneCurveDarks = 100 },
            { (s: inout EditStack) in s.toneCurveLights = 100 },
            { (s: inout EditStack) in s.toneCurveHighlights = 100 },
        ]
        for (index, mutate) in mutators.enumerated() {
            let out = Calibration.displaySweep(inputs: inputs, mutate: mutate)
            let deltas = zip(out, inputs).map { $0 - $1 }
            let peak = deltas.firstIndex(of: deltas.max()!)!
            XCTAssertEqual(peak, index,
                           "region \(index) peaked at input \(inputs[peak]); deltas \(deltas)")
        }
    }

    func testParametricIsAppliedInDisplaySpace() {
        // Darks +100 must move display 0.3 far more than display 0.7.
        let out = Calibration.displaySweep(inputs: [0.3, 0.7]) { $0.toneCurveDarks = 100 }
        XCTAssertGreaterThan(out[0] - 0.3, (out[1] - 0.7) * 2)
    }
}
