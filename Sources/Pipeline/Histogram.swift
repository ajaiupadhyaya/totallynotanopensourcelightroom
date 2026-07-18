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
}
