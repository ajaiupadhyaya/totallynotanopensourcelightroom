import CoreImage
import XCTest
@testable import PhotoEditor

/// Verifies crop, rotation, straightening, and flips.
final class GeometryTests: XCTestCase {
    /// A 400×200 landscape image, so orientation changes are visible in extents.
    private func landscape() -> CIImage {
        TestSupport.solidImage(red: 0.5, green: 0.5, blue: 0.5,
                               in: CGRect(x: 0, y: 0, width: 400, height: 200))
    }

    func testIdentityGeometryLeavesTheImageAlone() {
        let image = landscape()
        let result = GeometryTransform.apply(image, geometry: Geometry())
        XCTAssertEqual(result.extent, image.extent)
    }

    func testQuarterTurnSwapsWidthAndHeight() {
        var geometry = Geometry()
        geometry.rotation = .quarter

        let result = GeometryTransform.apply(landscape(), geometry: geometry)
        XCTAssertEqual(result.extent.width, 200, accuracy: 0.5)
        XCTAssertEqual(result.extent.height, 400, accuracy: 0.5)
    }

    func testHalfTurnKeepsDimensions() {
        var geometry = Geometry()
        geometry.rotation = .half

        let result = GeometryTransform.apply(landscape(), geometry: geometry)
        XCTAssertEqual(result.extent.width, 400, accuracy: 0.5)
        XCTAssertEqual(result.extent.height, 200, accuracy: 0.5)
    }

    func testRotationCyclesThroughFourQuarterTurns() {
        var rotation = Geometry.Rotation.none
        for _ in 0..<4 { rotation = rotation.next }
        XCTAssertEqual(rotation, .none)

        XCTAssertEqual(Geometry.Rotation.none.previous, .threeQuarter)
        XCTAssertEqual(Geometry.Rotation.quarter.previous, .none)
    }

    func testCropTakesTheRequestedFraction() {
        var geometry = Geometry()
        geometry.cropRect = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)

        let result = GeometryTransform.apply(landscape(), geometry: geometry)
        XCTAssertEqual(result.extent.width, 200, accuracy: 0.5)
        XCTAssertEqual(result.extent.height, 100, accuracy: 0.5)
        XCTAssertEqual(result.extent.origin.x, 0, accuracy: 0.5,
                       "A cropped image should be re-origined at zero.")
    }

    func testCropIsResolutionIndependent() {
        // The same normalized crop must select the same *region* of a preview
        // and of a full-resolution export -- that's why it isn't stored in
        // pixels.
        var geometry = Geometry()
        geometry.cropRect = CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.4)

        let small = TestSupport.solidImage(red: 0.5, green: 0.5, blue: 0.5,
                                           in: CGRect(x: 0, y: 0, width: 400, height: 200))
        let large = TestSupport.solidImage(red: 0.5, green: 0.5, blue: 0.5,
                                           in: CGRect(x: 0, y: 0, width: 4000, height: 2000))

        let smallResult = GeometryTransform.apply(small, geometry: geometry)
        let largeResult = GeometryTransform.apply(large, geometry: geometry)

        XCTAssertEqual(smallResult.extent.width / small.extent.width,
                       largeResult.extent.width / large.extent.width,
                       accuracy: 0.001)
        XCTAssertEqual(smallResult.extent.height / small.extent.height,
                       largeResult.extent.height / large.extent.height,
                       accuracy: 0.001)
    }

    func testFlipsPreserveTheExtent() {
        var geometry = Geometry()
        geometry.flipHorizontal = true
        geometry.flipVertical = true

        let result = GeometryTransform.apply(landscape(), geometry: geometry)
        XCTAssertEqual(result.extent.width, 400, accuracy: 0.5)
        XCTAssertEqual(result.extent.height, 200, accuracy: 0.5)
    }

    func testFlipActuallyMirrorsContent() {
        // Half-black, half-white image: after a horizontal flip the bright side
        // must have moved.
        let dark = TestSupport.solidImage(red: 0, green: 0, blue: 0,
                                          in: CGRect(x: 0, y: 0, width: 100, height: 100))
        let bright = TestSupport.solidImage(red: 1, green: 1, blue: 1,
                                            in: CGRect(x: 100, y: 0, width: 100, height: 100))
        let image = bright.composited(over: dark)
            .cropped(to: CGRect(x: 0, y: 0, width: 200, height: 100))

        var geometry = Geometry()
        geometry.flipHorizontal = true
        let flipped = GeometryTransform.apply(image, geometry: geometry)

        let leftBefore = TestSupport.readColor(image.cropped(
            to: CGRect(x: 0, y: 0, width: 100, height: 100)))
        let leftAfter = TestSupport.readColor(flipped.cropped(
            to: CGRect(x: 0, y: 0, width: 100, height: 100)))

        XCTAssertLessThan(leftBefore.red, 0.5, "The left side starts dark.")
        XCTAssertGreaterThan(leftAfter.red, 0.5, "After flipping it should be bright.")
    }

    func testStraighteningTrimsTheEmptyCorners() {
        var geometry = Geometry()
        geometry.straightenAngle = 10

        let result = GeometryTransform.apply(landscape(), geometry: geometry)
        // The inscribed rectangle must be strictly smaller than the original --
        // that's the whole point of trimming -- but not degenerate.
        XCTAssertLessThan(result.extent.width, 400)
        XCTAssertGreaterThan(result.extent.width, 200)
        XCTAssertLessThan(result.extent.height, 200)
        XCTAssertGreaterThan(result.extent.height, 100)
    }

    func testInscribedSizeIsUnchangedAtZeroAngle() {
        let size = GeometryTransform.largestInscribedSize(
            width: 400, height: 200, radians: 0
        )
        XCTAssertEqual(size.width, 400, accuracy: 0.5)
        XCTAssertEqual(size.height, 200, accuracy: 0.5)
    }

    func testInscribedSizeShrinksAsTheAngleGrows() {
        let gentle = GeometryTransform.largestInscribedSize(
            width: 400, height: 300, radians: 5 * .pi / 180
        )
        let steep = GeometryTransform.largestInscribedSize(
            width: 400, height: 300, radians: 20 * .pi / 180
        )
        XCTAssertLessThan(steep.width, gentle.width)
        XCTAssertLessThan(steep.height, gentle.height)
    }

    func testGeometrySurvivesACatalogRoundTrip() throws {
        let store = try TestSupport.inMemoryCatalog()
        var entry = TestSupport.makeEntry(fileURL: URL(fileURLWithPath: "/tmp/a.jpg"))
        entry.editStack.geometry.rotation = .threeQuarter
        entry.editStack.geometry.straightenAngle = -3.5
        entry.editStack.geometry.flipHorizontal = true
        entry.editStack.geometry.cropRect = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        try store.save(entry)

        let fetched = try XCTUnwrap(store.entry(id: entry.id))
        XCTAssertEqual(fetched.editStack.geometry, entry.editStack.geometry)
    }
}
