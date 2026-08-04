import CoreImage
import CoreImage.CIFilterBuiltins

/// The print engine's render stage: one GPU pass through
/// `film_density_print`, on linear working-space values.
///
/// The legacy converter brackets its work in sRGB because a linear
/// divide-and-invert crushes highlights — a correct workaround for a model
/// with no logarithm in it. The density model is *defined* on linear
/// transmittance, so this path simply does not bracket.
enum FilmDensityConverter {
    private static let kernel = KernelLibrary.color("film_density_print")

    static func convert(_ image: CIImage, settings: FilmNegativeSettings) -> CIImage {
        let p = settings.print

        // The persisted base is display-encoded (shared with the matrix
        // engine, the swatch, and the eyedropper); linearize at the boundary.
        // B&W has no color mask: its base is one neutral level, same reasoning
        // as the matrix path.
        let dminLinear: (Double, Double, Double)
        if settings.type.hasColorMask {
            let b = settings.baseColor.safeForDivision
            dminLinear = (PaperResponse.srgbDecode(b.red),
                          PaperResponse.srgbDecode(b.green),
                          PaperResponse.srgbDecode(b.blue))
        } else {
            let level = PaperResponse.srgbDecode(max(settings.baseColor.maxChannel, 0.0001))
            dminLinear = (level, level, level)
        }

        let grade = PaperResponse.gradeScale(p.contrast)
        var result = kernel.apply(
            extent: image.extent,
            arguments: [
                image,
                CIVector(x: dminLinear.0, y: dminLinear.1, z: dminLinear.2),
                CIVector(x: p.dmax.red, y: p.dmax.green, z: p.dmax.blue),
                CIVector(x: p.gamma.red * grade, y: p.gamma.green * grade,
                         z: p.gamma.blue * grade),
                Float(p.exposure * log10(2.0)),
                Float(PaperResponse.kneeP(shoulder: p.shoulder)),
                Float(PaperResponse.kneeQ(toe: p.toe)),
                Float(PaperResponse.shoulderStart),
                Float(PaperResponse.highlightDesat),
                Float(1.0 + p.saturation / 100.0),
            ]
        ) ?? image

        // Film Exposure (the legacy EV lift) still applies if set — it is a
        // linear-light stop, meaningful on either engine.
        if settings.exposure != 0 {
            let exposure = CIFilter.exposureAdjust()
            exposure.inputImage = result
            exposure.ev = Float(settings.exposure)
            result = exposure.outputImage ?? result
        }

        // A B&W negative comes back neutral, same promise as the matrix path.
        if settings.type == .blackAndWhiteNegative {
            let mono = CIFilter.colorControls()
            mono.inputImage = result
            mono.saturation = 0
            result = mono.outputImage ?? result
        }

        return result
    }
}
