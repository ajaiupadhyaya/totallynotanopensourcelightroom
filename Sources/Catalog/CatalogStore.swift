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
        migrator.registerMigration("v3_addRatingFlagAndLabel") { db in
            try db.alter(table: CatalogEntry.databaseTableName) { table in
                table.add(column: "rating", .integer).notNull().defaults(to: 0)
                table.add(column: "flag", .integer).notNull().defaults(to: 0)
                table.add(column: "colorLabel", .text).notNull().defaults(to: "none")
            }
        }
        migrator.registerMigration("v4_createDevelopPreset") { db in
            try db.create(table: DevelopPreset.databaseTableName) { table in
                table.primaryKey("id", .text)
                table.column("name", .text).notNull()
                table.column("group", .text).notNull()
                table.column("dateCreated", .datetime).notNull()
                table.column("editStack", .text).notNull() // JSON
            }
        }
        migrator.registerMigration("v5_addCaptureMetadataAndIndexes") { db in
            try db.alter(table: CatalogEntry.databaseTableName) { table in
                table.add(column: "cameraMake", .text)
                table.add(column: "cameraModel", .text)
                table.add(column: "lensModel", .text)
                table.add(column: "iso", .integer)
                table.add(column: "captureDate", .datetime)
            }
            // Culling and browsing filter on these constantly, and a catalog
            // is read far more often than it is written, so the index cost is
            // worth paying.
            try db.create(index: "idx_catalogEntry_rating",
                          on: CatalogEntry.databaseTableName, columns: ["rating"])
            try db.create(index: "idx_catalogEntry_flag",
                          on: CatalogEntry.databaseTableName, columns: ["flag"])
            try db.create(index: "idx_catalogEntry_colorLabel",
                          on: CatalogEntry.databaseTableName, columns: ["colorLabel"])
            try db.create(index: "idx_catalogEntry_cameraModel",
                          on: CatalogEntry.databaseTableName, columns: ["cameraModel"])
            try db.create(index: "idx_catalogEntry_lensModel",
                          on: CatalogEntry.databaseTableName, columns: ["lensModel"])
            try db.create(index: "idx_catalogEntry_iso",
                          on: CatalogEntry.databaseTableName, columns: ["iso"])
            try db.create(index: "idx_catalogEntry_captureDate",
                          on: CatalogEntry.databaseTableName, columns: ["captureDate"])
            try db.create(index: "idx_catalogEntry_dateImported",
                          on: CatalogEntry.databaseTableName, columns: ["dateImported"])
        }
        migrator.registerMigration("v6_virtualCopiesAndSnapshots") { db in
            try db.alter(table: CatalogEntry.databaseTableName) { table in
                table.add(column: "copyNumber", .integer).notNull().defaults(to: 0)
            }
            // Copies of the same file are looked up together (numbering the
            // next copy, showing siblings).
            try db.create(index: "idx_catalogEntry_fileURL",
                          on: CatalogEntry.databaseTableName, columns: ["fileURL"])

            try db.create(table: EditSnapshot.databaseTableName) { table in
                table.primaryKey("id", .blob)
                table.column("entryID", .blob).notNull()
                table.column("name", .text).notNull()
                table.column("dateCreated", .datetime).notNull()
                table.column("editStack", .text).notNull() // JSON
            }
            try db.create(index: "idx_editSnapshot_entryID",
                          on: EditSnapshot.databaseTableName, columns: ["entryID"])
        }
        return migrator
    }

    // MARK: Virtual copies

    /// The next free copy number for a file — one greater than the highest
    /// among the master (0) and any existing copies.
    func nextCopyNumber(forFileURL fileURL: URL) throws -> Int {
        try dbQueue.read { db in
            let highest = try Int.fetchOne(
                db,
                sql: "SELECT MAX(copyNumber) FROM \(CatalogEntry.databaseTableName) WHERE fileURL = ?",
                arguments: [fileURL.absoluteString]
            ) ?? 0
            return highest + 1
        }
    }

    // MARK: Snapshots

    /// Snapshots belonging to one entry, newest first.
    func snapshots(for entryID: UUID) throws -> [EditSnapshot] {
        try dbQueue.read { db in
            try EditSnapshot
                .filter(Column("entryID") == entryID)
                .order(Column("dateCreated").desc)
                .fetchAll(db)
        }
    }

    func saveSnapshot(_ snapshot: EditSnapshot) throws {
        try dbQueue.write { db in try snapshot.save(db) }
    }

    func deleteSnapshot(id: UUID) throws {
        _ = try dbQueue.write { db in try EditSnapshot.deleteOne(db, key: id) }
    }

    // MARK: Develop presets

    /// All presets, grouped name order.
    func allPresets() throws -> [DevelopPreset] {
        try dbQueue.read { db in
            try DevelopPreset.order(Column("group"), Column("name")).fetchAll(db)
        }
    }

    func savePreset(_ preset: DevelopPreset) throws {
        try dbQueue.write { db in try preset.save(db) }
    }

    func deletePreset(id: String) throws {
        _ = try dbQueue.write { db in try DevelopPreset.deleteOne(db, key: id) }
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
