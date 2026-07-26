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
}
