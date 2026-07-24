import CoreImage
import CoreImage.CIFilterBuiltins

/// Builds masks from the photograph's own content: a band of tones, or a
/// distance from a sampled colour.
///
/// Both are classical image processing — a transfer curve and a colour-distance
/// lookup. There is deliberately no model here; `handoff.md` rules out AI
/// masking and subject selection.
enum RangeMaskBuilder {
    /// Selects everything whose luminance falls inside the component's band,
    /// with smoothstep shoulders of `luminanceFalloff` at each edge.
    static func luminanceMask(
        _ component: MaskComponent, source: CIImage, extent: CGRect
    ) -> CIImage? {
        // Measure tone the way the photographer sees it. Core Image works in
        // linear space, where 0.5 is not middle grey — a band picked against
        // the histogram would land somewhere else entirely.
        let encoded = source
            .clampedToExtent()
            .applyingFilter("CILinearToSRGBToneCurve")
            .cropped(to: extent)

        let luma = CIFilter.colorMatrix()
        luma.inputImage = encoded
        let weights = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
        luma.rVector = weights
        luma.gVector = weights
        luma.bVector = weights
        luma.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        luma.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        guard let gray = luma.outputImage?.cropped(to: extent) else { return nil }

        let curve = CIFilter.colorCurves()
        curve.inputImage = gray
        curve.curvesDomain = CIVector(x: 0, y: 1)
        curve.curvesData = bandCurveData(
            lower: component.luminanceMin,
            upper: component.luminanceMax,
            falloff: component.luminanceFalloff
        )
        return curve.outputImage?.cropped(to: extent)
    }

    /// A 256-sample transfer curve: 0 outside the band, 1 inside, smoothstep
    /// shoulders of `falloff` on each side.
    static func bandCurveData(lower: Double, upper: Double, falloff: Double) -> Data {
        let samples = 256
        var values = [Float]()
        values.reserveCapacity(samples * 3)
        for index in 0..<samples {
            let x = Double(index) / Double(samples - 1)
            let value = Float(band(x, lower: lower, upper: upper, falloff: falloff))
            values.append(value)
            values.append(value)
            values.append(value)
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func band(_ x: Double, lower: Double, upper: Double, falloff: Double) -> Double {
        let width = Swift.max(falloff, 0.0001)
        let rise = smoothstep((x - (lower - width)) / width)
        let fall = 1 - smoothstep((x - upper) / width)
        return Swift.max(0, Swift.min(rise, fall))
    }

    static func smoothstep(_ t: Double) -> Double {
        let c = Swift.min(Swift.max(t, 0), 1)
        return c * c * (3 - 2 * c)
    }
}
