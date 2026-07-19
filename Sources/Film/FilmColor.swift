import CoreGraphics
import CoreImage
import Foundation

/// A plain RGB triple in `0...1`, `Codable` so it can live inside an edit stack.
///
/// Deliberately not a `CGColor`/`NSColor` — those carry a color space and don't
/// serialize cleanly. Values here are always in the pipeline's working space.
struct FilmColor: Codable, Equatable, Hashable {
    var red: Double
    var green: Double
    var blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    static let white = FilmColor(red: 1, green: 1, blue: 1)

    /// The largest channel — for a film base sample this is the mask's
    /// dominant (usually red) channel.
    var maxChannel: Double { max(red, max(green, blue)) }

    /// Scaled so the brightest channel is 1.0, which strips overall exposure
    /// and leaves only the *hue* of the sample. This is what makes two scans of
    /// the same film stock comparable even at different scanner brightnesses.
    var normalized: FilmColor {
        let peak = maxChannel
        guard peak > 0.0001 else { return .white }
        return FilmColor(red: red / peak, green: green / peak, blue: blue / peak)
    }

    /// Euclidean distance between two colors' normalized chromaticities.
    /// Zero means identical hue; larger means less alike.
    func chromaticityDistance(to other: FilmColor) -> Double {
        let a = normalized
        let b = other.normalized
        let dr = a.red - b.red
        let dg = a.green - b.green
        let db = a.blue - b.blue
        return (dr * dr + dg * dg + db * db).squareRoot()
    }

    /// Guards against divide-by-zero when this color is used as a divisor.
    var safeForDivision: FilmColor {
        FilmColor(red: Swift.max(red, 0.0001),
                 green: Swift.max(green, 0.0001),
                 blue: Swift.max(blue, 0.0001))
    }

    var cgColor: CGColor {
        CGColor(red: red, green: green, blue: blue, alpha: 1)
    }
}
