import CoreGraphics
import Foundation

/// One continuous pass of a local-adjustment brush. Points and radius are
/// stored in unit coordinates so the same hand-painted mask lands identically
/// on the preview proxy and a full-resolution export.
struct BrushStroke: Codable, Equatable, Identifiable {
    var id = UUID()
    var points: [CGPoint] = []
    var radius: Double = 0.04
    var feather: Double = 0.65
    var flow: Double = 0.8

    init(points: [CGPoint] = [], radius: Double = 0.04,
         feather: Double = 0.65, flow: Double = 0.8) {
        self.points = points
        self.radius = radius
        self.feather = feather
        self.flow = flow
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(.id, UUID())
        points = c.lenient(.points, [])
        radius = c.lenient(.radius, 0.04)
        feather = c.lenient(.feather, 0.65)
        flow = c.lenient(.flow, 0.8)
    }
}

/// One masked local adjustment: a gradient-shaped region plus the corrections
/// applied inside it.
///
/// Geometry lives in **unit coordinates** of the (geometry-applied) frame,
/// origin bottom-left to match Core Image — the same convention as the crop —
/// so one stored mask lands identically on the preview and the export.
///
/// There is deliberately no AI here. A linear gradient and a radial ellipse
/// are the two shapes darkroom printing actually used — a graduated burn for
/// a sky, a dodge for a face — and both are fully described by a few numbers
/// the photographer placed by hand.
struct LocalAdjustment: Codable, Equatable, Identifiable {
    enum Shape: String, Codable, CaseIterable {
        /// A gradient band: full effect at ``startPoint`` fading to nothing at
        /// ``endPoint``.
        case linear
        /// An ellipse centered on ``center``, feathered at its edge.
        case radial
        /// A hand-painted mask made from resolution-independent brush strokes.
        case brush
    }

    var id = UUID()
    var shape: Shape = .linear
    var isEnabled = true

    /// Applies the corrections *outside* the shape instead of inside — a
    /// radial becomes a burn of everything but the subject.
    var isInverted = false

    // MARK: Geometry (unit coordinates, origin bottom-left)

    /// Linear: where the effect is at full strength.
    var startPoint = CGPoint(x: 0.5, y: 0.85)

    /// Linear: where the effect has faded to nothing.
    var endPoint = CGPoint(x: 0.5, y: 0.45)

    /// Radial: ellipse center.
    var center = CGPoint(x: 0.5, y: 0.5)

    /// Radial: horizontal radius as a fraction of the frame width.
    var radiusX = 0.3

    /// Radial: vertical radius as a fraction of the frame height.
    var radiusY = 0.25

    /// Radial: edge softness, `0...1`. 0 is a hard ellipse edge.
    var feather = 0.5

    // MARK: Brush

    /// Hand-painted strokes. Each stroke captures its own brush settings so
    /// changing the brush later does not rewrite work already laid down.
    var brushStrokes: [BrushStroke] = []

    /// Settings for the next brush stroke.
    var brushSize = 0.04
    var brushFeather = 0.65
    var brushFlow = 0.8

    // MARK: Corrections

    /// EV stops, the classic dodge/burn.
    var exposure: Double = 0

    /// `-100...100`.
    var contrast: Double = 0

    /// `-100...100`, negative recovers.
    var highlights: Double = 0

    /// `-100...100`, positive lifts.
    var shadows: Double = 0

    /// `-100...100`.
    var saturation: Double = 0

    /// Warmth shift, `-100...100`. Positive warms the masked area.
    var warmth: Double = 0

    /// True when the corrections would change nothing.
    var isNeutral: Bool {
        exposure == 0 && contrast == 0 && highlights == 0
            && shadows == 0 && saturation == 0 && warmth == 0
    }

    var displayName: String {
        switch shape {
        case .linear: "Linear"
        case .radial: "Radial"
        case .brush: "Brush"
        }
    }

    init(shape: Shape = .linear) {
        self.shape = shape
    }

    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(.id, UUID())
        shape = c.lenient(.shape, .linear)
        isEnabled = c.lenient(.isEnabled, true)
        isInverted = c.lenient(.isInverted, false)
        startPoint = c.lenient(.startPoint, CGPoint(x: 0.5, y: 0.85))
        endPoint = c.lenient(.endPoint, CGPoint(x: 0.5, y: 0.45))
        center = c.lenient(.center, CGPoint(x: 0.5, y: 0.5))
        radiusX = c.lenient(.radiusX, 0.3)
        radiusY = c.lenient(.radiusY, 0.25)
        feather = c.lenient(.feather, 0.5)
        brushStrokes = c.lenient(.brushStrokes, [])
        brushSize = c.lenient(.brushSize, 0.04)
        brushFeather = c.lenient(.brushFeather, 0.65)
        brushFlow = c.lenient(.brushFlow, 0.8)
        exposure = c.lenient(.exposure, 0)
        contrast = c.lenient(.contrast, 0)
        highlights = c.lenient(.highlights, 0)
        shadows = c.lenient(.shadows, 0)
        saturation = c.lenient(.saturation, 0)
        warmth = c.lenient(.warmth, 0)
    }
}
