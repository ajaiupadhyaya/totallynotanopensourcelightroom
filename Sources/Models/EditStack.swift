import CoreGraphics
import Foundation

/// The non-destructive edit description for a single photo.
///
/// This is the source of truth for how an imported image should *look* — the
/// original file on disk is never modified. Every preview is produced by
/// replaying this stack against the untouched original through a Core Image
/// filter chain (see ``EditRenderer``). Because it is `Codable`, the whole
/// edit state for a photo is just a small JSON blob in the catalog.
///
/// Every field's default is its neutral value, so a freshly-constructed stack
/// renders the original image unchanged. Decoding is lenient (see
/// ``LenientDecoding``), which is what makes adding a field safe for photos
/// edited by an earlier build.
struct EditStack: Codable, Equatable {
    // MARK: Process version

    /// Which rendering engine interprets this stack. 1 = the original chain,
    /// frozen verbatim in ``LegacyToneRenderer`` so old edits never change
    /// appearance; 2 = the calibrated PV2 chain. New stacks start at 2;
    /// decoding falls back to 1 because any stack persisted before this field
    /// existed was authored against the old math.
    var processVersion: Int = 2

    // MARK: Light

    /// Exposure adjustment in EV stops. `0` leaves the image unchanged.
    var exposure: Double = 0

    /// Contrast adjustment on a `-100...100` scale. `0` leaves it unchanged.
    var contrast: Double = 0

    /// Highlight adjustment, `-100...100`. Negative recovers (darkens) bright
    /// tones; `0` leaves them unchanged.
    var highlights: Double = 0

    /// Shadow adjustment, `-100...100`. Positive lifts (lightens) dark tones,
    /// negative deepens them; `0` leaves them unchanged.
    var shadows: Double = 0

    /// White-point adjustment, `-100...100`. Shapes the brightest tones,
    /// above where ``highlights`` acts.
    var whites: Double = 0

    /// Black-point adjustment, `-100...100`. Shapes the darkest tones, below
    /// where ``shadows`` acts.
    var blacks: Double = 0

    // MARK: White balance

    /// White-balance temperature in Kelvin. `6500` (D65) is neutral; higher is
    /// warmer, lower is cooler.
    var whiteBalanceTemp: Double = 6500

    /// White-balance tint on a green–magenta axis, `-100...100`. `0` is neutral.
    var whiteBalanceTint: Double = 0

    // MARK: Presence

    /// Fine-detail local contrast, `-100...100`. Small-radius; brings out
    /// surface texture without touching overall tonality.
    var texture: Double = 0

    /// Midtone local contrast, `-100...100`. Large-radius; adds punch and
    /// apparent depth.
    var clarity: Double = 0

    /// Haze reduction, `-100...100`. See ``EditRenderer`` for what this
    /// actually does — it is an approximation, not a true atmospheric model.
    var dehaze: Double = 0

    /// Saturation weighted toward already-muted colors, `-100...100`. Protects
    /// skin tones better than a flat saturation boost.
    var vibrance: Double = 0

    /// Saturation adjustment, `-100...100`. `-100` is fully desaturated
    /// (grayscale), `0` is unchanged, `+100` doubles saturation.
    var saturation: Double = 0

    // MARK: Detail

    /// Sharpening strength, `0...100`.
    var sharpenAmount: Double = 0

    /// Sharpening radius in pixels, `0.5...5`.
    var sharpenRadius: Double = 1.5

    /// Luminance noise reduction, `0...100`.
    var luminanceNoiseReduction: Double = 0

    /// Color (chroma) noise reduction, `0...100`.
    var colorNoiseReduction: Double = 0

    // MARK: Effects

    /// Post-crop vignette, `-100...100`. Negative darkens the corners.
    var vignetteAmount: Double = 0

    /// How far the vignette reaches in from the corners, `0...100`.
    var vignetteMidpoint: Double = 50

    /// Film grain strength, `0...100`.
    var grainAmount: Double = 0

    /// Grain size, `0...100`; larger is coarser, like a faster stock.
    var grainSize: Double = 25

    /// Vignette shape, `-100...100`. Negative pushes the superellipse toward
    /// rectangular; positive rounds it toward a circle.
    var vignetteRoundness: Double = 0

    /// Vignette falloff width, `0...100`.
    var vignetteFeather: Double = 50

    /// Vignette highlight priority, `0...100`. Lets bright areas punch
    /// through a darkening vignette.
    var vignetteHighlights: Double = 0

    // MARK: Tone curve

    /// Tone-curve control points in the unit square (x = input, y = output),
    /// sorted by ascending x. An empty array means the identity curve (no
    /// change). When set, it holds exactly five points to feed `CIToneCurve`.
    var toneCurvePoints: [CGPoint] = []

    /// Parametric tone-curve regions, `-100...100`.
    var toneCurveHighlights: Double = 0
    var toneCurveLights: Double = 0
    var toneCurveDarks: Double = 0
    var toneCurveShadows: Double = 0

    // MARK: Color mixer, grading, and per-channel curves

    /// Everything rendered through the color LUT: black-and-white treatment,
    /// the per-hue-band mixer, three-way grading, and per-channel curves.
    var color = ColorSettings()

    // MARK: Local adjustments

    /// Masked local corrections (linear and radial gradients), applied in
    /// order after the global adjustments.
    var localAdjustments: [LocalAdjustment] = []

    // MARK: Retouch

    /// Spot-removal corrections (heal/clone), applied to the developed frame
    /// before any global adjustment.
    var retouch: [RetouchSpot] = []

    /// Chromatic-aberration fringe removal, applied to the developed frame.
    var defringe = Defringe()

    // MARK: Geometry

    /// Crop, rotation, straightening, and flips.
    var geometry = Geometry()

    // MARK: Film

    /// Scanned-negative conversion. Disabled by default, so ordinary digital
    /// photos are unaffected.
    var filmNegative = FilmNegativeSettings()

    // MARK: RAW

    /// Baseline RAW rendering boost, `0...100`, mapped to
    /// `CIRAWFilter.boostAmount`. 100 is Apple's default look; 0 is the flat
    /// linear rendering. This is the spec's "visible, adjustable baseline
    /// tone lift" — the lift exists either way; this makes it a slider
    /// instead of an invisible bake. Ignored for non-RAW sources.
    var rawBoost: Double = 100

    /// Whether as-shot white balance has been read from the RAW file into
    /// ``whiteBalanceTemp``/``whiteBalanceTint`` (done once on first load).
    var rawWBInitialized: Bool = false

    init() {}
}

// MARK: - Lenient decoding

extension EditStack {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)

        processVersion = c.lenient(.processVersion, 1)

        exposure = c.lenient(.exposure, 0)
        contrast = c.lenient(.contrast, 0)
        highlights = c.lenient(.highlights, 0)
        shadows = c.lenient(.shadows, 0)
        whites = c.lenient(.whites, 0)
        blacks = c.lenient(.blacks, 0)

        whiteBalanceTemp = c.lenient(.whiteBalanceTemp, 6500)
        whiteBalanceTint = c.lenient(.whiteBalanceTint, 0)

        texture = c.lenient(.texture, 0)
        clarity = c.lenient(.clarity, 0)
        dehaze = c.lenient(.dehaze, 0)
        vibrance = c.lenient(.vibrance, 0)
        saturation = c.lenient(.saturation, 0)

        sharpenAmount = c.lenient(.sharpenAmount, 0)
        sharpenRadius = c.lenient(.sharpenRadius, 1.5)
        luminanceNoiseReduction = c.lenient(.luminanceNoiseReduction, 0)
        colorNoiseReduction = c.lenient(.colorNoiseReduction, 0)

        vignetteAmount = c.lenient(.vignetteAmount, 0)
        vignetteMidpoint = c.lenient(.vignetteMidpoint, 50)
        grainAmount = c.lenient(.grainAmount, 0)
        grainSize = c.lenient(.grainSize, 25)
        vignetteRoundness = c.lenient(.vignetteRoundness, 0)
        vignetteFeather = c.lenient(.vignetteFeather, 50)
        vignetteHighlights = c.lenient(.vignetteHighlights, 0)

        toneCurvePoints = c.lenient(.toneCurvePoints, [])
        toneCurveHighlights = c.lenient(.toneCurveHighlights, 0)
        toneCurveLights = c.lenient(.toneCurveLights, 0)
        toneCurveDarks = c.lenient(.toneCurveDarks, 0)
        toneCurveShadows = c.lenient(.toneCurveShadows, 0)
        color = c.lenient(.color, ColorSettings())
        localAdjustments = c.lenient(.localAdjustments, [])
        retouch = c.lenient(.retouch, [])
        defringe = c.lenient(.defringe, Defringe())
        geometry = c.lenient(.geometry, Geometry())
        filmNegative = c.lenient(.filmNegative, FilmNegativeSettings())
        rawBoost = c.lenient(.rawBoost, 100)
        rawWBInitialized = c.lenient(.rawWBInitialized, false)
    }
}

extension EditStack {
    /// True when the stack contains no edits, regardless of which process
    /// version it targets. Use this — not `== EditStack()` — for "has the
    /// user done anything" checks; a neutral PV1 stack differs from
    /// `EditStack()` only in `processVersion`, and a neutral stack renders
    /// identically under both engines.
    var isNeutralEdit: Bool {
        var normalized = self
        normalized.processVersion = EditStack().processVersion
        normalized.rawWBInitialized = false
        // renderVersion is a freeze flag, not an edit: a stack persisted by a
        // pre-Minilab build decodes 1 while a fresh stack initializes 2, and
        // without this line every photo imported-but-never-edited under the
        // old build would read as edited after upgrade (enabling Reset on an
        // untouched photo). Same reasoning as processVersion above.
        normalized.filmNegative.print.renderVersion = EditStack().filmNegative.print.renderVersion
        return normalized == EditStack()
    }
}
