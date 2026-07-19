import Foundation

/// A per-channel image histogram: normalized bin values for the red, green, and
/// blue channels, as produced by Core Image's area-histogram pass.
///
/// Values are relative (Core Image normalizes counts); for display, divide by
/// ``peak`` to scale the tallest bar to full height.
struct Histogram: Equatable {
    var red: [Float]
    var green: [Float]
    var blue: [Float]

    /// A histogram with no data (e.g. when no photo is open).
    static let empty = Histogram(red: [], green: [], blue: [])

    var isEmpty: Bool { red.isEmpty }

    /// The largest bin value across all channels, used to normalize display
    /// height. Never returns 0, so it is safe to divide by.
    var peak: Float {
        let m = max(red.max() ?? 0, green.max() ?? 0, blue.max() ?? 0)
        return m > 0 ? m : 1
    }

    // MARK: Clipping

    /// Fraction of the histogram's mass sitting in the bottom bin of any
    /// channel — pixels crushed to pure black.
    var shadowClippedFraction: Double { edgeFraction(atTop: false) }

    /// Fraction of the histogram's mass in the top bin of any channel —
    /// pixels blown to pure white.
    var highlightClippedFraction: Double { edgeFraction(atTop: true) }

    /// True when enough pixels are crushed that the photographer should know.
    /// The threshold ignores the odd specular pixel; a real crush trips it.
    var isClippingShadows: Bool { shadowClippedFraction > 0.005 }

    /// True when enough pixels are blown to matter.
    var isClippingHighlights: Bool { highlightClippedFraction > 0.005 }

    private func edgeFraction(atTop: Bool) -> Double {
        guard !isEmpty else { return 0 }
        var edgeMass = 0.0
        var totalMass = 0.0
        for channel in [red, green, blue] {
            edgeMass += Double((atTop ? channel.last : channel.first) ?? 0)
            totalMass += channel.reduce(0) { $0 + Double($1) }
        }
        return totalMass > 0 ? edgeMass / totalMass : 0
    }
}
