import CoreImage

enum EffectsStages {
    private static let vignetteKernel = KernelLibrary.general("pv2_vignette")

    static func vignette(_ image: CIImage, stack: EditStack) -> CIImage {
        guard stack.vignetteAmount != 0 else { return image }
        let extent = image.extent
        guard !extent.isInfinite, extent.width > 0 else { return image }

        var hw = extent.width / 2
        var hh = extent.height / 2
        // Positive roundness pulls the field toward a circle by equalizing
        // the two radii; negative squares the superellipse exponent instead.
        let roundness = stack.vignetteRoundness / 100
        if roundness > 0 {
            let m = min(hw, hh)
            hw += (m - hw) * roundness
            hh += (m - hh) * roundness
        }
        let shapeN = roundness < 0 ? 2 + 4 * (-roundness) : 2.0

        return vignetteKernel.apply(
            extent: extent,
            roiCallback: { _, rect in rect },
            arguments: [image,
                        Float(extent.midX), Float(extent.midY),
                        Float(hw), Float(hh),
                        Float(stack.vignetteAmount / 100),
                        Float(stack.vignetteMidpoint / 100),
                        Float(stack.vignetteFeather / 100),
                        Float(shapeN),
                        Float(stack.vignetteHighlights / 100)]) ?? image
    }
}
