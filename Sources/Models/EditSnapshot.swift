import Foundation
import GRDB

/// A named, saved state of one photo's edit stack.
///
/// Snapshots answer "keep this version while I try something else" without the
/// weight of a virtual copy: they live inside the same frame, and applying one
/// simply restores its stack (undo still works across the restore).
struct EditSnapshot: Codable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "editSnapshot"

    let id: UUID

    /// The catalog entry this snapshot belongs to.
    let entryID: UUID

    var name: String

    let dateCreated: Date

    /// The full edit state at the moment the snapshot was taken.
    var editStack: EditStack

    init(entryID: UUID, name: String, editStack: EditStack, dateCreated: Date = Date()) {
        self.id = UUID()
        self.entryID = entryID
        self.name = name
        self.dateCreated = dateCreated
        self.editStack = editStack
    }
}
