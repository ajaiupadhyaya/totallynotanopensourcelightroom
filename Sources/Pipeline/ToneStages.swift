import CoreImage

/// Swift faces of the Tone.ci.metal kernels. Amounts arrive on the sliders'
/// −100…100 scale and are normalized here, so the kernels speak −1…1.
enum ToneStages {
    private static let contrastKernel = KernelLibrary.color("pv2_contrast")
    private static let whitesBlacksKernel = KernelLibrary.color("pv2_whites_blacks")

    static func contrast(_ image: CIImage, amount: Double) -> CIImage {
        guard amount != 0 else { return image }
        return contrastKernel.apply(extent: image.extent,
                                    arguments: [image, Float(amount / 100)]) ?? image
    }

    static func whitesAndBlacks(_ image: CIImage, whites: Double, blacks: Double) -> CIImage {
        guard whites != 0 || blacks != 0 else { return image }
        return whitesBlacksKernel.apply(extent: image.extent,
                                        arguments: [image, Float(whites / 100), Float(blacks / 100)]) ?? image
    }
}
