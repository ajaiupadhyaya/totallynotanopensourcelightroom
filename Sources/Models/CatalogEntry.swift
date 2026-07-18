import Foundation
import GRDB

/// One photo in the catalog: a reference to the original file on disk plus its
/// non-destructive edit stack. The original file is never modified — everything
/// about how the photo looks lives in ``editStack``.
///
/// Persisted via GRDB. Scalar `DatabaseValueConvertible` properties (`UUID`,
/// `URL`, `Date`) store as native columns; ``editStack`` is a nested `Codable`
/// value, which GRDB stores as JSON automatically.
struct CatalogEntry: Codable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "catalogEntry"

    /// Stable identity, also the primary key and the thumbnail file name.
    let id: UUID

    /// Location of the untouched original on disk.
    var fileURL: URL

    /// When the photo was first imported.
    let dateImported: Date

    /// The non-destructive edit description.
    var editStack: EditStack

    /// Location of the generated thumbnail, if one exists yet.
    var thumbnailPath: URL?
}
