import CoreImage
import Foundation

/// What Auto solved, and how much of it was actually measured.
struct AutoInvertSolution: Equatable {
    /// Display-encoded, ready for `FilmNegativeSettings.baseColor`.
    var baseColor: FilmColor
    var baseOrigin: FilmBaseOrigin
    var dmax: DensityTriple
    var gamma: DensityTriple
    var printExposure: Double

    /// The median density per channel the bisection placed at middle grey —
    /// written to `PrintSettings.gradePivot` so Contrast holds the mids
    /// (renderVersion 2) instead of darkening everything below paper white.
    var medianDensity: DensityTriple

    /// Auto colour balance, in CAST-SLIDER units despite the type —
    /// `DensityTriple` is the house "triple of Doubles, not a colour" carrier
    /// and keeps this struct's synthesized `Equatable`, which a labeled tuple
    /// would break. `.zero` unless the profile enables auto colour balance
    /// (the Task 7 cast solver).
    var cast: DensityTriple

    /// Human-readable names of terms that fell back to defaults because the
    /// scan gave nothing to measure. Empty means a clean solve.
    var degradedTerms: [String]

    var isDegraded: Bool { !degradedTerms.isEmpty }
}

/// One frame's gated measurement — everything the solve consumes, split from
/// the solving so `RollAnalysis` (Task 9) can pool measurements across a
/// roll's frames and solve constants once.
struct FrameMeasurement {
    /// Ascending-sorted linear transmittances of the gated population.
    var sortedRed: [Double]
    var sortedGreen: [Double]
    var sortedBlue: [Double]
    /// Display-encoded; wins over the percentile estimate — actual clear
    /// film beats any statistic.
    var sampledBase: FilmColor?
    /// Gating fallbacks, carried into the solve's degraded terms.
    var degradedTerms: [String]
}

/// The one-button solve: measure a downsampled linear render of the scan,
/// derive every density parameter in closed form, and place the exposure with
/// one scalar bisection. Deterministic — no search, no randomness — so the
/// same scan always solves to the same numbers.
enum AutoInvert {
    /// Grid edge for measurement. Enough for stable percentiles, cheap enough
    /// to be instant (spec: `autoDownsample`).
    static let sampleSide = 256

    /// `D_low` colliding with `Dmax` inside this margin means the scan has no
    /// measurable tonal range in that channel.
    private static let minimumDensityRange = 0.05

    /// Linear level, in every channel at once, above which a pixel is treated
    /// as clipped backlight rather than film.
    ///
    /// No genuine film pixel is near-white in ALL THREE channels at once: light
    /// through even a thin orange mask keeps blue far down (a clear C-41 base
    /// measures well under this in blue), and even a clear B&W base sits
    /// visibly below raw, unfiltered backlight. A pixel whose darkest channel
    /// is still ≥ this level is not being seen *through* any film at all — it
    /// is a sprocket hole, the gap around a floating frame, or bare lightbox
    /// shining straight into the sensor. Left in, that population becomes the
    /// scan's brightest, densest-reading material and can steal the very
    /// statistics (Dmin, Dmax, the median) the solve is trying to measure off
    /// the film itself.
    private static let backlightLevel = 0.9

    /// Below this fraction of the frame, a candidate pixel population is
    /// refused rather than trusted — whether that's the clip-only fallback
    /// or the chroma-gated hypothesis set below: a scan that is *mostly*
    /// backlight, or whose chroma-gated survivors are a sliver of the frame,
    /// would otherwise solve confidently off a handful of pixels. Falling
    /// back to a larger, less-filtered set and flagging the degradation is
    /// more honest than a precise-looking number built on noise.
    private static let minimumUsableFraction = 0.05

    /// Above this ratio of blue to red (linear transmittance), a pixel is too
    /// blue-relative-to-red to be seen through an orange mask, however bright
    /// or dark it happens to be — the discriminator `backlightLevel` misses
    /// when the light source isn't clipped.
    ///
    /// On a masked color negative, transmittance is `t_c = dmin_c · 10^(−D_c)`
    /// per channel, and the mask itself makes `dmin_red` roughly 4×
    /// `dmin_blue` (C-41's own orange cast — see `FilmSim.c41Base`, whose red
    /// Dmin is ~4.2× its blue). For `t_blue` to reach 0.9·`t_red` despite that
    /// 4× head start, the *density* has to overcome it too:
    /// `(dmin_blue/dmin_red) · 10^(D_red − D_blue) ≥ 0.9` reduces to
    /// `D_red − D_blue ≥ log10(0.9 · dmin_red/dmin_blue) ≈ 0.58` at that ratio
    /// — a red-dense/blue-thin corner extreme enough that percentile
    /// statistics can afford to lose it. Genuine film essentially never sits
    /// there; light sources do: unclipped-but-cool sprocket/edge backlight
    /// (an iPhone can pull clipped white down to an unclipped blue-cyan,
    /// which is exactly why `backlightLevel` alone misses it), bare lightbox,
    /// and — usefully — a neutral holder mask, where `r ≈ g ≈ b` puts
    /// blue/red right at 1.0, comfortably over this ceiling too.
    ///
    /// Applied speculatively (see `solve`'s gate-then-validate step): every
    /// scan gets this filter tried on it, and the result is kept only if the
    /// population that survives validates its own premise.
    private static let chromaGateBlueToRedRatio = 0.9

    /// A candidate pixel population's chroma, judged the same way
    /// `FilmBaseSampler.inferType` judges the panel's base color: a
    /// throwaway Dmin estimate (98th percentile per channel) over the
    /// population, normalized so overall brightness drops out, then
    /// `maxChannel − minChannel`. Above 0.18 reads as an orange-masked base;
    /// at or below reads as clear (B&W/slide) or, for a population that
    /// isn't really film at all, coincidentally neutral.
    private static func chromaSpread(of pixels: [(Double, Double, Double)]) -> Double {
        let dmin = (percentile(pixels.map(\.0).sorted(), PaperResponse.dminPercentile),
                   percentile(pixels.map(\.1).sorted(), PaperResponse.dminPercentile),
                   percentile(pixels.map(\.2).sorted(), PaperResponse.dminPercentile))
        return chromaSpread(FilmColor(red: PaperResponse.srgbEncode(dmin.0),
                                      green: PaperResponse.srgbEncode(dmin.1),
                                      blue: PaperResponse.srgbEncode(dmin.2)))
    }

    /// The same spread computation, directly on an already-known color (the
    /// user's sampled base) rather than estimating one from pixels.
    private static func chromaSpread(_ color: FilmColor) -> Double {
        let normalized = color.normalized
        return normalized.maxChannel - min(normalized.red, min(normalized.green, normalized.blue))
    }

    /// The one-shot Auto: measure, then solve under the given profile.
    static func solve(scan: CIImage, sampledBase: FilmColor?,
                      profile: FilmToneProfile,
                      context: CIContext) -> AutoInvertSolution? {
        guard let m = measure(scan: scan, sampledBase: sampledBase, context: context)
        else { return nil }
        return solve(from: m, profile: profile)
    }

    /// Measurement half: downsample, gate, sort. Everything statistical about
    /// ONE frame, none of it about rendering — so a roll can pool these.
    ///
    /// - Parameter sampledBase: the user's eyedropper (or Phase 3 rebate)
    ///   measurement, display-encoded. Non-nil wins over the percentile
    ///   estimate: actual clear film beats any statistic.
    static func measure(scan: CIImage, sampledBase: FilmColor?,
                        context: CIContext) -> FrameMeasurement? {
        guard let rawPixels = linearPixels(of: scan, side: sampleSide, context: context),
              !rawPixels.isEmpty else { return nil }

        var degraded: [String] = []

        // 0. Gate-then-validate (not detect-then-gate — that was circular:
        // the unclipped-but-cool backlight this gate exists to remove also
        // contaminates any Dmin candidate estimated *before* gating, so a
        // detection step run first can be fooled by the very thing it's
        // trying to detect). Two populations are built without any mask
        // decision at all:
        //
        // - `clipOnly`: survives just the backlight clip filter (round 1's
        //   original behavior) — the B&W/slide/neutral-base fallback.
        // - `candidateB`: survives BOTH the clip filter and the chroma gate
        //   (`blue < chromaGateBlueToRedRatio · red`) at once — computed
        //   speculatively, on every scan, with no prior judgment about
        //   whether this scan even looks masked.
        //
        // The hypothesis "this is masked film, and B is its film pixels" is
        // then validated against B's OWN evidence: if B is a usable fraction
        // of the frame AND a throwaway Dmin estimated FROM B still reads as
        // orange-masked (`chromaSpread(of:) > 0.18`, `FilmBaseSampler
        // .inferType`'s own threshold), the surviving population supports
        // the assumption that was used to build it, and B is adopted for the
        // entire solve — Dmin (unless sampled), every density, Dmax, D_low,
        // gamma, and the median-EV anchor. If it doesn't validate (B is a
        // sliver of the frame, or what's left is itself chroma-neutral —
        // evidence the "orange" reading was backlight bleed, not film), fall
        // back to `clipOnly`: chroma-gating a genuinely clear base would only
        // strip real image data, not backlight, since a clear base has
        // nothing distinguishing it from backlight along this axis.
        //
        // A user-sampled base overrides the hypothesis test entirely, in
        // both directions: its own chroma spread — not B's — decides masked
        // or not, the same way it already wins for Dmin. An eyedropper on
        // real, physical film is stronger evidence than any statistic.
        let clipOnly = rawPixels.filter { min($0.0, min($0.1, $0.2)) < backlightLevel }
        let clipOnlyUsable = Double(clipOnly.count) >= Double(rawPixels.count) * minimumUsableFraction
        let candidateB = rawPixels.filter {
            min($0.0, min($0.1, $0.2)) < backlightLevel && $0.2 < chromaGateBlueToRedRatio * $0.0
        }
        let candidateBUsable = Double(candidateB.count) >= Double(rawPixels.count) * minimumUsableFraction

        var pixels: [(Double, Double, Double)]
        if let sampledBase {
            if chromaSpread(sampledBase) > 0.18 {
                // The user has told us it's masked film: adopt B if there's
                // enough of it to trust, otherwise fall back and say so —
                // the claim and the pixels disagree.
                if candidateBUsable {
                    pixels = candidateB
                } else {
                    pixels = clipOnlyUsable ? clipOnly : rawPixels
                    degraded.append("scan chroma inconsistent with a masked negative")
                }
            } else {
                // The user has told us it's NOT masked film (a real sample
                // of clear/neutral base) — no point testing a hypothesis
                // already disproven by direct measurement.
                if clipOnlyUsable {
                    pixels = clipOnly
                } else {
                    pixels = rawPixels
                    degraded.append("scan is mostly backlight")
                }
            }
        } else if candidateBUsable, chromaSpread(of: candidateB) > 0.18 {
            // Hypothesis confirmed: what survives the gate still looks like
            // orange-masked film on its own terms.
            pixels = candidateB
        } else if clipOnlyUsable {
            pixels = clipOnly
        } else {
            pixels = rawPixels
            degraded.append("scan is mostly backlight")
        }

        return FrameMeasurement(sortedRed: pixels.map(\.0).sorted(),
                                sortedGreen: pixels.map(\.1).sorted(),
                                sortedBlue: pixels.map(\.2).sorted(),
                                sampledBase: sampledBase,
                                degradedTerms: degraded)
    }

    /// Solving half: closed-form density parameters plus the one-scalar EV
    /// bisection, on a measurement — this frame's, or (through `RollAnalysis`)
    /// a roll's pooled statistics. Deterministic, like everything here.
    ///
    /// The bisection places the median under the PROFILE's rendering — the
    /// paper knees, house filtration (balanced tint: new solves are
    /// renderVersion 2), and the profile's own punch/fade/glow/toeChroma —
    /// because Auto's contract is "the midtone the user will actually see
    /// lands at middle grey," not "…under a hypothetical neutral render."
    static func solve(from m: FrameMeasurement,
                      profile: FilmToneProfile) -> AutoInvertSolution? {
        guard !m.sortedRed.isEmpty else { return nil }
        var degraded = m.degradedTerms
        let sampledBase = m.sampledBase

        // 1. Dmin per channel — sampled if available, else the 98th
        // percentile (NOT the maximum: on a lightbox scan the top of the
        // histogram is bare panel, not film base — see the spec's risk note).
        var reds = m.sortedRed
        var greens = m.sortedGreen
        var blues = m.sortedBlue
        let dminLinear: (Double, Double, Double)
        let origin: FilmBaseOrigin
        if let sampledBase {
            dminLinear = (PaperResponse.srgbDecode(sampledBase.red),
                          PaperResponse.srgbDecode(sampledBase.green),
                          PaperResponse.srgbDecode(sampledBase.blue))
            origin = .sampled
        } else {
            dminLinear = (percentile(reds, PaperResponse.dminPercentile),
                          percentile(greens, PaperResponse.dminPercentile),
                          percentile(blues, PaperResponse.dminPercentile))
            origin = .estimated
        }

        // 2. Densities across the frame, per channel.
        func density(_ t: Double, _ dmin: Double) -> Double {
            log10(max(dmin, 1e-4) / max(t, PaperResponse.transmittanceFloor))
        }
        for i in reds.indices {
            reds[i] = density(reds[i], dminLinear.0)
            greens[i] = density(greens[i], dminLinear.1)
            blues[i] = density(blues[i], dminLinear.2)
        }
        // Densities are anti-monotone in transmittance: re-sort ascending.
        reds.sort(); greens.sort(); blues.sort()

        // 3–4. White point and shadow anchor, per channel.
        let dmaxV = (percentile(reds, PaperResponse.dmaxPercentile),
                     percentile(greens, PaperResponse.dmaxPercentile),
                     percentile(blues, PaperResponse.dmaxPercentile))
        let dlow = (percentile(reds, PaperResponse.dLowPercentile),
                    percentile(greens, PaperResponse.dLowPercentile),
                    percentile(blues, PaperResponse.dLowPercentile))

        // 5. Gammas: land every channel's low end on one target black. Both
        // ends of all three channels now coincide — that IS "no crossover".
        func solveGamma(_ dlow: Double, _ dmax: Double, _ channel: String) -> Double {
            let range = dlow - dmax
            guard abs(range) > minimumDensityRange else {
                degraded.append("gamma (\(channel)): no measurable density range")
                return 1.0
            }
            return log10(PaperResponse.targetBlack) / range
        }
        let gamma = DensityTriple(red: solveGamma(dlow.0, dmaxV.0, "red"),
                                  green: solveGamma(dlow.1, dmaxV.1, "green"),
                                  blue: solveGamma(dlow.2, dmaxV.2, "blue"))

        // 6. Print exposure: bisect so the median density renders at middle
        // grey. Median, not the extremes — percentile ends are noisy and the
        // midtone is what the eye judges. paper() is monotone in the offset,
        // so bisection on one scalar converges deterministically.
        let medianD = (percentile(reds, 0.5), percentile(greens, 0.5), percentile(blues, 0.5))
        let medianT = (dminLinear.0 * pow(10, -medianD.0),
                       dminLinear.1 * pow(10, -medianD.1),
                       dminLinear.2 * pow(10, -medianD.2))

        // Auto colour balance (Lab profiles only): equalize the per-channel
        // median densities — midtone gray-world — via the closed-form cast
        // solver, expressed in the same ±100 slider units the panel shows.
        // Solved BEFORE the bisection and folded into it, so the placed EV
        // already accounts for the correction. Honesty-gated: gray-world on
        // genuinely colourful midtones is a risky assumption, and the solve
        // says so rather than guessing confidently.
        var cast = DensityTriple.zero   // slider units — see AutoInvertSolution.cast
        if profile.enablesAutoColorBalance {
            let solved = CastSolver.castSliders(
                neutralDensity: DensityTriple(red: medianD.0, green: medianD.1,
                                              blue: medianD.2),
                gamma: gamma, dmax: DensityTriple(red: dmaxV.0, green: dmaxV.1,
                                                  blue: dmaxV.2))
            cast = DensityTriple(red: solved.red, green: solved.green, blue: solved.blue)
            if solved.clipped {
                degraded.append("auto colour balance hit the slider limit")
            }
            let medianColor = FilmColor(red: PaperResponse.srgbEncode(medianT.0),
                                        green: PaperResponse.srgbEncode(medianT.1),
                                        blue: PaperResponse.srgbEncode(medianT.2))
            if chromaSpread(medianColor) > 0.18 {
                degraded.append("auto colour balance: midtones are strongly coloured — check with the neutral picker")
            }
        }
        let printEV = solveExposure(medianT: medianT, dminLinear: dminLinear,
                                    dmax: DensityTriple(red: dmaxV.0, green: dmaxV.1,
                                                        blue: dmaxV.2),
                                    gamma: gamma, cast: cast, profile: profile)

        return AutoInvertSolution(
            baseColor: sampledBase ?? FilmColor(
                red: PaperResponse.srgbEncode(dminLinear.0),
                green: PaperResponse.srgbEncode(dminLinear.1),
                blue: PaperResponse.srgbEncode(dminLinear.2)),
            baseOrigin: origin,
            dmax: DensityTriple(red: dmaxV.0, green: dmaxV.1, blue: dmaxV.2),
            gamma: gamma,
            printExposure: printEV,
            medianDensity: DensityTriple(red: medianD.0, green: medianD.1, blue: medianD.2),
            cast: cast,
            degradedTerms: degraded)
    }

    /// The shared EV bisection — one bisection, two callers (`solve(from:
    /// profile:)` per frame, `RollAnalysis` per roll). `cast` is in cast-
    /// slider units, matching `AutoInvertSolution.cast`.
    ///
    /// Solved with the PROFILE's default knees, toning, and the house
    /// filtration — the same reasoning throughout: Auto places the median
    /// under the rendering the user will actually see (balanced tint: new
    /// solves are renderVersion 2), not under a hypothetical neutral one,
    /// so neither the shipped warmth/tint nor a Lab profile's punch/fade
    /// quietly shifts the midtone off target. satScale stays 1.0: the
    /// ratio scaling is exact for the max channel, which is what the
    /// bisection reads.
    static func solveExposure(medianT: (Double, Double, Double),
                              dminLinear: (Double, Double, Double),
                              dmax: DensityTriple, gamma: DensityTriple,
                              cast: DensityTriple,
                              profile: FilmToneProfile) -> Double {
        var defaults = PrintSettings()
        defaults.applyToneProfile(profile)
        let p = PaperResponse.kneeP(shoulder: defaults.shoulder)
        let q = PaperResponse.kneeQ(toe: defaults.toe)
        // The cast fold, hoisted: a density offset folds through the
        // effective gamma into the log-domain print offset (the Task 4
        // identity γ·(D + c − Dmax) = γ·(D − Dmax) + γ·c), constant across
        // bisection iterations.
        let castFold = (gamma.red * PaperResponse.castDensity(cast.red),
                        gamma.green * PaperResponse.castDensity(cast.green),
                        gamma.blue * PaperResponse.castDensity(cast.blue))
        var lo = -8.0, hi = 8.0
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            var offset = PaperResponse.printOffsets(exposureEV: mid, warmth: defaults.warmth,
                                                     tint: defaults.tint, balancedTint: true)
            offset.0 += castFold.0
            offset.1 += castFold.1
            offset.2 += castFold.2
            let out = PaperResponse.develop(
                medianT, dminLinear: dminLinear,
                dmax: (dmax.red, dmax.green, dmax.blue),
                gammaEffective: (gamma.red, gamma.green, gamma.blue),
                printOffset: offset, p: p, q: q, satScale: 1.0,
                punch: PaperResponse.punchAmount(defaults.punch),
                fade: PaperResponse.fadeLift(defaults.fade),
                glow: PaperResponse.glowDrop(defaults.glow),
                toeChroma: PaperResponse.toeChromaWeight(defaults.toeChroma))
            if max(out.0, max(out.1, out.2)) < PaperResponse.targetMid { lo = mid } else { hi = mid }
        }
        return ((lo + hi) / 2 * 100).rounded() / 100 // stable to read
    }

    // MARK: Measurement

    /// Reads a downsampled render back as LINEAR values — the density model's
    /// native domain. Contrast with `FilmBaseSampler.readPixels`, which reads
    /// sRGB because the matrix engine divides in gamma space.
    static func linearPixels(of image: CIImage, side: Int,
                             context: CIContext) -> [(Double, Double, Double)]? {
        let extent = image.extent
        guard !extent.isInfinite, extent.width >= 1, extent.height >= 1 else { return nil }
        let scale = CGFloat(side) / max(extent.width, extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: min(scale, 1),
                                                             y: min(scale, 1)))
        let bounds = CGRect(x: 0, y: 0,
                            width: max(1, scaled.extent.width.rounded(.down)),
                            height: max(1, scaled.extent.height.rounded(.down)))
        let width = Int(bounds.width), height = Int(bounds.height)
        var buffer = [Float](repeating: 0, count: width * height * 4)
        context.render(
            scaled.transformed(by: CGAffineTransform(translationX: -scaled.extent.origin.x,
                                                     y: -scaled.extent.origin.y)),
            toBitmap: &buffer,
            rowBytes: width * 4 * MemoryLayout<Float>.stride,
            bounds: bounds, format: .RGBAf,
            colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        return (0..<(width * height)).map { i in
            (Double(buffer[i * 4]), Double(buffer[i * 4 + 1]), Double(buffer[i * 4 + 2]))
        }
    }

    /// Nearest-rank percentile over an ascending-sorted array.
    static func percentile(_ sorted: [Double], _ q: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = Int((Double(sorted.count - 1) * q).rounded())
        return sorted[min(max(index, 0), sorted.count - 1)]
    }
}
