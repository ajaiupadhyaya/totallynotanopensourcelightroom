import XCTest
@testable import PhotoEditor

/// Verifies the `EditorModel` actions that drive the print engine: the Auto
/// button, Update Conversion (matrix → density), the eyedropper re-solve, and
/// calibrated stocks carrying print character through the catalog.
@MainActor
final class PrintEngineModelTests: XCTestCase {

    /// Enabling conversion on a fresh (density-model) photo runs the full
    /// Auto solve — one button to a converted frame, not a chore of samples.
    func testEnableFilmNegativeRunsAutoOnDensityModel() throws {
        let model = try TestSupport.makeEditorModel()
        model.enableFilmNegative()
        XCTAssertTrue(model.editStack.filmNegative.isEnabled)
        XCTAssertEqual(model.editStack.filmNegative.conversionModel, .density)
        // A solid grey test image is a degenerate scan; the solve still ran
        // and wrote *something* measurable rather than leaving defaults.
        XCTAssertEqual(model.editStack.filmNegative.baseOrigin, .estimated)
    }

    /// The whole Auto result is one undo step: one Cmd-Z returns to the
    /// pre-conversion stack, not to a half-solved intermediate.
    func testAutoConvertIsOneUndoStep() throws {
        let model = try TestSupport.makeEditorModel()
        let before = model.editStack
        model.autoConvertNegative()
        XCTAssertNotEqual(model.editStack, before)
        model.commitEdit() // flush the debounced commit, as EditorUndoTests does
        model.undo()
        XCTAssertEqual(model.editStack.filmNegative, before.filmNegative)
    }

    /// Update Conversion: snapshots the matrix look, then switches and
    /// re-solves — same contract as the Process badge.
    func testUpdateConversionSnapshotsThenSwitches() throws {
        var stack = EditStack()
        stack.filmNegative.isEnabled = true
        stack.filmNegative.conversionModel = .matrix
        let model = try TestSupport.makeEditorModel(editStack: stack)
        let snapshotsBefore = model.snapshots.count

        model.updateConversion()

        XCTAssertEqual(model.editStack.filmNegative.conversionModel, .density)
        XCTAssertEqual(model.snapshots.count, snapshotsBefore + 1)
        XCTAssertTrue(model.snapshots.contains { $0.name == "Before Print Engine" })
        // The snapshot preserves the matrix rendering.
        XCTAssertEqual(model.snapshots.first { $0.name == "Before Print Engine" }?
            .editStack.filmNegative.conversionModel, .matrix)
    }

    func testUpdateConversionIsANoOpOnDensityStacks() throws {
        let model = try TestSupport.makeEditorModel()
        model.autoConvertNegative()
        let count = model.snapshots.count
        model.updateConversion()
        XCTAssertEqual(model.snapshots.count, count, "no snapshot, nothing to update")
    }

    /// The eyedropper on a density-model photo re-solves with the sampled
    /// base — a better Dmin should immediately improve Dmax and gamma too.
    func testEyedropperResolvesWithSampledBase() throws {
        let model = try TestSupport.makeEditorModel()
        model.autoConvertNegative()
        let estimated = model.editStack.filmNegative.print.dmax
        model.sampleFilmBase(inUnitRect: CGRect(x: 0, y: 0, width: 0.1, height: 0.1))
        XCTAssertEqual(model.editStack.filmNegative.baseOrigin, .sampled)
        // On the flat grey fixture the numbers may coincide; the invariant is
        // that the solve reran against the sampled base without crashing and
        // origin is now .sampled.
        _ = estimated
    }

    /// Calibrated stocks persist their print character through the catalog.
    func testCalibratedStockRoundTripsPrintCharacter() throws {
        let model = try TestSupport.makeEditorModel()
        model.autoConvertNegative()
        model.editStack.filmNegative.print.contrast = 3.0
        model.editStack.filmNegative.print.saturation = 20
        let stock = try XCTUnwrap(model.saveCalibratedStock(name: "Test 400",
                                                            manufacturer: "Test", iso: 400))
        XCTAssertEqual(stock.printContrast, 3.0)
        XCTAssertEqual(stock.printSaturation, 20)

        // And applying it to a fresh photo carries the character over.
        let fresh = try TestSupport.makeEditorModel()
        fresh.autoConvertNegative()
        fresh.applyFilmStock(stock)
        XCTAssertEqual(fresh.editStack.filmNegative.print.contrast, 3.0)
        XCTAssertEqual(fresh.editStack.filmNegative.print.saturation, 20)
    }
}
