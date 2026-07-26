import CoreImage

/// Highlights/shadows: guided-filter base + kernel recombine.
enum LocalToneStage {
    private static let kernel = KernelLibrary.color("pv2_local_tone")

    static func apply(_ image: CIImage, highlights: Double, shadows: Double) -> CIImage {
        guard highlights != 0 || shadows != 0 else { return image }
        guard !image.extent.isInfinite, image.extent.width > 0 else { return image }

        // Radius ~1% of the long edge: big enough to be "local tone", small
        // enough that CIGuidedFilter stays cheap. Clamped so tiny previews
        // and huge exports both behave.
        let longEdge = Double(max(image.extent.width, image.extent.height))
        let radius = min(60.0, max(8.0, longEdge * 0.01))

        guard let guided = CIFilter(name: "CIGuidedFilter") else { return image }
        // NOTE: deliberately NOT clampedToExtent() here. CIGuidedFilter's
        // domain-of-definition math can't handle an infinite input extent —
        // feeding it a clamped (infinite) image collapses outputImage.extent
        // to CGRect.null (verified empirically), silently turning this stage
        // into a no-op. The finite image on its own already produces a base
        // whose extent matches the input exactly, with no boundary falloff.
        guided.setValue(image, forKey: kCIInputImageKey)
        guided.setValue(image, forKey: "inputGuideImage")
        guided.setValue(radius, forKey: "inputRadius")
        guided.setValue(0.01, forKey: "inputEpsilon")
        guard let base = guided.outputImage?.cropped(to: image.extent) else { return image }

        return kernel.apply(extent: image.extent,
                            arguments: [image, base,
                                        Float(highlights / 100), Float(shadows / 100)]) ?? image
    }
}
