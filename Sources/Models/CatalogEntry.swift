import Foundation
import GRDB

/// A quick keep/reject decision, kept separate from the star rating because
/// they answer different questions: the flag is "does this frame survive the
/// first pass," the rating is "how good is it."
enum PickFlag: Int, Codable, CaseIterable, Identifiable {
    case rejected = -1
    case unflagged = 0
    case picked = 1

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .rejected: "Rejected"
        case .unflagged: "Unflagged"
        case .picked: "Picked"
        }
    }

    var symbolName: String {
        switch self {
        case .rejected: "xmark.circle"
        case .unflagged: "flag"
        case .picked: "flag.fill"
        }
    }
}

/// A color label for grouping frames however the photographer likes.
enum ColorLabel: String, Codable, CaseIterable, Identifiable {
    case none, red, yellow, green, blue, purple

    var id: String { rawValue }

    var displayName: String { self == .none ? "None" : rawValue.capitalized }
}

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

    /// Star rating, `0...5`. Zero means unrated.
    var rating: Int = 0

    /// Keep/reject decision from a first culling pass.
    var flag: PickFlag = .unflagged

    /// Optional color label.
    var colorLabel: ColorLabel = .none

    var fileName: String { fileURL.lastPathComponent }

    init(
        id: UUID,
        fileURL: URL,
        dateImported: Date,
        editStack: EditStack,
        thumbnailPath: URL?,
        rating: Int = 0,
        flag: PickFlag = .unflagged,
        colorLabel: ColorLabel = .none
    ) {
        self.id = id
        self.fileURL = fileURL
        self.dateImported = dateImported
        self.editStack = editStack
        self.thumbnailPath = thumbnailPath
        self.rating = rating
        self.flag = flag
        self.colorLabel = colorLabel
    }

    /// Decodes leniently for the same reason ``EditStack`` does: rows written
    /// before rating/flag/label existed must still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        fileURL = try c.decode(URL.self, forKey: .fileURL)
        dateImported = try c.decode(Date.self, forKey: .dateImported)
        editStack = c.lenient(.editStack, EditStack())
        thumbnailPath = c.lenient(.thumbnailPath, nil)
        rating = c.lenient(.rating, 0)
        flag = c.lenient(.flag, PickFlag.unflagged)
        colorLabel = c.lenient(.colorLabel, ColorLabel.none)
    }
}
