import CoreImage
import XCTest
@testable import PhotoEditor

/// Exercises ``EditorModel`` as the single-photo editing loop: loading an
/// entry's original, live-rendering edits, resetting, and handling a missing
/// file. A long `commitDelay` keeps the debounce timer from firing mid-test.
final class EditorModelTests: XCTestCase {
    private func makeEditor(gray: UInt8 = 128) throws -> (editor: EditorModel, url: URL) {
        let url = try TestSupport.makeTempPNG(gray: gray)
        let catalog = try TestSupport.inMemoryCatalog()
        let entry = TestSupport.makeEntry(fileURL: url)
        try catalog.save(entry)
        let editor = EditorModel(
            entry: entry, catalog: catalog,
            thumbnails: TestSupport.tempThumbnails(), commitDelay: 60
        )
        return (editor, url)
    }

    func testLoadsPreviewOnInit() throws {
        let (editor, url) = try makeEditor()
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertFalse(editor.isMissingFile)
        XCTAssertNotNil(editor.displayImage)
        XCTAssertEqual(editor.fileName, url.lastPathComponent)
    }

    func testExposureBrightensPreview() throws {
        let (editor, url) = try makeEditor()
        defer { try? FileManager.default.removeItem(at: url) }

        let base = TestSupport.averageBrightness(try XCTUnwrap(editor.displayImage))
        editor.editStack.exposure = 2.0
        let brightened = TestSupport.averageBrightness(try XCTUnwrap(editor.displayImage))

        XCTAssertGreaterThan(brightened, base,
                             "Raising exposure should brighten the rendered preview.")
    }

    func testResetRestoresPreview() throws {
        let (editor, url) = try makeEditor()
        defer { try? FileManager.default.removeItem(at: url) }

        let base = TestSupport.averageBrightness(try XCTUnwrap(editor.displayImage))
        editor.editStack.exposure = -2.0
        XCTAssertLessThan(TestSupport.averageBrightness(try XCTUnwrap(editor.displayImage)), base)

        editor.resetAdjustments()
        XCTAssertEqual(TestSupport.averageBrightness(try XCTUnwrap(editor.displayImage)),
                       base, accuracy: 0.01)
    }

    func testMissingFileIsFlagged() throws {
        let catalog = try TestSupport.inMemoryCatalog()
        let entry = TestSupport.makeEntry(
            fileURL: URL(fileURLWithPath: "/nonexistent/path/nope.png")
        )
        let editor = EditorModel(
            entry: entry, catalog: catalog,
            thumbnails: TestSupport.tempThumbnails(), commitDelay: 60
        )

        XCTAssertTrue(editor.isMissingFile)
        XCTAssertNil(editor.displayImage)
    }
}
