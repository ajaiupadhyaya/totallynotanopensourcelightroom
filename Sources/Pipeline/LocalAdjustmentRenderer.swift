import CoreImage
import CoreImage.CIFilterBuiltins

/// Applies masked local adjustments.
///
/// Each adjustment renders as: build the fully-corrected version of the image,
/// build the mask as a grayscale gradient, then `CIBlendWithMask` interpolates
/// between corrected and untouched per pixel. Everything stays lazy `CIImage`
/// graph-building; nothing rasterizes here.
///
/// Note `CIBlendWithMask` reads the mask's **alpha** (see ``FocusPeaking`` for
/// the scar tissue), so gradients are generated as grayscale and passed through
/// `CIMaskToAlpha` before blending.
enum LocalAdjustmentRenderer {
    /// Applies every enabled, non-neutral adjustment in order.
    static func apply(_ adjustments: [LocalAdjustment], to image: CIImage) -> CIImage {
        var result = image
        for adjustment in adjustments where adjustment.isEnabled && !adjustment.isNeutral {
            result = apply(adjustment, to: result)
        }
        return result
    }

    static func apply(_ adjustment: LocalAdjustment, to image: CIImage) -> CIImage {
        let extent = image.extent
        guard !extent.isInfinite, extent.width >= 1, extent.height >= 1 else { return image }

        let corrected = corrections(of: adjustment, applied: image)
        guard let mask = mask(for: adjustment, extent: extent) else { return image }

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

    /// The adjustment's mask over `extent`: white (alpha 1) where corrections
    /// apply fully, black (alpha 0) where the image stays untouched.
    static func mask(for adjustment: LocalAdjustment, extent: CGRect) -> CIImage? {
        let gradient: CIImage?
        switch adjustment.shape {
        case .linear:
            gradient = linearGradient(adjustment, extent: extent)
        case .radial:
            gradient = radialGradient(adjustment, extent: extent)
        }
        guard var grayscale = gradient?.cropped(to: extent) else { return nil }

        if adjustment.isInverted {
            let invert = CIFilter.colorInvert()
            invert.inputImage = grayscale
            grayscale = invert.outputImage?.cropped(to: extent) ?? grayscale
        }

        // Luminance → alpha; CIBlendWithMask reads alpha.
        let toAlpha = CIFilter.maskToAlpha()
        toAlpha.inputImage = grayscale
        return toAlpha.outputImage
    }

    private static func linearGradient(
        _ adjustment: LocalAdjustment, extent: CGRect
    ) -> CIImage? {
        let filter = CIFilter.smoothLinearGradient()
        filter.point0 = pixelPoint(adjustment.startPoint, in: extent)
        filter.point1 = pixelPoint(adjustment.endPoint, in: extent)
        filter.color0 = CIColor.white
        filter.color1 = CIColor.black
        return filter.outputImage
    }

    /// An elliptical feathered gradient, built as a circular gradient and
    /// scaled anisotropically into the requested ellipse.
    private static func radialGradient(
        _ adjustment: LocalAdjustment, extent: CGRect
    ) -> CIImage? {
        let radiusX = max(adjustment.radiusX * extent.width, 1)
        let radiusY = max(adjustment.radiusY * extent.height, 1)
        let reference = max(radiusX, radiusY)

        let feather = min(max(adjustment.feather, 0), 1)
        let inner = reference * (1 - feather)

        let filter = CIFilter.radialGradient()
        filter.center = .zero
        filter.radius0 = Float(inner)
        filter.radius1 = Float(reference)
        filter.color0 = CIColor.white
        filter.color1 = CIColor.black
        guard let circle = filter.outputImage else { return nil }

        let center = pixelPoint(adjustment.center, in: extent)
        let transform = CGAffineTransform(translationX: center.x, y: center.y)
            .scaledBy(x: radiusX / reference, y: radiusY / reference)
        return circle.transformed(by: transform)
    }

    private static func pixelPoint(_ unit: CGPoint, in extent: CGRect) -> CGPoint {
        CGPoint(
            x: extent.origin.x + unit.x * extent.width,
            y: extent.origin.y + unit.y * extent.height
        )
    }
}
