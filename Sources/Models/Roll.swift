import Foundation
import GRDB

/// A roll's solved conversion: the roll-level constants every frame shares.
/// Stored on the roll (JSON column) so frames added later adopt it.
struct RollConversion: Codable, Equatable {
    var baseColor: FilmColor          // display-encoded, like every base
    var baseOrigin: FilmBaseOrigin
    var gamma: DensityTriple
    var dmax: DensityTriple
    var castRed: Double
    var castGreen: Double
    var castBlue: Double
    var toneProfile: FilmToneProfile
}

/// A physical roll of film: the unit conversion constants belong to.
/// "A roll is a physical fact, a collection is an editorial choice" — the
/// roadmap's boundary; collections are Phase 4 and stay out of this type.
struct Roll: Codable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "roll"
    let id: UUID
    var identifier: String            // "2026-07 Portra roll 3"
    var stock: String?
    var camera: String?
    var lens: String?
    var exposureIndex: Int?
    var pushPull: Int?
    var developer: String?
    var devNotes: String?
    var lab: String?
    var scanDate: Date?
    let dateCreated: Date
    var conversion: RollConversion?
}
