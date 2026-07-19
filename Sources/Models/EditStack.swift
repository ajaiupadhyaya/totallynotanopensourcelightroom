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

    // MARK: Tone curve

    /// Tone-curve control points in the unit square (x = input, y = output),
    /// sorted by ascending x. An empty array means the identity curve (no
    /// change). When set, it holds exactly five points to feed `CIToneCurve`.
    var toneCurvePoints: [CGPoint] = []

    // MARK: Color mixer, grading, and per-channel curves

    /// Everything rendered through the color LUT: black-and-white treatment,
    /// the per-hue-band mixer, three-way grading, and per-channel curves.
    var color = ColorSettings()

    // MARK: Geometry

    /// Crop, rotation, straightening, and flips.
    var geometry = Geometry()

    // MARK: Film

    /// Scanned-negative conversion. Disabled by default, so ordinary digital
    /// photos are unaffected.
    var filmNegative = FilmNegativeSettings()

    init() {}
}

// MARK: - Lenient decoding

extension EditStack {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)

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

        toneCurvePoints = c.lenient(.toneCurvePoints, [])
        color = c.lenient(.color, ColorSettings())
        geometry = c.lenient(.geometry, Geometry())
        filmNegative = c.lenient(.filmNegative, FilmNegativeSettings())
    }
}
