import CoreGraphics
import Foundation

/// A single spot-removal correction: a circular destination patch filled with
/// pixels copied from a nearby source region.
///
/// Everything is stored in **unit coordinates** of the developed frame
/// (bottom-left origin, matching Core Image), with the radius as a fraction of
/// the frame width — so the same spot lands identically on the downsampled
/// preview and the full-resolution export.
struct RetouchSpot: Codable, Equatable, Identifiable {
    /// How the copied pixels are laid into the destination.
    enum Mode: String, Codable {
        /// The source pixels are copied verbatim — for repeating texture where
        /// exact structure matters (a brick wall, a fence).
        case clone
        /// The source pixels are shifted to match the destination's local
        /// color and brightness before blending — for dust, scratches, and
        /// blemishes sitting on a gradient (sky, skin), where a verbatim copy
        /// would leave a visible patch of the wrong tone.
        case heal
    }

    var id = UUID()

    var mode: Mode = .heal

    /// Center of the destination circle, unit coordinates.
    var center = CGPoint(x: 0.5, y: 0.5)

    /// Radius as a fraction of the frame **width**.
    var radius: Double = 0.025

    /// Edge softness, `0...1` — the fraction of the radius over which the
    /// patch fades out. `0` is a hard-edged punch, `1` fades from the center.
    var feather: Double = 0.5

    /// Where the source pixels come from, relative to ``center`` — `dx` as a
    /// fraction of width, `dy` as a fraction of height.
    var sourceOffset = CGVector(dx: 0.06, dy: 0)

    var isEnabled = true

    init() {}

    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(.id, UUID())
        mode = c.lenient(.mode, .heal)
        center = c.lenient(.center, CGPoint(x: 0.5, y: 0.5))
        radius = c.lenient(.radius, 0.025)
        feather = c.lenient(.feather, 0.5)
        sourceOffset = c.lenient(.sourceOffset, CGVector(dx: 0.06, dy: 0))
        isEnabled = c.lenient(.isEnabled, true)
    }
}
