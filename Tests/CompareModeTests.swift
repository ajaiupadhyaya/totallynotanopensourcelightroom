import CoreImage
import XCTest
@testable import PhotoEditor

@MainActor
final class CompareModeTests: XCTestCase {
    private func makeEditor() throws -> (editor: EditorModel, url: URL) {
        let url = try TestSupport.makeTempPNG(gray: 128)
        let catalog = try TestSupport.inMemoryCatalog()
        let entry = TestSupport.makeEntry(fileURL: url)
        try catalog.save(entry)
        return (EditorModel(entry: entry, catalog: catalog,
                            thumbnails: TestSupport.tempThumbnails(), commitDelay: 60), url)
    }

    func testYTogglesSideBySideAndTheSameKeyExits() throws {
        let (editor, url) = try makeEditor()
        defer { try? FileManager.default.removeItem(at: url) }

        editor.toggleCompare(.sideBySide)
        XCTAssertEqual(editor.compareMode, .sideBySide)
        editor.toggleCompare(.split)
        XCTAssertEqual(editor.compareMode, .split, "⇧Y switches modes directly")
        editor.toggleCompare(.split)
        XCTAssertEqual(editor.compareMode, .off, "repeating the key exits")
    }

    /// The before image must show the unedited interpretation — same source,
    /// adjustments reset — or the comparison lies.
    func testCompareRendersABeforeThatIgnoresTheEdit() throws {
        let (editor, url) = try makeEditor()
        defer { try? FileManager.default.removeItem(at: url) }

        editor.editStack.exposure = 2.0
        editor.toggleCompare(.sideBySide)

        let before = try XCTUnwrap(editor.beforeCIImage)
        let after = try XCTUnwrap(editor.previewCIImage)
        let beforeLuma = TestSupport.readColor(before)
        let afterLuma = TestSupport.readColor(after)
        XCTAssertGreaterThan(afterLuma.red, beforeLuma.red + 0.1,
                             "two stops of exposure must separate the panes")
    }

    /// "Before" keeps geometry: comparing a crop against an uncropped frame
    /// would just look like a different photo.
    func testBeforeKeepsTheCrop() throws {
        let (editor, url) = try makeEditor()
        defer { try? FileManager.default.removeItem(at: url) }

        editor.editStack.geometry.cropRect = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        editor.toggleCompare(.sideBySide)
        let before = try XCTUnwrap(editor.beforeCIImage)
        let after = try XCTUnwrap(editor.previewCIImage)
        XCTAssertEqual(before.extent, after.extent)
    }

    func testExitingCompareDropsTheBeforeRender() throws {
        let (editor, url) = try makeEditor()
        defer { try? FileManager.default.removeItem(at: url) }
        editor.toggleCompare(.sideBySide)
        XCTAssertNotNil(editor.beforeCIImage)
        editor.toggleCompare(.sideBySide)
        XCTAssertNil(editor.beforeCIImage, "no mode, no second render being paid for")
    }
}
