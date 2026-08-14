import CoreGraphics
import Foundation
import XCTest
@testable import PhotoEditor

/// The wheel's geometry (pure) and the Global zone's decode contract.
final class ColorWheelTests: XCTestCase {
    func testPuckRoundTripsHueAndSaturation() {
        let offset = ColorWheelMath.puckOffset(hue: 137, saturation: 62, radius: 60)
        let value = ColorWheelMath.value(atOffset: offset, radius: 60)
        XCTAssertEqual(value.hue, 137, accuracy: 0.01)
        XCTAssertEqual(value.saturation, 62, accuracy: 0.01)
    }

    func testDraggingPastTheRimClampsSaturationAtFull() {
        let value = ColorWheelMath.value(atOffset: CGSize(width: 500, height: 0), radius: 60)
        XCTAssertEqual(value.saturation, 100)
        XCTAssertEqual(value.hue, 0, accuracy: 0.01)
    }

    func testTheCentreIsSaturationZero() {
        XCTAssertEqual(ColorWheelMath.value(atOffset: .zero, radius: 60).saturation, 0)
    }

    // MARK: Global zone — the plan's one new persisted colour field

    func testAStackWrittenBeforeGlobalDecodesToANeutralGlobalZone() throws {
        // Exactly what an existing catalog row contains: a grading dict with
        // three zones and no "global" key.
        let json = """
        {"shadows": {"hue": 220, "saturation": 30, "luminance": 0},
         "midtones": {"hue": 0, "saturation": 0, "luminance": 0},
         "highlights": {"hue": 40, "saturation": 20, "luminance": 0},
         "blending": 50, "balance": 0}
        """
        let grading = try JSONDecoder().decode(ColorGrading.self, from: Data(json.utf8))
        XCTAssertEqual(grading.global, ColorGradeZone(), "absent → exact no-op")
        XCTAssertEqual(grading.shadows.hue, 220)
    }

    /// Bit-for-bit, CPU-side: the LUT built for an old-decoded grading equals
    /// the LUT built for the same grading constructed today. Byte equality of
    /// cube data is the strongest render-identity proof available without a GPU.
    func testGlobalAtDefaultLeavesTheCubeDataByteIdentical() throws {
        var settings = ColorSettings()
        settings.grading.shadows.hue = 220
        settings.grading.shadows.saturation = 30

        var withExplicitNeutralGlobal = settings
        withExplicitNeutralGlobal.grading.global = ColorGradeZone()

        XCTAssertEqual(ColorCubeBuilder.cubeData(for: settings),
                       ColorCubeBuilder.cubeData(for: withExplicitNeutralGlobal))
    }
}
