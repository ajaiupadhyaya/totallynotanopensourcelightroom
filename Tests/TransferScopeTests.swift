import CoreGraphics
import Foundation
import XCTest
@testable import PhotoEditor

final class PipelineSectionTests: XCTestCase {
    func testTheFourteenSectionsCarryTheirPanelIndices() {
        XCTAssertEqual(PipelineSection.allCases.count, 14)
        XCTAssertEqual(PipelineSection.film.index, "01")
        XCTAssertEqual(PipelineSection.toneCurve.index, "11")
        XCTAssertEqual(PipelineSection.effects.index, "14")
    }

    func testIsModifiedMatchesThePanelSpineSemantics() {
        var stack = EditStack()
        XCTAssertTrue(PipelineSection.allCases.allSatisfy { !$0.isModified(in: stack) })
        stack.sharpenRadius = 3 // non-zero neutral: 1.5, the Detail predicate's edge
        XCTAssertTrue(PipelineSection.detail.isModified(in: stack))
        stack = EditStack()
        stack.vignetteFeather = 80 // neutral 50
        XCTAssertTrue(PipelineSection.effects.isModified(in: stack))
        stack = EditStack()
        stack.whiteBalanceTemp = 5000
        XCTAssertTrue(PipelineSection.whiteBalance.isModified(in: stack))
    }

    /// The gap fixes, asserted where they used to lie: the section copy
    /// carries every Effects field and the parametric curve — fields the old
    /// options path dropped on the floor.
    func testSectionCopyCarriesTheFieldsTheOldPathDropped() {
        var source = EditStack()
        source.vignetteRoundness = -60
        source.vignetteFeather = 90
        source.vignetteHighlights = 40
        source.toneCurveDarks = -30

        let scoped = EditStack().applying(source, scope: TransferScope.all)
        XCTAssertEqual(scoped.vignetteRoundness, -60)
        XCTAssertEqual(scoped.vignetteFeather, 90)
        XCTAssertEqual(scoped.vignetteHighlights, 40)
        XCTAssertEqual(scoped.toneCurveDarks, -30)

        // …and the options path is fixed too, so presets stop dropping them.
        let viaOptions = EditStack().applying(source, options: .init())
        XCTAssertEqual(viaOptions.vignetteFeather, 90)
        XCTAssertEqual(viaOptions.toneCurveDarks, -30)
    }

    func testScopingActuallyScopes() {
        var source = EditStack()
        source.exposure = 1.5
        source.saturation = 40
        let scoped = EditStack().applying(source,
                                          scope: TransferScope(sections: [.light]))
        XCTAssertEqual(scoped.exposure, 1.5)
        XCTAssertEqual(scoped.saturation, 0, "Presence was not in scope")
    }

    func testFilmCarriesTheLookButNeverTheScansOwnMeasurements() {
        var source = EditStack()
        source.filmNegative.isEnabled = true
        source.filmNegative.print.contrast = 3.2
        source.filmNegative.print.punch = 40
        source.filmNegative.print.castRed = 12
        source.filmNegative.baseColor = FilmColor(red: 0.9, green: 0.5, blue: 0.3)
        source.filmNegative.print.dmax = DensityTriple(red: 2.4, green: 2.2, blue: 1.9)
        source.filmNegative.print.exposure = 0.7

        let target = EditStack().applying(source, scope: TransferScope(sections: [.film]))
        XCTAssertTrue(target.filmNegative.isEnabled)
        XCTAssertEqual(target.filmNegative.print.contrast, 3.2)
        XCTAssertEqual(target.filmNegative.print.punch, 40)
        XCTAssertEqual(target.filmNegative.print.castRed, 12)
        XCTAssertEqual(target.filmNegative.baseColor, FilmNegativeSettings().baseColor,
                       "the base is measured from THIS scan — never pasted")
        XCTAssertEqual(target.filmNegative.print.dmax, PrintSettings().dmax,
                       "per-scan solve stays per-scan")
        XCTAssertEqual(target.filmNegative.print.exposure, 0)
    }

    func testDefaultScopeLeavesTheFrameAndRetouchAlone() {
        XCTAssertFalse(TransferScope.default.sections.contains(.frame))
        XCTAssertFalse(TransferScope.default.sections.contains(.retouch))
        XCTAssertEqual(TransferScope.all.sections.count, 14)
        XCTAssertTrue(TransferScope.none.sections.isEmpty)
    }

    func testModifiedScopeIsExactlyTheLitSpineSections() {
        var stack = EditStack()
        stack.exposure = 1
        stack.color.grading.global.saturation = 10
        XCTAssertEqual(TransferScope.modified(in: stack).sections, [.light, .colorGrade])
    }
}

@MainActor
final class PreviousCommandTests: XCTestCase {
    func testPreviousAppliesTheLastEditedFramesLookThroughTheRememberedScope() throws {
        let catalog = try TestSupport.inMemoryCatalog()
        let urlA = try TestSupport.makeTempPNG(gray: 100)
        let urlB = try TestSupport.makeTempPNG(gray: 180)
        defer {
            try? FileManager.default.removeItem(at: urlA)
            try? FileManager.default.removeItem(at: urlB)
        }
        let a = TestSupport.makeEntry(fileURL: urlA)
        let b = TestSupport.makeEntry(fileURL: urlB)
        try catalog.save(a)
        try catalog.save(b)
        let app = AppModel(catalog: catalog, thumbnails: TestSupport.tempThumbnails())

        app.open(a)
        app.editor?.editStack.exposure = 1.4
        app.editor?.editStack.geometry.cropRect = CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)
        app.open(b) // capture point — and the pending commit flush

        XCTAssertEqual(app.applyPreviousSettings(), 1)
        XCTAssertEqual(app.editor?.editStack.exposure ?? 0, 1.4, accuracy: 1e-9)
        XCTAssertEqual(app.editor?.editStack.geometry.cropRect, .unitFrame,
                       "the default scope leaves B's framing alone")
    }

    func testPreviousWithNoHistoryDoesNothing() throws {
        let app = AppModel(catalog: try TestSupport.inMemoryCatalog(),
                           thumbnails: TestSupport.tempThumbnails())
        XCTAssertEqual(app.applyPreviousSettings(), 0)
    }
}
