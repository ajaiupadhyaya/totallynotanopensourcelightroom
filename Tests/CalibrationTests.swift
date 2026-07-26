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
}
