import CoreGraphics
import XCTest
@testable import PhotoEditor

final class CalibrationTests: XCTestCase {
    /// Dragging the curve's midpoint up must lift DISPLAY midtones most.
    ///
    /// `CIToneCurve` is natively display-referred — it interpolates its control
    /// points in display space, not in the linear working space it is handed —
    /// which is why ``EditRenderer/applyToneCurve(_:stack:)`` deliberately does
    /// no space conversion around it. That is an undocumented property of a
    /// system filter, so this test is what pins it: if it ever changed, a 0.5
    /// control point would land near display 0.74 and every point curve in the
    /// catalog would be wrong.
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

    func testHighlightsWorksInBothDirections() {
        // The PV1 bug: +highlights was a hard no-op. Both signs must move a
        // bright patch, monotonically.
        let bright = 0.8
        let up = Calibration.displaySweep(inputs: [bright]) { $0.highlights = 80 }
        let down = Calibration.displaySweep(inputs: [bright]) { $0.highlights = -80 }
        let downFull = Calibration.displaySweep(inputs: [bright]) { $0.highlights = -100 }
        XCTAssertGreaterThan(up[0], bright + 0.02)
        XCTAssertLessThan(down[0], bright - 0.05)
        XCTAssertLessThan(downFull[0], down[0], "recovery must deepen with amount")
        // …and leave a shadow patch essentially alone.
        let dark = Calibration.displaySweep(inputs: [0.15]) { $0.highlights = -100 }
        XCTAssertEqual(dark[0], 0.15, accuracy: 0.02)
    }

    func testShadowsWorksInBothDirectionsAndIsLocalToShadows() {
        let lifted = Calibration.displaySweep(inputs: [0.2]) { $0.shadows = 80 }
        let deepened = Calibration.displaySweep(inputs: [0.2]) { $0.shadows = -80 }
        XCTAssertGreaterThan(lifted[0], 0.25)
        XCTAssertLessThan(deepened[0], 0.15)
        let bright = Calibration.displaySweep(inputs: [0.85]) { $0.shadows = 80 }
        XCTAssertEqual(bright[0], 0.85, accuracy: 0.03)
    }

    /// The halo test. Shadow recovery on a hard dark/bright edge must not
    /// overshoot on either side of the boundary — the guided-filter base
    /// keeps the step a step, so the gain map cannot leak across it.
    func testShadowLiftDoesNotHaloAcrossAHardEdge() {
        let renderer = EditRenderer()
        var stack = EditStack()
        stack.shadows = 100
        let edge = CalibrationEdge.image(dark: 0.16, bright: 0.82, size: 128)
        let out = renderer.render(source: edge, stack: stack)
        // Bright side, near and far from the edge: lift must not darken it,
        // and near-edge must match far-edge (no dark band).
        let brightNear = Calibration.displayValue(of: out, x: 68, y: 64)
        let brightFar = Calibration.displayValue(of: out, x: 120, y: 64)
        XCTAssertGreaterThanOrEqual(brightNear, 0.80)
        XCTAssertEqual(brightNear, brightFar, accuracy: 0.03, "halo band on the bright side")
        // Dark side near the edge must be lifted the same as far from it.
        let darkNear = Calibration.displayValue(of: out, x: 60, y: 64)
        let darkFar = Calibration.displayValue(of: out, x: 8, y: 64)
        XCTAssertEqual(darkNear, darkFar, accuracy: 0.04, "uneven lift = halo on the dark side")
    }

    // MARK: Vibrance / saturation

    private func rgbAfter(_ r: Double, _ g: Double, _ b: Double,
                          _ mutate: (inout EditStack) -> Void) -> (r: Double, g: Double, b: Double) {
        let renderer = EditRenderer()
        var stack = EditStack()
        mutate(&stack)
        let src = TestSupport.solidImage(red: r, green: g, blue: b, size: 16)
        let c = TestSupport.readColor(renderer.render(source: src, stack: stack))
        return (c.red, c.green, c.blue)
    }

    private func displayLuma(_ c: (r: Double, g: Double, b: Double)) -> Double {
        0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
    }

    func testSaturationPreservesDisplayLuminance() {
        // PV1 dropped a bright red's display luma from 0.43 to 0.21 at +50.
        for color in [(0.9, 0.3, 0.3), (0.2, 0.35, 0.7), (0.35, 0.1, 0.1)] {
            let before = displayLuma((color.0, color.1, color.2))
            let after = displayLuma(rgbAfter(color.0, color.1, color.2) { $0.saturation = 50 })
            XCTAssertEqual(after, before, accuracy: 0.015,
                           "saturation +50 moved display luma of \(color): \(before) → \(after)")
        }
    }

    func testSaturationRollsOffAtTheGamutEdgeInsteadOfClipping() {
        // PV1 sent (0.9, 0.3, 0.3) to (1.0, 0.0, 0.0) at +50 — two channels
        // slammed into the walls. The rolloff must keep all channels interior.
        let c = rgbAfter(0.9, 0.3, 0.3) { $0.saturation = 60 }
        XCTAssertGreaterThan(c.g, 0.02)
        XCTAssertGreaterThan(c.b, 0.02)
        XCTAssertLessThan(c.r, 0.999)
        XCTAssertGreaterThan(c.r - c.g, 0.6 - 0.0001, "it must still saturate meaningfully")
    }

    func testSaturationMinus100IsGreyscale() {
        let c = rgbAfter(0.7, 0.4, 0.2) { $0.saturation = -100 }
        XCTAssertEqual(c.r, c.g, accuracy: 0.01)
        XCTAssertEqual(c.g, c.b, accuracy: 0.01)
    }

    func testVibranceProtectsSkinAndFavorsMutedColors() {
        // Muted blue moves more than an equally-muted skin tone.
        let skinBefore = (r: 0.75, g: 0.62, b: 0.55)
        let blueBefore = (r: 0.55, g: 0.62, b: 0.75)
        func chroma(_ c: (r: Double, g: Double, b: Double)) -> Double {
            max(c.r, c.g, c.b) - min(c.r, c.g, c.b)
        }
        let skinAfter = rgbAfter(skinBefore.r, skinBefore.g, skinBefore.b) { $0.vibrance = 100 }
        let blueAfter = rgbAfter(blueBefore.r, blueBefore.g, blueBefore.b) { $0.vibrance = 100 }
        let skinGain = chroma(skinAfter) - chroma(skinBefore)
        let blueGain = chroma(blueAfter) - chroma(blueBefore)
        XCTAssertGreaterThan(blueGain, skinGain * 1.5 + 0.005,
                             "vibrance must move muted non-skin colors more than skin")
        // And an already-saturated color barely moves.
        let vivid = rgbAfter(0.95, 0.1, 0.1) { $0.vibrance = 100 }
        XCTAssertEqual(chroma(vivid), 0.85, accuracy: 0.08)
    }

    // MARK: Extended range

    /// The EDR policy, pinned end-to-end: every PV2 kernel does its math on the
    /// display-encoded value clamped to [0, 1] and adds the out-of-range
    /// residual back afterwards. Two consequences must hold for every tonal and
    /// colour control:
    ///
    /// 1. **Headroom survives.** A linear 2.0 or 4.0 input still comes out
    ///    above 1.0, so a highlight recovered later in the chain (or by the
    ///    display's own EDR) still has something to recover.
    /// 2. **Brighter stays brighter.** Feeding 4.0 never produces a darker
    ///    result than feeding 2.0. Before this convention was uniform,
    ///    `whites −100` was quadratic in the *unclamped* value and inverted the
    ///    two (2.0 → 0.47, 4.0 → 0.39), and `saturation` clamped both to 1.0.
    ///
    /// Expected values follow directly from the kernels' math (encode 2.0 =
    /// 1.3533, residual 0.3533; encode 4.0 = 1.8248, residual 0.8248):
    /// contrast/saturation are identity on a clipped achromatic patch (2.0,
    /// 4.0); `whites −100` sends the clamped 1.0 to 0.65 (1.007, 2.44);
    /// `highlights −60` sends it to 0.73 (1.200, 2.757).
    func testToneKernelsPreserveExtendedRange() {
        let renderer = EditRenderer()
        let cases: [(name: String, mutate: (inout EditStack) -> Void)] = [
            ("contrast +70", { (s: inout EditStack) in s.contrast = 70 }),
            ("whites −100", { (s: inout EditStack) in s.whites = -100 }),
            ("highlights −60", { (s: inout EditStack) in s.highlights = -60 }),
            ("saturation +50", { (s: inout EditStack) in s.saturation = 50 }),
        ]
        for (name, mutate) in cases {
            var stack = EditStack()
            mutate(&stack)
            let dim = Calibration.linearValue(
                of: renderer.render(source: Calibration.edrPatch(2), stack: stack), x: 32, y: 32)
            let bright = Calibration.linearValue(
                of: renderer.render(source: Calibration.edrPatch(4), stack: stack), x: 32, y: 32)
            XCTAssertGreaterThan(dim, 1.0,
                                 "\(name): linear 2.0 flattened to \(dim) — EDR headroom lost")
            XCTAssertGreaterThan(bright, 1.0,
                                 "\(name): linear 4.0 flattened to \(bright) — EDR headroom lost")
            XCTAssertGreaterThan(bright, dim,
                                 "\(name): non-monotonic — 2.0 → \(dim) but 4.0 → \(bright)")
        }
    }
}
