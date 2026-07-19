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
/// ## Order of operations
///
/// The chain follows the order a photographer would work in, and several steps
/// only make sense in one position:
///
/// 1. **Film negative** — first, because on an un-inverted scan every
///    subsequent slider would work backwards.
/// 2. **Geometry** — early, so the histogram and every local effect (vignette,
///    grain) describe the cropped frame rather than the discarded one.
/// 3. **White balance**, then **exposure** — global color and brightness.
/// 4. **Tonal shaping** — whites/blacks, highlights/shadows, contrast.
/// 5. **Presence** — texture, clarity, dehaze: local-contrast work that wants
///    the tones already placed.
/// 6. **Color** — vibrance and saturation.
/// 7. **Tone curve** — the last tonal shaping step, as in Lightroom.
/// 8. **Detail** — noise reduction *before* sharpening, so sharpening isn't
///    amplifying noise the reduction was about to remove.
/// 9. **Effects** — vignette and grain last, over the finished image.
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

        image = FilmNegativeConverter.convert(image, settings: stack.filmNegative)
        image = GeometryTransform.apply(image, geometry: stack.geometry)
        image = applyWhiteBalance(image, stack: stack)
        image = applyExposure(image, stack: stack)
        image = applyWhitesAndBlacks(image, stack: stack)
        image = applyHighlightsAndShadows(image, stack: stack)
        image = applyContrast(image, stack: stack)
        image = applyPresence(image, stack: stack)
        image = applyColor(image, stack: stack)
        image = applyToneCurve(image, stack: stack)
        image = applyDetail(image, stack: stack)
        image = applyEffects(image, stack: stack)

        return image
    }

    // MARK: Tone

    private func applyWhiteBalance(_ image: CIImage, stack: EditStack) -> CIImage {
        guard stack.whiteBalanceTemp != 6500 || stack.whiteBalanceTint != 0 else { return image }
        let wb = CIFilter.temperatureAndTint()
        wb.inputImage = image
        // Treat the chosen temp/tint as the image's *current* neutral and remap
        // it to D65. This gives the intuitive direction: a higher temperature
        // warms the image (pushes red up, blue down).
        wb.neutral = CIVector(x: stack.whiteBalanceTemp, y: stack.whiteBalanceTint)
        wb.targetNeutral = CIVector(x: 6500, y: 0)
        return wb.outputImage ?? image
    }

    private func applyExposure(_ image: CIImage, stack: EditStack) -> CIImage {
        guard stack.exposure != 0 else { return image }
        let exposure = CIFilter.exposureAdjust()
        exposure.inputImage = image
        exposure.ev = Float(stack.exposure)
        return exposure.outputImage ?? image
    }

    /// Whites and blacks reshape the two ends of the tone range via a curve
    /// pinned at both extremes: pure black stays black and pure white stays
    /// white, while the quarter- and three-quarter-tones move. Scaling the
    /// endpoints instead would just clip.
    private func applyWhitesAndBlacks(_ image: CIImage, stack: EditStack) -> CIImage {
        guard stack.whites != 0 || stack.blacks != 0 else { return image }

        func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }
        let quarter = clamp(0.25 + stack.blacks / 100 * 0.15)
        let threeQuarter = clamp(0.75 + stack.whites / 100 * 0.15)

        let curve = CIFilter.toneCurve()
        curve.inputImage = image
        curve.point0 = CGPoint(x: 0, y: 0)
        curve.point1 = CGPoint(x: 0.25, y: quarter)
        curve.point2 = CGPoint(x: 0.5, y: 0.5)
        curve.point3 = CGPoint(x: 0.75, y: threeQuarter)
        curve.point4 = CGPoint(x: 1, y: 1)
        return curve.outputImage ?? image
    }

    private func applyHighlightsAndShadows(_ image: CIImage, stack: EditStack) -> CIImage {
        guard stack.highlights != 0 || stack.shadows != 0 else { return image }
        // highlightAmount 1.0 == no change (lower recovers highlights);
        // shadowAmount 0 == no change (positive lifts).
        let hs = CIFilter.highlightShadowAdjust()
        hs.inputImage = image
        hs.highlightAmount = Float(1.0 + stack.highlights / 100.0)
        hs.shadowAmount = Float(stack.shadows / 100.0)
        return hs.outputImage ?? image
    }

    private func applyContrast(_ image: CIImage, stack: EditStack) -> CIImage {
        guard stack.contrast != 0 else { return image }
        let controls = CIFilter.colorControls()
        controls.inputImage = image
        controls.contrast = Float(1.0 + stack.contrast / 100.0)
        return controls.outputImage ?? image
    }

    // MARK: Presence

    /// Texture, clarity, and dehaze.
    ///
    /// Texture and clarity are both unsharp masks; the only real difference is
    /// radius. Texture works at a few pixels, so it lifts surface detail (skin,
    /// fabric, grain) without halos around large edges. Clarity works at a much
    /// larger radius, which is what produces its midtone "punch."
    private func applyPresence(_ image: CIImage, stack: EditStack) -> CIImage {
        var result = image

        if stack.texture != 0 {
            result = unsharpMask(result, radius: 2.5,
                                 intensity: stack.texture / 100.0)
        }

        if stack.clarity != 0 {
            result = unsharpMask(result, radius: 30,
                                 intensity: stack.clarity / 100.0 * 0.7)
        }

        if stack.dehaze != 0 {
            result = applyDehaze(result, amount: stack.dehaze)
        }

        return result
    }

    private func unsharpMask(_ image: CIImage, radius: Double, intensity: Double) -> CIImage {
        let filter = CIFilter.unsharpMask()
        filter.inputImage = image
        filter.radius = Float(radius)
        filter.intensity = Float(intensity)
        return filter.outputImage ?? image
    }

    /// An *approximation* of haze removal.
    ///
    /// Real dehazing estimates a per-pixel atmospheric transmission map — it
    /// needs a depth-ish model of the scene, which is well beyond a fixed
    /// filter chain. What this does instead is reproduce haze's three visible
    /// signatures: it pulls the black point back down (haze lifts blacks toward
    /// gray), adds contrast, and restores the saturation haze washes out.
    ///
    /// On genuinely hazy landscapes that lands close to the real thing. On an
    /// image with no haze it behaves like a combined contrast/saturation
    /// control rather than doing nothing, which is worth knowing.
    private func applyDehaze(_ image: CIImage, amount: Double) -> CIImage {
        let normalized = amount / 100.0
        var result = image

        // Pull the black point down (or lift it, for negative amounts).
        let blackPoint = 0.06 * normalized
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = result
        let scale = 1.0 / max(1.0 - blackPoint, 0.2)
        matrix.rVector = CIVector(x: scale, y: 0, z: 0, w: 0)
        matrix.gVector = CIVector(x: 0, y: scale, z: 0, w: 0)
        matrix.bVector = CIVector(x: 0, y: 0, z: scale, w: 0)
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        matrix.biasVector = CIVector(x: -blackPoint * scale,
                                     y: -blackPoint * scale,
                                     z: -blackPoint * scale, w: 0)
        result = matrix.outputImage ?? result

        let controls = CIFilter.colorControls()
        controls.inputImage = result
        controls.contrast = Float(1.0 + normalized * 0.25)
        controls.saturation = Float(1.0 + normalized * 0.20)
        return controls.outputImage ?? result
    }

    // MARK: Color

    private func applyColor(_ image: CIImage, stack: EditStack) -> CIImage {
        var result = image

        if stack.vibrance != 0 {
            let filter = CIFilter.vibrance()
            filter.inputImage = result
            filter.amount = Float(stack.vibrance / 100.0)
            result = filter.outputImage ?? result
        }

        if stack.saturation != 0 {
            let controls = CIFilter.colorControls()
            controls.inputImage = result
            controls.saturation = Float(1.0 + stack.saturation / 100.0)
            result = controls.outputImage ?? result
        }

        return result
    }

    private func applyToneCurve(_ image: CIImage, stack: EditStack) -> CIImage {
        guard stack.toneCurvePoints.count == 5 else { return image }
        let curve = CIFilter.toneCurve()
        curve.inputImage = image
        curve.point0 = stack.toneCurvePoints[0]
        curve.point1 = stack.toneCurvePoints[1]
        curve.point2 = stack.toneCurvePoints[2]
        curve.point3 = stack.toneCurvePoints[3]
        curve.point4 = stack.toneCurvePoints[4]
        return curve.outputImage ?? image
    }

    // MARK: Detail

    private func applyDetail(_ image: CIImage, stack: EditStack) -> CIImage {
        var result = image

        if stack.colorNoiseReduction > 0 {
            result = reduceColorNoise(result, amount: stack.colorNoiseReduction)
        }

        if stack.luminanceNoiseReduction > 0 {
            let filter = CIFilter.noiseReduction()
            filter.inputImage = result
            // CINoiseReduction's useful noiseLevel range is small; 0.05 at full
            // strength is already heavy-handed.
            filter.noiseLevel = Float(stack.luminanceNoiseReduction / 100.0 * 0.05)
            filter.sharpness = 0.4
            result = filter.outputImage ?? result
        }

        if stack.sharpenAmount > 0 {
            result = unsharpMask(result,
                                 radius: stack.sharpenRadius,
                                 intensity: stack.sharpenAmount / 100.0 * 1.5)
        }

        return result
    }

    /// Chroma noise reduction: blur the *color* while keeping the original
    /// luminance.
    ///
    /// Color noise shows up as blotchy hue shifts that survive a luminance
    /// blur, and blurring the whole image to remove them would throw away real
    /// detail. `CIColorBlendMode` takes hue and saturation from the top layer
    /// and luminosity from the bottom, so compositing a blurred copy over the
    /// original in that mode discards the noisy chroma and keeps every bit of
    /// the original's sharpness.
    private func reduceColorNoise(_ image: CIImage, amount: Double) -> CIImage {
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = image.clampedToExtent()
        blur.radius = Float(amount / 100.0 * 12.0)
        guard let blurred = blur.outputImage?.cropped(to: image.extent) else { return image }

        let blend = CIFilter.colorBlendMode()
        blend.inputImage = blurred
        blend.backgroundImage = image
        return blend.outputImage ?? image
    }

    // MARK: Effects

    private func applyEffects(_ image: CIImage, stack: EditStack) -> CIImage {
        var result = image

        if stack.vignetteAmount != 0 {
            result = applyVignette(result, stack: stack)
        }

        if stack.grainAmount > 0 {
            result = applyGrain(result, stack: stack)
        }

        return result
    }

    private func applyVignette(_ image: CIImage, stack: EditStack) -> CIImage {
        let extent = image.extent
        guard !extent.isInfinite, extent.width > 0 else { return image }

        let filter = CIFilter.vignetteEffect()
        filter.inputImage = image
        filter.center = CGPoint(x: extent.midX, y: extent.midY)
        // Midpoint controls how far in from the corners the falloff reaches.
        let maxRadius = max(extent.width, extent.height) / 2
        filter.radius = Float(maxRadius * (0.5 + stack.vignetteMidpoint / 100.0))
        filter.intensity = Float(-stack.vignetteAmount / 100.0)
        filter.falloff = 0.5
        return filter.outputImage ?? image
    }

    /// Film grain: monochrome noise blended over the image in soft light.
    ///
    /// The noise is desaturated first — real grain is a density variation in
    /// the emulsion, not colored speckle, so colored noise reads as sensor
    /// noise rather than film. Soft light keeps the grain from crushing the
    /// blacks or blowing the highlights the way an additive blend would.
    private func applyGrain(_ image: CIImage, stack: EditStack) -> CIImage {
        let extent = image.extent
        guard !extent.isInfinite, extent.width > 0 else { return image }

        guard let noise = CIFilter(name: "CIRandomGenerator")?.outputImage else { return image }

        // Scale the noise up for coarser grain, then crop to the frame.
        let scale = 0.5 + stack.grainSize / 100.0 * 2.5
        let scaled = noise.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let mono = CIFilter.colorControls()
        mono.inputImage = scaled
        mono.saturation = 0
        // Pull the noise toward mid-gray so soft light nudges rather than
        // stamps; strength then scales that residual contrast.
        mono.contrast = Float(stack.grainAmount / 100.0 * 0.9)
        mono.brightness = 0
        guard let grain = mono.outputImage?.cropped(to: extent) else { return image }

        let blend = CIFilter.softLightBlendMode()
        blend.inputImage = grain
        blend.backgroundImage = image
        return blend.outputImage?.cropped(to: extent) ?? image
    }

    // MARK: Rasterization

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
