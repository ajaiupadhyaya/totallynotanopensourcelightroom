import CoreImage
import XCTest
@testable import PhotoEditor

final class RollAnalysisTests: XCTestCase {
    private let context = CIContext()

    /// Four frames of one simulated roll: identical film (base + gammas),
    /// different content — a full-scene frame, a shadow-heavy crop, a
    /// highlight-heavy crop — plus a thinner exposure. The situation that
    /// makes per-frame Auto inconsistent by construction.
    ///
    /// PLAN BUG, corrected: the plan's "thinner exposure" scaled the WHOLE
    /// frame ×10^−0.2 — rebate included. Camera exposure cannot touch the
    /// rebate (it is unexposed film); scaling it too simulates scan-gain
    /// drift between frames, which is the one variation the roll model's
    /// premise excludes (one roll, one scan session) and which per-frame
    /// base estimation legitimately handles better — the fixture made the
    /// test unpassable for reasons that argued FOR per-frame solving. The
    /// thin frame now dims only the image interior; its rebate matches the
    /// roll's, as film physics requires.
    private func rollFrames() -> [CIImage] {
        let full = FilmSim.negativeImage(dmin: FilmSim.c41Base,
                                         gammas: FilmSim.crossoverGammas, size: 128)
        // SECOND PLAN BUG here, same correction pass: the plan cropped both
        // half-frames to the pure interior (x/y from 12), which cuts the
        // rebate out of them entirely — while the variance metric below
        // samples "the rebate in every frame's lower-left corner." For those
        // frames the corner was two DIFFERENT scene patches, whose chroma no
        // solver could make agree. Real half-frame compositions still carry
        // the rebate; these crops keep the bottom-left border strip so the
        // metric's premise is actually true of its fixture.
        let dark = full.cropped(to: CGRect(x: 0, y: 0, width: 62, height: 128))
        let bright = full.cropped(to: CGRect(x: 66, y: 0, width: 62, height: 128))
        let dim = CIFilter.colorMatrix()
        // The fixture's interior (border = size/10 = 12): scene patches only.
        let interior = CGRect(x: 12, y: 12, width: 104, height: 104)
        dim.inputImage = full.cropped(to: interior)
        let k = CGFloat(pow(10.0, -0.2)) // −0.2 density: a thinner exposure
        dim.rVector = CIVector(x: k, y: 0, z: 0, w: 0)
        dim.gVector = CIVector(x: 0, y: k, z: 0, w: 0)
        dim.bVector = CIVector(x: 0, y: 0, z: k, w: 0)
        let thin = dim.outputImage!.composited(over: full)
        // A FOGGED frame: uniform extra density over the whole frame, rebate
        // included — that is what fog physically does. It exists to make the
        // base-envelope DIRECTION falsifiable: with four identical rebates,
        // min and max of the per-frame estimates were equal and the group
        // review proved the min→max fix untestable. The fogged rebate is
        // darker; the spec's "thinnest film is closest to true base" demands
        // the envelope ignore it (max transmittance), and the ground-truth
        // assertion below fails under min.
        let fog = CIFilter.colorMatrix()
        fog.inputImage = full
        let kf = CGFloat(pow(10.0, -0.05))
        fog.rVector = CIVector(x: kf, y: 0, z: 0, w: 0)
        fog.gVector = CIVector(x: 0, y: kf, z: 0, w: 0)
        fog.bVector = CIVector(x: 0, y: 0, z: kf, w: 0)
        let fogged = fog.outputImage!
        return [full, dark, bright, thin, fogged]
    }

    /// The clean four — no fog. The corner-variance metric is premised on
    /// every frame's rebate being IDENTICAL material; the fogged frame
    /// violates that premise by construction (its rebate genuinely differs),
    /// so it belongs only to the constants/envelope test above, never here.
    private func cleanRollFrames() -> [CIImage] {
        Array(rollFrames().prefix(4))
    }

    func testRollConstantsAreSharedAndPerFrameSolvesAreNot() throws {
        let frames = rollFrames()
        let ms = try frames.map {
            try XCTUnwrap(AutoInvert.measure(scan: $0, sampledBase: nil,
                                             context: context))
        }
        // Per-frame: the gammas genuinely differ across these frames — the
        // inconsistency this whole task exists to remove.
        let perFrame = try ms.map { try XCTUnwrap(AutoInvert.solve(from: $0, profile: .linear)) }
        let gammaSpread = perFrame.map(\.gamma.red).max()! - perFrame.map(\.gamma.red).min()!
        XCTAssertGreaterThan(gammaSpread, 0.01,
                             "the fixture no longer provokes per-frame drift — strengthen it")

        let roll = try XCTUnwrap(RollAnalysis.solve(measurements: ms, profile: .linear))
        XCTAssertEqual(roll.frameExposures.count, frames.count)
        XCTAssertEqual(roll.framePivots.count, frames.count)
        // One gamma/dmax/base for the roll; exposures differ per frame.
        XCTAssertGreaterThan(
            roll.frameExposures.max()! - roll.frameExposures.min()!, 0.05,
            "the dimmed frame must solve a different exposure")

        // GROUND TRUTH (group review: without these, ANY shared-but-wrong
        // pooling passed — shared garbage renders consistently). The fixture
        // KNOWS its film: base is FilmSim.c41Base, and the fogged frame's
        // darker rebate must lose the envelope to the clean frames' (max
        // transmittance = thinnest film). Tolerance covers the 98th-pct
        // estimator reading base-adjacent texture, not the envelope
        // direction: under min() the fogged estimate wins and red lands
        // ~11% low, far outside this band.
        let truth = (PaperResponse.srgbEncode(FilmSim.c41Base.0),
                     PaperResponse.srgbEncode(FilmSim.c41Base.1),
                     PaperResponse.srgbEncode(FilmSim.c41Base.2))
        XCTAssertEqual(roll.conversion.baseColor.red, truth.0, accuracy: 0.03)
        XCTAssertEqual(roll.conversion.baseColor.green, truth.1, accuracy: 0.03)
        XCTAssertEqual(roll.conversion.baseColor.blue, truth.2, accuracy: 0.03)
        // And the pooled gamma must agree with the full-frame per-frame solve
        // to first order — pooling refines the same statistics, it does not
        // invent different ones.
        XCTAssertEqual(roll.conversion.gamma.red, perFrame[0].gamma.red,
                       accuracy: perFrame[0].gamma.red * 0.25,
                       "pooled gamma far from the full-frame solve — wrong pooling")
    }

    /// The metric that justifies the feature: the rebate (border) of every
    /// frame is IDENTICAL film base, so after conversion its chromaticity
    /// should agree across frames. Roll-solved frames must agree at least as
    /// well as per-frame-solved ones (in practice far better).
    func testRollSolveShrinksCrossFrameChromaVariance() throws {
        let frames = cleanRollFrames()
        let ms = try frames.map {
            try XCTUnwrap(AutoInvert.measure(scan: $0, sampledBase: nil,
                                             context: context))
        }
        let perFrame = try ms.map { try XCTUnwrap(AutoInvert.solve(from: $0, profile: .linear)) }
        let roll = try XCTUnwrap(RollAnalysis.solve(measurements: ms, profile: .linear))

        func borderChroma(_ image: CIImage, settings: FilmNegativeSettings) throws -> Double {
            let out = FilmDensityConverter.convert(image, settings: settings)
            // The frame's lower-left corner is rebate in every fixture frame.
            let corner = out.cropped(to: CGRect(x: out.extent.minX, y: out.extent.minY,
                                                width: 8, height: 8))
            let px = try XCTUnwrap(AutoInvert.linearPixels(of: corner, side: 8,
                                                           context: context))
            let mean = px.reduce((0.0, 0.0, 0.0)) { ($0.0 + $1.0, $0.1 + $1.1, $0.2 + $1.2) }
            let c = (mean.0 / Double(px.count), mean.1 / Double(px.count),
                     mean.2 / Double(px.count))
            let n = max(c.0, max(c.1, c.2))
            return n > 0 ? (n - min(c.0, min(c.1, c.2))) / n : 0
        }
        func settings(base: FilmColor, origin: FilmBaseOrigin, gamma: DensityTriple,
                      dmax: DensityTriple, ev: Double, pivot: DensityTriple) -> FilmNegativeSettings {
            var f = FilmNegativeSettings()
            f.isEnabled = true; f.conversionModel = .density
            f.baseColor = base; f.baseOrigin = origin
            f.print.gamma = gamma; f.print.dmax = dmax
            f.print.exposure = ev; f.print.gradePivot = pivot
            return f
        }
        func variance(_ v: [Double]) -> Double {
            let m = v.reduce(0, +) / Double(v.count)
            return v.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(v.count)
        }
        let perFrameChroma = try zip(frames, perFrame).map { frame, s in
            try borderChroma(frame, settings: settings(
                base: s.baseColor, origin: s.baseOrigin, gamma: s.gamma,
                dmax: s.dmax, ev: s.printExposure, pivot: s.medianDensity))
        }
        let c = roll.conversion
        let rollChroma = try zip(frames, zip(roll.frameExposures, roll.framePivots)).map {
            frame, solved in
            try borderChroma(frame, settings: settings(
                base: c.baseColor, origin: c.baseOrigin, gamma: c.gamma,
                dmax: c.dmax, ev: solved.0, pivot: solved.1))
        }
        XCTAssertLessThanOrEqual(variance(rollChroma), variance(perFrameChroma) * 1.05,
                                 "roll analysis must not be less consistent than per-frame")
        print("ROLLCONSISTENCY synthetic: perFrame=\(variance(perFrameChroma)) roll=\(variance(rollChroma))")
    }

    /// A sampled rebate base anywhere on the roll wins for the whole roll.
    func testSampledBaseAnywhereWinsForTheRoll() throws {
        let frames = rollFrames()
        let sampled = FilmColor(red: 0.94, green: 0.72, blue: 0.50)
        var ms = try frames.map {
            try XCTUnwrap(AutoInvert.measure(scan: $0, sampledBase: nil,
                                             context: context))
        }
        ms[2].sampledBase = sampled
        let roll = try XCTUnwrap(RollAnalysis.solve(measurements: ms, profile: .linear))
        XCTAssertEqual(roll.conversion.baseOrigin, .sampled)
        XCTAssertEqual(roll.conversion.baseColor, sampled)
    }
}
