import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Builds a 3D color lookup table for the color mixer, black-and-white
/// conversion, three-way color grading, and per-channel curves.
///
/// ## Why one LUT instead of a filter per feature
///
/// All four of these are pure color→color functions: the output for a pixel
/// depends only on that pixel's own value. That's exactly what a LUT encodes,
/// so the whole group collapses into a single `CIColorCube` — one GPU pass
/// regardless of how many of the features are in use. Chaining separate
/// filters would cost a pass each, and Core Image has no per-hue-band filter
/// to chain in the first place.
///
/// The table is sampled on a 32³ grid and interpolated by the GPU in between.
/// That's the same resolution as a typical grading LUT and far finer than any
/// of these adjustments varies.
///
/// ## Color space
///
/// The cube is applied through `CIColorCubeWithColorSpace` in sRGB rather than
/// Core Image's linear working space. Hue and lightness only behave the way an
/// editor expects on gamma-encoded values — in linear light the luminance
/// sliders bunch up badly at the dark end.
enum ColorCubeBuilder {
    /// Grid resolution per axis.
    static let dimension = 32

    /// Returns a filter applying `settings`, or `nil` when the settings are
    /// neutral and the LUT would be the identity.
    static func makeFilter(for settings: ColorSettings) -> CIFilter? {
        guard !settings.isNeutral else { return nil }

        let filter = CIFilter.colorCubeWithColorSpace()
        filter.cubeDimension = Float(dimension)
        filter.cubeData = cubeData(for: settings)
        filter.colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return filter
    }

    /// Builds the raw cube data.
    ///
    /// `CIColorCube` expects premultiplied RGBA floats with red varying
    /// fastest and blue slowest.
    static func cubeData(for settings: ColorSettings) -> Data {
        let size = dimension
        var values = [Float](repeating: 0, count: size * size * size * 4)
        let scale = Double(size - 1)

        var offset = 0
        for blueIndex in 0..<size {
            for greenIndex in 0..<size {
                for redIndex in 0..<size {
                    let color = transform(
                        red: Double(redIndex) / scale,
                        green: Double(greenIndex) / scale,
                        blue: Double(blueIndex) / scale,
                        settings: settings
                    )
                    values[offset] = Float(color.red)
                    values[offset + 1] = Float(color.green)
                    values[offset + 2] = Float(color.blue)
                    values[offset + 3] = 1
                    offset += 4
                }
            }
        }

        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// The per-color transform the cube samples.
    ///
    /// Order matters here the same way it does in the main chain: the hue-band
    /// mixer (or B&W mix) runs first while the original hues are still intact,
    /// then grading tints the result, then the per-channel curves shape it.
    static func transform(
        red: Double, green: Double, blue: Double, settings: ColorSettings
    ) -> (red: Double, green: Double, blue: Double) {
        var color = (red: red, green: green, blue: blue)

        switch settings.treatment {
        case .color:
            color = applyMixer(color, mixer: settings.mixer)
        case .blackAndWhite:
            color = applyBlackAndWhite(color, mixer: settings.mixer)
        }

        if !settings.grading.isNeutral {
            color = applyGrading(color, grading: settings.grading)
        }

        if !settings.channelCurves.isNeutral {
            let curves = settings.channelCurves
            color = (
                ColorScience.evaluateCurve(curves.red, at: color.red),
                ColorScience.evaluateCurve(curves.green, at: color.green),
                ColorScience.evaluateCurve(curves.blue, at: color.blue)
            )
        }

        return (
            ColorScience.clamp(color.red),
            ColorScience.clamp(color.green),
            ColorScience.clamp(color.blue)
        )
    }

    // MARK: Hue-band mixer

    /// Applies the per-band HSL adjustments, blending smoothly between
    /// neighboring bands so a gradient doesn't band where one hue range ends.
    private static func applyMixer(
        _ color: (red: Double, green: Double, blue: Double), mixer: ColorMixer
    ) -> (red: Double, green: Double, blue: Double) {
        guard !mixer.isNeutral else { return color }

        var (hue, saturation, lightness) =
            ColorScience.rgbToHSL(color.red, color.green, color.blue)

        // A near-gray pixel has no meaningful hue, so band adjustments must
        // fade out as colors approach neutral.
        //
        // This has to be a smooth ramp rather than a `saturation > 0` guard.
        // The GPU interpolates *between* grid points, and the neighbors of a
        // gray entry are slightly chromatic — so a hard cutoff still drags gray
        // toward whatever those neighbors were adjusted to, tinting neutrals
        // that should have been left alone. Ramping in means the near-gray
        // entries carry almost no adjustment and the interpolated result stays
        // neutral. It's also just truer: a barely-colored pixel shouldn't take
        // a full band adjustment.
        let strength = smoothstep(saturation / 0.2)
        guard strength > 1e-6 else { return color }

        let weights = bandWeights(for: hue)
        var hueShift = 0.0
        var saturationScale = 0.0
        var lightnessShift = 0.0

        for (index, band) in HueBand.allCases.enumerated() {
            let weight = weights[index] * strength
            guard weight > 0 else { continue }
            let adjustment = mixer[band]
            hueShift += weight * adjustment.hue / 100 * 30
            saturationScale += weight * adjustment.saturation / 100
            lightnessShift += weight * adjustment.luminance / 100 * 0.3
        }

        hue = ColorScience.wrapHue(hue + hueShift)
        saturation = ColorScience.clamp(saturation * (1 + saturationScale))
        lightness = ColorScience.clamp(lightness + lightnessShift)

        return ColorScience.hslToRGB(hue, saturation, lightness)
    }

    /// Black-and-white conversion with a per-band channel mix.
    ///
    /// The base is perceptual luminance; each band's weight then brightens or
    /// darkens pixels of that hue, which is the digital equivalent of shooting
    /// through a colored filter (push red up and a blue sky goes dark).
    private static func applyBlackAndWhite(
        _ color: (red: Double, green: Double, blue: Double), mixer: ColorMixer
    ) -> (red: Double, green: Double, blue: Double) {
        var gray = ColorScience.luminance(color.red, color.green, color.blue)

        let (hue, saturation, _) = ColorScience.rgbToHSL(color.red, color.green, color.blue)
        // Same saturation ramp as the color mixer, and for the same reason —
        // near-gray entries must carry almost no adjustment so interpolation
        // doesn't drag true neutrals around.
        let strength = smoothstep(saturation / 0.2)
        if strength > 1e-6 {
            let weights = bandWeights(for: hue)
            var shift = 0.0
            for (index, band) in HueBand.allCases.enumerated() where weights[index] > 0 {
                shift += weights[index] * mixer.blackAndWhiteWeight(band) / 100 * 0.5
            }
            gray += shift * strength
        }

        let clamped = ColorScience.clamp(gray)
        return (clamped, clamped, clamped)
    }

    /// Smoothstep over `0...1`, used to ramp adjustments in without a visible
    /// threshold.
    private static func smoothstep(_ t: Double) -> Double {
        let t = ColorScience.clamp(t)
        return t * t * (3 - 2 * t)
    }

    /// Weight of each hue band for a given hue, summing to 1.
    ///
    /// Each band falls off linearly to zero at its neighbors' centers, so a hue
    /// exactly between two bands is influenced half by each.
    static func bandWeights(for hue: Double) -> [Double] {
        let bands = HueBand.allCases
        var weights = [Double](repeating: 0, count: bands.count)

        for (index, band) in bands.enumerated() {
            let previous = bands[(index - 1 + bands.count) % bands.count]
            let next = bands[(index + 1) % bands.count]
            let reach = max(
                ColorScience.hueDistance(band.centerHue, previous.centerHue),
                ColorScience.hueDistance(band.centerHue, next.centerHue)
            )
            guard reach > 0 else { continue }
            let distance = ColorScience.hueDistance(hue, band.centerHue)
            weights[index] = max(0, 1 - distance / reach)
        }

        let total = weights.reduce(0, +)
        guard total > 1e-9 else {
            // Degenerate fallback: give everything to the nearest band.
            var nearest = 0
            var best = Double.greatestFiniteMagnitude
            for (index, band) in bands.enumerated() {
                let distance = ColorScience.hueDistance(hue, band.centerHue)
                if distance < best { best = distance; nearest = index }
            }
            weights[nearest] = 1
            return weights
        }
        return weights.map { $0 / total }
    }

    // MARK: Color grading

    /// Three-way grading: tint and lift each tonal zone independently.
    private static func applyGrading(
        _ color: (red: Double, green: Double, blue: Double), grading: ColorGrading
    ) -> (red: Double, green: Double, blue: Double) {
        let luminance = ColorScience.luminance(color.red, color.green, color.blue)
        let weights = zoneWeights(luminance: luminance, grading: grading)

        var result = color
        let zones = [
            (grading.shadows, weights.shadows),
            (grading.midtones, weights.midtones),
            (grading.highlights, weights.highlights),
        ]

        for (zone, weight) in zones where weight > 0 && !zone.isNeutral {
            let strength = zone.saturation / 100
            if strength > 0 {
                // A fully saturated version of the zone's hue, centered so the
                // tint pushes color without shifting overall brightness.
                let tint = ColorScience.hslToRGB(zone.hue, 1.0, 0.5)
                result.red += weight * (tint.red - 0.5) * strength
                result.green += weight * (tint.green - 0.5) * strength
                result.blue += weight * (tint.blue - 0.5) * strength
            }
            if zone.luminance != 0 {
                let lift = weight * zone.luminance / 100 * 0.25
                result.red += lift
                result.green += lift
                result.blue += lift
            }
        }

        return result
    }

    /// How strongly each zone claims a pixel of the given luminance.
    ///
    /// `balance` slides the split point, and `blending` controls how wide the
    /// overlap between zones is — at low blending the handoff is abrupt, at
    /// high blending each zone reaches well into its neighbors.
    static func zoneWeights(luminance: Double, grading: ColorGrading)
        -> (shadows: Double, midtones: Double, highlights: Double) {
        let balance = grading.balance / 100 * 0.25
        let midpoint = ColorScience.clamp(0.5 + balance, 0.15, 0.85)
        let width = 0.25 + grading.blending / 100 * 0.35

        func falloff(_ distance: Double) -> Double {
            let t = ColorScience.clamp(1 - distance / width)
            // Smoothstep, so zones fade rather than switch.
            return t * t * (3 - 2 * t)
        }

        let shadows = falloff(luminance)
        let highlights = falloff(1 - luminance)
        let midtones = falloff(abs(luminance - midpoint))

        let total = shadows + midtones + highlights
        guard total > 1e-9 else { return (0, 1, 0) }
        return (shadows / total, midtones / total, highlights / total)
    }
}
