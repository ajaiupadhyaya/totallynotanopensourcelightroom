import CoreGraphics
import XCTest
@testable import PhotoEditor

final class EffectsCalibrationTests: XCTestCase {
    private func rendered(_ mutate: (inout EditStack) -> Void,
                          patch: Double = 0.6, size: Int = 128) -> CIImage {
        let renderer = EditRenderer()
        var stack = EditStack()
        mutate(&stack)
        return renderer.render(source: Calibration.patch(patch, size: CGFloat(size)),
                               stack: stack)
    }

    func testVignetteDarkensCornersNotCenter() {
        let out = rendered { $0.vignetteAmount = -80 }
        let center = Calibration.displayValue(of: out, x: 64, y: 64)
        let corner = Calibration.displayValue(of: out, x: 4, y: 4)
        XCTAssertEqual(center, 0.6, accuracy: 0.03)
        XCTAssertLessThan(corner, center - 0.1)
    }

    func testMidpointMovesTheFalloffInward() {
        let far = rendered { $0.vignetteAmount = -80; $0.vignetteMidpoint = 80 }
        let near = rendered { $0.vignetteAmount = -80; $0.vignetteMidpoint = 10 }
        // With a low midpoint the darkening reaches a point midway out;
        // with a high midpoint that same point is untouched.
        let mid = (x: 96, y: 96)
        XCTAssertLessThan(Calibration.displayValue(of: near, x: mid.x, y: mid.y),
                          Calibration.displayValue(of: far, x: mid.x, y: mid.y) - 0.04)
    }

    func testFeatherWidensTheTransition() {
        let hard = rendered { $0.vignetteAmount = -100; $0.vignetteFeather = 5 }
        let soft = rendered { $0.vignetteAmount = -100; $0.vignetteFeather = 95 }
        func band(_ img: CIImage) -> Double {
            // Difference across a fixed radial span — smaller span delta = softer.
            abs(Calibration.displayValue(of: img, x: 24, y: 24)
                - Calibration.displayValue(of: img, x: 40, y: 40))
        }
        XCTAssertGreaterThan(band(hard), band(soft) + 0.02)
    }

    func testHighlightPriorityProtectsBrightCorners() {
        let plain = rendered({ $0.vignetteAmount = -90 }, patch: 0.92)
        let prioritized = rendered({ $0.vignetteAmount = -90; $0.vignetteHighlights = 100 },
                                   patch: 0.92)
        XCTAssertGreaterThan(Calibration.displayValue(of: prioritized, x: 4, y: 4),
                             Calibration.displayValue(of: plain, x: 4, y: 4) + 0.04)
    }

    func testVignetteMeasuresTheCroppedFrame() {
        // Crop to the right half; the vignette center must be the CROP's
        // center, so the crop's own left edge darkens like an edge, not like
        // the middle of the original frame.
        let renderer = EditRenderer()
        var stack = EditStack()
        stack.vignetteAmount = -90
        stack.geometry.cropRect = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        let out = renderer.render(source: Calibration.patch(0.6, size: 128), stack: stack)
        let w = Int(out.extent.width), h = Int(out.extent.height)
        let leftEdge = Calibration.displayValue(of: out, x: Int(out.extent.minX) + 2,
                                                y: Int(out.extent.minY) + h / 2)
        let center = Calibration.displayValue(of: out, x: Int(out.extent.minX) + w / 2,
                                              y: Int(out.extent.minY) + h / 2)
        XCTAssertLessThan(leftEdge, center - 0.05)
    }

    func testGrainIsDeterministic() {
        let a = rendered { $0.grainAmount = 60 }
        let b = rendered { $0.grainAmount = 60 }
        for point in [(10, 10), (50, 80), (100, 30)] {
            XCTAssertEqual(Calibration.displayValue(of: a, x: point.0, y: point.1),
                           Calibration.displayValue(of: b, x: point.0, y: point.1),
                           accuracy: 0.004, "grain must be identical across renders")
        }
    }

    func testGrainActuallyAppears() {
        let out = rendered { $0.grainAmount = 80 }
        var values: Set<Int> = []
        for x in stride(from: 4, to: 124, by: 4) {
            values.insert(Int(Calibration.displayValue(of: out, x: x, y: 64) * 255))
        }
        XCTAssertGreaterThan(values.count, 4, "an 80-strength grain must vary the patch")
    }

    /// The preview/export contract: the same photo rendered at two sizes
    /// carries the SAME grain field. Rendering the noise in normalized frame
    /// coordinates makes the 256px render a downsample of the 512px one.
    func testGrainIsResolutionIndependent() {
        let renderer = EditRenderer()
        var stack = EditStack()
        stack.grainAmount = 70
        stack.grainSize = 50
        let small = renderer.render(source: Calibration.patch(0.5, size: 256), stack: stack)
        // Downsample the large render to the small one's size before
        // comparing — point-sampling both would compare misaligned pixel
        // centers of a continuous noise field and flake.
        let large = renderer.render(source: Calibration.patch(0.5, size: 512), stack: stack)
            .transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5))
        var matched = 0, total = 0
        for y in stride(from: 8, to: 248, by: 12) {
            for x in stride(from: 8, to: 248, by: 12) {
                let s = Calibration.displayValue(of: small, x: x, y: y)
                let l = Calibration.displayValue(of: large, x: x, y: y)
                total += 1
                if abs(s - l) < 0.05 { matched += 1 }
            }
        }
        XCTAssertGreaterThan(Double(matched) / Double(total), 0.7,
                             "grain field must match across render sizes (\(matched)/\(total))")
    }

    func testGrainZeroIsIdentity() {
        let out = rendered { $0.grainAmount = 0 }
        XCTAssertEqual(Calibration.displayValue(of: out, x: 64, y: 64), 0.6, accuracy: 0.01)
    }
}
