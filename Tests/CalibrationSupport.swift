import CoreGraphics
import CoreImage
import XCTest
@testable import PhotoEditor

/// Measures what the pipeline does to known display-referred sRGB values.
/// This is the harness that would have caught every PV1 calibration bug:
/// direction tests say "brighter"; these say "brighter by how much, where."
enum Calibration {
    static let context = CIContext()
    static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    /// A patch whose sRGB *display* value is `v` in all channels.
    static func patch(_ v: Double, size: CGFloat = 16) -> CIImage {
        TestSupport.solidImage(red: v, green: v, blue: v, size: size)
    }

    /// Reads back the sRGB display value of the red channel at (x, y).
    static func displayValue(of image: CIImage, x: Int = 0, y: Int = 0) -> Double {
        var px = [UInt8](repeating: 0, count: 4)
        context.render(image, toBitmap: &px, rowBytes: 4,
                       bounds: CGRect(x: x, y: y, width: 1, height: 1),
                       format: .RGBA8, colorSpace: srgb)
        return Double(px[0]) / 255.0
    }

    /// Feeds each display value through the PV2 renderer with `mutate`
    /// applied to a fresh (PV2) stack; returns display-out values.
    static func displaySweep(inputs: [Double],
                             mutate: (inout EditStack) -> Void) -> [Double] {
        let renderer = EditRenderer()
        var stack = EditStack()
        mutate(&stack)
        return inputs.map { v in
            displayValue(of: renderer.render(source: patch(v), stack: stack), x: 2, y: 2)
        }
    }

    /// A 128-wide horizontal display-space ramp from 0 to 1, `height` tall.
    static func ramp(height: Int = 16) -> CIImage {
        let w = 128
        var bytes = [UInt8](repeating: 255, count: w * height * 4)
        for y in 0..<height {
            for x in 0..<w {
                let v = UInt8((Double(x) / Double(w - 1) * 255).rounded())
                let i = (y * w + x) * 4
                bytes[i] = v; bytes[i + 1] = v; bytes[i + 2] = v
            }
        }
        return CIImage(bitmapData: Data(bytes), bytesPerRow: w * 4,
                       size: CGSize(width: w, height: height),
                       format: .RGBA8, colorSpace: srgb)
    }
}

enum CalibrationEdge {
    /// A vertical hard edge: left half `dark`, right half `bright` (display values).
    static func image(dark: Double, bright: Double, size: Int) -> CIImage {
        var bytes = [UInt8](repeating: 255, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let v = UInt8(((x < size / 2 ? dark : bright) * 255).rounded())
                let i = (y * size + x) * 4
                bytes[i] = v; bytes[i + 1] = v; bytes[i + 2] = v
            }
        }
        return CIImage(bitmapData: Data(bytes), bytesPerRow: size * 4,
                       size: CGSize(width: size, height: size),
                       format: .RGBA8, colorSpace: Calibration.srgb)
    }
}
