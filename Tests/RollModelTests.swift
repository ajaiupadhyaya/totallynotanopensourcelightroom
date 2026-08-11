import CoreImage
import XCTest
@testable import PhotoEditor

final class RollModelTests: XCTestCase {
    private func entry(_ name: String, stack: EditStack = EditStack()) -> CatalogEntry {
        CatalogEntry(id: UUID(), fileURL: URL(fileURLWithPath: "/tmp/\(name).tif"),
                     dateImported: Date(), editStack: stack, thumbnailPath: nil)
    }

    func testConversionStacksShareConstantsAndKeepSampledBases() throws {
        var sampledStack = EditStack()
        sampledStack.filmNegative.baseColor = FilmColor(red: 0.9, green: 0.7, blue: 0.5)
        sampledStack.filmNegative.baseOrigin = .sampled
        sampledStack.filmNegative.isBaseSampled = true
        let entries = [entry("a"), entry("b", stack: sampledStack), entry("c")]
        let conversion = RollConversion(
            baseColor: FilmColor(red: 0.95, green: 0.75, blue: 0.55),
            baseOrigin: .estimated,
            gamma: DensityTriple(red: 1.1, green: 1.2, blue: 1.3),
            dmax: DensityTriple(red: 2.1, green: 2.0, blue: 1.9),
            castRed: 4, castGreen: 0, castBlue: -3, toneProfile: .labStandard)
        // Distinct pivots per frame — identical ones could not catch the
        // zip misindexing the group review flagged.
        let pivots = [DensityTriple(red: 1.0, green: 1.0, blue: 1.0),
                      DensityTriple(red: 1.1, green: 1.1, blue: 1.1),
                      DensityTriple(red: 1.2, green: 1.2, blue: 1.2)]
        let solution = RollSolution(conversion: conversion,
                                    frameExposures: [0.5, 0.7, 0.9],
                                    framePivots: pivots,
                                    degradedTerms: [])
        let stacks = RollModel.conversionStacks(entries: entries, solution: solution)
        XCTAssertEqual(stacks.count, 3)
        for (i, (_, stack)) in stacks.enumerated() {
            let f = stack.filmNegative
            XCTAssertTrue(f.isEnabled)
            XCTAssertEqual(f.conversionModel, .density)
            XCTAssertEqual(f.print.gamma, conversion.gamma)
            XCTAssertEqual(f.print.dmax, conversion.dmax)
            XCTAssertEqual(f.print.castRed, conversion.castRed)
            XCTAssertEqual(f.print.toneProfile, .labStandard)
            XCTAssertEqual(f.print.punch, FilmToneProfile.labStandard.punch)
            XCTAssertEqual(f.print.exposure, solution.frameExposures[i])
            XCTAssertEqual(f.print.gradePivot, pivots[i], "pivot must track its own frame")
            XCTAssertEqual(f.print.renderVersion, 2,
                           "roll conversion writes v2 semantics onto every frame")
            XCTAssertEqual(f.exposure, 0, "legacy EV must be zeroed, like Auto")
        }
        XCTAssertEqual(stacks[0].1.filmNegative.baseColor, conversion.baseColor)
        XCTAssertEqual(stacks[1].1.filmNegative.baseColor,
                       sampledStack.filmNegative.baseColor,
                       "a frame's own sampled base survives roll conversion")
        XCTAssertEqual(stacks[1].1.filmNegative.baseOrigin, .sampled)
    }

    func testCreateAndAssignRollNumbersFramesInOrder() throws {
        let store = try CatalogStore()
        let a = entry("a"), b = entry("b")
        try store.save(a); try store.save(b)
        let roll = Roll(id: UUID(), identifier: "r1", stock: nil, camera: nil,
                        lens: nil, exposureIndex: nil, pushPull: nil, developer: nil,
                        devNotes: nil, lab: nil, scanDate: nil,
                        dateCreated: Date(), conversion: nil)
        try store.saveRoll(roll)
        // Saved in REVERSE frame order, plus one entry with no roll at all —
        // pinning both the rollID filter and the frameNumber ordering, which
        // the group review found undiscriminated (insertion order happened
        // to match).
        let outsider = entry("outsider")
        try store.save(outsider)
        var ua = a; ua.rollID = roll.id; ua.frameNumber = 1
        var ub = b; ub.rollID = roll.id; ub.frameNumber = 2
        try store.save(ub); try store.save(ua)
        let inRoll = try store.entries(inRoll: roll.id)
        XCTAssertEqual(inRoll.map(\.frameNumber), [1, 2],
                       "ordering must come from frameNumber, not insertion")
        XCTAssertFalse(inRoll.contains { $0.id == outsider.id },
                       "entries without the rollID must not appear")
    }
}
