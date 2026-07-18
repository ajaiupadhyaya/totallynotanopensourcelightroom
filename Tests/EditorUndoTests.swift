import XCTest
@testable import PhotoEditor

/// Verifies the undo/redo history and debounced persistence in ``EditorModel``.
/// `commitEdit()` is invoked directly to make commit boundaries deterministic
/// (in the app they are driven by the debounce timer).
final class EditorUndoTests: XCTestCase {
    private func makeEditor() throws -> (editor: EditorModel, url: URL, catalog: CatalogStore) {
        let url = try TestSupport.makeTempPNG()
        let catalog = try TestSupport.inMemoryCatalog()
        let entry = TestSupport.makeEntry(fileURL: url)
        try catalog.save(entry)
        let editor = EditorModel(
            entry: entry, catalog: catalog,
            thumbnails: TestSupport.tempThumbnails(), commitDelay: 60
        )
        return (editor, url, catalog)
    }

    func testUndoRedoTracksCommittedEdits() throws {
        let (editor, url, _) = try makeEditor()
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertFalse(editor.canUndo)

        editor.editStack.exposure = 1.0
        editor.commitEdit()
        editor.editStack.exposure = 2.0
        editor.commitEdit()

        XCTAssertTrue(editor.canUndo)
        XCTAssertFalse(editor.canRedo)

        editor.undo()
        XCTAssertEqual(editor.editStack.exposure, 1.0, accuracy: 1e-9)
        XCTAssertTrue(editor.canRedo)

        editor.undo()
        XCTAssertEqual(editor.editStack.exposure, 0.0, accuracy: 1e-9)
        XCTAssertFalse(editor.canUndo)

        editor.redo()
        XCTAssertEqual(editor.editStack.exposure, 1.0, accuracy: 1e-9)
        editor.redo()
        XCTAssertEqual(editor.editStack.exposure, 2.0, accuracy: 1e-9)
        XCTAssertFalse(editor.canRedo)
    }

    func testFreshEditAfterUndoClearsRedo() throws {
        let (editor, url, _) = try makeEditor()
        defer { try? FileManager.default.removeItem(at: url) }

        editor.editStack.exposure = 1.0
        editor.commitEdit()
        editor.undo()
        XCTAssertTrue(editor.canRedo)

        editor.editStack.contrast = 30
        editor.commitEdit()
        XCTAssertFalse(editor.canRedo, "A fresh edit should clear the redo stack.")
    }

    func testCommitPersistsStackAndThumbnail() throws {
        let (editor, url, catalog) = try makeEditor()
        defer { try? FileManager.default.removeItem(at: url) }

        editor.editStack.saturation = 55
        editor.commitEdit()

        let stored = try XCTUnwrap(catalog.entry(id: editor.entry.id))
        XCTAssertEqual(stored.editStack.saturation, 55, accuracy: 1e-9)
        XCTAssertNotNil(stored.thumbnailPath, "Commit should also write a thumbnail.")
    }
}
