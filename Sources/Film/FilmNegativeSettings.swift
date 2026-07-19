import Foundation

/// The film-negative conversion parameters carried inside an ``EditStack``.
///
/// These are *resolved values*, not a reference to a stock. Picking a film
/// stock in the UI copies that profile's numbers in here, so the edit stack
/// stays self-contained: renaming, editing, or deleting a stock profile can
/// never change how an already-edited photo looks, and rendering needs no
/// access to the stock library. ``stockID``/``stockName`` are kept only as a
/// provenance label for the UI.
struct FilmNegativeSettings: Codable, Equatable {
    /// Whether to run the negative conversion at all. Off means the photo is
    /// treated as an ordinary positive image.
    var isEnabled: Bool = false

    var type: FilmType = .colorNegative

    /// Which stock these numbers came from, for display only.
    var stockID: String?
    var stockName: String?

    /// The film base / D-min color sampled from (or assumed for) this scan.
    /// Everything is divided by this to remove the orange mask.
    var baseColor: FilmColor = FilmNegativeSettings.defaultColorNegativeBase

    /// Per-channel gain applied during inversion to neutralize residual cast.
    var channelGains: FilmColor = .white

    /// Exposure lift applied after inversion, in EV. Negatives rarely invert
    /// to a well-placed exposure on the first try.
    var exposure: Double = 0

    /// The stock's contrast character, `-100...100`. Applied inside the film
    /// conversion so the user's own contrast slider stays independent on top.
    var stockContrast: Double = 0

    /// The stock's saturation character, `-100...100`.
    var stockSaturation: Double = 0

    /// A representative orange mask, used before the base has been sampled.
    static let defaultColorNegativeBase = FilmColor(red: 1.00, green: 0.61, blue: 0.36)

    /// Copies a stock profile's numbers into these settings, keeping the
    /// already-sampled base color if the user calibrated one for this scan.
    mutating func apply(_ stock: FilmStock, keepSampledBase: Bool = false) {
        stockID = stock.id
        stockName = stock.displayName
        type = stock.type
        if !keepSampledBase {
            baseColor = stock.baseColor
        }
        channelGains = stock.channelGains
        stockContrast = stock.contrast
        stockSaturation = stock.saturation
    }
}
