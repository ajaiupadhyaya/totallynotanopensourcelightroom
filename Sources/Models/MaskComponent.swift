import CoreGraphics
import Foundation

/// An RGB sample in `0...1`, stored alongside the mask that references it.
///
/// Deliberately not ``FilmColor``: that type carries the film subsystem's
/// negative math, and reusing it here would drag film concerns into local
/// adjustments for the sake of three doubles.
struct MaskColor: Codable, Equatable {
    var red = 0.5
    var green = 0.5
    var blue = 0.5

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        red = c.lenient(.red, 0.5)
        green = c.lenient(.green, 0.5)
        blue = c.lenient(.blue, 0.5)
    }
}

/// Softening and grow/shrink applied to one component before it is combined.
///
/// Per component rather than per mask because edge character differs by kind:
/// a brush is already soft, a luminance band is not. Both values are stored
/// unit-relative and scaled by the frame's short side at render time, so
/// refinement survives the trip from preview proxy to full-resolution export.
struct MaskRefinement: Codable, Equatable {
    /// Gaussian softening. `0...1` maps to 0…10% of the frame's short side.
    var blur = 0.0

    /// Grow (positive) or shrink (negative). `-1...1` maps to ∓5% of the
    /// frame's short side.
    var shift = 0.0

    init(blur: Double = 0, shift: Double = 0) {
        self.blur = blur
        self.shift = shift
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        blur = c.lenient(.blur, 0)
        shift = c.lenient(.shift, 0)
    }

    var isNeutral: Bool { blur == 0 && shift == 0 }
}

/// One piece of a built selection.
///
/// A mask is no longer a single shape. It is a list of these, folded together
/// with set algebra, which is what lets a tonal range be intersected with a
/// gradient and have a painted area subtracted from the result.
struct MaskComponent: Codable, Equatable, Identifiable {
    enum Shape: String, Codable, CaseIterable {
        /// A gradient band: full effect at ``startPoint``, gone by ``endPoint``.
        case linear
        /// An ellipse centred on ``center``, feathered at its edge.
        case radial
        /// Hand-painted, resolution-independent strokes.
        case brush
        /// Everything within a luminance band of the photograph itself.
        case luminance
        /// Everything within a colour distance of a sampled colour.
        case colorRange
        /// On-device Vision foreground instance mask.
        case subject
        /// On-device Vision person segmentation.
        case person
        /// Inverted subject mask.
        case background
        /// Top-seeded colour heuristic for sky regions.
        case sky
    }

    /// How this component folds into the components before it.
    enum Combine: String, Codable, CaseIterable {
        case add
        case subtract
        case intersect
    }

    var id = UUID()
    var shape: Shape = .linear
    var combine: Combine = .add
    var isEnabled = true

    /// Inverts *this component* only. The whole composed mask has its own
    /// invert on ``LocalAdjustment`` — the same distinction Photoshop draws
    /// between inverting a channel and inverting a selection.
    var isInverted = false

    var refine = MaskRefinement()

    // MARK: Linear (unit coordinates, origin bottom-left)

    var startPoint = CGPoint(x: 0.5, y: 0.85)
    var endPoint = CGPoint(x: 0.5, y: 0.45)

    // MARK: Radial

    var center = CGPoint(x: 0.5, y: 0.5)
    var radiusX = 0.3
    var radiusY = 0.25
    /// Edge softness, `0...1`. 0 is a hard ellipse edge.
    var feather = 0.5

    // MARK: Brush

    var brushStrokes: [BrushStroke] = []
    var brushSize = 0.04
    var brushFeather = 0.65
    var brushFlow = 0.8

    // MARK: Luminance range

    /// Band bounds on the mask source's luminance, `0...1`.
    var luminanceMin = 0.0
    var luminanceMax = 1.0
    /// Smoothstep shoulder width at each edge of the band.
    var luminanceFalloff = 0.15

    // MARK: Colour range

    /// Nil until the photographer samples a colour. A component with no
    /// sample selects nothing and is skipped entirely.
    var sampledColor: MaskColor?
    var colorTolerance = 0.25
    var colorFalloff = 0.15

    var displayName: String {
        switch shape {
        case .linear: "Linear"
        case .radial: "Radial"
        case .brush: "Brush"
        case .luminance: "Luminance"
        case .colorRange: "Colour Range"
        case .subject: "Subject"
        case .person: "Person"
        case .background: "Background"
        case .sky: "Sky"
        }
    }

    /// False when this component cannot select anything, so the compositor
    /// skips it rather than folding in an empty selection. That matters most
    /// for `intersect`, where an empty piece would blank the whole mask before
    /// the photographer has finished setting it up.
    var isContributing: Bool {
        guard isEnabled else { return false }
        switch shape {
        case .brush: return !brushStrokes.isEmpty
        case .colorRange: return sampledColor != nil
        case .linear, .radial, .luminance, .subject, .person, .background, .sky: return true
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
        combine = c.lenient(.combine, .add)
        isEnabled = c.lenient(.isEnabled, true)
        isInverted = c.lenient(.isInverted, false)
        refine = c.lenient(.refine, MaskRefinement())
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
        luminanceMin = c.lenient(.luminanceMin, 0.0)
        luminanceMax = c.lenient(.luminanceMax, 1.0)
        luminanceFalloff = c.lenient(.luminanceFalloff, 0.15)
        sampledColor = c.lenient(.sampledColor, nil as MaskColor?)
        colorTolerance = c.lenient(.colorTolerance, 0.25)
        colorFalloff = c.lenient(.colorFalloff, 0.15)
    }
}
