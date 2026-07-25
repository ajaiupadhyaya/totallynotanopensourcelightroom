import AppKit
import CoreGraphics
import XCTest
@testable import PhotoEditor

/// Round-trips ``CatalogEntry`` values through ``CatalogStore`` (GRDB/SQLite),
/// including the JSON-encoded edit stack and on-disk persistence.
final class CatalogStoreTests: XCTestCase {
    func testSaveFetchRoundTripIncludingEditStack() throws {
        let store = try CatalogStore()
        var entry = TestSupport.makeEntry(fileURL: URL(fileURLWithPath: "/tmp/a.jpg"))
        entry.editStack.exposure = 1.25
        entry.editStack.whiteBalanceTemp = 7200
        entry.editStack.toneCurvePoints = [
            CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0.7), CGPoint(x: 1, y: 1),
        ]

        try store.save(entry)
        let fetched = try XCTUnwrap(store.entry(id: entry.id))

        XCTAssertEqual(fetched.id, entry.id)
        XCTAssertEqual(fetched.fileURL, entry.fileURL)
        XCTAssertEqual(fetched.thumbnailPath, entry.thumbnailPath)
        XCTAssertEqual(fetched.editStack, entry.editStack,
                       "The JSON-encoded edit stack should round-trip exactly.")
        XCTAssertEqual(fetched.editStack.toneCurvePoints.count, 3)
        // GRDB stores dates at millisecond precision, which is plenty for an
        // import timestamp.
        XCTAssertEqual(fetched.dateImported.timeIntervalSince1970,
                       entry.dateImported.timeIntervalSince1970, accuracy: 0.001)
    }

    func testAllEntriesAreNewestFirst() throws {
        let store = try CatalogStore()
        let older = CatalogEntry(
            id: UUID(), fileURL: URL(fileURLWithPath: "/tmp/old.jpg"),
            dateImported: Date(timeIntervalSince1970: 1_000),
            editStack: EditStack(), thumbnailPath: nil
        )
        let newer = CatalogEntry(
            id: UUID(), fileURL: URL(fileURLWithPath: "/tmp/new.jpg"),
            dateImported: Date(timeIntervalSince1970: 2_000),
            editStack: EditStack(), thumbnailPath: nil
        )
        try store.save(older)
        try store.save(newer)

        XCTAssertEqual(try store.allEntries().map(\.id), [newer.id, older.id])
    }

    func testUpdateAndDelete() throws {
        let store = try CatalogStore()
        var entry = TestSupport.makeEntry(fileURL: URL(fileURLWithPath: "/tmp/a.jpg"))
        try store.save(entry)

        entry.editStack.contrast = 40
        try store.save(entry) // update by primary key
        XCTAssertEqual(try store.entry(id: entry.id)?.editStack.contrast, 40)

        try store.delete(id: entry.id)
        XCTAssertNil(try store.entry(id: entry.id))
        XCTAssertTrue(try store.allEntries().isEmpty)
    }

    func testOnDiskCatalogPersistsAcrossReopen() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pecat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("catalog.sqlite").path

        let id = UUID()
        do {
            let store = try CatalogStore(path: path)
            try store.save(CatalogEntry(
                id: id, fileURL: URL(fileURLWithPath: "/tmp/x.jpg"),
                dateImported: Date(), editStack: EditStack(), thumbnailPath: nil
            ))
        }

        let reopened = try CatalogStore(path: path)
        XCTAssertNotNil(try reopened.entry(id: id),
                        "Entries should survive closing and reopening the on-disk catalog.")
    }
}

// MARK: - Thumbnail repair

/// The library must never be permanently stuck showing the empty-frame
/// placeholder. A thumbnail can go missing for reasons that have nothing to do
/// with the photograph — an unmounted volume at import, a cleared cache — and
/// the catalog has to be able to recover on its own.
final class ThumbnailRepairTests: XCTestCase {
    private func makeApp() throws -> (app: AppModel, thumbs: ThumbnailGenerator) {
        let thumbs = TestSupport.tempThumbnails()
        let app = AppModel(catalog: try TestSupport.inMemoryCatalog(), thumbnails: thumbs)
        return (app, thumbs)
    }

    func testImportWritesAThumbnailAndRecordsItsPath() throws {
        let (app, thumbs) = try makeApp()
        let url = try TestSupport.makeTempPNG(gray: 90, size: 700)
        defer { try? FileManager.default.removeItem(at: url) }

        let entry = try XCTUnwrap(app.importPhoto(from: url))
        let path = try XCTUnwrap(entry.thumbnailPath, "Import must record the thumbnail path.")
        XCTAssertEqual(path, thumbs.url(for: entry.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
    }

    func testARepairRebuildsAThumbnailDeletedFromDisk() throws {
        let (app, thumbs) = try makeApp()
        let url = try TestSupport.makeTempPNG(gray: 90, size: 700)
        defer { try? FileManager.default.removeItem(at: url) }
        let entry = try XCTUnwrap(app.importPhoto(from: url))

        // Simulate a cleared cache.
        try FileManager.default.removeItem(at: thumbs.url(for: entry.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: thumbs.url(for: entry.id).path))

        app.refreshThumbnail(for: entry)

        XCTAssertTrue(FileManager.default.fileExists(atPath: thumbs.url(for: entry.id).path),
                      "A missing thumbnail must be rebuilt, not left as a placeholder.")
    }

    /// The regression that shipped: the thumbnail file was rewritten but its
    /// location was never saved, so an entry that imported without one kept
    /// drawing the placeholder forever.
    func testRefreshRecordsThePathForAnEntryThatNeverHadOne() throws {
        let (app, _) = try makeApp()
        let url = try TestSupport.makeTempPNG(gray: 120, size: 700)
        defer { try? FileManager.default.removeItem(at: url) }
        let imported = try XCTUnwrap(app.importPhoto(from: url))

        var orphan = imported
        orphan.thumbnailPath = nil

        let repaired = app.refreshThumbnail(for: orphan)

        XCTAssertNotNil(repaired.thumbnailPath,
                        "Refreshing must record where the thumbnail was written.")
        XCTAssertEqual(app.entries.first { $0.id == orphan.id }?.thumbnailPath,
                       repaired.thumbnailPath,
                       "The in-memory library must see the repaired path too.")
    }

    func testAppliedEditsAreVisibleInTheThumbnail() throws {
        let (app, thumbs) = try makeApp()
        let url = try TestSupport.makeTempPNG(gray: 120, size: 700)
        defer { try? FileManager.default.removeItem(at: url) }
        let entry = try XCTUnwrap(app.importPhoto(from: url))

        func brightness() throws -> Double {
            let image = try XCTUnwrap(NSImage(contentsOf: thumbs.url(for: entry.id)))
            let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
            return TestSupport.averageBrightness(cg)
        }

        let before = try brightness()
        var brighter = EditStack()
        brighter.exposure = 2.0
        XCTAssertEqual(app.apply(brighter, to: [entry]), 1)

        XCTAssertGreaterThan(try brightness(), before + 0.05,
                             "The library thumbnail must reflect the edit that was applied.")
    }
}
