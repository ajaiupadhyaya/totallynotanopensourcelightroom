import CoreImage

/// Swift face of the Color.ci.metal kernel. Amounts arrive on the sliders'
/// −100…100 scale and are normalized here, so the kernel speaks −1…1.
enum ColorStages {
    private static let kernel = KernelLibrary.color("pv2_vibrance_saturation")

    static func vibranceAndSaturation(_ image: CIImage,
                                      vibrance: Double, saturation: Double) -> CIImage {
        guard vibrance != 0 || saturation != 0 else { return image }
        return kernel.apply(extent: image.extent,
                            arguments: [image, Float(vibrance / 100),
                                        Float(saturation / 100)]) ?? image
    }
}
