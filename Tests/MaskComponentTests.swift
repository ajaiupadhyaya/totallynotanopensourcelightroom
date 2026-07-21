import CoreGraphics
import XCTest
@testable import PhotoEditor

/// Verifies the mask component value type: its defaults, and that it decodes
/// leniently. Stacks are JSON in SQLite, so a component written by an older
/// build must never throw on the way back in.
final class MaskComponentTests: XCTestCase {
    func testDefaultsAreNeutral() {
        let component = MaskComponent(shape: .linear)
        XCTAssertEqual(component.combine, .add)
        XCTAssertTrue(component.isEnabled)
        XCTAssertFalse(component.isInverted)
        XCTAssertTrue(component.refine.isNeutral)
        XCTAssertNil(component.sampledColor)
    }

    func testRoundTripsThroughCodable() throws {
        var component = MaskComponent(shape: .colorRange)
        component.combine = .intersect
        component.isInverted = true
        component.refine = MaskRefinement(blur: 0.3, shift: -0.2)
        component.sampledColor = MaskColor(red: 0.2, green: 0.6, blue: 0.3)
        component.colorTolerance = 0.4
        component.luminanceMin = 0.25
        component.brushStrokes = [BrushStroke(points: [CGPoint(x: 0.1, y: 0.2)])]

        let data = try JSONEncoder().encode(component)
        let decoded = try JSONDecoder().decode(MaskComponent.self, from: data)
        XCTAssertEqual(decoded, component)
    }

    /// An almost-empty object must come back with every field at its default
    /// rather than throwing.
    func testDecodesLenientlyFromASparseObject() throws {
        let json = Data(#"{"shape":"radial"}"#.utf8)
        let decoded = try JSONDecoder().decode(MaskComponent.self, from: json)

        XCTAssertEqual(decoded.shape, .radial)
        XCTAssertEqual(decoded.combine, .add)
        XCTAssertEqual(decoded.radiusX, 0.3, accuracy: 1e-9)
        XCTAssertEqual(decoded.luminanceMax, 1.0, accuracy: 1e-9)
        XCTAssertTrue(decoded.refine.isNeutral)
    }

    func testRefinementDecodesLenientlyInsideAComponent() throws {
        let json = Data(#"{"shape":"brush","refine":{"blur":0.5}}"#.utf8)
        let decoded = try JSONDecoder().decode(MaskComponent.self, from: json)

        XCTAssertEqual(decoded.refine.blur, 0.5, accuracy: 1e-9)
        XCTAssertEqual(decoded.refine.shift, 0.0, accuracy: 1e-9,
                       "A missing key inside a nested Codable must not discard the sibling.")
    }

    func testUnsampledColorRangeDoesNotContribute() {
        var component = MaskComponent(shape: .colorRange)
        XCTAssertFalse(component.isContributing,
                       "An unsampled colour range must be skipped, not treated as empty.")
        component.sampledColor = MaskColor(red: 0.5, green: 0.5, blue: 0.5)
        XCTAssertTrue(component.isContributing)
    }

    func testDisabledComponentDoesNotContribute() {
        var component = MaskComponent(shape: .linear)
        component.isEnabled = false
        XCTAssertFalse(component.isContributing)
    }

    func testEmptyBrushDoesNotContribute() {
        let component = MaskComponent(shape: .brush)
        XCTAssertFalse(component.isContributing,
                       "A brush with no strokes selects nothing and must be skipped.")
    }
}
