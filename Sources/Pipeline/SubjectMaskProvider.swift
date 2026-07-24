import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Vision

/// On-device Vision masks that compose with the existing mask set algebra.
///
/// Subject and person masks use Apple's local ML; background is the inverted
/// subject; sky is a classical top-weighted colour heuristic refinable with
/// range masks — there is no public Vision sky API.
enum SubjectMaskProvider {
    enum Kind: String, CaseIterable {
        case subject
        case person
        case background
        case sky
    }

    static func mask(
        kind: Kind,
        source: CIImage,
        extent: CGRect,
        environment: MLMaskEnvironment?,
        context: CIContext
    ) -> CIImage? {
        if let environment,
           let cached = MLMaskCache.shared.load(kind: kind, environment: environment) {
            return align(cached, to: extent)
        }

        guard let cgImage = context.createCGImage(source, from: extent) else { return nil }

        let generated: CIImage?
        switch kind {
        case .subject:
            generated = foregroundMask(from: cgImage, extent: extent)
        case .person:
            generated = personMask(from: cgImage, extent: extent)
        case .background:
            generated = foregroundMask(from: cgImage, extent: extent).map {
                invert($0, extent: extent)
            }
        case .sky:
            generated = skyMask(source: source, extent: extent, context: context)
        }

        if let generated, let environment {
            MLMaskCache.shared.store(generated, kind: kind, environment: environment, context: context)
        }
        return generated
    }

    // MARK: Vision

    private static func foregroundMask(from cgImage: CGImage, extent: CGRect) -> CIImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
            guard let observation = request.results?.first else { return nil }
            let instances = observation.allInstances
            guard !instances.isEmpty else { return nil }
            let buffer = try observation.generateScaledMaskForImage(
                forInstances: instances, from: handler
            )
            return ciImage(from: buffer)?.cropped(to: extent)
        } catch {
            return nil
        }
    }

    private static func personMask(from cgImage: CGImage, extent: CGRect) -> CIImage? {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
            guard let observation = request.results?.first else { return nil }
            return ciImage(from: observation.pixelBuffer)?.cropped(to: extent)
        } catch {
            return nil
        }
    }

    // MARK: Sky heuristic

    /// Seeds from the top band's average colour, then selects similar tones
    /// with a top-weighted gradient so the horizon fades out naturally.
    private static func skyMask(
        source: CIImage, extent: CGRect, context: CIContext
    ) -> CIImage? {
        let topBand = CGRect(
            x: extent.origin.x,
            y: extent.origin.y + extent.height * 0.75,
            width: extent.width,
            height: extent.height * 0.25
        )
        guard let sampled = FilmBaseSampler.sampleAverage(
            from: source, in: topBand, context: context
        ) else { return nil }

        var component = MaskComponent(shape: .colorRange)
        component.sampledColor = MaskColor(red: sampled.red, green: sampled.green, blue: sampled.blue)
        component.colorTolerance = 0.35
        component.colorFalloff = 0.25
        guard let colour = RangeMaskBuilder.colorRangeMask(component, source: source, extent: extent)
        else { return nil }

        let gradient = CIFilter.linearGradient()
        gradient.point0 = CGPoint(x: extent.midX, y: extent.maxY)
        gradient.point1 = CGPoint(x: extent.midX, y: extent.midY)
        gradient.color0 = CIColor(red: 1, green: 1, blue: 1)
        gradient.color1 = CIColor(red: 0, green: 0, blue: 0)
        guard let falloff = gradient.outputImage?.cropped(to: extent) else { return colour }

        let multiply = CIFilter.multiplyCompositing()
        multiply.inputImage = colour
        multiply.backgroundImage = falloff
        return multiply.outputImage?.cropped(to: extent)
    }

    // MARK: Helpers

    private static func ciImage(from buffer: CVPixelBuffer) -> CIImage? {
        CIImage(cvPixelBuffer: buffer)
    }

    private static func invert(_ image: CIImage, extent: CGRect) -> CIImage {
        let filter = CIFilter.colorInvert()
        filter.inputImage = image
        return filter.outputImage?.cropped(to: extent) ?? image
    }

    private static func align(_ image: CIImage, to extent: CGRect) -> CIImage {
        let sourceExtent = image.extent
        guard sourceExtent.size != extent.size else {
            return image.cropped(to: extent)
        }
        let scaleX = extent.width / sourceExtent.width
        let scaleY = extent.height / sourceExtent.height
        return image
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .transformed(by: CGAffineTransform(translationX: extent.origin.x, y: extent.origin.y))
            .cropped(to: extent)
    }
}
