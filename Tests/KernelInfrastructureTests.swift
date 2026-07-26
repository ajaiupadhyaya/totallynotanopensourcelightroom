import CoreImage
import CoreImage.CIFilterBuiltins
import XCTest
@testable import PhotoEditor

final class KernelInfrastructureTests: XCTestCase {
    func testProbeKernelLoadsAndIsIdentity() throws {
        let kernel = KernelLibrary.color("pv2_probe_identity")
        let source = TestSupport.solidImage(red: 0.25, green: 0.5, blue: 0.75, size: 16)
        let out = try XCTUnwrap(kernel.apply(extent: source.extent, arguments: [source]))
        let color = TestSupport.readColor(out)
        XCTAssertEqual(color.red, 0.25, accuracy: 0.01)
        XCTAssertEqual(color.green, 0.5, accuracy: 0.01)
        XCTAssertEqual(color.blue, 0.75, accuracy: 0.01)
    }

    /// The load-bearing assumption of the whole design: values above 1.0
    /// survive a kernel pass unclamped in the default working format.
    func testExtendedRangeSurvivesAKernelPass() throws {
        let kernel = KernelLibrary.color("pv2_probe_identity")
        // Push a 1.0 patch to 2.0 with a color matrix (bias is unclamped).
        let base = TestSupport.solidImage(red: 1, green: 1, blue: 1, size: 16)
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = base
        matrix.biasVector = CIVector(x: 1, y: 1, z: 1, w: 0)
        let edr = try XCTUnwrap(matrix.outputImage)
        let out = try XCTUnwrap(kernel.apply(extent: base.extent, arguments: [edr]))

        var px = [Float](repeating: 0, count: 4)
        let ctx = CIContext()
        ctx.render(out, toBitmap: &px, rowBytes: 4 * MemoryLayout<Float>.stride,
                   bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                   format: .RGBAf, colorSpace: nil)
        XCTAssertGreaterThan(px[0], 1.5, "EDR value was clamped inside the kernel path")
    }
}
