import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// How closely a scan's film base matches a known stock profile.
struct StockMatch: Identifiable, Equatable {
    let stock: FilmStock

    /// Chromaticity distance between the sampled base and the stock's base.
    /// Smaller is closer; 0 is identical.
    let distance: Double

    var id: String { stock.id }

    /// A rough 0–1 confidence for display. This is a presentation convenience
    /// derived from ``distance``, not a calibrated probability — see
    /// ``FilmBaseSampler`` for why base color alone can't firmly identify a
    /// stock.
    var confidence: Double {
        max(0, 1 - distance / 0.35)
    }
}

/// Samples the film base from a scan and ranks known stocks against it.
///
/// ## What this can and cannot tell you
///
/// Matching compares the *chromaticity* of the film base — the hue of the
/// orange mask with overall brightness divided out — against each profile.
/// That reliably separates the broad families: a masked color negative, a
/// near-clear B&W base, and a slide are obviously different.
///
/// Within a family it is much weaker. Most modern C-41 stocks use very similar
/// masks, and the sampled value also absorbs your scanner's light source, white
/// balance, and development — so two scans of the *same* stock can land further
/// apart than two different stocks scanned identically.
///
/// Treat the ranking as "here are the plausible candidates, closest first," not
/// as an identification. The reliable path is the other direction: tell the app
/// which stock you shot, sample the base from your own scan, and save that as a
/// calibrated profile.
enum FilmBaseSampler {
    /// Samples the film base as the average color of the brightest pixels.
    ///
    /// On a negative the developed film base is the most transmissive area, so
    /// it scans brighter than any part of the image. Taking a percentile of the
    /// brightest pixels rather than a single maximum keeps one hot dust speck or
    /// a clipped pixel from defining the base.
    ///
    /// - Parameter percentile: Fraction of the brightest pixels to average.
    ///   The default samples the top 2%.
    /// - Returns: The base color, or `nil` if the image can't be sampled.
    static func sampleBase(
        from image: CIImage,
        context: CIContext = CIContext(),
        percentile: Double = 0.02,
        gridSize: Int = 64
    ) -> FilmColor? {
        guard let pixels = readPixels(image, context: context, gridSize: gridSize),
              !pixels.isEmpty else { return nil }

        // Rank by luminance and average the brightest slice.
        let sorted = pixels.sorted { luminance($0) > luminance($1) }
        let count = max(1, Int((Double(sorted.count) * percentile).rounded()))
        let slice = sorted.prefix(count)

        var r = 0.0, g = 0.0, b = 0.0
        for pixel in slice {
            r += pixel.red
            g += pixel.green
            b += pixel.blue
        }
        let n = Double(slice.count)
        return FilmColor(red: r / n, green: g / n, blue: b / n)
    }

    /// Averages the color over a sub-rectangle — the eyedropper path, for when
    /// the user points at a piece of clear film border directly.
    ///
    /// - Parameter rect: The region in the image's own coordinate space.
    static func sampleAverage(
        from image: CIImage,
        in rect: CGRect,
        context: CIContext = CIContext()
    ) -> FilmColor? {
        var clamped = rect.intersection(image.extent)
        guard !clamped.isNull, clamped.width > 0, clamped.height > 0 else { return nil }

        // CIAreaAverage silently returns zeros for tiny non-integral extents
        // (verified empirically: a 1.3 px click rect averaged to pure black).
        // Grow the sample to a minimum integral area — a few pixels averaged
        // is also simply a better eyedropper, since it rejects grain.
        let minimumSide: CGFloat = 4
        if clamped.width < minimumSide || clamped.height < minimumSide {
            clamped = clamped.insetBy(
                dx: -max(0, (minimumSide - clamped.width) / 2),
                dy: -max(0, (minimumSide - clamped.height) / 2)
            )
        }
        clamped = clamped.integral.intersection(image.extent)
        guard !clamped.isNull, clamped.width >= 1, clamped.height >= 1 else { return nil }

        let filter = CIFilter.areaAverage()
        filter.inputImage = image
        filter.extent = clamped
        guard let output = filter.outputImage else { return nil }

        var buffer = [Float](repeating: 0, count: 4)
        context.render(
            output,
            toBitmap: &buffer,
            rowBytes: 4 * MemoryLayout<Float>.stride,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBAf,
            colorSpace: workingColorSpace
        )
        return FilmColor(red: Double(buffer[0]),
                        green: Double(buffer[1]),
                        blue: Double(buffer[2]))
    }

    /// Ranks stocks by how closely their base matches `base`, closest first.
    ///
    /// - Parameter type: When non-nil, only stocks of that family are ranked.
    ///   Filtering by a family the user already knows is the single biggest
    ///   improvement to match quality.
    static func rankStocks(
        matching base: FilmColor,
        in stocks: [FilmStock] = FilmStock.builtIn,
        type: FilmType? = nil
    ) -> [StockMatch] {
        stocks
            .filter { type == nil || $0.type == type }
            .map { StockMatch(stock: $0, distance: base.chromaticityDistance(to: $0.baseColor)) }
            .sorted { $0.distance < $1.distance }
    }

    /// Guesses the film family from a base color.
    ///
    /// This is the part of matching that *is* dependable: a strongly colored
    /// base means a masked color negative, while a near-neutral base means B&W
    /// or a slide. It cannot separate B&W from slide (both have a clear base),
    /// so it defaults to B&W negative — the more common case for a scan being
    /// imported for inversion.
    static func inferType(from base: FilmColor) -> FilmType {
        let normalized = base.normalized
        let spread = normalized.maxChannel - min(normalized.red,
                                                 min(normalized.green, normalized.blue))
        return spread > 0.18 ? .colorNegative : .blackAndWhiteNegative
    }

    // MARK: Private

    /// Sampling happens in gamma-encoded sRGB because that is the space
    /// ``FilmNegativeConverter`` divides the base out in. Sampling in linear
    /// light would give a base color that doesn't cancel the mask.
    private static var workingColorSpace: CGColorSpace {
        CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }

    /// Scales the image down to a small grid and reads it back on the CPU.
    /// A 64×64 grid is ~4k pixels — enough to find the base reliably, small
    /// enough to be instant, and the downscale averages away sensor noise.
    private static func readPixels(
        _ image: CIImage,
        context: CIContext,
        gridSize: Int
    ) -> [FilmColor]? {
        let extent = image.extent
        guard !extent.isInfinite, extent.width >= 1, extent.height >= 1 else { return nil }

        let scale = CGFloat(gridSize) / max(extent.width, extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let bounds = CGRect(x: 0, y: 0,
                            width: max(1, min(CGFloat(gridSize), scaled.extent.width.rounded())),
                            height: max(1, min(CGFloat(gridSize), scaled.extent.height.rounded())))

        let width = Int(bounds.width)
        let height = Int(bounds.height)
        var buffer = [Float](repeating: 0, count: width * height * 4)
        context.render(
            scaled.transformed(by: CGAffineTransform(translationX: -scaled.extent.origin.x,
                                                     y: -scaled.extent.origin.y)),
            toBitmap: &buffer,
            rowBytes: width * 4 * MemoryLayout<Float>.stride,
            bounds: bounds,
            format: .RGBAf,
            colorSpace: workingColorSpace
        )

        return (0..<(width * height)).map { i in
            FilmColor(red: Double(buffer[i * 4]),
                     green: Double(buffer[i * 4 + 1]),
                     blue: Double(buffer[i * 4 + 2]))
        }
    }

    private static func luminance(_ color: FilmColor) -> Double {
        0.2126 * color.red + 0.7152 * color.green + 0.0722 * color.blue
    }
}
