import CoreGraphics
import Foundation

/// Crop, rotation, straightening, and flips.
///
/// The crop is stored in **normalized** coordinates (0–1 of the image's width
/// and height) rather than pixels, so the same edit stack applies correctly to
/// the downsampled preview and the full-resolution export alike.
struct Geometry: Codable, Equatable {
    /// Quarter-turn rotation, in 90° steps counted counter-clockwise.
    enum Rotation: Int, Codable, CaseIterable, Identifiable {
        case none = 0, quarter = 90, half = 180, threeQuarter = 270

        var id: Int { rawValue }

        var next: Rotation {
            switch self {
            case .none: .quarter
            case .quarter: .half
            case .half: .threeQuarter
            case .threeQuarter: .none
            }
        }

        var previous: Rotation {
            next.next.next
        }

        /// True when this rotation swaps the width and height.
        var swapsAxes: Bool { self == .quarter || self == .threeQuarter }
    }

    /// The kept region in normalized coordinates. The full frame is the unit
    /// rectangle, which is also the default (no crop).
    var cropRect: CGRect = .unitFrame

    var rotation: Rotation = .none

    /// Fine straightening in degrees, `-45...45`, applied on top of
    /// ``rotation``. Positive rotates the image counter-clockwise.
    var straightenAngle: Double = 0

    var flipHorizontal: Bool = false
    var flipVertical: Bool = false

    // MARK: Optics

    /// Manual lens-distortion correction, `-100...100`. Positive bulges the
    /// center outward (corrects pincushion); negative pinches it in (corrects
    /// barrel). `0` is off.
    var distortion: Double = 0

    /// Vertical keystone, `-100...100`. Positive narrows the top of the frame
    /// (corrects the converging verticals of a camera tilted up); negative
    /// narrows the bottom.
    var perspectiveVertical: Double = 0

    /// Horizontal keystone, `-100...100`. Positive narrows the right edge;
    /// negative narrows the left.
    var perspectiveHorizontal: Double = 0

    /// True when this leaves the frame completely untouched.
    var isIdentity: Bool {
        cropRect == .unitFrame
            && rotation == .none
            && straightenAngle == 0
            && !flipHorizontal
            && !flipVertical
            && distortion == 0
            && perspectiveVertical == 0
            && perspectiveHorizontal == 0
    }

    init() {}

    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cropRect = c.lenient(.cropRect, CGRect.unitFrame)
        rotation = c.lenient(.rotation, Rotation.none)
        straightenAngle = c.lenient(.straightenAngle, 0)
        flipHorizontal = c.lenient(.flipHorizontal, false)
        flipVertical = c.lenient(.flipVertical, false)
        distortion = c.lenient(.distortion, 0)
        perspectiveVertical = c.lenient(.perspectiveVertical, 0)
        perspectiveHorizontal = c.lenient(.perspectiveHorizontal, 0)
    }
}

extension CGRect {
    /// The whole frame in normalized coordinates.
    static let unitFrame = CGRect(x: 0, y: 0, width: 1, height: 1)
}
