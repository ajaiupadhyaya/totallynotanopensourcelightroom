import CoreGraphics
import Foundation

/// The non-destructive edit description for a single photo.
///
/// This is the source of truth for how an imported image should *look* — the
/// original file on disk is never modified. Every preview is produced by
/// replaying this stack against the untouched original through a Core Image
/// filter chain (see ``EditRenderer``). Because it is `Codable`, the whole
/// edit state for a photo is just a small JSON blob to persist later.
///
/// Fields are added incrementally, one phase at a time — the model never
/// carries fields that nothing renders yet. Phase 1 added exposure/contrast;
/// Phase 2 adds white balance, saturation, highlights/shadows, and the tone
/// curve below.
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

    // MARK: White balance

    /// White-balance temperature in Kelvin. `6500` (D65) is neutral; higher is
    /// warmer, lower is cooler.
    var whiteBalanceTemp: Double = 6500

    /// White-balance tint on a green–magenta axis, `-100...100`. `0` is neutral.
    var whiteBalanceTint: Double = 0

    // MARK: Color

    /// Saturation adjustment, `-100...100`. `-100` is fully desaturated
    /// (grayscale), `0` is unchanged, `+100` doubles saturation.
    var saturation: Double = 0

    // MARK: Tone curve

    /// Tone-curve control points in the unit square (x = input, y = output),
    /// sorted by ascending x. An empty array means the identity curve (no
    /// change). When set, it holds exactly five points to feed `CIToneCurve`.
    var toneCurvePoints: [CGPoint] = []

    // MARK: Film

    /// Scanned-negative conversion. Disabled by default, so ordinary digital
    /// photos are unaffected.
    var filmNegative = FilmNegativeSettings()

    init() {}
}

// MARK: - Lenient decoding

extension EditStack {
    /// Decodes an edit stack, treating every missing key as its default.
    ///
    /// Edit stacks are persisted as JSON in the catalog, so a stack written by
    /// an older build will not contain fields added since. The synthesized
    /// decoder would throw on those missing keys and the photo's edits would be
    /// silently lost. Decoding leniently instead means adding a field is always
    /// a backward-compatible change: old rows simply come back with the new
    /// field at its neutral default.
    init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)

        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }

        exposure = value(.exposure, 0)
        contrast = value(.contrast, 0)
        highlights = value(.highlights, 0)
        shadows = value(.shadows, 0)
        whiteBalanceTemp = value(.whiteBalanceTemp, 6500)
        whiteBalanceTint = value(.whiteBalanceTint, 0)
        saturation = value(.saturation, 0)
        toneCurvePoints = value(.toneCurvePoints, [])
        filmNegative = value(.filmNegative, FilmNegativeSettings())
    }
}
