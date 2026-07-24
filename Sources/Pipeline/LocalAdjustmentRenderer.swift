import CoreImage
import CoreImage.CIFilterBuiltins

/// Applies masked local adjustments.
///
/// Each adjustment renders as: build the fully-corrected version of the image,
/// compose its mask from ``MaskComponent``s via ``MaskCompositor``, then
/// `CIBlendWithMask` interpolates between corrected and untouched per pixel.
/// Everything stays lazy `CIImage` graph-building; nothing rasterizes here.
///
/// Note `CIBlendWithMask` reads the mask's **alpha** (see ``FocusPeaking`` for
/// the scar tissue), so masks are composed as grayscale and passed through
/// `CIMaskToAlpha` before blending.
enum LocalAdjustmentRenderer {
    /// Applies every enabled, non-neutral adjustment in order.
    ///
    /// `maskSource` is the image generated components measure — the frame as it
    /// entered this stage, *not* the running result, so masks do not cascade
    /// into one another.
    static func apply(
        _ adjustments: [LocalAdjustment], to image: CIImage, maskSource: CIImage,
        mlEnvironment: MLMaskEnvironment? = nil, context: CIContext? = nil
    ) -> CIImage {
        var result = image
        for adjustment in adjustments
        where adjustment.isEnabled && !adjustment.isNeutral && !adjustment.isEmpty {
            result = apply(adjustment, to: result, maskSource: maskSource,
                           mlEnvironment: mlEnvironment, context: context)
        }
        return result
    }

    static func apply(
        _ adjustment: LocalAdjustment, to image: CIImage, maskSource: CIImage,
        mlEnvironment: MLMaskEnvironment? = nil, context: CIContext? = nil
    ) -> CIImage {
        let extent = image.extent
        guard !extent.isInfinite, extent.width >= 1, extent.height >= 1 else { return image }

        let corrected = corrections(of: adjustment, applied: image)
        guard let mask = mask(for: adjustment, source: maskSource, extent: extent,
                              mlEnvironment: mlEnvironment, context: context) else {
            return image
        }

        let blend = CIFilter.blendWithMask()
        blend.inputImage = corrected
        blend.backgroundImage = image
        blend.maskImage = mask
        return blend.outputImage?.cropped(to: extent) ?? image
    }

    // MARK: Corrections

    /// The adjustment's corrections applied to the whole frame — masking
    /// happens afterwards in the blend.
    private static func corrections(
        of adjustment: LocalAdjustment, applied image: CIImage
    ) -> CIImage {
        var result = image

        if adjustment.warmth != 0 {
            let wb = CIFilter.temperatureAndTint()
            wb.inputImage = result
            // Same convention as the global slider: declare a warmer/cooler
            // neutral and remap to D65. 20 K per unit gives ±2000 K range.
            wb.neutral = CIVector(x: 6500 + adjustment.warmth * 20, y: 0)
            wb.targetNeutral = CIVector(x: 6500, y: 0)
            result = wb.outputImage ?? result
        }

        if adjustment.exposure != 0 {
            let exposure = CIFilter.exposureAdjust()
            exposure.inputImage = result
            exposure.ev = Float(adjustment.exposure)
            result = exposure.outputImage ?? result
        }

        if adjustment.highlights != 0 || adjustment.shadows != 0 {
            let hs = CIFilter.highlightShadowAdjust()
            hs.inputImage = result
            hs.highlightAmount = Float(1.0 + adjustment.highlights / 100.0)
            hs.shadowAmount = Float(adjustment.shadows / 100.0)
            result = hs.outputImage ?? result
        }

        if adjustment.contrast != 0 || adjustment.saturation != 0 {
            let controls = CIFilter.colorControls()
            controls.inputImage = result
            controls.contrast = Float(1.0 + adjustment.contrast / 100.0)
            controls.saturation = Float(1.0 + adjustment.saturation / 100.0)
            result = controls.outputImage ?? result
        }

        return result
    }

    // MARK: Masks

    /// The adjustment's composed mask as **grayscale**, with the whole-mask
    /// invert applied. The overlay draws this directly; the blend converts it.
    static func grayscaleMask(
        for adjustment: LocalAdjustment, source: CIImage, extent: CGRect,
        mlEnvironment: MLMaskEnvironment? = nil, context: CIContext? = nil
    ) -> CIImage? {
        guard var grayscale = MaskCompositor.composedMask(
            adjustment.components, source: source, extent: extent,
            mlEnvironment: mlEnvironment, context: context
        ) else { return nil }

        if adjustment.isInverted {
            let invert = CIFilter.colorInvert()
            invert.inputImage = grayscale
            grayscale = invert.outputImage?.cropped(to: extent) ?? grayscale
        }
        return grayscale
    }

    /// The composed mask as **alpha**, which is what `CIBlendWithMask` reads.
    static func mask(
        for adjustment: LocalAdjustment, source: CIImage, extent: CGRect,
        mlEnvironment: MLMaskEnvironment? = nil, context: CIContext? = nil
    ) -> CIImage? {
        guard let grayscale = grayscaleMask(
            for: adjustment, source: source, extent: extent,
            mlEnvironment: mlEnvironment, context: context
        )
        else { return nil }
        let toAlpha = CIFilter.maskToAlpha()
        toAlpha.inputImage = grayscale
        return toAlpha.outputImage
    }
}
