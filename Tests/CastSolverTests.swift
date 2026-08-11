import CoreImage
import XCTest
@testable import PhotoEditor

final class CastSolverTests: XCTestCase {
    /// The defining property: applying the solved offsets makes the three
    /// straight-line log outputs equal, and their mean is unchanged (the
    /// correction moves colour, not exposure).
    func testSolvedOffsetsEqualizeWithoutMovingTheMean() {
        let d = DensityTriple(red: 1.30, green: 1.05, blue: 0.85)
        let gamma = DensityTriple(red: 1.1, green: 1.2, blue: 1.35)
        let dmax = DensityTriple(red: 2.2, green: 2.1, blue: 1.9)
        let o = CastSolver.densityOffsets(neutralDensity: d, gamma: gamma, dmax: dmax)
        func L(_ dd: Double, _ oo: Double, _ g: Double, _ dm: Double) -> Double {
            g * (dd + oo - dm)
        }
        let l = (L(d.red, o.red, gamma.red, dmax.red),
                 L(d.green, o.green, gamma.green, dmax.green),
                 L(d.blue, o.blue, gamma.blue, dmax.blue))
        XCTAssertEqual(l.0, l.1, accuracy: 1e-12)
        XCTAssertEqual(l.1, l.2, accuracy: 1e-12)
        let before = (L(d.red, 0, gamma.red, dmax.red)
                      + L(d.green, 0, gamma.green, dmax.green)
                      + L(d.blue, 0, gamma.blue, dmax.blue)) / 3
        XCTAssertEqual(l.0, before, accuracy: 1e-12,
                       "the equalized level must be the pre-correction mean")
    }

    func testCastSlidersRoundTripAndClamp() {
        // PLAN BUG, corrected: the plan's fixture (1.30/1.05/0.85) needs a
        // −0.233 density offset on red, but full slider scale is
        // castFullScaleEV·log10(2) ≈ ±0.1505 — the offset it asserted
        // unclipped CANNOT be represented unclipped. This spread stays inside
        // the range (largest offset ≈ 0.107).
        let d = DensityTriple(red: 1.16, green: 1.05, blue: 0.95)
        let gamma = DensityTriple.unit
        let dmax = DensityTriple(red: 2, green: 2, blue: 2)
        let s = CastSolver.castSliders(neutralDensity: d, gamma: gamma, dmax: dmax)
        XCTAssertFalse(s.clipped)
        XCTAssertEqual(PaperResponse.castDensity(s.red),
                       CastSolver.densityOffsets(neutralDensity: d, gamma: gamma,
                                                 dmax: dmax).red,
                       accuracy: 1e-12)
        // A cast far past the slider range must clamp and say so.
        let wild = DensityTriple(red: 2.5, green: 1.0, blue: 0.2)
        let clamped = CastSolver.castSliders(neutralDensity: wild, gamma: gamma,
                                             dmax: dmax)
        XCTAssertTrue(clamped.clipped)
        XCTAssertLessThanOrEqual(abs(clamped.red), 100)
    }

    /// End-to-end: inject a green cast into the scan while PINNING the base
    /// with a sampled true-base, solve under labStandard, and auto colour
    /// balance must return the render to what the clean scan gets.
    ///
    /// PLAN BUG, corrected after a measured diagnostic. The plan injected the
    /// cast with a free (estimated) base and asserted absolute midtone chroma
    /// < 0.06. Two things made that test wrong rather than strict:
    /// - A global channel scale rescales the rebate too, so the 98th-percentile
    ///   Dmin estimate absorbs it COMPLETELY — densities never change, and the
    ///   "injected" solve equals the clean solve to 1.5e-6 with the cast
    ///   solver deleted. The perturbation never reached the mechanism under
    ///   test. Pinning the base with `sampledBase` (the seam the eyedropper
    ///   and Phase 3 rebate use) makes the injection land in the densities,
    ///   where the solver must remove it.
    /// - The render deliberately carries the house filtration (warmth 24 /
    ///   tint −8 ≈ 0.08 midtone chroma by construction) and this probe is a
    ///   COLOUR CHART — gray-world's own no-go case (measured: auto-balance
    ///   moves this probe's midtone chroma 0.089 → 0.142, and correctly
    ///   reports the gray-world degraded term while doing it). An absolute
    ///   0.06 was unreachable on this probe with or without a perfect solver.
    /// The honest contract is differential: whatever taste auto-balance
    /// imposes, a scan-side cast must not survive into the final render.
    func testAutoColorBalanceNeutralizesAnInjectedCast() throws {
        let context = CIContext()
        let clean = FilmSim.negativeImage(dmin: FilmSim.c41Base,
                                          gammas: FilmSim.crossoverGammas, size: 128)
        // Inject: green transmittance × 10^(−0.12) — a green-magenta cast of
        // 0.12 density, well inside the ±0.5 EV solver range.
        let castMatrix = CIFilter.colorMatrix()
        castMatrix.inputImage = clean
        castMatrix.gVector = CIVector(x: 0, y: CGFloat(pow(10.0, -0.12)), z: 0, w: 0)
        let injected = castMatrix.outputImage!
        // The TRUE base, sampled — so the injection cannot hide in the
        // Dmin estimate.
        let trueBase = FilmColor(red: PaperResponse.srgbEncode(FilmSim.c41Base.0),
                                 green: PaperResponse.srgbEncode(FilmSim.c41Base.1),
                                 blue: PaperResponse.srgbEncode(FilmSim.c41Base.2))
        func medianChroma(_ solution: AutoInvertSolution, scan: CIImage) throws -> Double {
            var stack = EditStack()
            stack.filmNegative.isEnabled = true
            stack.filmNegative.conversionModel = .density
            stack.filmNegative.baseColor = solution.baseColor
            stack.filmNegative.baseOrigin = solution.baseOrigin
            stack.filmNegative.print.dmax = solution.dmax
            stack.filmNegative.print.gamma = solution.gamma
            stack.filmNegative.print.exposure = solution.printExposure
            stack.filmNegative.print.gradePivot = solution.medianDensity
            stack.filmNegative.print.castRed = solution.cast.red
            stack.filmNegative.print.castGreen = solution.cast.green
            stack.filmNegative.print.castBlue = solution.cast.blue
            stack.filmNegative.print.applyToneProfile(.labStandard)
            let out = EditRenderer().render(source: scan, stack: stack)
            let px = try XCTUnwrap(AutoInvert.linearPixels(of: out, side: 64,
                                                           context: context))
            let med = (AutoInvert.percentile(px.map(\.0).sorted(), 0.5),
                       AutoInvert.percentile(px.map(\.1).sorted(), 0.5),
                       AutoInvert.percentile(px.map(\.2).sorted(), 0.5))
            let n = max(med.0, max(med.1, med.2))
            return n > 0 ? (n - min(med.0, min(med.1, med.2))) / n : 0
        }

        // The wiring is exact: the solution's cast must BE the closed form
        // evaluated on the solution's own statistics — no drift, no rescale,
        // no forgotten gamma — and on the crossover probe it is nonzero (the
        // mid-vs-endpoints imbalance is this probe's defining defect).
        let cleanLab = try XCTUnwrap(AutoInvert.solve(scan: clean, sampledBase: trueBase,
                                                      profile: .labStandard, context: context))
        let expected = CastSolver.castSliders(neutralDensity: cleanLab.medianDensity,
                                              gamma: cleanLab.gamma, dmax: cleanLab.dmax)
        XCTAssertEqual(cleanLab.cast.red, expected.red, accuracy: 1e-9)
        XCTAssertEqual(cleanLab.cast.green, expected.green, accuracy: 1e-9)
        XCTAssertEqual(cleanLab.cast.blue, expected.blue, accuracy: 1e-9)
        XCTAssertNotEqual(cleanLab.cast, .zero,
                          "the crossover probe's mid imbalance must solve a nonzero cast")

        // DISCOVERED INVARIANCE (this is the corrected claim): a global
        // channel scale cancels inside L = γ·(D_median − D_max) — the
        // endpoint solve absorbs it — so gray-world neither sees it nor
        // mis-attributes it, and the balanced render of the injected scan
        // equals the balanced render of the clean scan. Global casts are
        // UNOBSERVABLE from one frame's statistics (every layer normalizes
        // them away); absolute reference comes from the neutral picker, which
        // is why the spec ships both tools.
        let balanced = try XCTUnwrap(AutoInvert.solve(scan: injected, sampledBase: trueBase,
                                                      profile: .labStandard, context: context))
        XCTAssertEqual(balanced.cast.green, cleanLab.cast.green, accuracy: 1.0,
                       "a global scale must not be mis-read as a cast")
        let chromaClean = try medianChroma(cleanLab, scan: clean)
        let chromaBalanced = try medianChroma(balanced, scan: injected)
        XCTAssertEqual(chromaBalanced, chromaClean, accuracy: 0.01,
                       "the injected global cast must not survive into the render")

        // Gray-world honesty: this probe IS a colour chart, and the solve
        // must say so rather than balance it silently.
        XCTAssertTrue(balanced.degradedTerms.contains {
            $0.contains("strongly coloured")
        }, "the gray-world honesty gate must fire on a colour-chart probe")

        let linear = try XCTUnwrap(AutoInvert.solve(scan: injected, sampledBase: trueBase,
                                                    profile: .linear, context: context))
        XCTAssertEqual(linear.cast.red, 0, "linear must not auto-balance")
    }
}
