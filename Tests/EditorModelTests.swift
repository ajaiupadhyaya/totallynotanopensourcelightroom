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

    /// An editor opened on the FilmSim crossover probe written to disk — the
    /// film-capable fixture. A flat gray PNG cannot exercise the profile
    /// solve (nothing to place) or the neutral picker (every patch already
    /// neutral), so the Minilab gesture tests open a real simulated negative.
    private func makeFilmEditor() throws -> (editor: EditorModel, url: URL) {
        let probe = FilmSim.negativeImage(dmin: FilmSim.c41Base,
                                          gammas: FilmSim.crossoverGammas, size: 128)
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("film-fixture-\(UUID().uuidString).png")
        let context = CIContext()
        try context.writePNGRepresentation(
            of: probe, to: url, format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let catalog = try TestSupport.inMemoryCatalog()
        let entry = TestSupport.makeEntry(fileURL: url)
        try catalog.save(entry)
        let editor = EditorModel(
            entry: entry, catalog: catalog,
            thumbnails: TestSupport.tempThumbnails(), commitDelay: 60
        )
        return (editor, url)
    }

    // MARK: Minilab gestures (Task 11)

    func testApplyToneProfileReSolvesInOneUndoStep() throws {
        let (model, url) = try makeFilmEditor()
        defer { try? FileManager.default.removeItem(at: url) }
        model.enableFilmNegative()
        // Deviation from the plan's sketch: gestures within the debounce
        // window coalesce into one undo step (house behavior), so the enable
        // must COMMIT before the profile switch for "one undo step" to mean
        // one step per gesture.
        model.commitEdit()
        let before = model.editStack
        XCTAssertEqual(model.editStack.filmNegative.print.toneProfile, .labStandard,
                       "first enable seeds Lab Standard (the spec's default)")
        model.applyToneProfile(.linear)
        XCTAssertEqual(model.editStack.filmNegative.print.toneProfile, .linear)
        XCTAssertEqual(model.editStack.filmNegative.print.punch, 0)
        XCTAssertNotEqual(model.editStack.filmNegative.print.exposure,
                          before.filmNegative.print.exposure,
                          "switching profiles re-solves the placement")
        model.commitEdit()
        model.undo()
        XCTAssertEqual(model.editStack, before, "profile switch is one undo step")
    }

    func testNeutralCastPickerRoutesAndWrites() throws {
        let (model, url) = try makeFilmEditor()
        defer { try? FileManager.default.removeItem(at: url) }
        model.enableFilmNegative()
        let before = model.editStack.filmNegative.print
        model.canvasPicker = .neutralCast
        model.handleCanvasClick(atUnitPoint: CGPoint(x: 0.5, y: 0.5))
        XCTAssertNil(model.canvasPicker, "picker is one-shot")
        let after = model.editStack.filmNegative.print
        XCTAssertTrue(after.castRed != before.castRed || after.castGreen != before.castGreen
                      || after.castBlue != before.castBlue,
                      "clicking a non-neutral patch must move the cast sliders")
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
