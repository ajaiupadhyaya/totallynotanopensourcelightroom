import Foundation
import GRDB

/// The three film families the converter treats differently.
enum FilmType: String, Codable, CaseIterable, Identifiable {
    /// Orange-masked color negative (C-41 and ECN-2). Needs mask removal and
    /// inversion.
    case colorNegative
    /// Black-and-white negative. Near-clear base, so only inversion.
    case blackAndWhiteNegative
    /// Reversal / transparency film. Already a positive — no inversion.
    case slide

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .colorNegative: "Color Negative"
        case .blackAndWhiteNegative: "B&W Negative"
        case .slide: "Slide / Reversal"
        }
    }

    /// Slide film is already positive; the other two are negatives.
    var requiresInversion: Bool { self != .slide }

    /// Only color negative carries an orange mask to divide out.
    var hasColorMask: Bool { self == .colorNegative }
}

/// A film stock profile: how to undo a stock's base mask and what its positive
/// rendering roughly looks like.
///
/// ## About the built-in values
///
/// The bundled profiles are **approximate starting points, not measured
/// emulations.** The base colors are representative of each family's mask
/// density, and the tone/color character is a hand-tuned nudge, not a
/// characteristic curve derived from densitometry. They exist so a scan lands
/// somewhere sane on the first click.
///
/// For accurate results on *your* scanner and *your* development, calibrate:
/// sample the film base from your own frame and save a custom profile. A
/// calibrated profile beats any built-in one, because it captures your whole
/// chain (stock + development + scanner + light source) rather than just the
/// stock.
struct FilmStock: Codable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    /// Custom (calibrated) stocks are persisted here. Built-ins live in code.
    static let databaseTableName = "filmStock"

    /// Stable identifier used to reference this stock from an edit stack.
    var id: String
    var name: String
    var manufacturer: String
    var iso: Int?
    var type: FilmType

    /// The film base / D-min color — what unexposed, developed film looks like
    /// on the scanner. This is both what gets divided out and what stock
    /// matching compares against.
    var baseColor: FilmColor

    /// Per-channel gain applied after inversion to neutralize residual cast.
    var channelGains: FilmColor

    /// Contrast nudge on the same `-100...100` scale as the main slider.
    var contrast: Double

    /// Saturation nudge, `-100...100`.
    var saturation: Double

    /// True for profiles the user calibrated from their own scan.
    var isCustom: Bool = false

    var displayName: String {
        manufacturer.isEmpty ? name : "\(manufacturer) \(name)"
    }

    var subtitle: String {
        var parts: [String] = [type.displayName]
        if let iso { parts.append("ISO \(iso)") }
        if isCustom { parts.append("Calibrated") }
        return parts.joined(separator: " · ")
    }
}

extension FilmStock {
    /// The bundled reference profiles. See the type doc: approximate, and
    /// meant to be superseded by user calibration.
    static let builtIn: [FilmStock] = [
        // MARK: Color negative — C-41
        FilmStock(id: "kodak-portra-400", name: "Portra 400", manufacturer: "Kodak",
                  iso: 400, type: .colorNegative,
                  baseColor: FilmColor(red: 1.00, green: 0.61, blue: 0.36),
                  channelGains: FilmColor(red: 1.00, green: 0.99, blue: 1.02),
                  contrast: -6, saturation: -4),
        FilmStock(id: "kodak-portra-160", name: "Portra 160", manufacturer: "Kodak",
                  iso: 160, type: .colorNegative,
                  baseColor: FilmColor(red: 1.00, green: 0.62, blue: 0.37),
                  channelGains: FilmColor(red: 1.00, green: 1.00, blue: 1.01),
                  contrast: -3, saturation: -2),
        FilmStock(id: "kodak-gold-200", name: "Gold 200", manufacturer: "Kodak",
                  iso: 200, type: .colorNegative,
                  baseColor: FilmColor(red: 1.00, green: 0.59, blue: 0.33),
                  channelGains: FilmColor(red: 1.04, green: 1.00, blue: 0.95),
                  contrast: 4, saturation: 10),
        FilmStock(id: "kodak-colorplus-200", name: "ColorPlus 200", manufacturer: "Kodak",
                  iso: 200, type: .colorNegative,
                  baseColor: FilmColor(red: 1.00, green: 0.58, blue: 0.32),
                  channelGains: FilmColor(red: 1.05, green: 1.00, blue: 0.94),
                  contrast: 6, saturation: 8),
        FilmStock(id: "kodak-ektar-100", name: "Ektar 100", manufacturer: "Kodak",
                  iso: 100, type: .colorNegative,
                  baseColor: FilmColor(red: 1.00, green: 0.63, blue: 0.38),
                  channelGains: FilmColor(red: 1.01, green: 1.00, blue: 1.00),
                  contrast: 12, saturation: 18),
        FilmStock(id: "kodak-ultramax-400", name: "UltraMax 400", manufacturer: "Kodak",
                  iso: 400, type: .colorNegative,
                  baseColor: FilmColor(red: 1.00, green: 0.60, blue: 0.34),
                  channelGains: FilmColor(red: 1.04, green: 1.00, blue: 0.96),
                  contrast: 6, saturation: 12),
        FilmStock(id: "fuji-superia-400", name: "Superia X-TRA 400", manufacturer: "Fujifilm",
                  iso: 400, type: .colorNegative,
                  baseColor: FilmColor(red: 1.00, green: 0.64, blue: 0.40),
                  channelGains: FilmColor(red: 0.97, green: 1.02, blue: 1.03),
                  contrast: 6, saturation: 10),
        FilmStock(id: "fuji-c200", name: "C200", manufacturer: "Fujifilm",
                  iso: 200, type: .colorNegative,
                  baseColor: FilmColor(red: 1.00, green: 0.65, blue: 0.41),
                  channelGains: FilmColor(red: 0.97, green: 1.02, blue: 1.02),
                  contrast: 4, saturation: 8),
        FilmStock(id: "fuji-pro-400h", name: "Pro 400H", manufacturer: "Fujifilm",
                  iso: 400, type: .colorNegative,
                  baseColor: FilmColor(red: 1.00, green: 0.66, blue: 0.42),
                  channelGains: FilmColor(red: 0.96, green: 1.01, blue: 1.05),
                  contrast: -6, saturation: -2),

        // MARK: Color negative — ECN-2 (motion picture; remjet removed)
        FilmStock(id: "cinestill-800t", name: "800T", manufacturer: "CineStill",
                  iso: 800, type: .colorNegative,
                  baseColor: FilmColor(red: 1.00, green: 0.57, blue: 0.34),
                  channelGains: FilmColor(red: 0.96, green: 1.00, blue: 1.08),
                  contrast: 2, saturation: 6),
        FilmStock(id: "cinestill-400d", name: "400D", manufacturer: "CineStill",
                  iso: 400, type: .colorNegative,
                  baseColor: FilmColor(red: 1.00, green: 0.60, blue: 0.37),
                  channelGains: FilmColor(red: 1.00, green: 1.00, blue: 1.01),
                  contrast: 0, saturation: 4),
        FilmStock(id: "kodak-vision3-250d", name: "Vision3 250D", manufacturer: "Kodak",
                  iso: 250, type: .colorNegative,
                  baseColor: FilmColor(red: 1.00, green: 0.58, blue: 0.35),
                  channelGains: FilmColor(red: 1.00, green: 1.00, blue: 1.00),
                  contrast: -10, saturation: -6),
        FilmStock(id: "kodak-vision3-500t", name: "Vision3 500T", manufacturer: "Kodak",
                  iso: 500, type: .colorNegative,
                  baseColor: FilmColor(red: 1.00, green: 0.56, blue: 0.33),
                  channelGains: FilmColor(red: 0.95, green: 1.00, blue: 1.09),
                  contrast: -10, saturation: -6),

        // MARK: Black-and-white negative — near-clear base
        FilmStock(id: "ilford-hp5", name: "HP5 Plus", manufacturer: "Ilford",
                  iso: 400, type: .blackAndWhiteNegative,
                  baseColor: FilmColor(red: 1.00, green: 0.98, blue: 0.95),
                  channelGains: .white, contrast: 4, saturation: 0),
        FilmStock(id: "ilford-delta-100", name: "Delta 100", manufacturer: "Ilford",
                  iso: 100, type: .blackAndWhiteNegative,
                  baseColor: FilmColor(red: 1.00, green: 0.99, blue: 0.97),
                  channelGains: .white, contrast: 8, saturation: 0),
        FilmStock(id: "kodak-trix-400", name: "Tri-X 400", manufacturer: "Kodak",
                  iso: 400, type: .blackAndWhiteNegative,
                  baseColor: FilmColor(red: 1.00, green: 0.97, blue: 0.93),
                  channelGains: .white, contrast: 10, saturation: 0),
        FilmStock(id: "kodak-tmax-100", name: "T-Max 100", manufacturer: "Kodak",
                  iso: 100, type: .blackAndWhiteNegative,
                  baseColor: FilmColor(red: 1.00, green: 0.99, blue: 0.98),
                  channelGains: .white, contrast: 6, saturation: 0),

        // MARK: Slide / reversal — already positive
        FilmStock(id: "fuji-velvia-50", name: "Velvia 50", manufacturer: "Fujifilm",
                  iso: 50, type: .slide,
                  baseColor: .white, channelGains: .white,
                  contrast: 16, saturation: 28),
        FilmStock(id: "fuji-provia-100f", name: "Provia 100F", manufacturer: "Fujifilm",
                  iso: 100, type: .slide,
                  baseColor: .white, channelGains: .white,
                  contrast: 6, saturation: 8),
        FilmStock(id: "kodak-ektachrome-e100", name: "Ektachrome E100", manufacturer: "Kodak",
                  iso: 100, type: .slide,
                  baseColor: .white, channelGains: .white,
                  contrast: 4, saturation: 6),
    ]

    static func builtIn(id: String) -> FilmStock? {
        builtIn.first { $0.id == id }
    }
}
