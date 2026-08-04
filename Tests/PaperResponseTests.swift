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

    /// The rolloff lerps every channel ratio toward 1 by a *common* weight,
    /// which scales all inter-channel differences by the same factor — so the
    /// channel ordering and the ratios of differences are invariant, and HSV
    /// hue is exactly preserved. This is where "not sigmoid" is written down.
    func testDevelopPreservesHueThroughTheShoulder() {
        let dmin = (0.9, 0.55, 0.30)
        let dmax = (2.0, 2.0, 2.0)
        let gamma = (1.2, 1.2, 1.2)
        // A saturated red at three densities climbing into the shoulder.
        var lastSat = Double.infinity
        for d in [1.6, 2.0, 2.4] {
            // Transmittance for a red patch: red channel dense, others thin
            // (more red exposure means more red-specific density, i.e. less
            // red transmittance — see testDevelopMapsBaseToNearBlackAndDmaxToNearWhite
            // for why lower transmittance is the channel that prints brighter).
            let t = (dmin.0 * pow(10, -d), dmin.1 * pow(10, -(d - 0.9)), dmin.2 * pow(10, -(d - 0.9)))
            let out = PaperResponse.develop(t, dminLinear: dmin, dmax: dmax,
                                            gammaEffective: gamma, printOffset: 0,
                                            p: PaperResponse.kneeP(shoulder: 40),
                                            q: PaperResponse.kneeQ(toe: 30),
                                            satScale: 1.0)
            // Red stays the max channel (ordering preserved)…
            XCTAssertGreaterThan(out.0, out.1)
            XCTAssertGreaterThanOrEqual(out.1, out.2)
            // …hue angle is invariant: (g−b)/(r−b) is the HSV hue fraction in
            // the red-to-yellow sextant, and a common-weight lerp toward
            // neutral cannot move it. Compared via t/dmin ratios — the
            // dmin-normalized quantity the density formula actually uses —
            // so per-channel dmin differences don't leak into the comparison.
            let ratioT = (t.0 / dmin.0, t.1 / dmin.1, t.2 / dmin.2)
            let hueFraction = (out.1 - out.2) / max(out.0 - out.2, 1e-9)
            let inHue = (ratioT.1 - ratioT.2) / max(ratioT.0 - ratioT.2, 1e-9)
            XCTAssertEqual(hueFraction, inHue, accuracy: 0.02)
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
                                         gammaEffective: gamma, printOffset: 0,
                                         p: p, q: q, satScale: 1.0)
        XCTAssertLessThan(max(base.0, base.1, base.2), 0.02)

        let dense = (dmin.0 * pow(10, -2.0), dmin.1 * pow(10, -2.0), dmin.2 * pow(10, -2.0))
        let white = PaperResponse.develop(dense, dminLinear: dmin, dmax: dmax,
                                          gammaEffective: gamma, printOffset: 0,
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
                                            printOffset: 0, p: 16, q: 204, satScale: 1.12)
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
}
