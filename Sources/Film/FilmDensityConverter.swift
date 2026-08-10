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
        let gammaEff = (p.gamma.red * grade, p.gamma.green * grade, p.gamma.blue * grade)
        let v2 = p.renderVersion >= 2
        // renderVersion 2 folds the legacy EV lift into the print exposure —
        // pre-curve, restoring the never-clips contract (Task 5). v1 keeps
        // the historical post-curve multiply below.
        var printOffset = PaperResponse.printOffsets(
            exposureEV: p.exposure + (v2 ? settings.exposure : 0),
            warmth: p.warmth, tint: p.tint, balancedTint: v2)
        // Cast correction: a density-domain offset per channel, folded
        // through the effective gamma (γ·(D + c − Dmax) = γ·(D − Dmax) + γ·c).
        printOffset.0 += gammaEff.0 * PaperResponse.castDensity(p.castRed)
        printOffset.1 += gammaEff.1 * PaperResponse.castDensity(p.castGreen)
        printOffset.2 += gammaEff.2 * PaperResponse.castDensity(p.castBlue)
        // Grade pivot (renderVersion 2, Auto-solved only): hold the solved
        // median invariant under grade — offset' = γ·(1 − k)·(P − Dmax),
        // with γ the UN-graded gamma and k the grade scale.
        if v2, let pivot = p.gradePivot {
            printOffset.0 += p.gamma.red * (1 - grade) * (pivot.red - p.dmax.red)
            printOffset.1 += p.gamma.green * (1 - grade) * (pivot.green - p.dmax.green)
            printOffset.2 += p.gamma.blue * (1 - grade) * (pivot.blue - p.dmax.blue)
        }
        var result = kernel.apply(
            extent: image.extent,
            arguments: [
                image,
                CIVector(x: dminLinear.0, y: dminLinear.1, z: dminLinear.2),
                CIVector(x: p.dmax.red, y: p.dmax.green, z: p.dmax.blue),
                CIVector(x: gammaEff.0, y: gammaEff.1, z: gammaEff.2),
                CIVector(x: printOffset.0, y: printOffset.1, z: printOffset.2),
                Float(PaperResponse.kneeP(shoulder: p.shoulder)),
                Float(PaperResponse.kneeQ(toe: p.toe)),
                Float(PaperResponse.shoulderStart),
                Float(PaperResponse.highlightDesat),
                Float(1.0 + p.saturation / 100.0),
                CIVector(x: gammaEff.0 * PaperResponse.zoneTrimDensity(p.shadowTrim.red),
                         y: gammaEff.1 * PaperResponse.zoneTrimDensity(p.shadowTrim.green),
                         z: gammaEff.2 * PaperResponse.zoneTrimDensity(p.shadowTrim.blue)),
                CIVector(x: gammaEff.0 * PaperResponse.zoneTrimDensity(p.midTrim.red),
                         y: gammaEff.1 * PaperResponse.zoneTrimDensity(p.midTrim.green),
                         z: gammaEff.2 * PaperResponse.zoneTrimDensity(p.midTrim.blue)),
                CIVector(x: gammaEff.0 * PaperResponse.zoneTrimDensity(p.highTrim.red),
                         y: gammaEff.1 * PaperResponse.zoneTrimDensity(p.highTrim.green),
                         z: gammaEff.2 * PaperResponse.zoneTrimDensity(p.highTrim.blue)),
                Float(PaperResponse.punchAmount(p.punch)),
                Float(PaperResponse.fadeLift(p.fade)),
                Float(PaperResponse.glowDrop(p.glow)),
                Float(PaperResponse.toeChromaWeight(p.toeChroma)),
                Float(PaperResponse.targetMid),
                Float(PaperResponse.toeStart),
                Float(PaperResponse.toeEnd),
                CIVector(x: PaperResponse.zoneShadowEnd,
                         y: PaperResponse.zoneShadowFade,
                         z: PaperResponse.zoneHighStart),
                Float(PaperResponse.zoneHighFull),
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
