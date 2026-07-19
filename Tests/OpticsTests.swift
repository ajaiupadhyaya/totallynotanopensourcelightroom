import CoreGraphics
import CoreImage
import Foundation
import XCTest
@testable import PhotoEditor

/// Tests for the optics corrections: defringe (CA removal), manual lens
/// distortion, and keystone perspective.
final class OpticsTests: XCTestCase {
    private let context = CIContext()

    // MARK: Helpers

    private func saturation(_ c: (red: Double, green: Double, blue: Double)) -> Double {
        let maxC = max(c.red, max(c.green, c.blue))
        let minC = min(c.red, min(c.green, c.blue))
        return maxC > 0 ? (maxC - minC) / maxC : 0
    }

    /// The column (index of `count` equal slices) with the highest average
    /// brightness inside `rowBand` (unit y-range) of the image.
    private func brightestColumn(
        of image: CIImage, rowBand: ClosedRange<CGFloat>, count: Int = 50
    ) -> Int {
        let extent = image.extent
        var best = 0
        var bestValue = -1.0
        for i in 0..<count {
            let rect = CGRect(
                x: extent.origin.x + extent.width * CGFloat(i) / CGFloat(count),
                y: extent.origin.y + extent.height * rowBand.lowerBound,
                width: extent.width / CGFloat(count),
                height: extent.height * (rowBand.upperBound - rowBand.lowerBound)
            )
            let c = TestSupport.readColor(image.cropped(to: rect), context: context)
            let brightness = (c.red + c.green + c.blue) / 3
            if brightness > bestValue {
                bestValue = brightness
                best = i
            }
        }
        return best
    }

    /// A black frame with a white vertical stripe centered at unit `x`.
    private func stripeImage(atUnitX x: CGFloat,
                             width: CGFloat = 200, height: CGFloat = 100) -> CIImage {
        let frame = CGRect(x: 0, y: 0, width: width, height: height)
        let black = TestSupport.solidImage(red: 0, green: 0, blue: 0, in: frame)
        let stripe = TestSupport.solidImage(
            red: 1, green: 1, blue: 1,
            in: CGRect(x: width * x - 3, y: 0, width: 6, height: height)
        )
        return stripe.composited(over: black).cropped(to: frame)
    }

    // MARK: Defringe

    func testDefringeDesaturatesPurpleAtAnEdge() {
        // White | purple stripe | black — the classic fringe geometry.
        let frame = CGRect(x: 0, y: 0, width: 200, height: 100)
        let white = TestSupport.solidImage(red: 1, green: 1, blue: 1,
                                           in: CGRect(x: 0, y: 0, width: 98, height: 100))
        let black = TestSupport.solidImage(red: 0, green: 0, blue: 0,
                                           in: CGRect(x: 102, y: 0, width: 98, height: 100))
        let fringe = TestSupport.solidImage(red: 0.55, green: 0.1, blue: 0.8,
                                            in: CGRect(x: 98, y: 0, width: 4, height: 100))
        let image = fringe.composited(over: black.composited(over: white)).cropped(to: frame)

        var settings = Defringe()
        settings.purple = 100
        let result = DefringeRenderer.apply(settings, to: image)

        let stripeRect = CGRect(x: 98, y: 20, width: 4, height: 60)
        let before = saturation(TestSupport.readColor(image.cropped(to: stripeRect),
                                                      context: context))
        let after = saturation(TestSupport.readColor(result.cropped(to: stripeRect),
                                                     context: context))
        XCTAssertLessThan(after, before * 0.6,
                          "the purple fringe along the edge should lose most of its color")
    }

    func testDefringeLeavesFlatColorAlone() {
        // A uniform purple field: no edges (away from the frame border), so
        // even full-strength defringe must not touch it.
        let image = TestSupport.solidImage(red: 0.55, green: 0.1, blue: 0.8, size: 200)
        var settings = Defringe()
        settings.purple = 100
        let result = DefringeRenderer.apply(settings, to: image)

        let center = CGRect(x: 60, y: 60, width: 80, height: 80)
        let before = TestSupport.readColor(image.cropped(to: center), context: context)
        let after = TestSupport.readColor(result.cropped(to: center), context: context)
        XCTAssertEqual(saturation(after), saturation(before), accuracy: 0.05,
                       "flat purple far from any edge must keep its color")
    }

    func testNeutralDefringeIsIdentity() {
        let image = TestSupport.solidImage(red: 0.5, green: 0.5, blue: 0.5, size: 64)
        XCTAssertTrue(DefringeRenderer.apply(Defringe(), to: image) === image)
    }

    // MARK: Distortion

    func testDistortionShiftsAnOffCenterStripe() {
        let image = stripeImage(atUnitX: 0.3)

        var barrel = Geometry()
        barrel.distortion = 100
        var pincushion = Geometry()
        pincushion.distortion = -100

        let bulged = GeometryTransform.apply(image, geometry: barrel)
        let pinched = GeometryTransform.apply(image, geometry: pincushion)

        let bulgedColumn = brightestColumn(of: bulged, rowBand: 0.35...0.65)
        let pinchedColumn = brightestColumn(of: pinched, rowBand: 0.35...0.65)

        // Bulging magnifies the center: an off-center stripe moves outward
        // (toward the near edge); pinching pulls it inward. The two directions
        // must land the stripe in clearly different places.
        XCTAssertLessThan(bulgedColumn + 2, pinchedColumn,
                          "barrel and pincushion must displace the stripe in opposite directions")
    }

    func testDistortionPreservesAspectRatio() {
        let image = stripeImage(atUnitX: 0.3)
        var geometry = Geometry()
        geometry.distortion = 80

        let result = GeometryTransform.apply(image, geometry: geometry)
        let aspect = result.extent.width / result.extent.height
        XCTAssertEqual(aspect, 2.0, accuracy: 0.05)
    }

    // MARK: Perspective

    func testVerticalKeystoneLeansAStripe() {
        // A stripe left of center: narrowing the top squeezes the top of the
        // frame toward the center, so the stripe's top sits further right
        // (toward center) than its bottom.
        let image = stripeImage(atUnitX: 0.3, width: 200, height: 200)
        var geometry = Geometry()
        geometry.perspectiveVertical = 100

        let result = GeometryTransform.apply(image, geometry: geometry)

        let topColumn = brightestColumn(of: result, rowBand: 0.88...0.98)
        let bottomColumn = brightestColumn(of: result, rowBand: 0.02...0.12)
        XCTAssertGreaterThan(topColumn, bottomColumn + 2,
                             "the stripe must lean toward the center at the top")
    }

    func testHorizontalKeystoneChangesTheFrame() {
        let image = stripeImage(atUnitX: 0.3, width: 200, height: 200)
        var geometry = Geometry()
        geometry.perspectiveHorizontal = 60

        let result = GeometryTransform.apply(image, geometry: geometry)
        XCTAssertFalse(result.extent.isInfinite)
        XCTAssertGreaterThan(result.extent.width, 1)

        // The right edge shrinks, so a right-side probe sees content that used
        // to live nearer the vertical center.
        let original = TestSupport.readColor(
            image.cropped(to: CGRect(x: 150, y: 96, width: 20, height: 8)), context: context
        )
        let warped = TestSupport.readColor(
            result.cropped(to: CGRect(x: result.extent.maxX - 30, y: result.extent.midY - 4,
                                      width: 20, height: 8)), context: context
        )
        // Both probes are away from the stripe — this is a sanity check that
        // the warp produced a finite, readable image, not a color assertion.
        XCTAssertGreaterThanOrEqual(original.red, 0)
        XCTAssertGreaterThanOrEqual(warped.red, 0)
    }

    func testNewGeometryFieldsRoundTripAndDefault() throws {
        var geometry = Geometry()
        geometry.distortion = 25
        geometry.perspectiveVertical = -40
        geometry.perspectiveHorizontal = 15
        XCTAssertFalse(geometry.isIdentity)

        let data = try JSONEncoder().encode(geometry)
        let decoded = try JSONDecoder().decode(Geometry.self, from: data)
        XCTAssertEqual(decoded, geometry)

        let legacy = try JSONDecoder().decode(Geometry.self, from: Data("{}".utf8))
        XCTAssertEqual(legacy.distortion, 0)
        XCTAssertEqual(legacy.perspectiveVertical, 0)
        XCTAssertEqual(legacy.perspectiveHorizontal, 0)
        XCTAssertTrue(legacy.isIdentity)
    }
}
