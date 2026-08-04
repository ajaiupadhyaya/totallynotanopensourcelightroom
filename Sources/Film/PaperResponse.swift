import Foundation

/// The print curve — the density engine's paper response, in pure Swift.
///
/// This file is the single source of truth for the look. The Metal kernel in
/// `Film.ci.metal` mirrors this math line for line, and a test asserts the two
/// agree across the range; the solver in ``AutoInvert`` calls this directly.
/// A curve that existed only inside a `.metal` file could not be unit-tested,
/// and this one carries the whole rendering.
///
/// Every taste judgment in the engine is a named constant here, so "the
/// defaults are arbitrary" is a claim anyone can check against one screen of
/// code. They get tuned against the user's real scans before the phase closes.
enum PaperResponse {

    // MARK: Constants — the house rendering

    /// Where the highlight rolloff engages, as a fraction of paper output.
    /// Below this the channel ratio is preserved exactly (hue AND saturation
    /// survive untouched); exposing it as a slider would invite dialing in the
    /// hue-skewed look this engine exists to avoid.
    static let shoulderStart = 0.75

    /// How completely the shoulder desaturates toward white. 1.0 forces exact
    /// neutrality at paper white; 0.9 reaches it without reading as a clip.
    static let highlightDesat = 0.9

    /// Where Auto lands the 0.5th-percentile density, pre-paper — roughly one
    /// stop above true black, so the toe has something to lift.
    static let targetBlack = 0.004

    /// Where Auto lands the median density: display middle grey.
    static let targetMid = 0.18

    /// Auto's white point: above dust, below the true maximum.
    static let dmaxPercentile = 0.995
    static let dLowPercentile = 0.005

    /// Auto's fallback base estimate. Not the 99.9th: on a lightbox scan the
    /// very top of the histogram is bare panel, not film (see the spec).
    static let dminPercentile = 0.98

    /// Transmittance floor for the log — a scan pixel at exactly zero is
    /// sensor noise, not infinite density.
    static let transmittanceFloor = 1e-5

    // MARK: Slider mappings

    /// Shoulder slider 0…100 → knee exponent, log-interpolated 64 → 2.
    /// At 64 the knee compresses n = 1 by ~1.1% (visually a hard clip); at 2
    /// it compresses to 0.71 (a long gradual rolloff).
    static func kneeP(shoulder: Double) -> Double {
        64.0 * pow(2.0 / 64.0, min(max(shoulder, 0), 100) / 100.0)
    }

    /// Toe slider 0…100 → knee exponent, log-interpolated 512 → 24.
    /// The black floor is `1 − 2^(−1/q)`: imperceptible (0.0014 linear) at
    /// 512, a heavy fog (0.028) at 24.
    static func kneeQ(toe: Double) -> Double {
        512.0 * pow(24.0 / 512.0, min(max(toe, 0), 100) / 100.0)
    }

    /// Paper grade 0…5 → gamma multiplier, one grade = ×1.15, grade 2 = ×1.0
    /// (the gammas Auto solved). Grade rather than a percentage because the
    /// number then means the thing a printer already knows.
    static func gradeScale(_ grade: Double) -> Double {
        pow(1.15, grade - 2.0)
    }

    // MARK: The curve

    /// Identity for small x, asymptote 1 for large x, strictly increasing,
    /// never clips. `k` sets how abrupt the knee is.
    ///
    /// Clamped one ULP below 1: past a few decades in `x` the true value is
    /// closer to 1 than `Double` can resolve, and an unclamped result rounds
    /// to exactly 1.0 — a real clip, contradicting the doc comment above.
    static func softknee(_ x: Double, _ k: Double) -> Double {
        guard x > 0 else { return 0 }
        return min(x / pow(1.0 + pow(x, k), 1.0 / k), 1.0.nextDown)
    }

    /// The paper's characteristic curve: a shoulder into white and, applied to
    /// the complement, a toe out of black. Maps [0, ∞) into [floor, 1),
    /// monotonically. `paper(0) = 1 − 2^(−1/q)` — a lifted black, which is not
    /// a compromise; it is the look of the user's own lab scans.
    ///
    /// Clamped one ULP below 1: for `n` far past white the true value is
    /// closer to 1 than a `Double` can represent, so the unclamped
    /// subtraction rounds to exactly 1.0 — silently breaking the "< 1"
    /// contract this type documents (and that callers, e.g. the highlight
    /// rolloff below, rely on to know the shoulder never fully clips).
    static func paper(_ n: Double, p: Double, q: Double) -> Double {
        min(1.0 - softknee(1.0 - softknee(n, p), q), 1.0.nextDown)
    }

    private static func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        let t = min(max((x - e0) / (e1 - e0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    // MARK: The full per-pixel model

    /// The complete density-to-print develop for one linear-transmittance
    /// pixel. `gammaEffective` is the per-channel gamma with the grade scale
    /// already folded in; `printOffset` is `printEV · log10(2)`; `satScale` is
    /// `1 + printSaturation / 100`.
    ///
    /// Stage order (spec §The model): density → straight line → paper on the
    /// max-channel norm → hue-preserving rolloff. The norm is `max`, not a
    /// weighted luma, because the max channel is the one that would otherwise
    /// clip.
    static func develop(_ t: (Double, Double, Double),
                        dminLinear: (Double, Double, Double),
                        dmax: (Double, Double, Double),
                        gammaEffective: (Double, Double, Double),
                        printOffset: Double,
                        p: Double, q: Double,
                        satScale: Double) -> (Double, Double, Double) {
        func straightLine(_ t: Double, _ dmin: Double, _ dmax: Double, _ g: Double) -> Double {
            let density = log10(max(dmin, 1e-4) / max(t, transmittanceFloor))
            return pow(10.0, g * (density - dmax) + printOffset)
        }
        let s = (straightLine(t.0, dminLinear.0, dmax.0, gammaEffective.0),
                 straightLine(t.1, dminLinear.1, dmax.1, gammaEffective.1),
                 straightLine(t.2, dminLinear.2, dmax.2, gammaEffective.2))
        let n = max(s.0, max(s.1, s.2))
        var ratio = n > 0 ? (s.0 / n, s.1 / n, s.2 / n) : (1.0, 1.0, 1.0)
        // Hue-preserving saturation: scale the ratio around 1. Clamped at zero
        // so a big boost cannot drive a channel negative.
        ratio = (max(1 + (ratio.0 - 1) * satScale, 0),
                 max(1 + (ratio.1 - 1) * satScale, 0),
                 max(1 + (ratio.2 - 1) * satScale, 0))
        let pn = paper(n, p: p, q: q)
        let w = smoothstep(shoulderStart, 1.0, pn) * highlightDesat
        return (pn * (ratio.0 + (1 - ratio.0) * w),
                pn * (ratio.1 + (1 - ratio.1) * w),
                pn * (ratio.2 + (1 - ratio.2) * w))
    }

    // MARK: sRGB transfer

    /// The base color is persisted display-encoded (shared with the matrix
    /// engine and the panel swatch); the density engine works in linear, so
    /// each side converts at its own boundary.
    static func srgbDecode(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    static func srgbEncode(_ c: Double) -> Double {
        c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1.0 / 2.4) - 0.055
    }
}
