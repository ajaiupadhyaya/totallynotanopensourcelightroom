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
