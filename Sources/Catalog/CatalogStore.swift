import Foundation
import GRDB

/// The catalog database: a thin GRDB wrapper providing CRUD for
/// ``CatalogEntry``. Backed by SQLite on disk (or in memory for tests).
///
/// The catalog stores *edit metadata* only. Original photo files are never
/// written to, and are referenced by URL rather than copied in.
final class CatalogStore {
    private let dbQueue: DatabaseQueue

    /// Opens (creating if needed) an on-disk catalog at `path`.
    init(path: String) throws {
        dbQueue = try DatabaseQueue(path: path)
        try Self.migrator.migrate(dbQueue)
    }

    /// Opens an in-memory catalog (used by tests).
    init() throws {
        dbQueue = try DatabaseQueue()
        try Self.migrator.migrate(dbQueue)
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_createCatalogEntry") { db in
            try db.create(table: CatalogEntry.databaseTableName) { table in
                table.primaryKey("id", .blob)
                table.column("fileURL", .text).notNull()
                table.column("dateImported", .datetime).notNull()
                table.column("editStack", .text).notNull() // JSON
                table.column("thumbnailPath", .text)
            }
        }
        return migrator
    }

    /// All entries, newest import first.
    func allEntries() throws -> [CatalogEntry] {
        try dbQueue.read { db in
            try CatalogEntry
                .order(Column("dateImported").desc)
                .fetchAll(db)
        }
    }

    /// Inserts or updates an entry by primary key.
    func save(_ entry: CatalogEntry) throws {
        try dbQueue.write { db in try entry.save(db) }
    }

    /// Fetches a single entry by id, if present.
    func entry(id: UUID) throws -> CatalogEntry? {
        try dbQueue.read { db in try CatalogEntry.fetchOne(db, key: id) }
    }

    /// Deletes an entry from the catalog. Does not touch the original file.
    func delete(id: UUID) throws {
        _ = try dbQueue.write { db in try CatalogEntry.deleteOne(db, key: id) }
    }
}
