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

/// One masked local adjustment: a built selection plus the corrections applied
/// inside it.
///
/// The selection lives in ``components`` — a list folded together with set
/// algebra by ``MaskCompositor``. Before 1.3 an adjustment carried exactly one
/// shape; those stacks migrate to a one-component list on decode.
struct LocalAdjustment: Codable, Equatable, Identifiable {
    var id = UUID()
    var isEnabled = true

    /// Inverts the *composed* mask — a radial becomes a burn of everything but
    /// the subject. Individual components have their own invert.
    var isInverted = false

    /// The pieces this selection is built from, folded in order.
    var components: [MaskComponent] = []

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

    /// True when the selection cannot select anything.
    var isEmpty: Bool { !components.contains(where: \.isContributing) }

    var displayName: String {
        guard let first = components.first else { return "Empty" }
        return components.count == 1 ? first.displayName : "\(first.displayName) +\(components.count - 1)"
    }

    init(shape: MaskComponent.Shape = .linear) {
        components = [MaskComponent(shape: shape)]
    }

    // Current keys plus the pre-1.3 flat mask keys. The legacy ones no longer
    // map to properties, so both the decoder and the encoder are written by
    // hand: legacy keys are read on the way in and never written back.
    enum CodingKeys: String, CodingKey {
        case id, isEnabled, isInverted, components
        case exposure, contrast, highlights, shadows, saturation, warmth
        case shape, startPoint, endPoint, center, radiusX, radiusY, feather
        case brushStrokes, brushSize, brushFeather, brushFlow
    }

    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(.id, UUID())
        isEnabled = c.lenient(.isEnabled, true)
        isInverted = c.lenient(.isInverted, false)

        // Branch on whether the key EXISTS, not on whether it decoded empty.
        // `lenient` returns [] for three different inputs — key absent, key
        // present and empty, key present but malformed — and only the first is
        // a pre-1.3 mask. Treating an emptied mask as legacy would hand it back
        // a linear gradient the photographer never placed, and then apply that
        // adjustment's corrections through it.
        let stored: [MaskComponent] = c.lenient(.components, [])
        components = c.contains(.components) ? stored : [Self.migratedComponent(from: c)]

        exposure = c.lenient(.exposure, 0)
        contrast = c.lenient(.contrast, 0)
        highlights = c.lenient(.highlights, 0)
        shadows = c.lenient(.shadows, 0)
        saturation = c.lenient(.saturation, 0)
        warmth = c.lenient(.warmth, 0)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(isEnabled, forKey: .isEnabled)
        try c.encode(isInverted, forKey: .isInverted)
        try c.encode(components, forKey: .components)
        try c.encode(exposure, forKey: .exposure)
        try c.encode(contrast, forKey: .contrast)
        try c.encode(highlights, forKey: .highlights)
        try c.encode(shadows, forKey: .shadows)
        try c.encode(saturation, forKey: .saturation)
        try c.encode(warmth, forKey: .warmth)
    }

    /// Rebuilds the single component a pre-1.3 adjustment described with flat
    /// fields. `isInverted` is deliberately not copied down: it inverted the
    /// whole mask then and still does now.
    private static func migratedComponent(
        from c: KeyedDecodingContainer<CodingKeys>
    ) -> MaskComponent {
        var component = MaskComponent(shape: c.lenient(.shape, MaskComponent.Shape.linear))
        component.startPoint = c.lenient(.startPoint, CGPoint(x: 0.5, y: 0.85))
        component.endPoint = c.lenient(.endPoint, CGPoint(x: 0.5, y: 0.45))
        component.center = c.lenient(.center, CGPoint(x: 0.5, y: 0.5))
        component.radiusX = c.lenient(.radiusX, 0.3)
        component.radiusY = c.lenient(.radiusY, 0.25)
        component.feather = c.lenient(.feather, 0.5)
        component.brushStrokes = c.lenient(.brushStrokes, [])
        component.brushSize = c.lenient(.brushSize, 0.04)
        component.brushFeather = c.lenient(.brushFeather, 0.65)
        component.brushFlow = c.lenient(.brushFlow, 0.8)
        return component
    }
}
