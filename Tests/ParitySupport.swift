import CoreGraphics
import CoreImage
import Foundation
import XCTest
@testable import PhotoEditor

/// CIELAB conversion and CIEDE2000, for measuring renders against
/// Lightroom's. Formulae follow Sharma, Wu & Dalal (2005).
enum DeltaE {
    static func srgbToLab(r: Double, g: Double, b: Double) -> (L: Double, a: Double, b: Double) {
        func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let rl = lin(r), gl = lin(g), bl = lin(b)
        let x = (0.4124564 * rl + 0.3575761 * gl + 0.1804375 * bl) / 0.95047
        let y = 0.2126729 * rl + 0.7151522 * gl + 0.0721750 * bl
        let z = (0.0193339 * rl + 0.1191920 * gl + 0.9503041 * bl) / 1.08883
        func f(_ t: Double) -> Double { t > 0.008856 ? pow(t, 1.0 / 3.0) : 7.787 * t + 16.0 / 116.0 }
        return (116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
    }

    static func ciede2000(_ p: (L: Double, a: Double, b: Double),
                          _ q: (L: Double, a: Double, b: Double)) -> Double {
        let c1 = sqrt(p.a * p.a + p.b * p.b), c2 = sqrt(q.a * q.a + q.b * q.b)
        let cBar = (c1 + c2) / 2
        let g = 0.5 * (1 - sqrt(pow(cBar, 7) / (pow(cBar, 7) + pow(25.0, 7))))
        let a1p = p.a * (1 + g), a2p = q.a * (1 + g)
        let c1p = sqrt(a1p * a1p + p.b * p.b), c2p = sqrt(a2p * a2p + q.b * q.b)
        func hp(_ a: Double, _ b: Double) -> Double {
            if a == 0 && b == 0 { return 0 }
            var h = atan2(b, a) * 180 / .pi
            if h < 0 { h += 360 }
            return h
        }
        let h1p = hp(a1p, p.b), h2p = hp(a2p, q.b)
        let dLp = q.L - p.L
        let dCp = c2p - c1p
        var dhp: Double
        if c1p * c2p == 0 { dhp = 0 }
        else if abs(h2p - h1p) <= 180 { dhp = h2p - h1p }
        else if h2p - h1p > 180 { dhp = h2p - h1p - 360 }
        else { dhp = h2p - h1p + 360 }
        let dHp = 2 * sqrt(c1p * c2p) * sin(dhp / 2 * .pi / 180)
        let lBar = (p.L + q.L) / 2, cBarP = (c1p + c2p) / 2
        var hBar: Double
        if c1p * c2p == 0 { hBar = h1p + h2p }
        else if abs(h1p - h2p) <= 180 { hBar = (h1p + h2p) / 2 }
        else if h1p + h2p < 360 { hBar = (h1p + h2p + 360) / 2 }
        else { hBar = (h1p + h2p - 360) / 2 }
        let t = 1 - 0.17 * cos((hBar - 30) * .pi / 180) + 0.24 * cos(2 * hBar * .pi / 180)
            + 0.32 * cos((3 * hBar + 6) * .pi / 180) - 0.20 * cos((4 * hBar - 63) * .pi / 180)
        let dTheta = 30 * exp(-pow((hBar - 275) / 25, 2))
        let rc = 2 * sqrt(pow(cBarP, 7) / (pow(cBarP, 7) + pow(25.0, 7)))
        let sl = 1 + 0.015 * pow(lBar - 50, 2) / sqrt(20 + pow(lBar - 50, 2))
        let sc = 1 + 0.045 * cBarP
        let sh = 1 + 0.015 * cBarP * t
        let rt = -sin(2 * dTheta * .pi / 180) * rc
        return sqrt(pow(dLp / sl, 2) + pow(dCp / sc, 2) + pow(dHp / sh, 2)
                    + rt * (dCp / sc) * (dHp / sh))
    }
}

enum ParitySupport {
    static let fixturesDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("Fixtures/Parity")

    /// Renders an image to `side`×`side` sRGB and returns Lab per pixel.
    static func labPixels(of image: CIImage, side: Int = 128) -> [(Double, Double, Double)] {
        let ctx = Calibration.context
        let scale = CGFloat(side) / max(image.extent.width, image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let w = Int(scaled.extent.width.rounded()), h = Int(scaled.extent.height.rounded())
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        ctx.render(scaled, toBitmap: &bytes, rowBytes: w * 4,
                   bounds: CGRect(x: scaled.extent.minX, y: scaled.extent.minY,
                                  width: CGFloat(w), height: CGFloat(h)),
                   format: .RGBA8, colorSpace: Calibration.srgb)
        var out: [(Double, Double, Double)] = []
        out.reserveCapacity(w * h)
        for i in stride(from: 0, to: bytes.count, by: 4) {
            out.append(DeltaE.srgbToLab(r: Double(bytes[i]) / 255,
                                        g: Double(bytes[i + 1]) / 255,
                                        b: Double(bytes[i + 2]) / 255))
        }
        return out
    }
}

/// One measured comparison: a control at a value, our render of the neutral
/// export vs Lightroom's own export of the same recipe.
struct ParityCase: Decodable {
    let fixture: String              // e.g. "contrast_p50.tif"
    let field: String                // EditStack field name
    let value: Double
    let meanTolerance: Double?       // nil = report-only (no strict mapping)
    let maxTolerance: Double?

    func apply(to stack: inout EditStack) {
        switch field {
        case "contrast": stack.contrast = value
        case "exposure": stack.exposure = value
        case "highlights": stack.highlights = value
        case "shadows": stack.shadows = value
        case "whites": stack.whites = value
        case "blacks": stack.blacks = value
        case "vibrance": stack.vibrance = value
        case "saturation": stack.saturation = value
        case "whiteBalanceTemp": stack.whiteBalanceTemp = value
        case "whiteBalanceTint": stack.whiteBalanceTint = value
        default: XCTFail("unknown parity field \(field)")
        }
    }
}
