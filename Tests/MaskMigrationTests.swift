import CoreGraphics
import XCTest
@testable import PhotoEditor

/// Edit stacks are JSON in SQLite. Every mask written by 1.2.x has its shape
/// stored flat on the adjustment, with no `components` key at all. Those rows
/// must come back as one-component masks with their geometry intact — a
/// regression here silently destroys real edits on upgrade.
///
/// The blobs below are the genuine 1.2.x wire format, reproduced by encoding
/// the pre-1.3 `LocalAdjustment` with `JSONEncoder`. Note in particular that
/// `CGPoint` serialises as a **two-element array**, not `{"x":…,"y":…}` —
/// writing the fixtures the intuitive way would test a dialect no catalog on
/// disk has ever contained.
final class MaskMigrationTests: XCTestCase {
    private func decodeStack(_ json: String) throws -> EditStack {
        try JSONDecoder().decode(EditStack.self, from: Data(json.utf8))
    }

    func testLegacyRadialMaskBecomesOneComponent() throws {
        let stack = try decodeStack("""
        {"exposure":0.5,"localAdjustments":[{
          "id":"11111111-1111-1111-1111-111111111111",
          "shape":"radial","isEnabled":false,"isInverted":true,
          "center":[0.3,0.7],"radiusX":0.4,"radiusY":0.15,"feather":0.8,
          "exposure":-1.25,"warmth":30
        }]}
        """)

        let adjustment = try XCTUnwrap(stack.localAdjustments.first)
        XCTAssertEqual(adjustment.components.count, 1)

        let component = try XCTUnwrap(adjustment.components.first)
        XCTAssertEqual(component.shape, .radial)
        XCTAssertEqual(component.center.x, 0.3, accuracy: 1e-9)
        XCTAssertEqual(component.center.y, 0.7, accuracy: 1e-9)
        XCTAssertEqual(component.radiusX, 0.4, accuracy: 1e-9)
        XCTAssertEqual(component.radiusY, 0.15, accuracy: 1e-9)
        XCTAssertEqual(component.feather, 0.8, accuracy: 1e-9)

        XCTAssertTrue(adjustment.isInverted, "Whole-mask invert stays on the adjustment.")
        XCTAssertFalse(component.isInverted, "It must not be copied onto the component too.")
        XCTAssertEqual(adjustment.exposure, -1.25, accuracy: 1e-9)
        XCTAssertEqual(adjustment.warmth, 30, accuracy: 1e-9)

        XCTAssertEqual(adjustment.id, UUID(uuidString: "11111111-1111-1111-1111-111111111111"),
                       "The adjustment's identity must survive migration too.")
        XCTAssertFalse(adjustment.isEnabled,
                       "isEnabled must round-trip from the fixture's false, not silently default to true.")
    }

    func testLegacyLinearMaskKeepsItsEndpoints() throws {
        let stack = try decodeStack("""
        {"localAdjustments":[{
          "shape":"linear",
          "startPoint":[0.5,0.95],"endPoint":[0.5,0.35]
        }]}
        """)

        let component = try XCTUnwrap(stack.localAdjustments.first?.components.first)
        XCTAssertEqual(component.shape, .linear)
        XCTAssertEqual(component.startPoint.y, 0.95, accuracy: 1e-9)
        XCTAssertEqual(component.endPoint.y, 0.35, accuracy: 1e-9)
    }

    func testLegacyBrushMaskKeepsItsStrokes() throws {
        let stack = try decodeStack("""
        {"localAdjustments":[{
          "shape":"brush","brushSize":0.09,"brushFeather":0.4,"brushFlow":0.55,
          "brushStrokes":[{"points":[[0.2,0.3],[0.4,0.5]],
                           "radius":0.09,"feather":0.4,"flow":0.55}]
        }]}
        """)

        let component = try XCTUnwrap(stack.localAdjustments.first?.components.first)
        XCTAssertEqual(component.shape, .brush)
        XCTAssertEqual(component.brushSize, 0.09, accuracy: 1e-9)
        XCTAssertEqual(component.brushStrokes.count, 1)
        XCTAssertEqual(component.brushStrokes.first?.points.count, 2)
    }

    /// A stack already written in the new format must be left alone.
    func testModernStackIsNotOverwrittenByTheLegacyPath() throws {
        let stack = try decodeStack("""
        {"localAdjustments":[{
          "shape":"linear",
          "components":[
            {"shape":"luminance","luminanceMin":0.6,"combine":"add"},
            {"shape":"radial","combine":"intersect"}
          ]
        }]}
        """)

        let adjustment = try XCTUnwrap(stack.localAdjustments.first)
        XCTAssertEqual(adjustment.components.count, 2,
                       "The legacy shape key must not clobber a real component list.")
        XCTAssertEqual(adjustment.components[0].shape, .luminance)
        XCTAssertEqual(adjustment.components[0].luminanceMin, 0.6, accuracy: 1e-9)
        XCTAssertEqual(adjustment.components[1].combine, .intersect)
    }

    /// An emptied mask must come back empty, not carrying a gradient nobody
    /// placed. `lenient` cannot tell "key absent" from "key present but empty",
    /// so the decoder has to ask whether the key exists.
    func testAnExplicitlyEmptyComponentListStaysEmpty() throws {
        let stack = try decodeStack("""
        {"localAdjustments":[{"components":[],"exposure":-2}]}
        """)

        let adjustment = try XCTUnwrap(stack.localAdjustments.first)
        XCTAssertTrue(adjustment.components.isEmpty,
                      "An emptied mask must not be mistaken for a pre-1.3 one.")
        XCTAssertEqual(adjustment.exposure, -2, accuracy: 1e-9)
    }

    /// Encoding must not write the legacy keys back out.
    ///
    /// Checked against the adjustment's **own** top-level keys rather than a
    /// substring of the whole document: `radiusX` and friends legitimately
    /// live on the nested components now, so a substring scan would be looking
    /// for something that is supposed to be there.
    func testEncodingOmitsLegacyKeys() throws {
        var adjustment = LocalAdjustment(shape: .radial)
        adjustment.exposure = 1
        let data = try JSONEncoder().encode(adjustment)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(
            Set(object.keys),
            ["id", "isEnabled", "isInverted", "components",
             "exposure", "contrast", "highlights", "shadows", "saturation", "warmth"],
            "Legacy keys are read on the way in and never written back."
        )
        XCTAssertEqual((object["components"] as? [Any])?.count, 1)
    }

    /// `encode(to:)` is hand-written, so a property added later can silently
    /// go unencoded. Populating every field and asserting round-trip equality
    /// is what catches that.
    func testEveryFieldSurvivesARoundTrip() throws {
        var adjustment = LocalAdjustment(shape: .radial)
        adjustment.isEnabled = false
        adjustment.isInverted = true
        adjustment.exposure = -1.5
        adjustment.contrast = 12
        adjustment.highlights = -30
        adjustment.shadows = 44
        adjustment.saturation = -18
        adjustment.warmth = 27
        adjustment.components[0].combine = .intersect
        adjustment.components[0].refine = MaskRefinement(blur: 0.3, shift: -0.4)

        let data = try JSONEncoder().encode(adjustment)
        let decoded = try JSONDecoder().decode(LocalAdjustment.self, from: data)
        XCTAssertEqual(decoded, adjustment)
    }

    func testMigratedMaskStillRenders() throws {
        let stack = try decodeStack("""
        {"localAdjustments":[{
          "shape":"radial","center":[0.5,0.5],
          "radiusX":0.3,"radiusY":0.3,"feather":0.2,"exposure":-2.0
        }]}
        """)

        let source = TestSupport.solidImage(red: 0.5, green: 0.5, blue: 0.5, size: 200)
        let result = EditRenderer().render(source: source, stack: stack)

        let inside = TestSupport.readColor(
            result.cropped(to: CGRect(x: 94, y: 94, width: 12, height: 12))).red
        let outside = TestSupport.readColor(
            result.cropped(to: CGRect(x: 4, y: 4, width: 12, height: 12))).red

        XCTAssertLessThan(inside, outside - 0.15,
                          "A migrated mask must still darken where it always did.")
    }
}
