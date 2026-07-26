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
        let snapshotsBefore = model.snapshots.count
        model.upgradeToProcessVersion2()
        XCTAssertEqual(model.editStack.processVersion, 2)
        XCTAssertEqual(model.editStack.contrast, 30, "slider values are kept — only the engine changes")
        XCTAssertEqual(model.snapshots.count, snapshotsBefore + 1, "must snapshot before upgrading")
        // Idempotent.
        model.upgradeToProcessVersion2()
        XCTAssertEqual(model.snapshots.count, snapshotsBefore + 1)
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
