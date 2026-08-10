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

    // MARK: Minilab constants — the lab rendering layers (Phase 2.5)

    /// Full-scale midtone punch. The S-curve is pn + a·pn(1−pn)(pn−targetMid);
    /// its worst-case slope is 1 − a·(1 − targetMid) ≈ 1 − 0.82a, so 1.0
    /// keeps the curve monotone with real margin (proven by test at 100).
    static let punchFullScale = 1.0
    /// Full-scale raised paper black ("Fade") — 6% linear, a clearly faded
    /// print at the extreme, imperceptible per slider tick.
    static let fadeFullScale = 0.06
    /// Full-scale lowered paper white ("Glow") — same bound, same reasoning.
    static let glowFullScale = 0.06
    /// Toe chroma compression ceiling — the mirror of highlightDesat: reaches
    /// print-like shadow neutrality without reading as a channel clamp.
    static let toeChromaFull = 0.9
    /// Norm band over which the toe compression fades out (fully engaged at
    /// toeStart, gone by toeEnd). Below the paper floor everything is black
    /// anyway; 0.10 keeps it out of the mids.
    static let toeStart = 0.02
    static let toeEnd = 0.10
    /// Zone weight edges over the pre-trim paper-output norm: shadows fade
    /// out across 0.15–0.45, highlights fade in across 0.55–0.85, mids take
    /// the remainder — complementary smoothsteps, always summing to ≤ 1.
    static let zoneShadowEnd = 0.15
    static let zoneShadowFade = 0.45
    static let zoneHighStart = 0.55
    static let zoneHighFull = 0.85
    /// Cast correction full scale: ±100 = ±0.5 EV of per-channel density —
    /// twice the filtration clamp: enough to remove a real base-estimation
    /// cast, still bounded against scan-rescue abuse (spec §Cast correction).
    static let castFullScaleEV = 0.5
    /// Zone trim full scale: ±0.25 EV, the filtration bound — a taste trim.
    static let zoneTrimFullScaleEV = 0.25

    static func punchAmount(_ slider: Double) -> Double {
        min(max(slider, 0), 100) / 100.0 * punchFullScale
    }
    static func fadeLift(_ slider: Double) -> Double {
        min(max(slider, 0), 100) / 100.0 * fadeFullScale
    }
    static func glowDrop(_ slider: Double) -> Double {
        min(max(slider, 0), 100) / 100.0 * glowFullScale
    }
    static func toeChromaWeight(_ slider: Double) -> Double {
        min(max(slider, 0), 100) / 100.0 * toeChromaFull
    }
    /// Slider (−100…100) → density offset. 1 EV = log10(2) density.
    static func castDensity(_ slider: Double) -> Double {
        min(max(slider, -100), 100) / 100.0 * castFullScaleEV * log10(2.0)
    }
    static func zoneTrimDensity(_ slider: Double) -> Double {
        min(max(slider, -100), 100) / 100.0 * zoneTrimFullScaleEV * log10(2.0)
    }

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

    /// Print exposure plus filtration, resolved to the three per-channel
    /// log-domain offsets `develop` takes as `printOffset`.
    ///
    /// The enlarger analogy: a real color enlarger places a dichroic filter
    /// pack (cyan/magenta/yellow, or the printer's shorthand of "more red" /
    /// "more green") in the light path below the negative. Every filtration
    /// value moves exposure between complementary channels rather than
    /// adding light overall — dial in more red and blue drops to match, so
    /// filtration warms or cools the print without changing its overall
    /// brightness the way `exposureEV` does. `warmth` is the red–blue pack;
    /// `tint` is the green–magenta pack (typically minus-green/minus-magenta
    /// on a real color head, but signed here as green-positive to match the
    /// panel and ``Conformance/greenMagenta``).
    ///
    /// ±100 = ±0.25 EV full scale: enough to read as a clear, deliberate cast
    /// at the extreme without being able to overpower a three-stop exposure
    /// mistake — filtration is meant to trim the house look, not rescue a
    /// bad scan.
    /// `balancedTint` selects renderVersion 2's tint semantics. In version 1
    /// the tint leg moves green alone, so dialing tint also moves the print's
    /// overall log exposure — the doc comment above promised filtration moves
    /// exposure *between* complementary channels, and on the green–magenta
    /// axis that was not true. Version 2 splits the complement across red and
    /// blue, half each, so the three offsets sum to zero and the promise holds
    /// on both axes. Version 1 keeps the old, unbalanced behaviour verbatim.
    static func printOffsets(exposureEV: Double, warmth: Double, tint: Double,
                             balancedTint: Bool = false)
        -> (Double, Double, Double) {
        let base = exposureEV * log10(2.0)
        let full = 0.25 * log10(2.0)
        let t = tint / 100.0 * full
        if balancedTint {
            return (base + warmth / 100.0 * full - t / 2,
                    base + t,
                    base - warmth / 100.0 * full - t / 2)
        }
        return (base + warmth / 100.0 * full,
                base + t,
                base - warmth / 100.0 * full)
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
    /// already folded in; `printOffset` is the per-channel log-domain
    /// exposure — `printEV · log10(2)` plus filtration, see
    /// ``printOffsets(exposureEV:warmth:tint:)`` — one value per channel so
    /// warmth/tint can move red and blue in opposite directions; `satScale`
    /// is `1 + printSaturation / 100`.
    ///
    /// Stage order (spec §The model): density → straight line → paper on the
    /// max-channel norm → hue-preserving rolloff. The norm is `max`, not a
    /// weighted luma, because the max channel is the one that would otherwise
    /// clip.
    static func develop(_ t: (Double, Double, Double),
                        dminLinear: (Double, Double, Double),
                        dmax: (Double, Double, Double),
                        gammaEffective: (Double, Double, Double),
                        printOffset: (Double, Double, Double),
                        p: Double, q: Double,
                        satScale: Double,
                        shadowTrim: (Double, Double, Double) = (0, 0, 0),
                        midTrim: (Double, Double, Double) = (0, 0, 0),
                        highTrim: (Double, Double, Double) = (0, 0, 0),
                        punch: Double = 0, fade: Double = 0, glow: Double = 0,
                        toeChroma: Double = 0) -> (Double, Double, Double) {
        func straightLine(_ t: Double, _ dmin: Double, _ dmax: Double, _ g: Double,
                          _ offset: Double) -> Double {
            let density = log10(max(dmin, 1e-4) / max(t, transmittanceFloor))
            return pow(10.0, g * (density - dmax) + offset)
        }
        var s = (straightLine(t.0, dminLinear.0, dmax.0, gammaEffective.0, printOffset.0),
                 straightLine(t.1, dminLinear.1, dmax.1, gammaEffective.1, printOffset.1),
                 straightLine(t.2, dminLinear.2, dmax.2, gammaEffective.2, printOffset.2))
        // Zone trims: weights from the PRE-trim paper-output norm — evaluated
        // once on the untrimmed value, then applied as folded log offsets
        // (trim args arrive as gammaEffective × zoneTrimDensity, CPU-folded).
        if shadowTrim != (0, 0, 0) || midTrim != (0, 0, 0) || highTrim != (0, 0, 0) {
            let n0 = max(s.0, max(s.1, s.2))
            let pn0 = paper(n0, p: p, q: q)
            let wS = 1 - smoothstep(zoneShadowEnd, zoneShadowFade, pn0)
            let wH = smoothstep(zoneHighStart, zoneHighFull, pn0)
            let wM = max(1 - wS - wH, 0)
            func trimmed(_ v: Double, _ tS: Double, _ tM: Double, _ tH: Double) -> Double {
                v * pow(10.0, wS * tS + wM * tM + wH * tH)
            }
            s = (trimmed(s.0, shadowTrim.0, midTrim.0, highTrim.0),
                 trimmed(s.1, shadowTrim.1, midTrim.1, highTrim.1),
                 trimmed(s.2, shadowTrim.2, midTrim.2, highTrim.2))
        }
        let n = max(s.0, max(s.1, s.2))
        var ratio = n > 0 ? (s.0 / n, s.1 / n, s.2 / n) : (1.0, 1.0, 1.0)
        // Hue-preserving saturation: scale the ratio around 1. Clamped at zero
        // so a big boost cannot drive a channel negative.
        ratio = (max(1 + (ratio.0 - 1) * satScale, 0),
                 max(1 + (ratio.1 - 1) * satScale, 0),
                 max(1 + (ratio.2 - 1) * satScale, 0))
        var pn = paper(n, p: p, q: q)
        // Punch: a monotone cubic S about the mid target — zero at black,
        // targetMid, and white, so it adds midtone contrast without moving
        // the endpoints the fade/glow remap below owns.
        pn = pn + punch * pn * (1 - pn) * (pn - targetMid)
        // Fade/glow: the endpoint remap — raised paper black, lowered paper
        // white. Affine, slope 1 − fade − glow > 0, still strictly < 1.
        pn = fade + pn * (1 - fade - glow)
        let w = smoothstep(shoulderStart, 1.0, pn) * highlightDesat
        let wToe = (1 - smoothstep(toeStart, toeEnd, pn)) * toeChroma
        let wAll = min(w + wToe, 1.0)
        return (pn * (ratio.0 + (1 - ratio.0) * wAll),
                pn * (ratio.1 + (1 - ratio.1) * wAll),
                pn * (ratio.2 + (1 - ratio.2) * wAll))
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
