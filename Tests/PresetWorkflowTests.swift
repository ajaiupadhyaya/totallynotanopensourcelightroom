import CoreGraphics
import Foundation
import XCTest
@testable import PhotoEditor

final class PresetAmountTests: XCTestCase {
    private func look() -> EditStack {
        var stack = EditStack()
        stack.exposure = 2.0
        stack.contrast = 40
        stack.color.treatment = .blackAndWhite
        stack.color.grading.shadows.saturation = 60
        return stack
    }

    func testAmountOneIsExactlyTheFullApply() {
        let base = EditStack()
        XCTAssertEqual(base.interpolated(toward: base.applying(look()), amount: 1),
                       base.applying(look()))
    }

    func testAmountZeroIsExactlyTheBase() {
        var base = EditStack()
        base.exposure = -1
        XCTAssertEqual(base.interpolated(toward: base.applying(look()), amount: 0), base)
    }

    func testHalfAmountLandsScalarsHalfway() {
        let base = EditStack()
        let half = base.interpolated(toward: base.applying(look()), amount: 0.5)
        XCTAssertEqual(half.exposure, 1.0, accuracy: 1e-9)
        XCTAssertEqual(half.contrast, 20, accuracy: 1e-9)
        XCTAssertEqual(half.color.grading.shadows.saturation, 30, accuracy: 1e-9)
        XCTAssertEqual(half.color.treatment, .blackAndWhite,
                       "discrete settings apply whole at any non-zero amount")
    }
}

@MainActor
final class PresetPreviewTests: XCTestCase {
    func testHoverPreviewShowsTheLookWithoutTouchingTheStack() throws {
        let editor = try TestSupport.makeEditorModel(gray: 100)
        let before = TestSupport.averageBrightness(try XCTUnwrap(editor.displayImage))

        var look = EditStack()
        look.exposure = 2
        let preset = DevelopPreset(name: "Bright", editStack: look)

        editor.beginPresetPreview(preset, amount: 1)
        let during = TestSupport.averageBrightness(try XCTUnwrap(editor.displayImage))
        XCTAssertGreaterThan(during, before + 0.05, "the canvas shows the candidate")
        XCTAssertEqual(editor.editStack.exposure, 0, "the stack is untouched")

        editor.endPresetPreview(preset)
        let after = TestSupport.averageBrightness(try XCTUnwrap(editor.displayImage))
        XCTAssertEqual(after, before, accuracy: 0.01, "mouse-out reverts")
    }

    /// Rapid row-to-row hovers deliver end(old) after begin(new) in no
    /// guaranteed order; ending a preview that is not the current one must
    /// not kill the current one.
    func testEndingAStalePreviewDoesNotClearTheCurrentOne() throws {
        let editor = try TestSupport.makeEditorModel(gray: 100)
        let a = DevelopPreset(name: "A", editStack: EditStack())
        var brightLook = EditStack(); brightLook.exposure = 2
        let b = DevelopPreset(name: "B", editStack: brightLook)

        editor.beginPresetPreview(a, amount: 1)
        editor.beginPresetPreview(b, amount: 1)
        editor.endPresetPreview(a) // the stale end arrives late
        let shown = TestSupport.averageBrightness(try XCTUnwrap(editor.displayImage))
        XCTAssertGreaterThan(shown, 0.45, "B's preview survives A's late mouse-out")
    }

    func testClickApplyIsOneUndoableStep() throws {
        let editor = try TestSupport.makeEditorModel(gray: 100)
        var look = EditStack(); look.exposure = 1.5
        editor.applyPreset(DevelopPreset(name: "P", editStack: look), amount: 0.5)
        XCTAssertEqual(editor.editStack.exposure, 0.75, accuracy: 1e-9)
        editor.commitEdit()
        XCTAssertEqual(editor.undoDepth, 1)
    }
}

final class PresetStorageTests: XCTestCase {
    func testFolderPathParsesSlashesAndIgnoresBlanks() {
        XCTAssertEqual(DevelopPreset(name: "x", group: "Portra/Warm",
                                     editStack: EditStack()).folderPath, ["Portra", "Warm"])
        XCTAssertEqual(DevelopPreset(name: "x", group: "User Presets",
                                     editStack: EditStack()).folderPath, ["User Presets"])
        XCTAssertEqual(DevelopPreset(name: "x", group: "  ",
                                     editStack: EditStack()).folderPath, ["User Presets"])
    }

    @MainActor
    func testExportImportRoundTripsThroughJSONWithFreshIdentities() throws {
        let app = AppModel(catalog: try TestSupport.inMemoryCatalog(),
                           thumbnails: TestSupport.tempThumbnails())
        var look = EditStack(); look.exposure = 1.2; look.color.grading.global.saturation = 15
        app.savePreset(named: "Roll Look", from: look, group: "Rolls/2026")

        let data = try XCTUnwrap(app.exportedPresetData())
        let other = AppModel(catalog: try TestSupport.inMemoryCatalog(),
                             thumbnails: TestSupport.tempThumbnails())
        XCTAssertEqual(other.importPresetData(data), 1)
        let imported = try XCTUnwrap(other.presets.first)
        XCTAssertEqual(imported.name, "Roll Look")
        XCTAssertEqual(imported.editStack, look, "the EditStack coding is shared verbatim")
        XCTAssertNotEqual(imported.id, app.presets.first?.id,
                          "imports mint fresh ids so re-import never clobbers")
    }
}
