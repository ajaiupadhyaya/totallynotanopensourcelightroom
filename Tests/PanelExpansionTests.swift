import Foundation
import XCTest
@testable import PhotoEditor

final class PanelExpansionTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "petest-solo-\(UUID().uuidString)"
    private let titles = ["Film", "Light", "Effects"]

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testSoloOpensTheChosenSectionAndFoldsTheRest() {
        PanelExpansion.solo("Light", among: titles, defaults: defaults)
        XCTAssertTrue(defaults.bool(forKey: PanelExpansion.key("Light")))
        XCTAssertFalse(defaults.bool(forKey: PanelExpansion.key("Film")))
        XCTAssertFalse(defaults.bool(forKey: PanelExpansion.key("Effects")))
        XCTAssertTrue(PanelExpansion.isSolo("Light", among: titles, defaults: defaults))
    }

    func testSoloingAnotherSectionMovesTheSolo() {
        PanelExpansion.solo("Light", among: titles, defaults: defaults)
        PanelExpansion.solo("Effects", among: titles, defaults: defaults)
        XCTAssertFalse(PanelExpansion.isSolo("Light", among: titles, defaults: defaults))
        XCTAssertTrue(PanelExpansion.isSolo("Effects", among: titles, defaults: defaults))
    }

    func testTheKeysAreTheSectionsOwnPersistenceKeys() {
        XCTAssertEqual(PanelExpansion.key("Tone Curve"), "panel.v3.expanded.Tone Curve",
                       "solo writes the exact keys PanelSection's @AppStorage reads")
    }

    func testTwoOpenSectionsAreNotASolo() {
        PanelExpansion.solo("Light", among: titles, defaults: defaults)
        defaults.set(true, forKey: PanelExpansion.key("Film"))
        XCTAssertFalse(PanelExpansion.isSolo("Light", among: titles, defaults: defaults))
    }
}

@MainActor
final class LightsOutTests: XCTestCase {
    func testLCyclesOffDimDarkOff() {
        let workspace = WorkspaceModel()
        XCTAssertEqual(workspace.lightsOut, .off)
        workspace.cycleLightsOut()
        XCTAssertEqual(workspace.lightsOut, .dim)
        workspace.cycleLightsOut()
        XCTAssertEqual(workspace.lightsOut, .dark)
        workspace.cycleLightsOut()
        XCTAssertEqual(workspace.lightsOut, .off)
    }

    func testVeilOpacityIsMonotoneAndAchromaticZeroAtOff() {
        XCTAssertEqual(WorkspaceModel.LightsOut.off.veilOpacity, 0)
        XCTAssertLessThan(WorkspaceModel.LightsOut.dim.veilOpacity,
                          WorkspaceModel.LightsOut.dark.veilOpacity)
        XCTAssertLessThan(WorkspaceModel.LightsOut.dark.veilOpacity, 1,
                          "dark dims the chrome; it does not delete it")
    }
}
