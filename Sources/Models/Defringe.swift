import Foundation

/// Chromatic-aberration cleanup: desaturates purple and green fringes, but
/// only along high-contrast edges — the only place lateral CA occurs.
///
/// Restricting the fix to edges is what makes it safe: a purple flower or a
/// green field far from any edge keeps its color at any slider setting.
struct Defringe: Codable, Equatable {
    /// Strength of purple-fringe removal, `0...100`.
    var purple: Double = 0

    /// Strength of green-fringe removal, `0...100`.
    var green: Double = 0

    var isNeutral: Bool { purple == 0 && green == 0 }

    init() {}

    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        purple = c.lenient(.purple, 0)
        green = c.lenient(.green, 0)
    }
}
