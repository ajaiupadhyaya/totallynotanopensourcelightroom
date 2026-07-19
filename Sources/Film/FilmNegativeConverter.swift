import CoreImage
import CoreImage.CIFilterBuiltins

/// Converts a scanned film negative into a positive image.
///
/// ## Why the math happens in gamma-encoded space
///
/// Core Image's working space is linear light. A film scan, though, is closer
/// to a *density* measurement, and the classic negative inversion (divide out
/// the base, then flip) is what scanner and darkroom software does on
/// gamma-encoded values. Inverting in linear light instead crushes the
/// highlights and produces the harsh, plasticky look people associate with a
/// bad negative conversion.
///
/// So the chain brackets its work: encode to sRGB, do the inversion, then
/// decode back to linear before handing off to the rest of the pipeline. The
/// downstream sliders (exposure, curves, and so on) are unaffected and still
/// see a normal linear positive image.
///
/// ## The single-matrix inversion
///
/// Mask removal, inversion, and per-channel balance collapse into one affine
/// operation per channel. For a channel with base `b` and gain `g`:
///
///     normalized = x / b          — divide the mask out; base becomes 1.0
///     inverted   = 1 - normalized — flip; the base area becomes black
///     balanced   = g * inverted
///
/// Substituting gives `balanced = -(g/b)·x + g`, i.e. a slope of `-g/b` and a
/// bias of `g`. One `CIColorMatrix` does all three, so the whole conversion is
/// a single GPU pass rather than three.
enum FilmNegativeConverter {
    /// Applies the negative conversion described by `settings`.
    ///
    /// Returns the image untouched when the conversion is disabled, so this is
    /// safe to call unconditionally from the render chain.
    static func convert(_ image: CIImage, settings: FilmNegativeSettings) -> CIImage {
        guard settings.isEnabled else { return image }

        var result = image

        // Work on gamma-encoded values (see the type doc).
        result = result.applyingFilter("CILinearToSRGBToneCurve")

        if settings.type.requiresInversion {
            result = invert(result, settings: settings)
        }

        // Back to the linear working space the rest of the pipeline expects.
        result = result.applyingFilter("CISRGBToneCurveToLinear")

        // Exposure placement, in linear light where EV stops are meaningful.
        if settings.exposure != 0 {
            let exposure = CIFilter.exposureAdjust()
            exposure.inputImage = result
            exposure.ev = Float(settings.exposure)
            result = exposure.outputImage ?? result
        }

        // The stock's own contrast/saturation character.
        if settings.stockContrast != 0 || settings.stockSaturation != 0 {
            let controls = CIFilter.colorControls()
            controls.inputImage = result
            controls.contrast = Float(1.0 + settings.stockContrast / 100.0)
            controls.saturation = Float(1.0 + settings.stockSaturation / 100.0)
            result = controls.outputImage ?? result
        }

        // A B&W negative should come back neutral; any residual scanner cast
        // after inversion is not information we want to keep.
        if settings.type == .blackAndWhiteNegative {
            let mono = CIFilter.colorControls()
            mono.inputImage = result
            mono.saturation = 0
            result = mono.outputImage ?? result
        }

        return result
    }

    /// Mask removal + inversion + channel balance as one color matrix.
    private static func invert(_ image: CIImage, settings: FilmNegativeSettings) -> CIImage {
        // B&W has no color mask to divide out, so its base is treated as a
        // single neutral level — dividing per-channel there would introduce a
        // color cast rather than remove one.
        let base: FilmColor = settings.type.hasColorMask
            ? settings.baseColor.safeForDivision
            : {
                let level = max(settings.baseColor.maxChannel, 0.0001)
                return FilmColor(red: level, green: level, blue: level)
            }()
        let gain = settings.channelGains

        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = image
        matrix.rVector = CIVector(x: -gain.red / base.red, y: 0, z: 0, w: 0)
        matrix.gVector = CIVector(x: 0, y: -gain.green / base.green, z: 0, w: 0)
        matrix.bVector = CIVector(x: 0, y: 0, z: -gain.blue / base.blue, w: 0)
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        matrix.biasVector = CIVector(x: gain.red, y: gain.green, z: gain.blue, w: 0)
        return matrix.outputImage ?? image
    }
}
