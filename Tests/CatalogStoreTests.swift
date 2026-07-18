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
