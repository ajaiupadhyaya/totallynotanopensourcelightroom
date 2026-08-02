import CoreGraphics
import CoreImage
import Foundation
import XCTest
@testable import PhotoEditor

/// The fixture and measurements behind ``ControlConformanceTests``.
///
/// The probe deliberately is not a flat patch. A flat patch cannot answer
/// "does Texture do anything" — there is no texture in it to move — and a
/// control that silently does nothing would pass. Each quadrant here exists so
/// that some group of controls has signal to act on.
///
/// This complements ``Calibration``, which answers a different question. That
/// harness feeds single known display values through the pipeline and asks
/// what they become; this one renders a whole scene and asks whether it
/// changed, and how.
enum Conformance {
    static let context = CIContext()
    static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Deliberately **not square**, and deliberately not tiny.
    ///
    /// Both dimensions are load-bearing. Vignette Roundness equalizes the
    /// field's two radii, which is by construction a no-op on a square frame —
    /// a square probe reports a working control as dead. And the grain lattice
    /// is sized as a fraction of the long edge, so on a small frame every cell
    /// size lands inside a single pixel and the Size control has nothing to
    /// resolve. 256 × 192 is large enough for both and still renders fast.
    static let width = 256
    static let height = 192

    static let extent = CGRect(x: 0, y: 0, width: width, height: height)

    // MARK: The probe

    /// Four quadrants:
    ///
    /// - top-left: a full black-to-white luminance ramp, for the tone controls
    /// - top-right: six saturated hues at two luminances, for colour
    /// - bottom-left: a 2 px checker plus chroma noise, for texture, clarity,
    ///   sharpening, grain and both noise reductions
    /// - bottom-right: a flat, slightly blue low-contrast wash, for dehaze
    static let probe: CIImage = {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let (r, g, b) = probePixel(x: x, y: y)
                pixels[i] = r
                pixels[i + 1] = g
                pixels[i + 2] = b
                pixels[i + 3] = 255
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let cgImage = CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: srgb,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent
        )!
        return CIImage(cgImage: cgImage)
    }()

    private static func byte(_ d: Double) -> UInt8 {
        UInt8(max(0, min(255, (d * 255).rounded())))
    }

    private static func probePixel(x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
        let halfW = width / 2
        let halfH = height / 2
        let left = x < halfW
        let top = y < halfH
        let u = Double(x % halfW) / Double(halfW - 1)
        let v = Double(y % halfH) / Double(halfH - 1)

        if top, left {
            return (byte(u), byte(u), byte(u))
        }
        if top {
            let hue = floor(u * 6) / 6
            let (r, g, b) = hsl(hue: hue, saturation: 0.85,
                                lightness: v < 0.5 ? 0.35 : 0.65)
            return (byte(r), byte(g), byte(b))
        }
        if left {
            // High-frequency checker for sharpening and luminance NR, a
            // mid-frequency ripple for clarity, and a deterministic chroma
            // jitter so colour noise reduction has colour noise to remove.
            let checker = ((x / 2) + (y / 2)) % 2 == 0 ? 0.10 : -0.10
            let l = 0.5 + checker + 0.15 * sin(u * .pi * 4)
            let jitter = chromaJitter(x: x, y: y)
            return (byte(l + jitter), byte(l), byte(l - jitter))
        }
        let l = 0.55 + 0.12 * u
        return (byte(l), byte(l), byte(min(1.0, l + 0.06)))
    }

    /// A deterministic ±0.06 red/blue jitter.
    ///
    /// Deterministic because a fixture that changes between runs turns a real
    /// regression into a coin flip — the same reason PV2's grain is a fixed
    /// lattice rather than sampled noise.
    private static func chromaJitter(x: Int, y: Int) -> Double {
        let h = (x &* 73_856_093) ^ (y &* 19_349_663)
        return (Double(abs(h) % 1000) / 1000.0 - 0.5) * 0.12
    }

    private static func hsl(hue: Double, saturation: Double,
                            lightness: Double) -> (Double, Double, Double) {
        let c = (1 - abs(2 * lightness - 1)) * saturation
        let hp = hue * 6
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        let (r1, g1, b1): (Double, Double, Double)
        switch hp {
        case ..<1: (r1, g1, b1) = (c, x, 0)
        case ..<2: (r1, g1, b1) = (x, c, 0)
        case ..<3: (r1, g1, b1) = (0, c, x)
        case ..<4: (r1, g1, b1) = (0, x, c)
        case ..<5: (r1, g1, b1) = (x, 0, c)
        default:   (r1, g1, b1) = (c, 0, x)
        }
        let m = lightness - c / 2
        return (r1 + m, g1 + m, b1 + m)
    }

    // MARK: Rendering

    /// Renders the probe through the PV2 renderer with `mutate` applied to a
    /// fresh stack, returning display-space RGBA8 bytes.
    static func render(_ mutate: (inout EditStack) -> Void) -> [UInt8] {
        var stack = EditStack()
        mutate(&stack)
        return bitmap(EditRenderer().render(source: probe, stack: stack))
    }

    static func bitmap(_ image: CIImage) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        context.render(image.cropped(to: extent), toBitmap: &buffer,
                       rowBytes: width * 4, bounds: extent,
                       format: .RGBA8, colorSpace: srgb)
        return buffer
    }

    // MARK: Measurements
    //
    // All of these read display-space bytes, because that is what a person
    // looking at the canvas sees — the same reason the histogram is measured
    // in display space rather than the linear working space.

    /// Mean absolute per-channel difference, `0...1`.
    static func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        var total = 0.0
        for i in stride(from: 0, to: a.count, by: 4) {
            for c in 0..<3 { total += abs(Double(a[i + c]) - Double(b[i + c])) }
        }
        return total / (Double(a.count / 4 * 3) * 255.0)
    }

    static func luma(_ px: [UInt8], at i: Int) -> Double {
        (0.2126 * Double(px[i]) + 0.7152 * Double(px[i + 1])
            + 0.0722 * Double(px[i + 2])) / 255.0
    }

    static func lumaValues(_ px: [UInt8]) -> [Double] {
        stride(from: 0, to: px.count, by: 4).map { luma(px, at: $0) }
    }

    static func meanLuma(_ px: [UInt8]) -> Double {
        let v = lumaValues(px)
        return v.reduce(0, +) / Double(v.count)
    }

    static func stdDevLuma(_ px: [UInt8]) -> Double {
        let v = lumaValues(px)
        let mean = v.reduce(0, +) / Double(v.count)
        return (v.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(v.count))
            .squareRoot()
    }

    static func percentileLuma(_ px: [UInt8], _ p: Double) -> Double {
        let sorted = lumaValues(px).sorted()
        let index = Int((Double(sorted.count - 1) * p).rounded())
        return sorted[index]
    }

    /// HSV-style saturation, averaged.
    static func meanSaturation(_ px: [UInt8]) -> Double {
        var total = 0.0
        var count = 0
        for i in stride(from: 0, to: px.count, by: 4) {
            let r = Double(px[i]), g = Double(px[i + 1]), b = Double(px[i + 2])
            let hi = max(r, g, b)
            total += hi <= 0 ? 0 : (hi - min(r, g, b)) / hi
            count += 1
        }
        return total / Double(count)
    }

    /// Mean absolute luma difference between horizontally adjacent pixels —
    /// the high-frequency energy that sharpening adds and noise reduction
    /// removes.
    static func localContrast(_ px: [UInt8]) -> Double {
        var total = 0.0
        var count = 0
        for y in 0..<height {
            for x in 0..<(width - 1) {
                let i = (y * width + x) * 4
                total += abs(luma(px, at: i) - luma(px, at: i + 4))
                count += 1
            }
        }
        return total / Double(count)
    }

    /// Variance of the red-minus-blue difference — chroma noise, which is what
    /// colour noise reduction is supposed to reduce.
    static func chromaVariance(_ px: [UInt8]) -> Double {
        var values: [Double] = []
        for i in stride(from: 0, to: px.count, by: 4) {
            values.append((Double(px[i]) - Double(px[i + 2])) / 255.0)
        }
        let mean = values.reduce(0, +) / Double(values.count)
        return values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
    }

    /// Mean red minus mean blue. Positive is warmer.
    static func warmth(_ px: [UInt8]) -> Double {
        var r = 0.0, b = 0.0
        for i in stride(from: 0, to: px.count, by: 4) {
            r += Double(px[i])
            b += Double(px[i + 2])
        }
        return (r - b) / (Double(px.count / 4) * 255.0)
    }

    /// Mean green minus the mean of red and blue. Positive is greener,
    /// negative is more magenta.
    static func greenMagenta(_ px: [UInt8]) -> Double {
        var g = 0.0, rb = 0.0
        for i in stride(from: 0, to: px.count, by: 4) {
            g += Double(px[i + 1])
            rb += (Double(px[i]) + Double(px[i + 2])) / 2
        }
        return (g - rb) / (Double(px.count / 4) * 255.0)
    }

    /// Mean luma of the four corners — what a vignette acts on.
    static func cornerLuma(_ px: [UInt8]) -> Double {
        var total = 0.0
        var count = 0
        let band = 24
        for y in 0..<height where y < band || y >= height - band {
            for x in 0..<width where x < band || x >= width - band {
                total += luma(px, at: (y * width + x) * 4)
                count += 1
            }
        }
        return total / Double(count)
    }
}
