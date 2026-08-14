import CoreGraphics
import Foundation
import XCTest
@testable import PhotoEditor

final class ProcessVersionTests: XCTestCase {
    /// A stack saved by an older build has no processVersion key — it MUST
    /// decode as version 1, or every existing edit changes appearance.
    func testStackWithoutVersionKeyDecodesAsVersion1() throws {
        let legacyJSON = #"{"exposure": 0.5, "contrast": 25}"#.data(using: .utf8)!
        let stack = try JSONDecoder().decode(EditStack.self, from: legacyJSON)
        XCTAssertEqual(stack.processVersion, 1)
        XCTAssertEqual(stack.exposure, 0.5)
    }

    func testFreshStackIsVersion2() {
        XCTAssertEqual(EditStack().processVersion, 2)
    }

    func testVersionRoundTripsThroughCoding() throws {
        var stack = EditStack()
        stack.processVersion = 1
        let data = try JSONEncoder().encode(stack)
        let decoded = try JSONDecoder().decode(EditStack.self, from: data)
        XCTAssertEqual(decoded.processVersion, 1)
    }

    /// A decoded PV1 stack with no edits is still "neutral" for the purposes
    /// of import/thumbnail shortcuts, even though it != EditStack().
    func testNeutralEditIgnoresProcessVersion() throws {
        let legacyJSON = "{}".data(using: .utf8)!
        let stack = try JSONDecoder().decode(EditStack.self, from: legacyJSON)
        XCTAssertNotEqual(stack, EditStack())      // versions differ
        XCTAssertTrue(stack.isNeutralEdit)          // but no edits
        var edited = EditStack()
        edited.exposure = 1
        XCTAssertFalse(edited.isNeutralEdit)
    }

    func testNewFieldsDecodeLeniently() throws {
        let stack = try JSONDecoder().decode(EditStack.self, from: "{}".data(using: .utf8)!)
        XCTAssertEqual(stack.vignetteRoundness, 0)
        XCTAssertEqual(stack.vignetteFeather, 50)
        XCTAssertEqual(stack.vignetteHighlights, 0)
        XCTAssertEqual(stack.rawBoost, 100)
        XCTAssertFalse(stack.rawWBInitialized)
    }

    func testVersion1RendersThroughLegacyChainUnchanged() {
        // The known legacy bug: positive highlights is a no-op. If PV1 ever
        // stops reproducing it, the freeze broke.
        let renderer = EditRenderer()
        var stack = EditStack()
        stack.processVersion = 1
        stack.highlights = 100
        let source = TestSupport.solidImage(red: 0.6, green: 0.6, blue: 0.6, size: 32)
        let out = renderer.render(source: source, stack: stack)
        let color = TestSupport.readColor(out)
        XCTAssertEqual(color.red, 0.6, accuracy: 0.01,
                       "PV1 must keep the legacy no-op highlights bug")
    }

    func testUpgradeToProcessVersion2SnapshotsFirst() throws {
        let model = try TestSupport.makeEditorModel()
        model.editStack.processVersion = 1
        model.editStack.contrast = 30
        model.commitEdit()
        let snapshotsBefore = model.snapshots.count
        let undoBefore = model.undoDepth

        model.upgradeToProcessVersion2()
        XCTAssertEqual(model.editStack.processVersion, 2)
        XCTAssertEqual(model.editStack.contrast, 30, "slider values are kept — only the engine changes")
        XCTAssertEqual(model.snapshots.count, snapshotsBefore + 1, "must snapshot before upgrading")
        // The source here is a PNG, so there is no as-shot neutral to seed:
        // the non-RAW upgrade must be exactly the version bump it always was.
        XCTAssertEqual(model.editStack.whiteBalanceTemp, 6500)
        XCTAssertEqual(model.editStack.whiteBalanceTint, 0)
        XCTAssertFalse(model.editStack.rawWBInitialized)
        // …and one user-visible undo step, seeding or not.
        model.commitEdit()
        XCTAssertEqual(model.undoDepth, undoBefore + 1, "the upgrade must be a single undo step")

        // Idempotent.
        model.upgradeToProcessVersion2()
        XCTAssertEqual(model.snapshots.count, snapshotsBefore + 1)
    }

    // MARK: The decode/version invariant

    /// A stack as an older build would have saved it.
    private var legacyStack: EditStack {
        var stack = EditStack()
        stack.processVersion = 1
        return stack
    }

    /// The invariant: whatever replaces the stack, the decoded source must be
    /// the one that stack's renderer dispatches on. Undo across an upgrade is
    /// the sharpest case — the frozen PV1 chain would otherwise replay against
    /// PV2's non-default RAW decode, which is precisely what the process
    /// version exists to prevent.
    func testUndoAndRedoAcrossTheUpgradeReDecodeTheSource() throws {
        let model = try TestSupport.makeEditorModel(editStack: legacyStack)
        XCTAssertEqual(model.decodedProcessVersion, 1)
        model.commitEdit()

        model.upgradeToProcessVersion2()
        model.commitEdit()
        XCTAssertEqual(model.decodedProcessVersion, 2)

        model.undo()
        XCTAssertEqual(model.editStack.processVersion, 1)
        XCTAssertEqual(model.decodedProcessVersion, 1,
                       "undo popped the stack to PV1 but left a PV2 decode in place")
        XCTAssertFalse(model.isMissingFile, "the re-decode must actually succeed")
        XCTAssertNotNil(model.displayImage)

        model.redo()
        XCTAssertEqual(model.editStack.processVersion, 2)
        XCTAssertEqual(model.decodedProcessVersion, 2)
    }

    func testSnapshotRestoreAcrossTheVersionBoundaryReDecodes() throws {
        let model = try TestSupport.makeEditorModel(editStack: legacyStack)
        model.upgradeToProcessVersion2()
        XCTAssertEqual(model.decodedProcessVersion, 2)

        let snapshot = try XCTUnwrap(model.snapshots.first { $0.name == "Before Process Version 2" })
        model.applySnapshot(snapshot)
        XCTAssertEqual(model.editStack.processVersion, 1)
        XCTAssertEqual(model.decodedProcessVersion, 1)
    }

    func testHistoryRestoreAcrossTheVersionBoundaryReDecodes() throws {
        let model = try TestSupport.makeEditorModel(editStack: legacyStack)
        let opened = try XCTUnwrap(model.historyEvents.first)
        XCTAssertEqual(opened.stack.processVersion, 1)

        model.upgradeToProcessVersion2()
        XCTAssertEqual(model.decodedProcessVersion, 2)

        model.restoreHistoryEvent(opened)
        XCTAssertEqual(model.editStack.processVersion, 1)
        XCTAssertEqual(model.decodedProcessVersion, 1)
    }

    /// Reset replaces a PV1 stack with a fresh PV2 one, so it crosses the
    /// boundary in the other direction — and it must cross it *before* the
    /// as-shot adoption reads the source, or a RAW would adopt from a decode
    /// that has no filter.
    func testResetFromALegacyStackReDecodesUnderTheFreshVersion() throws {
        let model = try TestSupport.makeEditorModel(editStack: legacyStack)
        XCTAssertEqual(model.decodedProcessVersion, 1)

        model.resetAdjustments()
        XCTAssertEqual(model.editStack.processVersion, 2)
        XCTAssertEqual(model.decodedProcessVersion, 2)
        XCTAssertFalse(model.isMissingFile)
    }

    /// The invariant holds even for a bare field mutation, because it is
    /// enforced where every path meets: `editStack`'s observer.
    func testMutatingTheVersionDirectlyReDecodes() throws {
        let model = try TestSupport.makeEditorModel()
        XCTAssertEqual(model.decodedProcessVersion, 2)
        model.editStack.processVersion = 1
        XCTAssertEqual(model.decodedProcessVersion, 1)
    }

    // MARK: As-shot white balance adoption

    /// A RAW's as-shot neutral, standing in for what `CIRAWFilter` reports.
    private let asShot = (temperature: 5100.0, tint: 12.0)

    func testAdoptedStackSeedsAsShotWhiteBalanceExactlyOnce() throws {
        let adopted = try XCTUnwrap(EditorModel.adoptedStack(
            EditStack(), asShotTemperature: asShot.temperature, asShotTint: asShot.tint))
        XCTAssertEqual(adopted.whiteBalanceTemp, asShot.temperature)
        XCTAssertEqual(adopted.whiteBalanceTint, asShot.tint)
        XCTAssertTrue(adopted.rawWBInitialized)

        XCTAssertNil(EditorModel.adoptedStack(adopted, asShotTemperature: 4000, asShotTint: -30),
                     "an already-adopted stack must never be overwritten")
    }

    func testAdoptedStackDeclinesLegacyAndFilmNegativeStacks() {
        var legacy = EditStack()
        legacy.processVersion = 1
        XCTAssertNil(EditorModel.adoptedStack(legacy, asShotTemperature: asShot.temperature,
                                              asShotTint: asShot.tint),
                     "PV1 renders through the legacy chain, which never reads sensor-domain WB")

        var film = EditStack()
        film.filmNegative.isEnabled = true
        XCTAssertNil(EditorModel.adoptedStack(film, asShotTemperature: asShot.temperature,
                                              asShotTint: asShot.tint),
                     "a film-negative RAW renders through WhiteBalanceStage — different units")
    }

    /// The other half of the same boundary. `adoptedStack` refuses to PUT
    /// sensor-domain Kelvin into a film-negative stack; this refuses to LEAVE
    /// it there when the conversion turns on afterwards — which is the order
    /// that actually happens (open a RAW, adopt as-shot, then press Auto).
    ///
    /// Measured on the 2026-08-13 ProRAW corpus: every frame adopted its
    /// as-shot neutral (IMG_7192 at 3235K, IMG_7196 at 3082K) and then
    /// rendered through `WhiteBalanceStage`, which reads that field on
    /// `ColorScience`'s uv-offset scale. All 20 frames came out heavily blue —
    /// median RGB (0.079, 0.236, 0.615) on IMG_7192, against the perfectly
    /// neutral (0.214, 0.214, 0.214) the same frame gives once the field is
    /// back in rendered-domain units.
    func testFilmNegativeReturnsAdoptedWhiteBalanceToTheRenderedDomain() throws {
        let adopted = try XCTUnwrap(EditorModel.adoptedStack(
            EditStack(), asShotTemperature: asShot.temperature, asShotTint: asShot.tint))
        var converted = adopted
        converted.filmNegative.isEnabled = true

        let corrected = try XCTUnwrap(
            EditorModel.whiteBalanceDomainCorrected(converted),
            "a film-negative stack still flagged sensor-domain is the "
            + "inconsistent state — Kelvin read on the uv-offset scale")
        XCTAssertEqual(corrected.whiteBalanceTemp, EditStack().whiteBalanceTemp,
                       "must return to the rendered-domain neutral")
        XCTAssertEqual(corrected.whiteBalanceTint, EditStack().whiteBalanceTint)
        XCTAssertFalse(corrected.rawWBInitialized,
                       "clearing the flag is what lets turning the conversion "
                       + "back off re-adopt as-shot")
        // Nothing else moves.
        var expected = converted
        expected.whiteBalanceTemp = EditStack().whiteBalanceTemp
        expected.whiteBalanceTint = EditStack().whiteBalanceTint
        expected.rawWBInitialized = false
        XCTAssertEqual(corrected, expected)
    }

    func testWhiteBalanceDomainCorrectionDeclinesStacksItDoesNotOwn() throws {
        XCTAssertNil(EditorModel.whiteBalanceDomainCorrected(EditStack()),
                     "no conversion, no adoption — nothing to correct")

        let adopted = try XCTUnwrap(EditorModel.adoptedStack(
            EditStack(), asShotTemperature: asShot.temperature, asShotTint: asShot.tint))
        XCTAssertNil(EditorModel.whiteBalanceDomainCorrected(adopted),
                     "a RAW with no film conversion reads sensor-domain "
                     + "Kelvin correctly — leave it alone")

        // A rendered source (HEIC/JPEG) never adopts, so its film conversions
        // are already in the right units and must not be reset.
        var renderedFilm = EditStack()
        renderedFilm.filmNegative.isEnabled = true
        renderedFilm.whiteBalanceTemp = 7200
        renderedFilm.whiteBalanceTint = -14
        XCTAssertNil(EditorModel.whiteBalanceDomainCorrected(renderedFilm),
                     "these are the photographer's own rendered-domain values")
    }

    func testAdoptedStackChangesNothingElse() throws {
        var stack = EditStack()
        stack.exposure = 0.8
        stack.contrast = -20
        stack.vibrance = 35
        stack.rawBoost = 40
        stack.geometry.cropRect = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)

        let adopted = try XCTUnwrap(EditorModel.adoptedStack(
            stack, asShotTemperature: asShot.temperature, asShotTint: asShot.tint))

        var expected = stack
        expected.whiteBalanceTemp = asShot.temperature
        expected.whiteBalanceTint = asShot.tint
        expected.rawWBInitialized = true
        XCTAssertEqual(adopted, expected, "adoption must touch exactly three fields")
    }

    /// The upgrade path: a PV1 RAW has never had a chance to adopt (the guard
    /// above rejected it), so bumping the version makes the decision newly
    /// applicable on the very same stack — which is why it is a pure function
    /// rather than a load-time side effect.
    func testAdoptedStackSeedsAStackThatWasJustUpgraded() throws {
        var legacy = EditStack()
        legacy.processVersion = 1
        legacy.contrast = 30
        XCTAssertNil(EditorModel.adoptedStack(legacy, asShotTemperature: asShot.temperature,
                                              asShotTint: asShot.tint))

        var upgraded = legacy
        upgraded.processVersion = 2
        let adopted = try XCTUnwrap(EditorModel.adoptedStack(
            upgraded, asShotTemperature: asShot.temperature, asShotTint: asShot.tint))
        XCTAssertEqual(adopted.whiteBalanceTemp, asShot.temperature)
        XCTAssertEqual(adopted.whiteBalanceTint, asShot.tint)
        XCTAssertTrue(adopted.rawWBInitialized)
        XCTAssertEqual(adopted.contrast, 30)
    }

    /// Reset clears `rawWBInitialized` along with everything else, so the
    /// as-shot decision becomes applicable again — and must fold into the one
    /// undo step Reset already registers.
    func testResetIsASingleUndoStep() throws {
        let model = try TestSupport.makeEditorModel()
        model.editStack.exposure = 1.5
        model.commitEdit()
        let undoBefore = model.undoDepth

        model.resetAdjustments()
        model.commitEdit()
        XCTAssertEqual(model.undoDepth, undoBefore + 1)
        XCTAssertEqual(model.editStack, EditStack(),
                       "a non-RAW reset is still exactly a fresh stack")
    }

    func testNeutralStacksRenderIdenticallyUnderBothVersions() {
        let renderer = EditRenderer()
        let source = TestSupport.solidImage(red: 0.4, green: 0.5, blue: 0.6, size: 32)
        var v1 = EditStack(); v1.processVersion = 1
        let a = TestSupport.readColor(renderer.render(source: source, stack: v1))
        let b = TestSupport.readColor(renderer.render(source: source, stack: EditStack()))
        XCTAssertEqual(a.red, b.red, accuracy: 0.005)
        XCTAssertEqual(a.green, b.green, accuracy: 0.005)
        XCTAssertEqual(a.blue, b.blue, accuracy: 0.005)
    }
}
