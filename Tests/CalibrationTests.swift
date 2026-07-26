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
}
