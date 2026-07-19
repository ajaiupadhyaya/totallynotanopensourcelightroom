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
        migrator.registerMigration("v2_createFilmStock") { db in
            // Only *custom* (calibrated) stocks live here; the built-in
            // profiles ship in code so they can be corrected in an update
            // without migrating anyone's database.
            try db.create(table: FilmStock.databaseTableName) { table in
                table.primaryKey("id", .text)
                table.column("name", .text).notNull()
                table.column("manufacturer", .text).notNull()
                table.column("iso", .integer)
                table.column("type", .text).notNull()
                table.column("baseColor", .text).notNull()    // JSON
                table.column("channelGains", .text).notNull() // JSON
                table.column("contrast", .double).notNull()
                table.column("saturation", .double).notNull()
                table.column("isCustom", .boolean).notNull()
            }
        }
        return migrator
    }

    // MARK: Film stocks

    /// Every stock available for selection: the built-ins plus anything the
    /// user has calibrated, custom profiles first.
    func allFilmStocks() throws -> [FilmStock] {
        try customFilmStocks() + FilmStock.builtIn
    }

    /// Only the user's calibrated profiles.
    func customFilmStocks() throws -> [FilmStock] {
        try dbQueue.read { db in
            try FilmStock.order(Column("name")).fetchAll(db)
        }
    }

    func saveFilmStock(_ stock: FilmStock) throws {
        try dbQueue.write { db in try stock.save(db) }
    }

    func deleteFilmStock(id: String) throws {
        _ = try dbQueue.write { db in try FilmStock.deleteOne(db, key: id) }
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
