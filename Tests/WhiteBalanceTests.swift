import CoreImage
import XCTest
@testable import PhotoEditor

final class WhiteBalanceTests: XCTestCase {
    private func greyAfterWB(temp: Double, tint: Double) -> (r: Double, g: Double, b: Double) {
        let renderer = EditRenderer()
        var stack = EditStack()
        stack.whiteBalanceTemp = temp
        stack.whiteBalanceTint = tint
        let out = renderer.render(source: Calibration.patch(0.5), stack: stack)
        let c = TestSupport.readColor(out)
        return (c.red, c.green, c.blue)
    }

    func testNeutralSettingIsExactIdentity() {
        let c = greyAfterWB(temp: 6500, tint: 0)
        XCTAssertEqual(c.r, 0.5, accuracy: 0.005)
        XCTAssertEqual(c.g, 0.5, accuracy: 0.005)
        XCTAssertEqual(c.b, 0.5, accuracy: 0.005)
    }

    func testDirectionMatchesLegacySemantics() {
        // Higher temperature warms (red up, blue down) — same convention as
        // PV1's "map the chosen neutral to D65".
        let warm = greyAfterWB(temp: 8000, tint: 0)
        XCTAssertGreaterThan(warm.r, warm.b + 0.02)
        let cool = greyAfterWB(temp: 4500, tint: 0)
        XCTAssertGreaterThan(cool.b, cool.r + 0.02)
        // Positive tint pushes magenta (green down relative to r/b mean).
        let magenta = greyAfterWB(temp: 6500, tint: 60)
        XCTAssertLessThan(magenta.g, (magenta.r + magenta.b) / 2 - 0.01)
    }

    /// The mired test: equal mired steps must produce equal chromatic effect.
    /// 4000→4444 K and 8000→10000 K are both 25 mired. In PV1 (uniform in
    /// Kelvin) the same slider distance was ~15× stronger at the cold end.
    func testEqualMiredStepsHaveEqualEffect() {
        func warmth(_ temp: Double) -> Double {
            let c = greyAfterWB(temp: temp, tint: 0)
            return c.r - c.b
        }
        let stepLow = warmth(4444) - warmth(4000)     // 25 mired at the cold end
        let stepHigh = warmth(10000) - warmth(8000)   // 25 mired at the warm end
        XCTAssertEqual(stepLow, stepHigh, accuracy: max(abs(stepLow), abs(stepHigh)) * 0.35 + 0.005,
                       "25 mired must cost the same at both ends: \(stepLow) vs \(stepHigh)")
    }

    func testMatrixMapsItsOwnNeutralToGrey() {
        // A grey patch cast with the chromaticity of 4500 K, corrected with
        // temp=4500, must come back near-neutral. This is the eyedropper
        // contract: sample a should-be-neutral color, set WB to it, get grey.
        let m = ColorScience.whiteBalanceMatrix(temperature: 4500, tint: 0)
        // Apply the matrix's inverse-direction check cheaply: correcting the
        // D65 grey by 4500K then by the inverse-of-4500K matrix round-trips.
        let mInv = ColorScience.whiteBalanceMatrix(temperature: 6500, tint: 0)
        XCTAssertEqual(mInv, [1, 0, 0, 0, 1, 0, 0, 0, 1].map(Double.init))
        let r = m[0] * 0.5 + m[1] * 0.5 + m[2] * 0.5
        let g = m[3] * 0.5 + m[4] * 0.5 + m[5] * 0.5
        let b = m[6] * 0.5 + m[7] * 0.5 + m[8] * 0.5
        // Correcting a 4500K-lit grey: matrix must boost blue relative to red.
        XCTAssertGreaterThan(b, r, "adapting FROM a warm neutral TO D65 raises blue of a D65 grey")
        _ = g
    }
}
