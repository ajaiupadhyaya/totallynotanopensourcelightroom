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

    /// Human-readable names of terms that fell back to defaults because the
    /// scan gave nothing to measure. Empty means a clean solve.
    var degradedTerms: [String]

    var isDegraded: Bool { !degradedTerms.isEmpty }
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

    /// - Parameter sampledBase: the user's eyedropper (or Phase 3 rebate)
    ///   measurement, display-encoded. Non-nil wins over the percentile
    ///   estimate: actual clear film beats any statistic.
    static func solve(scan: CIImage, sampledBase: FilmColor?,
                      context: CIContext) -> AutoInvertSolution? {
        guard let pixels = linearPixels(of: scan, side: sampleSide, context: context),
              !pixels.isEmpty else { return nil }

        var degraded: [String] = []

        // 1. Dmin per channel — sampled if available, else the 98th
        // percentile (NOT the maximum: on a lightbox scan the top of the
        // histogram is bare panel, not film base — see the spec's risk note).
        var reds = pixels.map(\.0).sorted()
        var greens = pixels.map(\.1).sorted()
        var blues = pixels.map(\.2).sorted()
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
        for i in pixels.indices {
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
        let defaults = PrintSettings()
        let p = PaperResponse.kneeP(shoulder: defaults.shoulder)
        let q = PaperResponse.kneeQ(toe: defaults.toe)
        var lo = -8.0, hi = 8.0
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            let out = PaperResponse.develop(
                medianT, dminLinear: dminLinear,
                dmax: (dmaxV.0, dmaxV.1, dmaxV.2),
                gammaEffective: (gamma.red, gamma.green, gamma.blue),
                printOffset: mid * log10(2.0), p: p, q: q, satScale: 1.0)
            if max(out.0, max(out.1, out.2)) < PaperResponse.targetMid { lo = mid } else { hi = mid }
        }
        let printEV = ((lo + hi) / 2 * 100).rounded() / 100 // stable to read

        return AutoInvertSolution(
            baseColor: sampledBase ?? FilmColor(
                red: PaperResponse.srgbEncode(dminLinear.0),
                green: PaperResponse.srgbEncode(dminLinear.1),
                blue: PaperResponse.srgbEncode(dminLinear.2)),
            baseOrigin: origin,
            dmax: DensityTriple(red: dmaxV.0, green: dmaxV.1, blue: dmaxV.2),
            gamma: gamma,
            printExposure: printEV,
            degradedTerms: degraded)
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
