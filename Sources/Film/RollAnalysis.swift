import Foundation

/// What a roll-level solve produced: the shared constants plus the one thing
/// that legitimately varies per frame (print exposure, with its pivot).
struct RollSolution: Equatable {
    var conversion: RollConversion
    var frameExposures: [Double]       // parallel to the input measurements
    var framePivots: [DensityTriple]   // per-frame gradePivot (median densities)
    var degradedTerms: [String]
}

/// Roll-level conversion (spec §Roll model & roll analysis): per-channel
/// base and gamma are properties of the roll — solved once from statistics
/// pooled across every frame — and only print exposure varies per frame.
/// The C F Systems / NLP-v3 discipline, applied to AutoInvert's own math.
enum RollAnalysis {
    /// Solves roll-level constants from ALL frames' measurements, then one
    /// exposure per frame. Deterministic, closed-form + bisection, like Auto.
    static func solve(measurements: [FrameMeasurement],
                      profile: FilmToneProfile) -> RollSolution? {
        guard !measurements.isEmpty,
              measurements.allSatisfy({ !$0.sortedRed.isEmpty }) else { return nil }
        var degraded = measurements.flatMap(\.degradedTerms)

        // 1. Roll base: any sampled rebate wins (median across sampled frames
        // if several); otherwise the thinnest-film envelope — the per-channel
        // MAXIMUM transmittance over each frame's own 98th-percentile
        // estimate, because the thinnest film seen anywhere on the roll is
        // the MOST transmissive and closest to true base. (The plan wrote
        // `min()` here — the densest estimate — which inverts its own spec's
        // "thinnest film" reasoning and lets one dim frame drag the whole
        // roll's base down; caught by the synthetic-roll variance test.)
        let sampled = measurements.compactMap(\.sampledBase)
        let dminLinear: (Double, Double, Double)
        let origin: FilmBaseOrigin
        let baseColor: FilmColor
        if !sampled.isEmpty {
            func median(_ v: [Double]) -> Double {
                let s = v.sorted(); return s[s.count / 2]
            }
            baseColor = FilmColor(red: median(sampled.map(\.red)),
                                  green: median(sampled.map(\.green)),
                                  blue: median(sampled.map(\.blue)))
            dminLinear = (PaperResponse.srgbDecode(baseColor.red),
                          PaperResponse.srgbDecode(baseColor.green),
                          PaperResponse.srgbDecode(baseColor.blue))
            origin = .sampled
        } else {
            let perFrame = measurements.map { m in
                (AutoInvert.percentile(m.sortedRed, PaperResponse.dminPercentile),
                 AutoInvert.percentile(m.sortedGreen, PaperResponse.dminPercentile),
                 AutoInvert.percentile(m.sortedBlue, PaperResponse.dminPercentile))
            }
            dminLinear = (perFrame.map(\.0).max()!,
                          perFrame.map(\.1).max()!,
                          perFrame.map(\.2).max()!)
            baseColor = FilmColor(red: PaperResponse.srgbEncode(dminLinear.0),
                                  green: PaperResponse.srgbEncode(dminLinear.1),
                                  blue: PaperResponse.srgbEncode(dminLinear.2))
            origin = .estimated
        }

        // 2. Densities per frame against the ROLL base; pooled per channel.
        func density(_ t: Double, _ dmin: Double) -> Double {
            log10(max(dmin, 1e-4) / max(t, PaperResponse.transmittanceFloor))
        }
        var frameDensities: [([Double], [Double], [Double])] = []
        for m in measurements {
            var r = m.sortedRed.map { density($0, dminLinear.0) }
            var g = m.sortedGreen.map { density($0, dminLinear.1) }
            var b = m.sortedBlue.map { density($0, dminLinear.2) }
            r.sort(); g.sort(); b.sort()
            frameDensities.append((r, g, b))
        }
        let pooled = (frameDensities.flatMap(\.0).sorted(),
                      frameDensities.flatMap(\.1).sorted(),
                      frameDensities.flatMap(\.2).sorted())

        // 3–5. Roll endpoints and gammas — AutoInvert's own math on the pool.
        let dmaxV = DensityTriple(
            red: AutoInvert.percentile(pooled.0, PaperResponse.dmaxPercentile),
            green: AutoInvert.percentile(pooled.1, PaperResponse.dmaxPercentile),
            blue: AutoInvert.percentile(pooled.2, PaperResponse.dmaxPercentile))
        let dlow = (AutoInvert.percentile(pooled.0, PaperResponse.dLowPercentile),
                    AutoInvert.percentile(pooled.1, PaperResponse.dLowPercentile),
                    AutoInvert.percentile(pooled.2, PaperResponse.dLowPercentile))
        func solveGamma(_ dlow: Double, _ dmax: Double, _ channel: String) -> Double {
            let range = dlow - dmax
            guard abs(range) > 0.05 else {
                degraded.append("roll gamma (\(channel)): no measurable density range")
                return 1.0
            }
            return log10(PaperResponse.targetBlack) / range
        }
        let gamma = DensityTriple(red: solveGamma(dlow.0, dmaxV.red, "red"),
                                  green: solveGamma(dlow.1, dmaxV.green, "green"),
                                  blue: solveGamma(dlow.2, dmaxV.blue, "blue"))

        // Roll cast from the POOLED medians (roll-level: per-frame auto
        // balance would reintroduce exactly the drift this type removes).
        var cast = DensityTriple.zero   // slider units
        if profile.enablesAutoColorBalance {
            let pooledMedian = DensityTriple(
                red: AutoInvert.percentile(pooled.0, 0.5),
                green: AutoInvert.percentile(pooled.1, 0.5),
                blue: AutoInvert.percentile(pooled.2, 0.5))
            let solved = CastSolver.castSliders(neutralDensity: pooledMedian,
                                                gamma: gamma, dmax: dmaxV)
            cast = DensityTriple(red: solved.red, green: solved.green, blue: solved.blue)
            if solved.clipped { degraded.append("roll colour balance hit the slider limit") }
        }

        // 6. Per frame: exposure only, from that frame's own medians.
        var exposures: [Double] = []
        var pivots: [DensityTriple] = []
        for d in frameDensities {
            let medianD = (AutoInvert.percentile(d.0, 0.5),
                           AutoInvert.percentile(d.1, 0.5),
                           AutoInvert.percentile(d.2, 0.5))
            let medianT = (dminLinear.0 * pow(10, -medianD.0),
                           dminLinear.1 * pow(10, -medianD.1),
                           dminLinear.2 * pow(10, -medianD.2))
            exposures.append(AutoInvert.solveExposure(
                medianT: medianT, dminLinear: dminLinear, dmax: dmaxV,
                gamma: gamma, cast: cast, profile: profile))
            pivots.append(DensityTriple(red: medianD.0, green: medianD.1, blue: medianD.2))
        }

        return RollSolution(
            conversion: RollConversion(baseColor: baseColor, baseOrigin: origin,
                                       gamma: gamma, dmax: dmaxV,
                                       castRed: cast.red, castGreen: cast.green,
                                       castBlue: cast.blue, toneProfile: profile),
            // (cast is slider units carried in a DensityTriple — see
            //  AutoInvertSolution.cast's doc comment)
            frameExposures: exposures, framePivots: pivots,
            degradedTerms: degraded)
    }
}
