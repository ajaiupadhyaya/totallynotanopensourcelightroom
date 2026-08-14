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
    ///
    /// The end bins are excluded from the search. They are where clipped pixels
    /// accumulate, and a frame with a genuinely black surround — a scan with a
    /// rebate, a night shot, a silhouette — can pile a third of its pixels into
    /// bin 0. Scaling to that spike squashes the entire tonal range of the
    /// actual photograph into the bottom sliver of the graph, which is the one
    /// job a histogram has. Clipping is still reported, separately and exactly,
    /// by ``shadowClippedFraction`` and ``highlightClippedFraction`` — so
    /// nothing is hidden by leaving the spikes out of the scale.
    var peak: Float {
        let interior = [red, green, blue].compactMap { channel -> Float? in
            guard channel.count > 2 else { return channel.max() }
            return channel.dropFirst().dropLast().max()
        }
        let m = interior.max() ?? 0
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

    /// Which channels are clipping at one end. The pooled diagnostics above
    /// keep their exact semantics; these answer the finer question the corner
    /// triangles ask ("blown *where*?"), with the same 0.5% threshold applied
    /// per channel.
    struct ChannelClipFlags: Equatable {
        var red = false
        var green = false
        var blue = false
        var any: Bool { red || green || blue }
    }

    var shadowClipFlags: ChannelClipFlags { clipFlags(atTop: false) }
    var highlightClipFlags: ChannelClipFlags { clipFlags(atTop: true) }

    private func clipFlags(atTop: Bool) -> ChannelClipFlags {
        func clipped(_ channel: [Float]) -> Bool {
            guard let edge = atTop ? channel.last : channel.first else { return false }
            let total = channel.reduce(0.0) { $0 + Double($1) }
            return total > 0 && Double(edge) / total > 0.005
        }
        return ChannelClipFlags(red: clipped(red), green: clipped(green), blue: clipped(blue))
    }

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
