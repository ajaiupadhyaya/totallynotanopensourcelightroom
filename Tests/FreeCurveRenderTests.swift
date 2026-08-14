import CoreImage
import CoreImage.CIFilterBuiltins
import XCTest
@testable import PhotoEditor

/// The renderer's side of the contract: five points stay on the frozen
/// CIToneCurve path bit-for-bit, other counts render through the free path,
/// and PV1 ignores free lists entirely.
final class FreeCurveRenderTests: XCTestCase {
    private let renderer = EditRenderer()

    private func gray(_ value: Double) -> CIImage {
        TestSupport.solidImage(red: value, green: value, blue: value, size: 32)
    }

    /// Pins the 5-point semantics: the stack render equals CIToneCurve applied
    /// by hand to the same source — the exact filter, the exact points.
    func testFivePointsRenderThroughCIToneCurveUnchanged() {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 0.25, y: 0.4),
                      CGPoint(x: 0.5, y: 0.7), CGPoint(x: 0.75, y: 0.9),
                      CGPoint(x: 1, y: 1)]
        var stack = EditStack()
        stack.toneCurvePoints = points

        let viaStack = TestSupport.readColor(renderer.render(source: gray(0.5), stack: stack))

        let filter = CIFilter.toneCurve()
        filter.inputImage = gray(0.5)
        filter.point0 = points[0]; filter.point1 = points[1]; filter.point2 = points[2]
        filter.point3 = points[3]; filter.point4 = points[4]
        let direct = TestSupport.readColor(filter.outputImage!)

        XCTAssertEqual(viaStack.red, direct.red, accuracy: 1e-3)
    }

    /// The free path exists and places tones where the curve says — the
    /// peak-placement discipline from CalibrationTests, applied to a 3-point
    /// curve that lifts mid-grey to 0.8.
    func testAThreePointCurveLiftsMidGreyWhereItSays() {
        var stack = EditStack()
        stack.toneCurvePoints = [CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0.8),
                                 CGPoint(x: 1, y: 1)]
        let result = TestSupport.readColor(renderer.render(source: gray(0.5), stack: stack))
        XCTAssertEqual(result.red, 0.8, accuracy: 0.05,
                       "the curve is display-referred: input 0.5 lands near output 0.8")
    }

    func testASevenPointCurveRendersAndAnIdentityListIsANoOp() {
        var identity = EditStack()
        identity.toneCurvePoints = (0...6).map { CGPoint(x: Double($0) / 6, y: Double($0) / 6) }
        let flat = TestSupport.readColor(renderer.render(source: gray(0.4), stack: identity))
        let untouched = TestSupport.readColor(renderer.render(source: gray(0.4), stack: EditStack()))
        XCTAssertEqual(flat.red, untouched.red, accuracy: 0.01,
                       "identity points through the free path change nothing")
    }

    /// PV1 is frozen: LegacyToneRenderer's count == 5 guard means a free list
    /// renders as if there were no curve at all. Not a feature gap — the
    /// freeze guarantee (free editing is gated on PV2 in the panel).
    func testPV1IgnoresAFreePointList() {
        var withCurve = EditStack()
        withCurve.processVersion = 1
        withCurve.toneCurvePoints = [CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0.9),
                                     CGPoint(x: 1, y: 1)]
        var without = EditStack()
        without.processVersion = 1

        let a = TestSupport.readColor(renderer.render(source: gray(0.5), stack: withCurve))
        let b = TestSupport.readColor(renderer.render(source: gray(0.5), stack: without))
        XCTAssertEqual(a.red, b.red, accuracy: 1e-4)
    }
}
