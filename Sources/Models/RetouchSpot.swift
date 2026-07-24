import CoreGraphics
import Foundation

/// A spot-removal correction: a circular patch or a painted stroke, filled
/// with cloned/healed/inpainted pixels.
///
/// Everything is stored in **unit coordinates** of the developed frame
/// (bottom-left origin, matching Core Image), with the radius as a fraction of
/// the frame width — so the same spot lands identically on the downsampled
/// preview and the full-resolution export.
struct RetouchSpot: Codable, Equatable, Identifiable {
    /// How the copied pixels are laid into the destination.
    enum Mode: String, Codable {
        case clone
        case heal
        /// Content-aware fill — no manual source; inpainted at commit time.
        case remove
    }

    /// Circle spot or a painted stroke path.
    enum RegionKind: String, Codable {
        case circle
        case stroke
    }

    var id = UUID()

    var mode: Mode = .heal
    var kind: RegionKind = .circle

    /// Center of the destination circle, unit coordinates.
    var center = CGPoint(x: 0.5, y: 0.5)

    /// Radius as a fraction of the frame **width**.
    var radius: Double = 0.025

    /// Edge softness, `0...1` — the fraction of the radius over which the
    /// patch fades out. `0` is a hard-edged punch, `1` fades from the center.
    var feather: Double = 0.5

    /// Overall strength of the correction through the mask.
    var opacity: Double = 1.0

    /// Painted stroke path in unit coordinates. Empty for circle spots.
    var strokePoints: [CGPoint] = []

    /// Where the source pixels come from, relative to ``center`` — `dx` as a
    /// fraction of width, `dy` as a fraction of height.
    var sourceOffset = CGVector(dx: 0.06, dy: 0)

    var isEnabled = true

    /// Centroid used for heal colour matching and default source placement.
    var effectiveCenter: CGPoint {
        guard kind == .stroke, !strokePoints.isEmpty else { return center }
        let sum = strokePoints.reduce(CGPoint.zero) { partial, point in
            CGPoint(x: partial.x + point.x, y: partial.y + point.y)
        }
        let count = CGFloat(strokePoints.count)
        return CGPoint(x: sum.x / count, y: sum.y / count)
    }

    init() {}

    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(.id, UUID())
        mode = c.lenient(.mode, .heal)
        kind = c.lenient(.kind, .circle)
        center = c.lenient(.center, CGPoint(x: 0.5, y: 0.5))
        radius = c.lenient(.radius, 0.025)
        feather = c.lenient(.feather, 0.5)
        opacity = c.lenient(.opacity, 1.0)
        strokePoints = c.lenient(.strokePoints, [])
        sourceOffset = c.lenient(.sourceOffset, CGVector(dx: 0.06, dy: 0))
        isEnabled = c.lenient(.isEnabled, true)
    }
}
