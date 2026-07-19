import CoreGraphics
import CoreImage
import Foundation
import XCTest
@testable import PhotoEditor

/// Pipeline-level tests for heal/clone spot removal.
final class RetouchTests: XCTestCase {
    private let context = CIContext()

    /// A 200×100 frame: left half red, right half green.
    private func splitImage(scale: CGFloat = 1) -> CIImage {
        let left = TestSupport.solidImage(
            red: 0.8, green: 0.1, blue: 0.1,
            in: CGRect(x: 0, y: 0, width: 100 * scale, height: 100 * scale)
        )
        let right = TestSupport.solidImage(
            red: 0.1, green: 0.7, blue: 0.1,
            in: CGRect(x: 100 * scale, y: 0, width: 100 * scale, height: 100 * scale)
        )
        return right.composited(over: left)
            .cropped(to: CGRect(x: 0, y: 0, width: 200 * scale, height: 100 * scale))
    }

    /// Average color over a small square at a unit position of the image.
    private func color(
        of image: CIImage, atUnit unit: CGPoint, side: CGFloat = 6
    ) -> (red: Double, green: Double, blue: Double) {
        let extent = image.extent
        // Integral rect: CIAreaAverage misreads small non-integral extents.
        let rect = CGRect(
            x: extent.origin.x + unit.x * extent.width - side / 2,
            y: extent.origin.y + unit.y * extent.height - side / 2,
            width: side, height: side
        ).integral
        return TestSupport.readColor(image.cropped(to: rect), context: context)
    }

    private func makeSpot(
        mode: RetouchSpot.Mode = .clone,
        center: CGPoint,
        radius: Double = 0.05,
        feather: Double = 0,
        offset: CGVector
    ) -> RetouchSpot {
        var spot = RetouchSpot()
        spot.mode = mode
        spot.center = center
        spot.radius = radius
        spot.feather = feather
        spot.sourceOffset = offset
        return spot
    }

    // MARK: Clone

    func testCloneCopiesSourcePixels() {
        let image = splitImage()
        // Spot in the red half; source half the frame to the right — green.
        let spot = makeSpot(center: CGPoint(x: 0.25, y: 0.5),
                            offset: CGVector(dx: 0.5, dy: 0))
        let result = RetouchRenderer.apply([spot], to: image, context: context)

        let patched = color(of: result, atUnit: CGPoint(x: 0.25, y: 0.5))
        XCTAssertGreaterThan(patched.green, 0.5, "spot should now show the green source")
        XCTAssertLessThan(patched.red, 0.3)
    }

    func testCloneLeavesOutsideUntouched() {
        let image = splitImage()
        let spot = makeSpot(center: CGPoint(x: 0.25, y: 0.5),
                            offset: CGVector(dx: 0.5, dy: 0))
        let result = RetouchRenderer.apply([spot], to: image, context: context)

        let corner = color(of: result, atUnit: CGPoint(x: 0.06, y: 0.1))
        XCTAssertGreaterThan(corner.red, 0.6, "far corner must stay red")
        XCTAssertLessThan(corner.green, 0.25)
    }

    func testFeatherSoftensTheRim() {
        let image = splitImage()
        let hard = makeSpot(center: CGPoint(x: 0.25, y: 0.5),
                            feather: 0, offset: CGVector(dx: 0.5, dy: 0))
        var soft = hard
        soft.feather = 1

        // Radius is 0.05 × 200 = 10 px; probe ~6 px from center — solidly
        // inside the hard mask, but well down the ramp when the feather spans
        // the whole radius. (Right at the rim the gradient antialiases, so a
        // probe there measures the falloff of the edge, not the feather.)
        let rimUnit = CGPoint(x: 0.25 + 0.03, y: 0.5)
        let hardRim = color(of: RetouchRenderer.apply([hard], to: image, context: context),
                            atUnit: rimUnit, side: 3)
        let softRim = color(of: RetouchRenderer.apply([soft], to: image, context: context),
                            atUnit: rimUnit, side: 3)

        XCTAssertGreaterThan(hardRim.green, 0.5, "hard edge is fully source at the rim")
        XCTAssertLessThan(softRim.green, hardRim.green - 0.15,
                          "feathered rim should blend back toward the red background")
    }

    // MARK: Heal

    /// Heal must shift the copied pixels to the destination's local tone —
    /// borrowing from a darker region should not leave a dark patch.
    func testHealMatchesDestinationTone() {
        let light = TestSupport.solidImage(
            red: 0.6, green: 0.6, blue: 0.6,
            in: CGRect(x: 0, y: 0, width: 100, height: 100)
        )
        let dark = TestSupport.solidImage(
            red: 0.3, green: 0.3, blue: 0.3,
            in: CGRect(x: 100, y: 0, width: 100, height: 100)
        )
        let image = dark.composited(over: light)
            .cropped(to: CGRect(x: 0, y: 0, width: 200, height: 100))

        let center = CGPoint(x: 0.25, y: 0.5)
        let offset = CGVector(dx: 0.5, dy: 0)

        let cloned = RetouchRenderer.apply(
            [makeSpot(mode: .clone, center: center, radius: 0.04, offset: offset)],
            to: image, context: context
        )
        let healed = RetouchRenderer.apply(
            [makeSpot(mode: .heal, center: center, radius: 0.04, offset: offset)],
            to: image, context: context
        )

        let clonedSpot = color(of: cloned, atUnit: center)
        let healedSpot = color(of: healed, atUnit: center)

        XCTAssertEqual(clonedSpot.red, 0.3, accuracy: 0.06,
                       "clone copies the dark source verbatim")
        XCTAssertEqual(healedSpot.red, 0.6, accuracy: 0.08,
                       "heal must lift the patch to the light surroundings")
    }

    // MARK: No-ops

    func testDisabledSpotIsIgnored() {
        let image = splitImage()
        var spot = makeSpot(center: CGPoint(x: 0.25, y: 0.5),
                            offset: CGVector(dx: 0.5, dy: 0))
        spot.isEnabled = false

        let result = RetouchRenderer.apply([spot], to: image, context: context)
        let patched = color(of: result, atUnit: CGPoint(x: 0.25, y: 0.5))
        XCTAssertGreaterThan(patched.red, 0.6, "disabled spot must change nothing")
    }

    func testEmptySpotsReturnTheSameImage() {
        let image = splitImage()
        let result = RetouchRenderer.apply([], to: image, context: context)
        XCTAssertTrue(result === image)
    }

    // MARK: Resolution independence

    /// The same spot must land on the same *unit* position at any pixel size —
    /// this is what makes the preview and the export agree.
    func testResolutionIndependence() {
        let spot = makeSpot(center: CGPoint(x: 0.25, y: 0.5),
                            offset: CGVector(dx: 0.5, dy: 0))

        let small = RetouchRenderer.apply([spot], to: splitImage(scale: 1), context: context)
        let large = RetouchRenderer.apply([spot], to: splitImage(scale: 2), context: context)

        let smallSpot = color(of: small, atUnit: CGPoint(x: 0.25, y: 0.5))
        let largeSpot = color(of: large, atUnit: CGPoint(x: 0.25, y: 0.5), side: 12)
        XCTAssertEqual(smallSpot.green, largeSpot.green, accuracy: 0.05)

        let smallEdge = color(of: small, atUnit: CGPoint(x: 0.4, y: 0.5))
        let largeEdge = color(of: large, atUnit: CGPoint(x: 0.4, y: 0.5), side: 12)
        XCTAssertEqual(smallEdge.red, largeEdge.red, accuracy: 0.05)
    }

    // MARK: Persistence

    func testRetouchRoundTripsThroughJSON() throws {
        var stack = EditStack()
        var spot = makeSpot(mode: .heal, center: CGPoint(x: 0.3, y: 0.7),
                            radius: 0.03, feather: 0.8,
                            offset: CGVector(dx: -0.1, dy: 0.05))
        spot.isEnabled = false
        stack.retouch = [spot]
        stack.defringe.purple = 40

        let data = try JSONEncoder().encode(stack)
        let decoded = try JSONDecoder().decode(EditStack.self, from: data)
        XCTAssertEqual(decoded, stack)
    }

    func testLegacyStackDecodesWithNoRetouch() throws {
        let decoded = try JSONDecoder().decode(EditStack.self, from: Data("{}".utf8))
        XCTAssertTrue(decoded.retouch.isEmpty)
        XCTAssertTrue(decoded.defringe.isNeutral)
    }
}
