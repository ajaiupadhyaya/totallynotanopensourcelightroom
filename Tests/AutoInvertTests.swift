import CoreImage
import XCTest
@testable import PhotoEditor

final class AutoInvertTests: XCTestCase {
    private let context = CIContext()

    private func develop(_ sceneLinear: (Double, Double, Double),
                         with solution: AutoInvertSolution,
                         gammasSim: (Double, Double, Double) = FilmSim.crossoverGammas,
                         printSettings: PrintSettings) -> (Double, Double, Double) {
        let t = FilmSim.transmittance(of: sceneLinear, dmin: FilmSim.c41Base,
                                      gammas: gammasSim)
        let dminLin = (PaperResponse.srgbDecode(solution.baseColor.red),
                       PaperResponse.srgbDecode(solution.baseColor.green),
                       PaperResponse.srgbDecode(solution.baseColor.blue))
        let grade = PaperResponse.gradeScale(printSettings.contrast)
        return PaperResponse.develop(
            t, dminLinear: dminLin,
            dmax: (solution.dmax.red, solution.dmax.green, solution.dmax.blue),
            gammaEffective: (solution.gamma.red * grade, solution.gamma.green * grade,
                             solution.gamma.blue * grade),
            printOffset: PaperResponse.printOffsets(exposureEV: solution.printExposure,
                                                     warmth: printSettings.warmth,
                                                     tint: printSettings.tint),
            p: PaperResponse.kneeP(shoulder: printSettings.shoulder),
            q: PaperResponse.kneeQ(toe: printSettings.toe),
            satScale: 1.0 + printSettings.saturation / 100.0)
    }

    /// The headline: a negative with deliberate crossover, solved blind, and
    /// the greys come back grey at BOTH ends. This is the property the matrix
    /// engine cannot have, and the next test documents that side by side.
    func testAutoRecoversNeutralsThroughCrossover() throws {
        let scan = FilmSim.negativeImage(dmin: FilmSim.c41Base,
                                         gammas: FilmSim.crossoverGammas)
        let solution = try XCTUnwrap(AutoInvert.solve(scan: scan, sampledBase: nil,
                                                      profile: .linear,
                                                      context: context))
        XCTAssertFalse(solution.isDegraded, "clean fixture must solve cleanly: \(solution.degradedTerms)")

        // Judge with the look controls neutralized: shoulder/toe off, flat
        // saturation — this test is about the SOLVE, not the house rendering.
        var flat = PrintSettings()
        flat.shoulder = 0; flat.toe = 0; flat.saturation = 0; flat.warmth = 0; flat.tint = 0

        for grey in ["shadowGrey", "midGrey", "lightGrey"] {
            let patch = FilmSim.scene().first { $0.name == grey }!.linear
            let out = develop(patch, with: solution, printSettings: flat)
            let lab = DeltaE.srgbToLab(r: PaperResponse.srgbEncode(out.0),
                                              g: PaperResponse.srgbEncode(out.1),
                                              b: PaperResponse.srgbEncode(out.2))
            XCTAssertLessThan(abs(lab.a), 5.0, "\(grey) has a cast: a*=\(lab.a)")
            XCTAssertLessThan(abs(lab.b), 5.0, "\(grey) has a cast: b*=\(lab.b)")
        }

        // Neutrality alone is direction-blind: a fully-inverted print of a
        // neutral scene is still neutral at every patch, just backwards (this
        // is not hypothetical — deleting AutoInvert's density re-sort produces
        // exactly that, and the neutrality checks above stay green). Assert
        // tone ORDER too, so a black-for-white inversion cannot pass silently.
        let toneOrder = ["black", "shadowGrey", "midGrey", "lightGrey", "white"]
        let levels = toneOrder.map { name -> Double in
            let patch = FilmSim.scene().first { $0.name == name }!.linear
            let out = develop(patch, with: solution, printSettings: flat)
            return max(out.0, max(out.1, out.2))
        }
        for i in 1..<levels.count {
            XCTAssertGreaterThan(levels[i], levels[i - 1],
                "\(toneOrder[i]) (\(levels[i])) should print lighter than \(toneOrder[i - 1]) (\(levels[i - 1]))")
        }
    }

    /// The matrix model's best case on the same fixture: base divided out
    /// perfectly and gains chosen to neutralize middle grey exactly. The ends
    /// still diverge — one gain per channel scales shadows and highlights
    /// together. Documented as a measured margin, not a claim.
    func testCrossoverIsProvablyBeyondTheMatrixModel() throws {
        let scan = FilmSim.negativeImage(dmin: FilmSim.c41Base,
                                         gammas: FilmSim.crossoverGammas)
        let solution = try XCTUnwrap(AutoInvert.solve(scan: scan, sampledBase: nil,
                                                      profile: .linear,
                                                      context: context))
        var flat = PrintSettings()
        flat.shoulder = 0; flat.toe = 0; flat.saturation = 0; flat.warmth = 0; flat.tint = 0

        // Matrix best case, computed in its own gamma-encoded domain: for each
        // channel, out = g·(1 − enc(t)/enc(base)); solve g so midGrey lands
        // exactly neutral, then measure the extremes.
        func matrix(_ scene: (Double, Double, Double), gains: (Double, Double, Double))
            -> (Double, Double, Double) {
            let t = FilmSim.transmittance(of: scene, dmin: FilmSim.c41Base,
                                          gammas: FilmSim.crossoverGammas)
            let base = FilmSim.c41Base
            func ch(_ t: Double, _ b: Double, _ g: Double) -> Double {
                g * (1 - PaperResponse.srgbEncode(t) / PaperResponse.srgbEncode(b))
            }
            return (ch(t.0, base.0, gains.0), ch(t.1, base.1, gains.1), ch(t.2, base.2, gains.2))
        }
        let mid = FilmSim.scene().first { $0.name == "midGrey" }!.linear
        let rawMid = matrix(mid, gains: (1, 1, 1))
        let target = (rawMid.0 + rawMid.1 + rawMid.2) / 3
        let gains = (target / rawMid.0, target / rawMid.1, target / rawMid.2)

        func chromaError(_ rgb: (Double, Double, Double)) -> Double {
            let lab = DeltaE.srgbToLab(r: min(max(rgb.0, 0), 1),
                                              g: min(max(rgb.1, 0), 1),
                                              b: min(max(rgb.2, 0), 1))
            return (lab.a * lab.a + lab.b * lab.b).squareRoot()
        }

        for grey in ["shadowGrey", "lightGrey"] {
            let patch = FilmSim.scene().first { $0.name == grey }!.linear
            let matrixErr = chromaError(matrix(patch, gains: gains))
            let out = develop(patch, with: solution, printSettings: flat)
            let densityErr = chromaError((PaperResponse.srgbEncode(out.0),
                                          PaperResponse.srgbEncode(out.1),
                                          PaperResponse.srgbEncode(out.2)))
            XCTAssertGreaterThan(matrixErr, densityErr * 2,
                "\(grey): matrix residual \(matrixErr) should dwarf density residual \(densityErr)")
        }
    }

    /// A sampled base wins over the percentile estimate, and the solution
    /// reports which one it used.
    func testSampledBaseIsUsedAndReported() throws {
        let scan = FilmSim.negativeImage(dmin: FilmSim.c41Base,
                                         gammas: FilmSim.crossoverGammas)
        let sampledBase = FilmColor(red: PaperResponse.srgbEncode(FilmSim.c41Base.0),
                                    green: PaperResponse.srgbEncode(FilmSim.c41Base.1),
                                    blue: PaperResponse.srgbEncode(FilmSim.c41Base.2))
        let solution = try XCTUnwrap(AutoInvert.solve(scan: scan, sampledBase: sampledBase,
                                                      profile: .linear,
                                                      context: context))
        XCTAssertEqual(solution.baseOrigin, .sampled)
        XCTAssertEqual(solution.baseColor, sampledBase)

        let estimated = try XCTUnwrap(AutoInvert.solve(scan: scan, sampledBase: nil,
                                                       profile: .linear,
                                                       context: context))
        XCTAssertEqual(estimated.baseOrigin, .estimated)
    }

    /// Median density lands at the target midtone — the printEV bisection.
    ///
    /// `printExposure` is a bisection midpoint of bounds that only narrow, so
    /// `isNaN` and range-membership can never fail on their own — they don't
    /// test the property this test is named for. The real, falsifiable claim
    /// is that DEVELOPING the scan's actual median tone with the solved
    /// parameters lands on `PaperResponse.targetMid`, so this recomputes the
    /// median-density transmittance independently (the same way `AutoInvert`
    /// measured it: `dminLinear` recovered from the reported `baseColor`,
    /// median density from a fresh percentile pass over the scan) rather than
    /// trusting the solver's own internal bookkeeping.
    func testPrintExposurePlacesTheMedianAtMiddleGrey() throws {
        let scan = FilmSim.negativeImage(dmin: FilmSim.c41Base,
                                         gammas: FilmSim.crossoverGammas)
        let solution = try XCTUnwrap(AutoInvert.solve(scan: scan, sampledBase: nil,
                                                      profile: .linear,
                                                      context: context))
        XCTAssertFalse(solution.printExposure.isNaN)
        XCTAssertTrue((-8.0...8.0).contains(solution.printExposure))

        let pixels = try XCTUnwrap(AutoInvert.linearPixels(of: scan, side: AutoInvert.sampleSide,
                                                           context: context))
        let dminLinear = (PaperResponse.srgbDecode(solution.baseColor.red),
                          PaperResponse.srgbDecode(solution.baseColor.green),
                          PaperResponse.srgbDecode(solution.baseColor.blue))
        func density(_ t: Double, _ dmin: Double) -> Double {
            log10(max(dmin, 1e-4) / max(t, PaperResponse.transmittanceFloor))
        }
        let reds = pixels.map { density($0.0, dminLinear.0) }.sorted()
        let greens = pixels.map { density($0.1, dminLinear.1) }.sorted()
        let blues = pixels.map { density($0.2, dminLinear.2) }.sorted()
        let medianD = (AutoInvert.percentile(reds, 0.5), AutoInvert.percentile(greens, 0.5),
                       AutoInvert.percentile(blues, 0.5))
        let medianT = (dminLinear.0 * pow(10, -medianD.0), dminLinear.1 * pow(10, -medianD.1),
                       dminLinear.2 * pow(10, -medianD.2))

        let defaults = PrintSettings()
        let out = PaperResponse.develop(
            medianT, dminLinear: dminLinear,
            dmax: (solution.dmax.red, solution.dmax.green, solution.dmax.blue),
            gammaEffective: (solution.gamma.red, solution.gamma.green, solution.gamma.blue),
            printOffset: PaperResponse.printOffsets(exposureEV: solution.printExposure,
                                                     warmth: defaults.warmth, tint: defaults.tint),
            p: PaperResponse.kneeP(shoulder: defaults.shoulder),
            q: PaperResponse.kneeQ(toe: defaults.toe),
            satScale: 1.0)
        let maxChannel = max(out.0, max(out.1, out.2))
        // 0.005 tolerance absorbs printExposure's 2-decimal-place rounding.
        XCTAssertEqual(maxChannel, PaperResponse.targetMid, accuracy: 0.005,
            "solved printExposure should place the median density at display middle grey: got \(maxChannel)")
    }

    /// A flat scan has no tonal range to solve against: every term that
    /// cannot be measured degrades to its default and says so, rather than
    /// producing a confidently wrong number.
    func testFlatScanDegradesGracefully() throws {
        let flat = TestSupport.solidImage(red: 0.5, green: 0.35, blue: 0.2,
                                          size: 64)
        let solution = try XCTUnwrap(AutoInvert.solve(scan: flat, sampledBase: nil,
                                                      profile: .linear, context: context))
        XCTAssertTrue(solution.isDegraded)
        XCTAssertEqual(solution.gamma, .unit, "unmeasurable gamma falls back to 1")
        for g in [solution.gamma.red, solution.dmax.red, solution.printExposure] {
            XCTAssertFalse(g.isNaN)
        }
    }

    // MARK: Measure/solve split (Task 6)

    /// The measure/solve split is pure refactor: solving a measurement must give
    /// the same numbers the one-shot wrapper gives, and (under .linear) the same
    /// numbers the pre-split solver gave — anchored by the conformance suite's
    /// reproducibility test and the unchanged corpus prints.
    func testMeasureThenSolveEqualsTheWrapper() throws {
        let probe = FilmSim.negativeImage(dmin: FilmSim.c41Base,
                                          gammas: FilmSim.crossoverGammas, size: 128)
        let context = CIContext()
        let m = try XCTUnwrap(AutoInvert.measure(scan: probe, sampledBase: nil,
                                                 context: context))
        let a = try XCTUnwrap(AutoInvert.solve(from: m, profile: .linear))
        let b = try XCTUnwrap(AutoInvert.solve(scan: probe, sampledBase: nil,
                                               profile: .linear, context: context))
        XCTAssertEqual(a, b)
    }

    /// Profile-aware placement: the Lab profiles change the rendering the median
    /// lands under (punch/fade/glow), so the solved EV must differ from linear's
    /// — if it didn't, the bisection would be ignoring the profile.
    func testLabProfileSolvesADifferentExposureThanLinear() throws {
        let probe = FilmSim.negativeImage(dmin: FilmSim.c41Base,
                                          gammas: FilmSim.crossoverGammas, size: 128)
        let context = CIContext()
        let linear = try XCTUnwrap(AutoInvert.solve(scan: probe, sampledBase: nil,
                                                    profile: .linear, context: context))
        let lab = try XCTUnwrap(AutoInvert.solve(scan: probe, sampledBase: nil,
                                                 profile: .labStandard, context: context))
        XCTAssertNotEqual(linear.printExposure, lab.printExposure)
        XCTAssertEqual(linear.dmax, lab.dmax, "endpoint statistics are profile-independent")
        XCTAssertEqual(linear.gamma, lab.gamma, "gammas are profile-independent")

        // The linear-vs-lab difference alone cannot prove the bisection reads
        // the TONING: both Lab profiles solve the identical cast (cast
        // depends only on medians/gamma/dmax), so if soft and standard solve
        // different EVs, only punch/fade/glow/toeChroma can be separating
        // them — the group review showed deleting those defaulted arguments
        // from solveExposure's develop() call compiled silently and survived
        // the original assertion via the cast fold.
        let soft = try XCTUnwrap(AutoInvert.solve(scan: probe, sampledBase: nil,
                                                  profile: .labSoft, context: context))
        XCTAssertEqual(soft.cast, lab.cast, "cast is profile-toning-independent")
        XCTAssertNotEqual(soft.printExposure, lab.printExposure,
                          "identical cast, different toning — only the toning "
                          + "parameters can separate these EVs")
    }

    /// The solved median density is reported (it becomes gradePivot): rendering
    /// the median transmittance under the solved stack must land its max channel
    /// at targetMid — the bisection's own contract, now visible in the solution.
    func testMedianDensityIsReportedAndLandsAtTargetMid() throws {
        let probe = FilmSim.negativeImage(dmin: FilmSim.c41Base,
                                          gammas: FilmSim.crossoverGammas, size: 128)
        let context = CIContext()
        let s = try XCTUnwrap(AutoInvert.solve(scan: probe, sampledBase: nil,
                                               profile: .linear, context: context))
        XCTAssertGreaterThan(s.medianDensity.red, 0)
        let dminLin = (PaperResponse.srgbDecode(s.baseColor.red),
                       PaperResponse.srgbDecode(s.baseColor.green),
                       PaperResponse.srgbDecode(s.baseColor.blue))
        let medianT = (dminLin.0 * pow(10, -s.medianDensity.red),
                       dminLin.1 * pow(10, -s.medianDensity.green),
                       dminLin.2 * pow(10, -s.medianDensity.blue))
        let defaults = PrintSettings()
        let offset = PaperResponse.printOffsets(exposureEV: s.printExposure,
                                                warmth: defaults.warmth,
                                                tint: defaults.tint, balancedTint: true)
        let out = PaperResponse.develop(
            medianT, dminLinear: dminLin,
            dmax: (s.dmax.red, s.dmax.green, s.dmax.blue),
            gammaEffective: (s.gamma.red, s.gamma.green, s.gamma.blue),
            printOffset: offset,
            p: PaperResponse.kneeP(shoulder: defaults.shoulder),
            q: PaperResponse.kneeQ(toe: defaults.toe), satScale: 1.0)
        XCTAssertEqual(max(out.0, max(out.1, out.2)), PaperResponse.targetMid,
                       accuracy: 0.01)
    }
}
