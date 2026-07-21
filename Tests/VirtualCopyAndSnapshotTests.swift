import Foundation
import XCTest
@testable import PhotoEditor

/// Catalog-level tests for virtual copies and edit snapshots.
final class VirtualCopyAndSnapshotTests: XCTestCase {
    // MARK: Virtual copies

    func testVirtualCopySharesFileButNotEdits() throws {
        let url = try TestSupport.makeTempPNG()
        let app = try makeApp()
        let master = try XCTUnwrap(app.importPhoto(from: url))

        let copy = try XCTUnwrap(app.createVirtualCopy(of: master))
        XCTAssertEqual(copy.fileURL, master.fileURL)
        XCTAssertNotEqual(copy.id, master.id)
        XCTAssertEqual(copy.copyNumber, 1)
        XCTAssertTrue(copy.isVirtualCopy)
        XCTAssertFalse(master.isVirtualCopy)

        // Editing the copy must not touch the master.
        var stack = EditStack()
        stack.exposure = 1.5
        _ = app.apply(stack, to: [copy], options: .everything)
        let reloadedMaster = app.entries.first { $0.id == master.id }
        let reloadedCopy = app.entries.first { $0.id == copy.id }
        XCTAssertEqual(reloadedMaster?.editStack.exposure, 0)
        XCTAssertEqual(reloadedCopy?.editStack.exposure, 1.5)
    }

    func testCopyNumbersIncrement() throws {
        let url = try TestSupport.makeTempPNG()
        let app = try makeApp()
        let master = try XCTUnwrap(app.importPhoto(from: url))

        let first = try XCTUnwrap(app.createVirtualCopy(of: master))
        let second = try XCTUnwrap(app.createVirtualCopy(of: master))
        XCTAssertEqual(first.copyNumber, 1)
        XCTAssertEqual(second.copyNumber, 2)

        // A different file starts its own numbering.
        let other = try XCTUnwrap(app.importPhoto(from: TestSupport.makeTempPNG(gray: 40)))
        let otherCopy = try XCTUnwrap(app.createVirtualCopy(of: other))
        XCTAssertEqual(otherCopy.copyNumber, 1)
    }

    func testVirtualCopyStartsFromSourceState() throws {
        let url = try TestSupport.makeTempPNG()
        let app = try makeApp()
        var master = try XCTUnwrap(app.importPhoto(from: url))

        var stack = EditStack()
        stack.contrast = 42
        _ = app.apply(stack, to: [master], options: .everything)
        master = try XCTUnwrap(app.entries.first { $0.id == master.id })
        app.setRating(4, for: master)
        master = try XCTUnwrap(app.entries.first { $0.id == master.id })

        let copy = try XCTUnwrap(app.createVirtualCopy(of: master))
        XCTAssertEqual(copy.editStack.contrast, 42)
        XCTAssertEqual(copy.rating, 4)
    }

    func testCopySortsAdjacentToSource() throws {
        let app = try makeApp()
        _ = app.importPhoto(from: try TestSupport.makeTempPNG(gray: 10))
        let master = try XCTUnwrap(app.importPhoto(from: try TestSupport.makeTempPNG(gray: 20)))
        _ = app.importPhoto(from: try TestSupport.makeTempPNG(gray: 30))

        let copy = try XCTUnwrap(app.createVirtualCopy(of: master))

        let ids = app.entries.map(\.id)
        let masterIndex = try XCTUnwrap(ids.firstIndex(of: master.id))
        let copyIndex = try XCTUnwrap(ids.firstIndex(of: copy.id))
        XCTAssertEqual(abs(masterIndex - copyIndex), 1,
                       "the copy must sit next to its source in the filmstrip")
    }

    func testMultipleCopiesStayOrderedInsideTheirImportGroup() throws {
        let app = try makeApp()
        _ = app.importPhoto(from: try TestSupport.makeTempPNG(gray: 10))
        let master = try XCTUnwrap(app.importPhoto(from: try TestSupport.makeTempPNG(gray: 20)))
        _ = app.importPhoto(from: try TestSupport.makeTempPNG(gray: 30))

        let first = try XCTUnwrap(app.createVirtualCopy(of: master))
        let second = try XCTUnwrap(app.createVirtualCopy(of: master))
        let group = app.entries.filter { $0.fileURL == master.fileURL }

        XCTAssertEqual(group.map(\.id), [master.id, first.id, second.id])
        XCTAssertEqual(group.map(\.copyNumber), [0, 1, 2])
    }

    // MARK: Snapshots

    func testSnapshotRoundTrip() throws {
        let catalog = try TestSupport.inMemoryCatalog()
        let entry = TestSupport.makeEntry(fileURL: try TestSupport.makeTempPNG())
        try catalog.save(entry)

        var stack = EditStack()
        stack.exposure = 0.7
        let snapshot = EditSnapshot(entryID: entry.id, name: "Warm print", editStack: stack)
        try catalog.saveSnapshot(snapshot)

        let loaded = try catalog.snapshots(for: entry.id)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.name, "Warm print")
        XCTAssertEqual(loaded.first?.editStack.exposure, 0.7)

        try catalog.deleteSnapshot(id: snapshot.id)
        XCTAssertTrue(try catalog.snapshots(for: entry.id).isEmpty)
    }

    func testSnapshotsAreScopedToTheirEntry() throws {
        let catalog = try TestSupport.inMemoryCatalog()
        let a = TestSupport.makeEntry(fileURL: try TestSupport.makeTempPNG())
        let b = TestSupport.makeEntry(fileURL: try TestSupport.makeTempPNG())
        try catalog.save(a)
        try catalog.save(b)

        try catalog.saveSnapshot(EditSnapshot(entryID: a.id, name: "A1", editStack: EditStack()))
        XCTAssertEqual(try catalog.snapshots(for: a.id).count, 1)
        XCTAssertTrue(try catalog.snapshots(for: b.id).isEmpty)
    }

    func testEditorSnapshotSaveApplyDelete() throws {
        let catalog = try TestSupport.inMemoryCatalog()
        let entry = TestSupport.makeEntry(fileURL: try TestSupport.makeTempPNG())
        try catalog.save(entry)

        let editor = EditorModel(entry: entry, catalog: catalog,
                                 thumbnails: TestSupport.tempThumbnails())
        editor.editStack.exposure = 1.2
        let snapshot = try XCTUnwrap(editor.saveSnapshot(named: "  Bright  "))
        XCTAssertEqual(snapshot.name, "Bright", "names are trimmed")
        XCTAssertEqual(editor.snapshots.count, 1)

        editor.editStack.exposure = -2
        editor.commitEdit() // settle the debounce so -2 is a committed state
        editor.applySnapshot(snapshot)
        XCTAssertEqual(editor.editStack.exposure, 1.2)

        // Restoring a snapshot is an edit like any other, so it must be
        // undoable back to the pre-restore state.
        editor.commitEdit()
        editor.undo()
        XCTAssertEqual(editor.editStack.exposure, -2)

        editor.deleteSnapshot(snapshot)
        XCTAssertTrue(editor.snapshots.isEmpty)
    }

    func testUnnamedSnapshotGetsADefaultName() throws {
        let catalog = try TestSupport.inMemoryCatalog()
        let entry = TestSupport.makeEntry(fileURL: try TestSupport.makeTempPNG())
        try catalog.save(entry)

        let editor = EditorModel(entry: entry, catalog: catalog,
                                 thumbnails: TestSupport.tempThumbnails())
        let snapshot = try XCTUnwrap(editor.saveSnapshot(named: "   "))
        XCTAssertEqual(snapshot.name, "Snapshot 1")
    }

    // MARK: Support

    /// The real AppModel against an isolated in-memory store, so the tests
    /// exercise the actual virtual-copy logic without touching the user's
    /// on-disk library.
    private func makeApp() throws -> AppModel {
        AppModel(catalog: try TestSupport.inMemoryCatalog(),
                 thumbnails: TestSupport.tempThumbnails())
    }
}
