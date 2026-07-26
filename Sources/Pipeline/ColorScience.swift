import CoreGraphics
import Foundation

/// Color-space conversions and curve evaluation shared by the LUT builder.
///
/// These operate on gamma-encoded values, which is where hue and "lightness"
/// behave the way a person editing a photo expects. HSL in linear light would
/// make the luminance sliders feel wrong at the dark end.
enum ColorScience {
    // MARK: HSL

    /// Converts RGB (each `0...1`) to hue in degrees, saturation, lightness.
    static func rgbToHSL(_ r: Double, _ g: Double, _ b: Double)
        -> (hue: Double, saturation: Double, lightness: Double) {
        let maximum = max(r, max(g, b))
        let minimum = min(r, min(g, b))
        let lightness = (maximum + minimum) / 2
        let delta = maximum - minimum

        guard delta > 1e-9 else { return (0, 0, lightness) }

        let saturation = lightness > 0.5
            ? delta / (2 - maximum - minimum)
            : delta / (maximum + minimum)

        var hue: Double
        if maximum == r {
            hue = (g - b) / delta + (g < b ? 6 : 0)
        } else if maximum == g {
            hue = (b - r) / delta + 2
        } else {
            hue = (r - g) / delta + 4
        }
        return (hue * 60, saturation, lightness)
    }

    /// Converts hue (degrees), saturation, lightness back to RGB.
    static func hslToRGB(_ hue: Double, _ saturation: Double, _ lightness: Double)
        -> (red: Double, green: Double, blue: Double) {
        guard saturation > 1e-9 else { return (lightness, lightness, lightness) }

        let q = lightness < 0.5
            ? lightness * (1 + saturation)
            : lightness + saturation - lightness * saturation
        let p = 2 * lightness - q
        let h = wrapHue(hue) / 360

        return (
            hueToChannel(p, q, h + 1.0 / 3.0),
            hueToChannel(p, q, h),
            hueToChannel(p, q, h - 1.0 / 3.0)
        )
    }

    private static func hueToChannel(_ p: Double, _ q: Double, _ t: Double) -> Double {
        var t = t
        if t < 0 { t += 1 }
        if t > 1 { t -= 1 }
        if t < 1.0 / 6.0 { return p + (q - p) * 6 * t }
        if t < 1.0 / 2.0 { return q }
        if t < 2.0 / 3.0 { return p + (q - p) * (2.0 / 3.0 - t) * 6 }
        return p
    }

    /// Normalizes a hue into `0..<360`.
    static func wrapHue(_ hue: Double) -> Double {
        let wrapped = hue.truncatingRemainder(dividingBy: 360)
        return wrapped < 0 ? wrapped + 360 : wrapped
    }

    /// The shortest angular distance between two hues, in degrees (`0...180`).
    /// Hue is circular, so red at 355° is 10° from red at 5°, not 350°.
    static func hueDistance(_ a: Double, _ b: Double) -> Double {
        let diff = abs(wrapHue(a) - wrapHue(b))
        return min(diff, 360 - diff)
    }

    /// Perceptual luminance (Rec. 709 weights).
    static func luminance(_ r: Double, _ g: Double, _ b: Double) -> Double {
        0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    static func clamp(_ value: Double, _ lower: Double = 0, _ upper: Double = 1) -> Double {
        min(max(value, lower), upper)
    }

    // MARK: White balance from a picked color

    /// Estimates the correlated color temperature and tint of an RGB color.
    ///
    /// This is what a white-balance eyedropper needs: the user clicks a thing
    /// that *should* be neutral, and setting the WB sliders to the clicked
    /// color's temperature/tint makes the correction map it back to gray.
    ///
    /// The route is standard colorimetry: linearize sRGB, convert to XYZ, take
    /// (x, y) chromaticity, then McCamy's cubic approximation for CCT. McCamy
    /// is accurate to a few kelvin across the daylight range — far tighter
    /// than the slider's own resolution. Tint is the signed distance from the
    /// Planckian locus mapped onto the green–magenta axis, scaled to the
    /// slider's `-100...100` range.
    ///
    /// - Returns: Temperature clamped to the slider range, and tint; or nil
    ///   for colors too dark to carry usable chromaticity.
    static func temperatureAndTint(ofRed red: Double, green: Double, blue: Double)
        -> (temperature: Double, tint: Double)? {
        // Gamma-decode sRGB to linear light.
        func linearize(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let r = linearize(clamp(red))
        let g = linearize(clamp(green))
        let b = linearize(clamp(blue))

        // Linear sRGB → XYZ (D65).
        let x = 0.4124 * r + 0.3576 * g + 0.1805 * b
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let z = 0.0193 * r + 0.1192 * g + 0.9505 * b

        let sum = x + y + z
        guard sum > 1e-6, y > 1e-4 else { return nil }
        let cx = x / sum
        let cy = y / sum

        // McCamy's approximation.
        let n = (cx - 0.3320) / (0.1858 - cy)
        let cct = 449.0 * pow(n, 3) + 3525.0 * pow(n, 2) + 6823.3 * n + 5520.33
        guard cct.isFinite else { return nil }

        // Tint: green–magenta offset from the locus. The Planckian locus's cy
        // for a given cx is approximated well enough locally by the D-series
        // daylight curve; the residual maps to the tint slider.
        let daylightCY = -3.0 * cx * cx + 2.87 * cx - 0.275
        let tint = (cy - daylightCY) * 3200.0

        return (
            temperature: min(max(cct, 2000), 10000),
            tint: min(max(tint, -100), 100)
        )
    }

    // MARK: White balance matrix

    /// Linear-sRGB → linear-sRGB Bradford adaptation that maps the neutral
    /// described by (temperature, tint) to D65.
    ///
    /// Semantics match PV1's `CITemperatureAndTint` usage: the sliders name
    /// the image's *current* neutral, and the correction carries it to D65 —
    /// so raising temperature warms the image. Internally the locus is
    /// parameterized in **mired** (1e6/K), which is what makes equal slider
    /// travel produce equal perceptual change at both ends; the UI stays in
    /// Kelvin. Tint is a signed offset perpendicular-ish to the locus in
    /// CIE 1960 uv (positive = magenta), scaled so ±100 covers a strong but
    /// recoverable cast.
    ///
    /// - Returns: 9 row-major values; identity when the input is D65 exactly.
    static func whiteBalanceMatrix(temperature: Double, tint: Double) -> [Double] {
        if temperature == 6500 && tint == 0 {
            return [1, 0, 0, 0, 1, 0, 0, 0, 1]
        }

        // CCT → CIE xy on the Planckian/daylight locus (Kim et al. cubic
        // spline approximation), computed from mired for numeric symmetry.
        func locusXY(kelvin: Double) -> (x: Double, y: Double) {
            let t = min(max(kelvin, 1667), 25000)
            let invT = 1000.0 / t   // kiloKelvin⁻¹, i.e. mired / 1000
            let x: Double
            if t < 4000 {
                x = -0.2661239 * pow(invT, 3) - 0.2343589 * pow(invT, 2)
                    + 0.8776956 * invT + 0.179910
            } else {
                x = -3.0258469 * pow(invT, 3) + 2.1070379 * pow(invT, 2)
                    + 0.2226347 * invT + 0.240390
            }
            let y: Double
            if t < 2222 {
                y = -1.1063814 * pow(x, 3) - 1.34811020 * pow(x, 2)
                    + 2.18555832 * x - 0.20219683
            } else if t < 4000 {
                y = -0.9549476 * pow(x, 3) - 1.37418593 * pow(x, 2)
                    + 2.09137015 * x - 0.16748867
            } else {
                y = 3.0817580 * pow(x, 3) - 5.87338670 * pow(x, 2)
                    + 3.75112997 * x - 0.37001483
            }
            return (x, y)
        }

        // Apply tint as a v-offset in CIE 1960 uv (green up, magenta down).
        func whitePointXYZ(kelvin: Double, tint: Double) -> (X: Double, Y: Double, Z: Double) {
            let (x, y) = locusXY(kelvin: kelvin)
            let d = -2 * x + 12 * y + 3
            var u = 4 * x / d
            var v = 6 * y / d
            v -= tint * 3e-4
            u = max(u, 1e-4); v = max(v, 1e-4)
            let d2 = 2 * u - 8 * v + 4
            let nx = 3 * u / d2
            let ny = 2 * v / d2
            return (nx / ny, 1.0, (1 - nx - ny) / ny)
        }

        // Bradford cone-response matrix and its inverse.
        let bradford = [0.8951, 0.2664, -0.1614,
                        -0.7502, 1.7135, 0.0367,
                        0.0389, -0.0685, 1.0296]
        let bradfordInv = [0.9869929, -0.1470543, 0.1599627,
                           0.4323053, 0.5183603, 0.0492912,
                           -0.0085287, 0.0400428, 0.9684867]
        // sRGB (D65) ↔ XYZ.
        let srgbToXYZ = [0.4124564, 0.3575761, 0.1804375,
                         0.2126729, 0.7151522, 0.0721750,
                         0.0193339, 0.1191920, 0.9503041]
        let xyzToSRGB = [3.2404542, -1.5371385, -0.4985314,
                         -0.9692660, 1.8760108, 0.0415560,
                         0.0556434, -0.2040259, 1.0572252]

        func mul(_ a: [Double], _ b: [Double]) -> [Double] {
            var out = [Double](repeating: 0, count: 9)
            for r in 0..<3 { for c in 0..<3 {
                out[r * 3 + c] = a[r * 3] * b[c] + a[r * 3 + 1] * b[3 + c] + a[r * 3 + 2] * b[6 + c]
            } }
            return out
        }
        func apply(_ m: [Double], _ v: (Double, Double, Double)) -> (Double, Double, Double) {
            (m[0] * v.0 + m[1] * v.1 + m[2] * v.2,
             m[3] * v.0 + m[4] * v.1 + m[5] * v.2,
             m[6] * v.0 + m[7] * v.1 + m[8] * v.2)
        }

        let src = whitePointXYZ(kelvin: temperature, tint: tint)
        let d65 = (X: 0.95047, Y: 1.0, Z: 1.08883)
        let srcCone = apply(bradford, (src.X, src.Y, src.Z))
        let dstCone = apply(bradford, (d65.X, d65.Y, d65.Z))
        let scale = [dstCone.0 / srcCone.0, 0, 0,
                     0, dstCone.1 / srcCone.1, 0,
                     0, 0, dstCone.2 / srcCone.2]

        let adapt = mul(bradfordInv, mul(scale, bradford))
        return mul(xyzToSRGB, mul(adapt, srgbToXYZ))
    }

    // MARK: Curves

    /// Evaluates a tone curve at `x` using Catmull-Rom interpolation through
    /// the control points, matching the smooth feel of `CIToneCurve`.
    ///
    /// - Returns: `x` unchanged when there are fewer than two control points,
    ///   so an empty curve is the identity.
    static func evaluateCurve(_ points: [CGPoint], at x: Double) -> Double {
        guard points.count >= 2 else { return x }
        let sorted = points.sorted { $0.x < $1.x }

        if x <= Double(sorted[0].x) { return Double(sorted[0].y) }
        if x >= Double(sorted[sorted.count - 1].x) { return Double(sorted[sorted.count - 1].y) }

        // Find the segment containing x.
        var index = 0
        for i in 0..<(sorted.count - 1) where x >= Double(sorted[i].x) && x <= Double(sorted[i + 1].x) {
            index = i
            break
        }

        let p1 = sorted[index]
        let p2 = sorted[index + 1]
        let p0 = index > 0 ? sorted[index - 1] : p1
        let p3 = index + 2 < sorted.count ? sorted[index + 2] : p2

        let span = Double(p2.x - p1.x)
        guard span > 1e-9 else { return Double(p2.y) }
        let t = (x - Double(p1.x)) / span

        // Catmull-Rom in y, parameterized by the normalized position in x.
        let t2 = t * t
        let t3 = t2 * t
        let y = 0.5 * (
            2 * Double(p1.y)
            + (Double(p2.y) - Double(p0.y)) * t
            + (2 * Double(p0.y) - 5 * Double(p1.y) + 4 * Double(p2.y) - Double(p3.y)) * t2
            + (-Double(p0.y) + 3 * Double(p1.y) - 3 * Double(p2.y) + Double(p3.y)) * t3
        )
        return clamp(y)
    }
}
