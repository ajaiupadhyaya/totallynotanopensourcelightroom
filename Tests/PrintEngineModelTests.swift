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
    /// base — a better Dmin should immediately improve Dmax, gamma, and
    /// exposure too.
    ///
    /// Needs a fixture with real tonal structure, not the flat-grey default:
    /// on a flat image every possible sample coincides with Auto's own
    /// percentile estimate, so a test built on it can't tell "the re-solve
    /// ran and changed nothing because the numbers happen to agree" apart
    /// from "the re-solve never ran at all" — asserting only `baseOrigin ==
    /// .sampled` would stay green even with the re-solve deleted, since
    /// `applySampledBase` writes that field unconditionally.
    ///
    /// `makeTempDetailPNG`'s checkerboard (see `TestSupport`) gives two
    /// distinct block values, 40 and 215, evenly split — so Auto's unsampled
    /// 98th-percentile Dmin estimate lands in the bright (215) group. The
    /// corner sampled below is the dark (40) group instead (verified
    /// empirically against `EditorModel`'s actual bottom-left-origin
    /// `CIImage` orientation — the *other* diagonal corner coincides with
    /// the bright estimate and would silently reintroduce the vacuous case),
    /// so the sampled base is genuinely far from what Auto already had, and
    /// every print-side output the re-solve touches has to move.
    func testEyedropperResolvesWithSampledBase() throws {
        let url = try TestSupport.makeTempDetailPNG()
        let catalog = try TestSupport.inMemoryCatalog()
        let entry = TestSupport.makeEntry(fileURL: url)
        try catalog.save(entry)
        let model = EditorModel(entry: entry, catalog: catalog,
                                thumbnails: TestSupport.tempThumbnails(), commitDelay: 60)

        model.autoConvertNegative()
        let solvedDmax = model.editStack.filmNegative.print.dmax
        let solvedGamma = model.editStack.filmNegative.print.gamma
        let solvedExposure = model.editStack.filmNegative.print.exposure

        model.sampleFilmBase(inUnitRect: CGRect(x: 0, y: 0.9, width: 0.1, height: 0.1))

        XCTAssertEqual(model.editStack.filmNegative.baseOrigin, .sampled)
        // dmax/gamma/exposure are written only by the density re-solve —
        // applySampledBase itself never touches them — so this fails if the
        // `conversionModel == .density` re-solve gate is ever deleted.
        let resolveRan = model.editStack.filmNegative.print.dmax != solvedDmax
            || model.editStack.filmNegative.print.gamma != solvedGamma
            || model.editStack.filmNegative.print.exposure != solvedExposure
        XCTAssertTrue(resolveRan,
                      "sampling a base far from Auto's estimate should move the re-solved print values")
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
