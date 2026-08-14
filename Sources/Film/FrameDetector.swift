import CoreImage
import Foundation

/// What the detector found on a lightbox scan.
struct DetectedFrame: Equatable {
    /// Unit rect, Core Image bottom-left origin, rebate INCLUDED — "crop to
    /// the negative" means masking the lightbox, never cutting the base away
    /// (measured 2026-08-10: a picture-tight crop drove the solve WORSE than
    /// blind, red gamma 3.55–6.91 vs neutral ≈ 0.66).
    var rect: CGRect
    /// Fraction of the scan classified as backlight — the caller's gate.
    var backlightFraction: Double
    /// Brightest-percentile linear colour of the rebate ring, display-encoded.
    /// nil when the ring reads as leaked backlight rather than film.
    var rebateBase: FilmColor?
}

/// Finds the film rectangle on a phone-on-lightbox scan: deterministic,
/// closed-form, no ML (spec: docs/superpowers/specs/2026-08-10-frame-
/// detection-design.md). Three cues classify backlight — an absolute luma
/// floor, a near-clip test, and (under the validated orange-mask hypothesis)
/// a luma-gated blue-to-red ratio — then marginal row/column film-fraction
/// profiles give the box: the film on a lightbox is a solid rectangle, and profiles shrug off
/// dust and holder shadows that would fool connected components.
///
/// When in doubt, nil: a false negative costs one manual crop; a false
/// positive writes a wrong crop into the user's geometry.
enum FrameDetector {
    /// Grid edge for detection — profile stability matters more than pixels.
    static let sampleSide = 128

    /// Mirrors `AutoInvert.backlightLevel` (private there, frozen tuning):
    /// no genuine film pixel is near-white in all three channels at once.
    static let backlightLevel = 0.9

    /// Linear luma above which a pixel is backlight regardless of channel
    /// balance. Absolute, not statistical, and that is the point: an early
    /// Otsu-split classifier self-split film-filling scans (a negative's own
    /// rebate vs its dense scene is bimodal) and, worse, could cut BETWEEN
    /// the rebate and the scene on a real lightbox scan — three modes, one
    /// threshold. Physics gives an absolute line instead: light seen THROUGH
    /// film has lost at least the base density (C-41 base renders ~0.34
    /// luma, a clear B&W base ~0.55), while bare backlight sits near clip.
    /// 0.80 splits the gap with margin on both sides.
    static let backlightLumaFloor = 0.80

    /// Below this backlight fraction the scan is already film-filling and
    /// there is nothing to detect; above `maximumBacklightFraction` there is
    /// not enough film to trust a box.
    static let minimumBacklightFraction = 0.08
    static let maximumBacklightFraction = 0.90

    /// A detected box smaller than this fraction of the frame is refused —
    /// more likely a bright scene's dark pocket than a negative.
    static let minimumBoxAreaFraction = 0.25

    /// A row/column belongs to the film box when at least this fraction of
    /// its pixels classify as film.
    static let profileThreshold = 0.5

    /// A row/column belongs to the LIGHTBOX extent when at least this
    /// fraction of its pixels classify as backlight — low on purpose: rows
    /// crossing the negative still carry the lightbox's side margins.
    static let lightboxProfileThreshold = 0.10

    /// The lightbox-box fallback only fires when the box is a PROPER subset
    /// of the frame — a box that is the whole frame crops nothing.
    static let lightboxFallbackMaxAreaFraction = 0.92

    /// The fallback's own floor, against the FRAME. Distinct from
    /// `minimumBoxAreaFraction` on purpose: that one asks "is this box a
    /// plausible share of the lightbox", and the primary path deliberately
    /// measures it that way because "a scan that includes lots of table
    /// legitimately shrinks the film's share of the frame" (see the gate
    /// below). Reusing it here re-imposed against the whole frame exactly the
    /// assumption that reasoning rejects, and refused the scans that need
    /// cropping MOST: measured on IMG_7191 (2026-08-13), a negative held
    /// further from the phone lit 21.3% of the frame, was refused, and Auto
    /// then measured four-fifths tabletop — dmax 2.7, print EV 4.69, blown,
    /// with no degradation warning. The sibling frame at 28.3% converted
    /// correctly through this same fallback.
    ///
    /// 0.10 keeps a floor against an absurd crop while staying consistent
    /// with `minimumBacklightFraction`: the span contains essentially every
    /// backlight pixel, so a box below the entry gate's own 0.08 is not a
    /// scan this detector accepted in the first place.
    static let lightboxFallbackMinAreaFraction = 0.10

    /// The rebate ring: the outer band of the detected box, as a fraction of
    /// the box's smaller side.
    static let ringFraction = 0.10

    /// Mirrors `AutoInvert.chromaGateBlueToRedRatio` (private there, frozen
    /// tuning): a pixel bluer than 0.9× its red cannot be seen through an
    /// orange mask — the cue that catches backlight an iPhone's HDR has
    /// pulled down below any absolute luma floor (its comment there
    /// documents exactly this failure).
    static let chromaGateBlueToRedRatio = 0.9

    /// The chroma cue only applies ABOVE this luma. Statistics can afford to
    /// lose the red-dense/blue-thin corner of genuine film the ratio test
    /// misreads; geometry cannot — measured on IMG_7077, the unrestricted
    /// cue classified 71% of the frame as backlight including the DENSE
    /// picture area (dense C-41 overwhelms the mask exactly as AutoInvert's
    /// derivation predicts, and dense areas are the picture). Dense film is
    /// dark; HDR-pulled lightbox is mid-bright: 0.30 separates them, and the
    /// rebate is exempt at any luma because its orange mask fails the ratio
    /// test outright.
    static let chromaCueLumaFloor = 0.30

    /// How orange a rebate ring must read (normalized max−min channel) to
    /// validate the chroma-gated hypothesis — `FilmBaseSampler.inferType`'s
    /// own masked/clear threshold.
    static let maskedChromaSpread = 0.18

    static func detect(scan: CIImage, context: CIContext) -> DetectedFrame? {
        guard let grid = linearGrid(of: scan, side: sampleSide, context: context)
        else { return nil }
        return detect(pixels: grid.pixels, width: grid.width, height: grid.height)
    }

    /// Pure core. `pixels` are LINEAR RGB, row-major, row 0 at the TOP (the
    /// bitmap convention `CIContext.render(toBitmap:)` produces); the
    /// returned rect converts to Core Image's bottom-left-origin unit space.
    ///
    /// Gate-then-validate, the AutoInvert discipline: first hypothesize an
    /// orange-masked negative (the chroma cue may classify dim, HDR-pulled
    /// backlight), and keep that answer only if the detected rebate actually
    /// reads orange-masked; otherwise fall back to the absolute cues alone,
    /// which is what a B&W or slide scan needs (a neutral rebate fails the
    /// chroma cue frame-wide, on purpose).
    static func detect(pixels: [(Double, Double, Double)],
                       width: Int, height: Int) -> DetectedFrame? {
        guard width > 4, height > 4, pixels.count == width * height else { return nil }
        if var masked = attempt(pixels: pixels, width: width, height: height,
                                useChromaGate: true) {
            // The ring's orange-spread validation governs trusting the
            // REBATE, not the geometry: a phone's auto white balance can
            // neutralize the mask in the capture (measured on IMG_7079 —
            // film stage converged, ring read neutral), and a guessed base
            // is worse than none while the box is still right. Unvalidated
            // ring → strip it, keep the crop.
            if let rebate = masked.rebateBase,
               normalizedSpread(of: rebate) <= maskedChromaSpread {
                masked.rebateBase = nil
            }
            return masked
        }
        return attempt(pixels: pixels, width: width, height: height,
                       useChromaGate: false)
    }

    private static func normalizedSpread(of color: FilmColor) -> Double {
        let peak = max(color.red, max(color.green, color.blue))
        guard peak > 0 else { return 0 }
        return (peak - min(color.red, min(color.green, color.blue))) / peak
    }

    private static func attempt(pixels: [(Double, Double, Double)],
                                width: Int, height: Int,
                                useChromaGate: Bool) -> DetectedFrame? {
        // 1. Classify. Under the masked hypothesis, COLOUR is the only
        // honest cue: a thin negative's picture area transmits so much of a
        // bright lightbox that its luma reaches backlight levels (measured
        // on IMG_7077 — the tree canopy renders near-white through the
        // mask), so any absolute luma floor eats the picture. What bare
        // backlight can never be is orange: everything seen through C-41 has
        // blue strongly attenuated against red. The dark-floor guard keeps
        // the dense picture (which legitimately overwhelms the mask) film.
        // The neutral fallback (B&W/slide: no mask, no colour signal) uses
        // the absolute floors instead.
        var isBacklight = [Bool](repeating: false, count: pixels.count)
        var backlightCount = 0
        for i in pixels.indices {
            let p = pixels[i]
            let luma = 0.2126 * p.0 + 0.7152 * p.1 + 0.0722 * p.2
            let backlight: Bool
            if useChromaGate {
                backlight = min(p.0, min(p.1, p.2)) >= backlightLevel
                    || (luma >= chromaCueLumaFloor
                        && p.2 >= chromaGateBlueToRedRatio * p.0)
            } else {
                backlight = luma >= backlightLumaFloor
                    || min(p.0, min(p.1, p.2)) >= backlightLevel
            }
            if backlight {
                isBacklight[i] = true
                backlightCount += 1
            }
        }
        let fraction = Double(backlightCount) / Double(pixels.count)
        guard fraction >= minimumBacklightFraction,
              fraction <= maximumBacklightFraction else { return nil }

        // 2a. The LIGHTBOX extent first. A real scan is not "film on bright
        // ground" — it is film on a bright lightbox on a DARK table (measured
        // on IMG_7077: the outer rows classified 100% film because they are
        // tabletop). The bright region's own contiguous run bounds the
        // lightbox; the film box is then found WITHIN it, where "dark means
        // film" is actually true.
        var rowBacklight = [Int](repeating: 0, count: height)
        var colBacklight = [Int](repeating: 0, count: width)
        for row in 0..<height {
            for col in 0..<width where isBacklight[row * width + col] {
                rowBacklight[row] += 1
                colBacklight[col] += 1
            }
        }
        var backRowCentroid = 0.0, backColCentroid = 0.0
        for row in 0..<height { backRowCentroid += Double(row) * Double(rowBacklight[row]) }
        for col in 0..<width { backColCentroid += Double(col) * Double(colBacklight[col]) }
        backRowCentroid /= Double(backlightCount)
        backColCentroid /= Double(backlightCount)
        // Bounding SPAN, not a contiguous run: a dark film holder crossing
        // the lightbox interrupts the backlight rows (measured on IMG_7077 —
        // rows 80–88 dropped to 3% backlight mid-lightbox), and a contiguous
        // run would truncate the box at the holder. Whatever dark material
        // sits inside the span is the film stage's problem, which is the
        // point.
        _ = backRowCentroid; _ = backColCentroid
        guard let boxRows = boundingSpan(
                of: rowBacklight.map { Double($0) / Double(width) },
                threshold: lightboxProfileThreshold),
              let boxCols = boundingSpan(
                of: colBacklight.map { Double($0) / Double(height) },
                threshold: lightboxProfileThreshold)
        else { return nil }

        // 2b. The film box within the lightbox: film-fraction profiles
        // restricted to the lightbox's extent, run containing the film
        // centroid.
        var rowFilm = [Int](repeating: 0, count: height)
        var colFilm = [Int](repeating: 0, count: width)
        var filmTotal = 0.0
        var centroidRow = 0.0, centroidCol = 0.0
        for row in boxRows {
            for col in boxCols where !isBacklight[row * width + col] {
                rowFilm[row] += 1
                colFilm[col] += 1
                centroidRow += Double(row)
                centroidCol += Double(col)
                filmTotal += 1
            }
        }
        guard filmTotal > 0 else { return nil }
        centroidRow /= filmTotal
        centroidCol /= filmTotal

        // On a phone scan the film stage can legitimately fail: auto white
        // balance neutralizes the orange mask in the capture, so a THIN
        // picture area reads like backlight under every pixel-wise cue
        // (measured on IMG_7077 — the tree canopy classified 60-99%
        // backlight under luma, chroma, and combined rules). The honest
        // fallback is the LIGHTBOX box itself: cropping to it removes the
        // room and the bezel, and Auto's own calibrated pixel gates were
        // built to drop the remaining bare strips — the demo-crop evidence
        // (accepted renders through a lightbox-level rect) proves that is
        // sufficient. No rebate is reported in that case: we do not know
        // where the rebate is, and a guessed base is worse than none.
        func lightboxFallback() -> DetectedFrame? {
            let lightboxArea = Double(boxRows.count * boxCols.count)
            guard lightboxArea / Double(pixels.count) <= lightboxFallbackMaxAreaFraction,
                  lightboxArea / Double(pixels.count) >= lightboxFallbackMinAreaFraction
            else { return nil }
            let rect = CGRect(
                x: Double(boxCols.lowerBound) / Double(width),
                y: Double(height - boxRows.upperBound) / Double(height),
                width: Double(boxCols.count) / Double(width),
                height: Double(boxRows.count) / Double(height))
            return DetectedFrame(rect: rect, backlightFraction: fraction,
                                 rebateBase: nil)
        }

        guard let rows = contiguousRun(of: rowFilm.map { Double($0) / Double(boxCols.count) },
                                       around: Int(centroidRow),
                                       threshold: profileThreshold),
              let cols = contiguousRun(of: colFilm.map { Double($0) / Double(boxRows.count) },
                                       around: Int(centroidCol),
                                       threshold: profileThreshold)
        else { return lightboxFallback() }

        let boxArea = Double((rows.upperBound - rows.lowerBound)
                             * (cols.upperBound - cols.lowerBound))
        // Area gate relative to the LIGHTBOX, not the whole photo — a scan
        // that includes lots of table legitimately shrinks the film's share
        // of the frame.
        let lightboxArea = Double(boxRows.count * boxCols.count)
        guard boxArea / lightboxArea >= minimumBoxAreaFraction else {
            return lightboxFallback()
        }

        // 3. The rebate ring: brightest-percentile colour of the box's outer
        // band — actual unexposed film, the most reliable Dmin there is.
        // Refused when it reads as leaked backlight.
        let ring = Int((Double(min(rows.count, cols.count)) * ringFraction).rounded(.up))
        var ringR: [Double] = [], ringG: [Double] = [], ringB: [Double] = []
        for row in rows {
            for col in cols {
                let inBand = row < rows.lowerBound + ring || row >= rows.upperBound - ring
                    || col < cols.lowerBound + ring || col >= cols.upperBound - ring
                guard inBand, !isBacklight[row * width + col] else { continue }
                let p = pixels[row * width + col]
                ringR.append(p.0); ringG.append(p.1); ringB.append(p.2)
            }
        }
        var rebate: FilmColor?
        if ringR.count >= 16 {
            let base = (AutoInvert.percentile(ringR.sorted(), PaperResponse.dminPercentile),
                        AutoInvert.percentile(ringG.sorted(), PaperResponse.dminPercentile),
                        AutoInvert.percentile(ringB.sorted(), PaperResponse.dminPercentile))
            if min(base.0, min(base.1, base.2)) < backlightLevel {
                rebate = FilmColor(red: PaperResponse.srgbEncode(base.0),
                                   green: PaperResponse.srgbEncode(base.1),
                                   blue: PaperResponse.srgbEncode(base.2))
            }
        }

        // 4. Unit rect, converting top-down rows to bottom-left-origin y.
        let rect = CGRect(
            x: Double(cols.lowerBound) / Double(width),
            y: Double(height - rows.upperBound) / Double(height),
            width: Double(cols.count) / Double(width),
            height: Double(rows.count) / Double(height))
        return DetectedFrame(rect: rect, backlightFraction: fraction, rebateBase: rebate)
    }

    // MARK: Internals

    /// First-to-last span of ≥-threshold entries — the lightbox's extent,
    /// deliberately tolerant of interruptions (holder bars) inside it.
    private static func boundingSpan(of fractions: [Double],
                                     threshold: Double) -> Range<Int>? {
        guard let first = fractions.firstIndex(where: { $0 >= threshold }),
              let last = fractions.lastIndex(where: { $0 >= threshold }),
              last >= first else { return nil }
        return first..<(last + 1)
    }

    /// Longest contiguous run of ≥-threshold entries containing `anchor`
    /// (a centroid), as an index range. nil when the anchor itself fails the
    /// threshold.
    private static func contiguousRun(of fractions: [Double],
                                      around anchor: Int,
                                      threshold: Double) -> Range<Int>? {
        let anchor = min(max(anchor, 0), fractions.count - 1)
        guard fractions[anchor] >= threshold else { return nil }
        var lo = anchor, hi = anchor
        while lo > 0, fractions[lo - 1] >= threshold { lo -= 1 }
        while hi < fractions.count - 1, fractions[hi + 1] >= threshold { hi += 1 }
        return lo..<(hi + 1)
    }

    /// Downsampled LINEAR grid with its dimensions — `AutoInvert.linearPixels`
    /// discards the shape, and the profiles need it.
    private static func linearGrid(of image: CIImage, side: Int, context: CIContext)
        -> (pixels: [(Double, Double, Double)], width: Int, height: Int)? {
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
        let pixels = (0..<(width * height)).map { i in
            (Double(buffer[i * 4]), Double(buffer[i * 4 + 1]), Double(buffer[i * 4 + 2]))
        }
        return (pixels, width, height)
    }
}
