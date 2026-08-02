import CoreGraphics
import XCTest
@testable import PhotoEditor

/// The View menu's toggles, checked the same way the sliders are.
///
/// A toggle bound to a property nothing downstream reads looks identical, from
/// the menu, to one that works: the checkmark still moves. These assert that
/// the canvas — or, for the clipping diagnostics, the number the readout
/// prints — actually responds.
///
/// Renders are synchronous under XCTest (see `EditorModel.renderSynchronously`),
/// so there is nothing to wait for.
final class DisplayToggleConformanceTests: XCTestCase {
    private func makeEditor(gray: UInt8 = 128,
                            detailed: Bool = false,
                            editStack: EditStack = EditStack()) throws -> (EditorModel, URL) {
        let url = detailed
            ? try TestSupport.makeTempDetailPNG()
            : try TestSupport.makeTempPNG(gray: gray)
        let catalog = try TestSupport.inMemoryCatalog()
        let entry = TestSupport.makeEntry(fileURL: url, editStack: editStack)
        try catalog.save(entry)
        let editor = EditorModel(
            entry: entry, catalog: catalog,
            thumbnails: TestSupport.tempThumbnails(), commitDelay: 60
        )
        return (editor, url)
    }

    private func bytes(_ image: CGImage) throws -> Data {
        try XCTUnwrap(image.dataProvider?.data as Data?)
    }

    /// Show Original must actually show the original.
    func testShowOriginalDisplaysTheUneditedFrame() throws {
        var stack = EditStack()
        stack.exposure = 1.5
        let (editor, url) = try makeEditor(editStack: stack)
        defer { try? FileManager.default.removeItem(at: url) }

        let developed = TestSupport.averageBrightness(try XCTUnwrap(editor.displayImage))

        editor.isShowingBefore = true
        let original = TestSupport.averageBrightness(try XCTUnwrap(editor.displayImage))
        XCTAssertLessThan(original, developed - 0.05,
                          "Show Original displayed the developed frame.")

        editor.isShowingBefore = false
        XCTAssertEqual(TestSupport.averageBrightness(try XCTUnwrap(editor.displayImage)),
                       developed, accuracy: 0.01,
                       "Returning from Show Original did not restore the develop.")
    }

    /// Focus peaking must draw something. It is chrome rather than an edit, so
    /// the assertion is only that the canvas changes and the edit stack does
    /// not.
    ///
    /// Needs a frame with edges: peaking marks what is in focus, and on a flat
    /// patch there is correctly nothing to mark.
    func testFocusPeakingChangesTheCanvasWithoutEditingThePhoto() throws {
        let (editor, url) = try makeEditor(detailed: true)
        defer { try? FileManager.default.removeItem(at: url) }

        let before = try bytes(try XCTUnwrap(editor.displayImage))
        let stackBefore = editor.editStack

        editor.isFocusPeakingEnabled = true
        XCTAssertNotEqual(before, try bytes(try XCTUnwrap(editor.displayImage)),
                          "Focus peaking left the canvas untouched.")
        XCTAssertEqual(stackBefore, editor.editStack,
                       "Focus peaking is an overlay and must not edit the photo.")

        editor.isFocusPeakingEnabled = false
        XCTAssertEqual(before, try bytes(try XCTUnwrap(editor.displayImage)),
                       "Turning focus peaking off did not remove it.")
    }

    /// The mask overlay tints the selected mask red. With no mask selected
    /// there is nothing to tint, so the toggle is correctly inert — asserting
    /// otherwise would be asserting a bug.
    func testMaskOverlayTintsTheSelectedMask() throws {
        let (editor, url) = try makeEditor()
        defer { try? FileManager.default.removeItem(at: url) }

        // Adds the mask and selects it, which is what the overlay needs.
        editor.addLocalAdjustment(.radial)
        editor.editStack.localAdjustments[0].exposure = 1
        XCTAssertEqual(editor.selectedMaskIndex, 0, "the new mask must be selected")

        let before = try bytes(try XCTUnwrap(editor.displayImage))
        editor.isShowingMaskOverlay = true
        XCTAssertNotEqual(before, try bytes(try XCTUnwrap(editor.displayImage)),
                          "The mask overlay did not tint anything.")

        editor.isShowingMaskOverlay = false
        XCTAssertEqual(before, try bytes(try XCTUnwrap(editor.displayImage)),
                       "Turning the mask overlay off did not remove it.")
    }

    /// The clipping toggles drive a numeric readout rather than the image, so
    /// what has to be true is that the numbers behind it are real.
    ///
    /// "Clipped" means mass in the outermost histogram bin, so the fixtures
    /// have to be driven all the way to the rail — a merely very dark frame is
    /// not a crushed one, and the diagnostic is right to say so.
    func testClippingDiagnosticsReportRealClipping() throws {
        var blown = EditStack()
        blown.exposure = 3
        let (editor, url) = try makeEditor(gray: 240, editStack: blown)
        defer { try? FileManager.default.removeItem(at: url) }

        editor.showsHighlightClipping = true
        XCTAssertTrue(editor.histogram.isClippingHighlights,
                      "Three stops over a near-white frame must register as clipped.")
        XCTAssertGreaterThan(editor.histogram.highlightClippedFraction, 0.5)

        var crushed = EditStack()
        crushed.exposure = -5
        let (dark, darkURL) = try makeEditor(gray: 10, editStack: crushed)
        defer { try? FileManager.default.removeItem(at: darkURL) }

        dark.showsShadowClipping = true
        XCTAssertTrue(dark.histogram.isClippingShadows,
                      "Five stops under a near-black frame must register as crushed.")
        XCTAssertGreaterThan(dark.histogram.shadowClippedFraction, 0.5)
    }

    /// …and a well-exposed frame must not report either, or the warning means
    /// nothing.
    func testAWellExposedFrameReportsNoClipping() throws {
        let (editor, url) = try makeEditor(gray: 128)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertFalse(editor.histogram.isClippingHighlights)
        XCTAssertFalse(editor.histogram.isClippingShadows)
    }
}
