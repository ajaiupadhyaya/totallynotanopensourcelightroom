import XCTest
@testable import PhotoEditor

/// The print curve is the whole look, so it gets direct mathematical tests —
/// monotonicity, bounds, closed-form endpoints — rather than only image-level
/// ones. A curve that exists only inside a `.metal` file cannot be tested at
/// all; this suite is the reason `PaperResponse` is Swift.
final class PaperResponseTests: XCTestCase {

    /// softknee(x,k) = x·(1+x^k)^(−1/k): its derivative is
    /// (1+x^k)^(−1/k−1) > 0, so it is strictly increasing, and the asymptote
    /// is 1. The identity behavior near zero is what keeps the toe and
    /// shoulder out of the midtones.
    func testSoftkneeIsIdentityNearZeroAndAsymptotic() {
        XCTAssertEqual(PaperResponse.softknee(0.01, 64), 0.01, accuracy: 1e-6)
        XCTAssertEqual(PaperResponse.softknee(0, 8), 0)
        XCTAssertLessThan(PaperResponse.softknee(1000, 8), 1.0)
        XCTAssertGreaterThan(PaperResponse.softknee(1000, 8), 0.999)
    }

    func testPaperIsStrictlyIncreasingAndBounded() {
        let p = PaperResponse.kneeP(shoulder: 40)
        let q = PaperResponse.kneeQ(toe: 30)
        var last = -1.0
        for i in 0...500 {
            let n = Double(i) / 100.0 // 0…5, well past paper white
            let y = PaperResponse.paper(n, p: p, q: q)
            XCTAssertGreaterThan(y, last, "paper() must be strictly increasing")
            XCTAssertGreaterThanOrEqual(y, 0)
            XCTAssertLessThan(y, 1.0)
            XCTAssertFalse(y.isNaN)
            last = y
        }
    }

    /// paper(0) = 1 − 2^(−1/q): the lifted-black floor, in closed form.
    func testPaperFloorMatchesClosedForm() {
        for toe in [0.0, 30, 100] {
            let q = PaperResponse.kneeQ(toe: toe)
            XCTAssertEqual(PaperResponse.paper(0, p: 16, q: q),
                           1 - pow(2, -1 / q), accuracy: 1e-9)
        }
    }

    func testKneeMappingsHitTheirDocumentedEndpoints() {
        XCTAssertEqual(PaperResponse.kneeP(shoulder: 0), 64, accuracy: 1e-9)
        XCTAssertEqual(PaperResponse.kneeP(shoulder: 100), 2, accuracy: 1e-9)
        XCTAssertEqual(PaperResponse.kneeQ(toe: 0), 512, accuracy: 1e-9)
        XCTAssertEqual(PaperResponse.kneeQ(toe: 100), 24, accuracy: 1e-9)
    }

    func testGradeScalePivotsAtTwo() {
        XCTAssertEqual(PaperResponse.gradeScale(2), 1.0, accuracy: 1e-12)
        XCTAssertEqual(PaperResponse.gradeScale(3), 1.15, accuracy: 1e-12)
        XCTAssertEqual(PaperResponse.gradeScale(1), 1 / 1.15, accuracy: 1e-12)
    }

    /// Neutral filtration (0, 0) collapses to the same scalar offset on all
    /// three channels — the enlarger analogy's "no filter pack" case.
    func testPrintOffsetsAtNeutralFiltrationIsScalarOnAllChannels() {
        let base = 1.25 * log10(2.0)
        let offsets = PaperResponse.printOffsets(exposureEV: 1.25, warmth: 0, tint: 0)
        XCTAssertEqual(offsets.0, base, accuracy: 1e-12)
        XCTAssertEqual(offsets.1, base, accuracy: 1e-12)
        XCTAssertEqual(offsets.2, base, accuracy: 1e-12)
    }

    /// ±100 warmth/tint is exactly ±0.25 EV, split red vs. blue (warmth) or
    /// applied to green alone (tint) — the closed form the doc comment
    /// promises.
    func testPrintOffsetsFullScaleFiltrationIsQuarterStop() {
        let full = 0.25 * log10(2.0)

        let warm = PaperResponse.printOffsets(exposureEV: 0, warmth: 100, tint: 0)
        XCTAssertEqual(warm.0, full, accuracy: 1e-12, "warmth +100 should add a quarter stop to red")
        XCTAssertEqual(warm.1, 0, accuracy: 1e-12, "warmth must not move green")
        XCTAssertEqual(warm.2, -full, accuracy: 1e-12, "warmth +100 should remove a quarter stop from blue")

        let cool = PaperResponse.printOffsets(exposureEV: 0, warmth: -100, tint: 0)
        XCTAssertEqual(cool.0, -full, accuracy: 1e-12)
        XCTAssertEqual(cool.2, full, accuracy: 1e-12)

        let green = PaperResponse.printOffsets(exposureEV: 0, warmth: 0, tint: 100)
        XCTAssertEqual(green.0, 0, accuracy: 1e-12, "tint must not move red")
        XCTAssertEqual(green.1, full, accuracy: 1e-12, "tint +100 should add a quarter stop to green")
        XCTAssertEqual(green.2, 0, accuracy: 1e-12, "tint must not move blue")

        let magenta = PaperResponse.printOffsets(exposureEV: 0, warmth: 0, tint: -100)
        XCTAssertEqual(magenta.1, -full, accuracy: 1e-12)

        // Exposure and filtration are additive, not exclusive: exposure sets
        // the common floor every channel inherits.
        let combined = PaperResponse.printOffsets(exposureEV: 2, warmth: 100, tint: -100)
        let base = 2 * log10(2.0)
        XCTAssertEqual(combined.0, base + full, accuracy: 1e-12)
        XCTAssertEqual(combined.1, base - full, accuracy: 1e-12)
        XCTAssertEqual(combined.2, base - full, accuracy: 1e-12)
    }

    /// The rolloff lerps every channel ratio toward 1 by a *common* weight,
    /// which scales all inter-channel differences by the same factor — so the
    /// channel ordering and the ratios of differences are invariant, and HSV
    /// hue is exactly preserved. This is where "not sigmoid" is written down.
    ///
    /// The reference value is the *pre-rolloff* straight-line fraction
    /// `(s.1−s.2)/(s.0−s.2)`, computed independently in closed form below —
    /// not a fraction taken in transmittance or density space, which the
    /// paper curve's own (nonlinear) compression would not preserve, and not
    /// the post-rolloff output fraction itself, which would make the
    /// assertion circular. `s` is exactly what the rolloff's common-weight
    /// lerp is claimed to leave invariant, so it's the only quantity that
    /// actually exercises the claim.
    func testDevelopPreservesHueThroughTheShoulder() {
        let dmin = (0.9, 0.55, 0.30)
        let dmax = (2.0, 2.0, 2.0)
        let gamma = (1.2, 1.2, 1.2)
        // A patch with three genuinely distinct channels (red densest, green
        // mid, blue thinnest) at three densities climbing into the shoulder.
        // Two channels sharing an exponent would make out.1 == out.2
        // identically and the hue check below trivially 0 ≈ 0 — it must not
        // degenerate that way for this test to mean anything.
        var lastSat = Double.infinity
        for d in [1.6, 2.0, 2.4] {
            let t = (dmin.0 * pow(10, -d), dmin.1 * pow(10, -(d - 0.6)), dmin.2 * pow(10, -(d - 0.9)))
            let out = PaperResponse.develop(t, dminLinear: dmin, dmax: dmax,
                                            gammaEffective: gamma, printOffset: (0, 0, 0),
                                            p: PaperResponse.kneeP(shoulder: 40),
                                            q: PaperResponse.kneeQ(toe: 30),
                                            satScale: 1.0)
            // Red stays the max channel, green stays the middle channel —
            // ordering preserved, strictly (no shared exponent to make this
            // pass by accidental equality).
            XCTAssertGreaterThan(out.0, out.1)
            XCTAssertGreaterThan(out.1, out.2)
            // The pre-rolloff straight-line value per channel, in closed
            // form: s = (dmin/t)^g · 10^(−g·dmax), i.e. straightLine() with
            // printOffset 0, reproduced independently rather than calling
            // through develop() so this is a check against the model, not
            // against itself.
            func straightLine(_ t: Double, _ dmin: Double, _ dmax: Double, _ g: Double) -> Double {
                pow(dmin / t, g) * pow(10, -g * dmax)
            }
            let s = (straightLine(t.0, dmin.0, dmax.0, gamma.0),
                     straightLine(t.1, dmin.1, dmax.1, gamma.1),
                     straightLine(t.2, dmin.2, dmax.2, gamma.2))
            let hueFraction = (out.1 - out.2) / (out.0 - out.2)
            let preRolloffFraction = (s.1 - s.2) / (s.0 - s.2)
            XCTAssertEqual(hueFraction, preRolloffFraction, accuracy: 1e-12)
            // …and saturation falls as it climbs.
            let sat = (out.0 - out.2) / max(out.0, 1e-9)
            XCTAssertLessThan(sat, lastSat)
            lastSat = sat
        }
    }

    /// The base (D = 0) lands near black, the densest area (D = Dmax) near
    /// white — the two ends of the enlarger analogy.
    func testDevelopMapsBaseToNearBlackAndDmaxToNearWhite() {
        let dmin = (0.9, 0.55, 0.30)
        let dmax = (2.0, 2.0, 2.0)
        // gamma solved for targetBlack exactly as AutoInvert will:
        let g = log10(PaperResponse.targetBlack) / (0.0 - 2.0)
        let gamma = (g, g, g)
        let p = PaperResponse.kneeP(shoulder: 40)
        let q = PaperResponse.kneeQ(toe: 30)

        let base = PaperResponse.develop(dmin, dminLinear: dmin, dmax: dmax,
                                         gammaEffective: gamma, printOffset: (0, 0, 0),
                                         p: p, q: q, satScale: 1.0)
        XCTAssertLessThan(max(base.0, base.1, base.2), 0.02)

        let dense = (dmin.0 * pow(10, -2.0), dmin.1 * pow(10, -2.0), dmin.2 * pow(10, -2.0))
        let white = PaperResponse.develop(dense, dminLinear: dmin, dmax: dmax,
                                          gammaEffective: gamma, printOffset: (0, 0, 0),
                                          p: p, q: q, satScale: 1.0)
        XCTAssertGreaterThan(min(white.0, white.1, white.2), 0.9)
    }

    /// Brighter-than-base input (bare lightbox) gives negative density and
    /// must land *below* the base's output, monotonically, with no NaN.
    func testDevelopSurvivesDegenerateInput() {
        let dmin = (0.9, 0.55, 0.30)
        let cases: [(Double, Double, Double)] = [
            (0, 0, 0), (1, 1, 1), (1e-9, 1e-9, 1e-9), (0.95, 0.7, 0.5),
        ]
        for t in cases {
            let out = PaperResponse.develop(t, dminLinear: dmin, dmax: (2, 2, 2),
                                            gammaEffective: (1.2, 1.2, 1.2),
                                            printOffset: (0, 0, 0), p: 16, q: 204, satScale: 1.12)
            for c in [out.0, out.1, out.2] {
                XCTAssertFalse(c.isNaN); XCTAssertFalse(c.isInfinite)
                XCTAssertGreaterThanOrEqual(c, 0); XCTAssertLessThan(c, 1.0)
            }
        }
    }

    func testSRGBEncodeDecodeRoundTrip() {
        for v in stride(from: 0.0, through: 1.0, by: 0.05) {
            XCTAssertEqual(PaperResponse.srgbDecode(PaperResponse.srgbEncode(v)), v,
                           accuracy: 1e-9)
        }
    }

    // MARK: Minilab extensions (Task 2)

    /// Every new develop() parameter at its default is an exact no-op — the
    /// same outputs as the pre-Minilab model, to the double's last bit. This is
    /// what lets renderVersion 1 photos keep their rendering through shared code.
    func testNewParametersDefaultToExactIdentity() {
        let dmin = (0.55, 0.30, 0.13)
        for i in 0...60 {
            let d = Double(i) / 20.0
            let t = (dmin.0 * pow(10, -d), dmin.1 * pow(10, -d * 1.1), dmin.2 * pow(10, -d * 0.9))
            let g = log10(PaperResponse.targetBlack) / -2.0
            let a = PaperResponse.develop(t, dminLinear: dmin, dmax: (2, 2, 2),
                                          gammaEffective: (g, g, g),
                                          printOffset: (0.05, 0.02, -0.03),
                                          p: 16, q: 204, satScale: 1.12)
            let b = PaperResponse.develop(t, dminLinear: dmin, dmax: (2, 2, 2),
                                          gammaEffective: (g, g, g),
                                          printOffset: (0.05, 0.02, -0.03),
                                          p: 16, q: 204, satScale: 1.12,
                                          shadowTrim: (0, 0, 0), midTrim: (0, 0, 0),
                                          highTrim: (0, 0, 0),
                                          punch: 0, fade: 0, glow: 0, toeChroma: 0)
            XCTAssertEqual(a.0, b.0); XCTAssertEqual(a.1, b.1); XCTAssertEqual(a.2, b.2)
        }
    }

    /// The punch S-curve is monotone at full strength (punchFullScale = 1.0 was
    /// chosen for exactly this margin: the cubic's worst slope is 1 − a·0.82).
    func testPunchStaysMonotoneAtFullStrength() {
        let g = log10(PaperResponse.targetBlack) / -2.0
        var last = -Double.infinity
        for i in 0...4000 {
            let d = Double(i) / 4000.0 * 3.0
            let t = 0.55 * pow(10, -d)
            let out = PaperResponse.develop((t, t, t), dminLinear: (0.55, 0.55, 0.55),
                                            dmax: (2, 2, 2), gammaEffective: (g, g, g),
                                            printOffset: (0, 0, 0), p: 16, q: 204,
                                            satScale: 1.0,
                                            punch: PaperResponse.punchAmount(100)).0
            XCTAssertGreaterThanOrEqual(out, last - 1e-12,
                                        "punch made the curve non-monotone at density \(d)")
            last = out
        }
    }

    /// Monotonicity alone would still hold if punch did nothing, so prove it
    /// is load-bearing: it steepens the mids around targetMid — pulling the
    /// below-mid tone down and pushing the above-mid tone up — which is what
    /// "midtone contrast" means here.
    func testPunchSteepensTheMidsAroundTheMidTarget() {
        let g = log10(PaperResponse.targetBlack) / -2.0
        func out(_ density: Double, punch: Double) -> Double {
            let t = 0.55 * pow(10, -density)
            return PaperResponse.develop((t, t, t), dminLinear: (0.55, 0.55, 0.55),
                                         dmax: (2, 2, 2), gammaEffective: (g, g, g),
                                         printOffset: (0, 0, 0), p: 16, q: 204,
                                         satScale: 1.0, punch: punch).0
        }
        let amount = PaperResponse.punchAmount(100)
        // Bracket targetMid: find one density below it and one above.
        let low = (1...300).map { Double($0) / 100.0 }.first { out($0, punch: 0) > 0.05 }!
        let high = (1...300).map { Double($0) / 100.0 }.first { out($0, punch: 0) > 0.45 }!
        XCTAssertLessThan(out(low, punch: amount), out(low, punch: 0),
                          "punch must pull the below-mid tone down")
        XCTAssertGreaterThan(out(high, punch: amount), out(high, punch: 0),
                             "punch must push the above-mid tone up")
    }

    /// Fade raises paper black; glow lowers paper white; both leave the map
    /// monotone and strictly below 1.
    func testFadeAndGlowMoveTheEndpoints() {
        let g = log10(PaperResponse.targetBlack) / -2.0
        func out(_ density: Double, fade: Double, glow: Double) -> Double {
            let t = 0.55 * pow(10, -density)
            return PaperResponse.develop((t, t, t), dminLinear: (0.55, 0.55, 0.55),
                                         dmax: (2, 2, 2), gammaEffective: (g, g, g),
                                         printOffset: (0, 0, 0), p: 16, q: 204,
                                         satScale: 1.0, fade: fade, glow: glow).0
        }
        let fadeAmount = PaperResponse.fadeLift(100)
        XCTAssertGreaterThan(out(0, fade: fadeAmount, glow: 0), out(0, fade: 0, glow: 0),
                             "fade must lift the black end")
        let glowAmount = PaperResponse.glowDrop(100)
        XCTAssertLessThan(out(3, fade: 0, glow: glowAmount), out(3, fade: 0, glow: 0),
                          "glow must lower the white end")
        XCTAssertLessThan(out(3, fade: fadeAmount, glow: glowAmount), 1.0)
    }

    /// Toe chroma compression is hue-preserving by the same argument as the
    /// highlight rolloff: one weight scales all inter-channel differences. In
    /// deep shadow the ratios move toward 1; the channel ORDER never flips.
    func testToeChromaCompressionDesaturatesShadowsWithoutHueFlip() {
        let g = log10(PaperResponse.targetBlack) / -2.0
        // A saturated deep-shadow pixel — a THIN negative, density just above
        // the base. Density is measured from the base, so a *dense* negative
        // is where the scene was bright: densities near dmax land at paper
        // white, where the toe weight is zero by construction and this test
        // could not fail no matter what the toe did.
        let t = (0.55 * pow(10, -0.40), 0.30 * pow(10, -0.25), 0.13 * pow(10, -0.10))
        let plain = PaperResponse.develop(t, dminLinear: (0.55, 0.30, 0.13),
                                          dmax: (2, 2, 2), gammaEffective: (g, g, g),
                                          printOffset: (0, 0, 0), p: 16, q: 204, satScale: 1.0)
        // Pin the regime: the assertions below are only meaningful while the
        // fixture actually lands in the toe band.
        XCTAssertLessThan(max(plain.0, max(plain.1, plain.2)), PaperResponse.toeEnd,
                          "fixture must land in the toe for this test to test anything")
        let squeezed = PaperResponse.develop(t, dminLinear: (0.55, 0.30, 0.13),
                                             dmax: (2, 2, 2), gammaEffective: (g, g, g),
                                             printOffset: (0, 0, 0), p: 16, q: 204,
                                             satScale: 1.0,
                                             toeChroma: PaperResponse.toeChromaWeight(100))
        XCTAssertNotEqual(plain.1, squeezed.1,
                          "toe chroma did nothing at all — the fixture is not in the toe")
        func spread(_ c: (Double, Double, Double)) -> Double {
            max(c.0, max(c.1, c.2)) - min(c.0, min(c.1, c.2))
        }
        XCTAssertLessThan(spread(squeezed), spread(plain),
                          "toe chroma compression must reduce shadow chroma")
        XCTAssertEqual(plain.0 < plain.1, squeezed.0 < squeezed.1, "channel order flipped")
        XCTAssertEqual(plain.1 < plain.2, squeezed.1 < squeezed.2, "channel order flipped")
    }

    /// Zone trims: a shadow trim moves a deep-shadow pixel and leaves a
    /// highlight pixel essentially alone; vice versa for a high trim. Weights
    /// come from the PRE-trim paper-output norm (no circularity).
    func testZoneTrimsAreZoneScoped() {
        let g = log10(PaperResponse.targetBlack) / -2.0
        func develop(_ density: Double, shadow: Double, high: Double) -> Double {
            let t = 0.55 * pow(10, -density)
            // Pre-folded trim: gammaEffective × density offset, as
            // FilmDensityConverter will fold it (Task 4).
            let fold = g * PaperResponse.zoneTrimDensity(shadow)
            let foldH = g * PaperResponse.zoneTrimDensity(high)
            return PaperResponse.develop((t, t, t), dminLinear: (0.55, 0.55, 0.55),
                                         dmax: (2, 2, 2), gammaEffective: (g, g, g),
                                         printOffset: (0, 0, 0), p: 16, q: 204,
                                         satScale: 1.0,
                                         shadowTrim: (fold, fold, fold),
                                         highTrim: (foldH, foldH, foldH)).0
        }
        // Deep shadow (density 0.35 ⇒ pn well under zoneShadowEnd):
        XCTAssertGreaterThan(develop(0.35, shadow: 100, high: 0), develop(0.35, shadow: 0, high: 0))
        // Bright highlight (density 2.0 ⇒ pn above zoneHighFull):
        XCTAssertEqual(develop(2.0, shadow: 100, high: 0), develop(2.0, shadow: 0, high: 0),
                       accuracy: 1e-6, "shadow trim leaked into the highlights")
        XCTAssertLessThan(develop(2.0, shadow: 0, high: -100), develop(2.0, shadow: 0, high: 0))
    }

    /// Balanced tint (renderVersion 2 semantics): green moves one way, red and
    /// blue each move half the other way — the offsets sum to zero, so tint no
    /// longer changes overall log-domain exposure. v1 (default) is unchanged.
    func testBalancedTintPreservesLogExposure() {
        let v1 = PaperResponse.printOffsets(exposureEV: 0, warmth: 0, tint: 60)
        XCTAssertEqual(v1.0, 0); XCTAssertGreaterThan(v1.1, 0); XCTAssertEqual(v1.2, 0)
        let v2 = PaperResponse.printOffsets(exposureEV: 0, warmth: 0, tint: 60,
                                            balancedTint: true)
        XCTAssertEqual(v2.0 + v2.1 + v2.2, 0, accuracy: 1e-15)
        XCTAssertEqual(v2.1, v1.1, accuracy: 1e-15, "green leg must not change")
        XCTAssertEqual(v2.0, -v1.1 / 2, accuracy: 1e-15)
        XCTAssertEqual(v2.2, -v1.1 / 2, accuracy: 1e-15)
    }
}
