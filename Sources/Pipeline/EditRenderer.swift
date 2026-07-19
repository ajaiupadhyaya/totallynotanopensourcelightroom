import CoreImage
import CoreImage.CIFilterBuiltins

/// Turns an ``EditStack`` into a rendered image by replaying it as a Core Image
/// filter chain against an untouched source `CIImage`.
///
/// The design keeps the edit math separate from rasterization:
/// - ``render(source:stack:)`` is pure — it assembles the (lazy) filter chain
///   and returns a `CIImage`, doing no pixel work. This is what makes the edit
///   logic straightforward to unit test.
/// - ``makeCGImage(_:)`` rasterizes a chain to a `CGImage` for display.
/// - ``histogram(of:binCount:)`` computes a per-channel histogram on the GPU.
///
/// Filters are applied in a deliberate order: white balance, then exposure,
/// then highlight/shadow recovery, then contrast/saturation, and finally the
/// tone curve as the last tonal shaping step.
struct EditRenderer {
    /// Shared context; GPU-backed (Metal) by default. Reused across renders so
    /// we don't pay context-setup cost on every slider tick.
    let context: CIContext

    init(context: CIContext = CIContext()) {
        self.context = context
    }

    /// Builds the edit filter chain. No rasterization happens here — filters
    /// that would leave the image unchanged (a value at its neutral point) are
    /// skipped, so the identity edit returns the source untouched.
    func render(source: CIImage, stack: EditStack) -> CIImage {
        var image = source

        // 0. Film negative conversion, before anything else. Everything
        //    downstream should be shaping a positive image, not a negative —
        //    on an un-inverted scan every other slider would work backwards.
        image = FilmNegativeConverter.convert(image, settings: stack.filmNegative)

        // 1. White balance (temperature / tint).
        if stack.whiteBalanceTemp != 6500 || stack.whiteBalanceTint != 0 {
            let wb = CIFilter.temperatureAndTint()
            wb.inputImage = image
            // Treat the chosen temp/tint as the image's *current* neutral and
            // remap it to D65. This gives the intuitive direction: a higher
            // temperature warms the image (pushes red up, blue down).
            wb.neutral = CIVector(x: stack.whiteBalanceTemp, y: stack.whiteBalanceTint)
            wb.targetNeutral = CIVector(x: 6500, y: 0)
            image = wb.outputImage ?? image
        }

        // 2. Exposure (EV stops).
        if stack.exposure != 0 {
            let exposure = CIFilter.exposureAdjust()
            exposure.inputImage = image
            exposure.ev = Float(stack.exposure)
            image = exposure.outputImage ?? image
        }

        // 3. Highlights & shadows. highlightAmount 1.0 == no change (lower
        //    recovers highlights); shadowAmount 0 == no change (positive lifts).
        if stack.highlights != 0 || stack.shadows != 0 {
            let hs = CIFilter.highlightShadowAdjust()
            hs.inputImage = image
            hs.highlightAmount = Float(1.0 + stack.highlights / 100.0)
            hs.shadowAmount = Float(stack.shadows / 100.0)
            image = hs.outputImage ?? image
        }

        // 4. Contrast + saturation, both centered on 1.0 (no change).
        if stack.contrast != 0 || stack.saturation != 0 {
            let controls = CIFilter.colorControls()
            controls.inputImage = image
            controls.contrast = Float(1.0 + stack.contrast / 100.0)
            controls.saturation = Float(1.0 + stack.saturation / 100.0)
            image = controls.outputImage ?? image
        }

        // 5. Tone curve — five control points, applied last. Empty == identity.
        if stack.toneCurvePoints.count == 5 {
            let curve = CIFilter.toneCurve()
            curve.inputImage = image
            curve.point0 = stack.toneCurvePoints[0]
            curve.point1 = stack.toneCurvePoints[1]
            curve.point2 = stack.toneCurvePoints[2]
            curve.point3 = stack.toneCurvePoints[3]
            curve.point4 = stack.toneCurvePoints[4]
            image = curve.outputImage ?? image
        }

        return image
    }

    /// Rasterizes an edited image to a `CGImage` for display.
    ///
    /// - Returns: `nil` if the image has an infinite extent (e.g. a bare
    ///   generator image) or Core Image fails to produce a bitmap.
    func makeCGImage(_ image: CIImage) -> CGImage? {
        guard !image.extent.isInfinite else { return nil }
        return context.createCGImage(image, from: image.extent)
    }

    /// Convenience: build the chain and rasterize in one call.
    func renderCGImage(source: CIImage, stack: EditStack) -> CGImage? {
        makeCGImage(render(source: source, stack: stack))
    }

    /// Computes a per-channel histogram of an image via `CIAreaHistogram`
    /// (a single GPU pass), read back into plain float arrays.
    ///
    /// - Returns: ``Histogram/empty`` if the image has no finite extent.
    func histogram(of image: CIImage, binCount: Int = 256) -> Histogram {
        let extent = image.extent
        guard !extent.isInfinite, extent.width >= 1, extent.height >= 1 else {
            return .empty
        }

        let filter = CIFilter.areaHistogram()
        filter.inputImage = image
        filter.extent = extent
        filter.count = binCount
        filter.scale = 20 // amplify counts into a visible range; we normalize by peak on display
        guard let output = filter.outputImage else { return .empty }

        var buffer = [Float](repeating: 0, count: binCount * 4)
        // Read the raw bin counts with no color management (colorSpace: nil) —
        // these are histogram values, not colors. The output is binCount×1.
        context.render(
            output,
            toBitmap: &buffer,
            rowBytes: binCount * 4 * MemoryLayout<Float>.stride,
            bounds: CGRect(x: 0, y: 0, width: binCount, height: 1),
            format: .RGBAf,
            colorSpace: nil
        )

        var red = [Float](repeating: 0, count: binCount)
        var green = red
        var blue = red
        for i in 0..<binCount {
            red[i] = buffer[i * 4]
            green[i] = buffer[i * 4 + 1]
            blue[i] = buffer[i * 4 + 2]
        }
        return Histogram(red: red, green: green, blue: blue)
    }
}
