import Foundation

/// Which engine interprets a photo's film conversion.
///
/// `.matrix` is the original single-`CIColorMatrix` inversion, frozen forever:
/// a stack loaded from an existing catalog decodes to it and keeps its exact
/// rendering. `.density` is the print engine. Both stay in the renderer
/// permanently — this is the same freeze contract as `processVersion`.
enum FilmConversionModel: String, Codable, Equatable {
    case matrix
    case density
}

/// Where the film base measurement came from, reported in the panel. The
/// distinction matters because Auto's percentile estimate can be fooled by
/// bare lightbox around the frame; the user deserves to know which number
/// they are trusting.
enum FilmBaseOrigin: String, Codable, Equatable {
    /// The built-in representative orange mask — nothing was measured.
    case assumed
    /// Auto's per-channel percentile estimate over the whole scan.
    case estimated
    /// Measured: the eyedropper on clear rebate, or (Phase 3) frame detection.
    case sampled
}

/// A per-channel triple in *density* space. Unlike ``FilmColor`` these are not
/// colors and routinely exceed 1 — a dense C-41 highlight is around 2.5.
struct DensityTriple: Codable, Equatable, Hashable {
    var red: Double
    var green: Double
    var blue: Double

    static let unit = DensityTriple(red: 1, green: 1, blue: 1)
}

/// The print half of the density engine: everything after the density
/// measurement, in the terms a printer would use. Resolved values, like the
/// rest of ``FilmNegativeSettings`` — Auto writes numbers in here and every
/// one of them stays an ordinary, visible slider.
struct PrintSettings: Codable, Equatable {
    /// Print exposure in EV. A log-domain offset, so one stop is one stop
    /// regardless of grade.
    var exposure: Double = 0

    /// Paper grade 0…5. Grade 2 is defined as ×1.0 — the gammas Auto solved;
    /// each whole grade is ×1.15 on all three (see `PaperResponse.gradeScale`).
    var contrast: Double = 2

    /// Highlight knee, 0…100 → `PaperResponse.kneeP`. 0 is a hard clip.
    var shoulder: Double = 40

    /// Shadow knee, 0…100 → `PaperResponse.kneeQ`. 0 is a plugged black.
    var toe: Double = 30

    /// Hue-preserving saturation, applied to the channel ratio around neutral
    /// before the rolloff. Defaults above zero because C-41 papers are more
    /// saturated than a straight solve.
    var saturation: Double = 12

    /// Solved per-channel maximum density — the white point. Trimming one
    /// channel neutralizes a highlight cast.
    var dmax = DensityTriple(red: 2, green: 2, blue: 2)

    /// Solved per-channel paper gamma at grade 2. Three different slopes is
    /// the crossover fix — the degree of freedom the matrix model lacks.
    var gamma = DensityTriple.unit

    /// Print filtration on the red–blue axis, −100…100. The enlarger color
    /// pack: positive warms the print (more red exposure, less blue). Applied
    /// after the solve, so Auto stays a neutral measurement and this carries
    /// the house look. ±100 = ±0.25 EV split between red and blue.
    var warmth: Double = 0

    /// Print filtration on the green–magenta axis, −100…100. Positive is
    /// green, negative magenta. Same units as ``warmth``.
    var tint: Double = 0

    init() {}

    /// Lenient, field by field, for the same reason as the parent type.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exposure = c.lenient(.exposure, 0)
        contrast = c.lenient(.contrast, 2)
        shoulder = c.lenient(.shoulder, 40)
        toe = c.lenient(.toe, 30)
        saturation = c.lenient(.saturation, 12)
        dmax = c.lenient(.dmax, DensityTriple(red: 2, green: 2, blue: 2))
        gamma = c.lenient(.gamma, .unit)
        warmth = c.lenient(.warmth, 0)
        tint = c.lenient(.tint, 0)
    }
}
