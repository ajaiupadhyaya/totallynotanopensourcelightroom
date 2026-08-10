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

/// A named rendering family for the print stage — the first choice after
/// conversion, separating "accurate" from "pleasing" (spec §Tone profiles).
/// `.linear` is exactly the Phase 2 render; the Lab profiles add the minilab
/// layers (midtone punch, raised black, softened white, shadow chroma
/// compression) at increasing strength. Values are slider units; selecting a
/// profile WRITES them into ordinary visible sliders (resolved values, like
/// a film stock), so the profile is a starting point, not hidden state.
/// Provisional values — tuned against the corpora in the acceptance pass.
enum FilmToneProfile: String, Codable, Equatable, CaseIterable {
    case linear, labSoft, labStandard, labHard

    var punch: Double {
        switch self {
        case .linear: 0; case .labSoft: 30; case .labStandard: 50; case .labHard: 70
        }
    }
    var fade: Double {
        switch self {
        case .linear: 0; case .labSoft: 35; case .labStandard: 22; case .labHard: 12
        }
    }
    var glow: Double {
        switch self {
        case .linear: 0; case .labSoft: 20; case .labStandard: 12; case .labHard: 8
        }
    }
    var toeChroma: Double {
        switch self { case .linear: 0; default: 30 }
    }
    /// Lab profiles balance midtone colour automatically (Task 6/7);
    /// linear stays a pure measurement.
    var enablesAutoColorBalance: Bool { self != .linear }

    var displayName: String {
        switch self {
        case .linear: "Linear"; case .labSoft: "Lab Soft"
        case .labStandard: "Lab Standard"; case .labHard: "Lab Hard"
        }
    }
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
    ///
    /// Default 24: the house look, chosen on visual inspection of a rendered
    /// warmth/tint sweep against the user's own corpus (Task 8, Phase C —
    /// see task-8-filtration-report.md). A deliberate trim of this engine's
    /// default green-leaning cast, not an attempt to rescue any one scan.
    var warmth: Double = 24

    /// Print filtration on the green–magenta axis, −100…100. Positive is
    /// green, negative magenta. Same units as ``warmth``.
    ///
    /// Default −8, chosen alongside ``warmth``'s 24 — see that doc comment.
    var tint: Double = -8

    /// Which semantics render this photo. Initialized 2 (the Minilab fixes:
    /// pre-curve legacy EV, balanced tint, mid-pivot grade); decoded 1 so
    /// every photo converted before this field existed keeps its exact
    /// rendering — the conversionModel freeze trick, one level down.
    var renderVersion: Int = 2

    /// The rendering family these toning sliders were seeded from. Provenance
    /// plus the Auto solve's parameter source — the sliders below stay the
    /// truth the renderer reads.
    var toneProfile: FilmToneProfile = .linear

    /// Midtone punch, 0…100 → PaperResponse.punchAmount. The minilab's
    /// midtone contrast, applied to the norm only (hue-preserving).
    var punch: Double = 0

    /// Raised paper black, 0…100 → PaperResponse.fadeLift.
    var fade: Double = 0

    /// Lowered paper white, 0…100 → PaperResponse.glowDrop.
    var glow: Double = 0

    /// Shadow chroma compression, 0…100 → PaperResponse.toeChromaWeight —
    /// the toe's mirror of the highlight rolloff.
    var toeChroma: Double = 0

    mutating func applyToneProfile(_ profile: FilmToneProfile) {
        toneProfile = profile
        punch = profile.punch
        fade = profile.fade
        glow = profile.glow
        toeChroma = profile.toeChroma
    }

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
        warmth = c.lenient(.warmth, 24)
        tint = c.lenient(.tint, -8)
        renderVersion = c.lenient(.renderVersion, 1)
        toneProfile = c.lenient(.toneProfile, .linear)
        punch = c.lenient(.punch, 0)
        fade = c.lenient(.fade, 0)
        glow = c.lenient(.glow, 0)
        toeChroma = c.lenient(.toeChroma, 0)
    }
}
