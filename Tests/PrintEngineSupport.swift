import CoreGraphics
import CoreImage
import Foundation
@testable import PhotoEditor

/// A simulated C-41 exposure: turns a known linear scene into a film negative
/// with a chosen base and per-channel characteristic slopes. Different slopes
/// per channel IS crossover — the thing the matrix model provably cannot
/// remove and the density engine exists to fix.
///
/// The model: negative density above base is proportional to log exposure,
/// `D_c = gammaSim_c · (log10 L_c + 3)` with L clamped to [1e-3, 1], so the
/// scene's 3 decades of luminance map to densities 0…3·gammaSim. Transmittance
/// is then `t_c = dmin_c · 10^(−D_c)` — the brightest scene area is the
/// densest, exactly as film behaves.
enum FilmSim {
    /// Named patches spanning tone and color: the round-trip fixture.
    static func scene() -> [(name: String, linear: (Double, Double, Double))] {
        [
            ("black", (0.002, 0.002, 0.002)),
            ("shadowGrey", (0.02, 0.02, 0.02)),
            ("midGrey", (0.18, 0.18, 0.18)),
            ("lightGrey", (0.45, 0.45, 0.45)),
            ("white", (0.95, 0.95, 0.95)),
            ("red", (0.45, 0.05, 0.04)),
            ("green", (0.06, 0.40, 0.07)),
            ("blue", (0.05, 0.07, 0.42)),
            ("skin", (0.42, 0.26, 0.18)),
            ("sky", (0.20, 0.32, 0.55)),
        ]
    }

    static func transmittance(of scene: (Double, Double, Double),
                              dmin: (Double, Double, Double),
                              gammas: (Double, Double, Double)) -> (Double, Double, Double) {
        func channel(_ l: Double, _ dmin: Double, _ g: Double) -> Double {
            let clamped = min(max(l, 1e-3), 1.0)
            let density = g * (log10(clamped) + 3.0)
            return dmin * pow(10.0, -density)
        }
        return (channel(scene.0, dmin.0, gammas.0),
                channel(scene.1, dmin.1, gammas.1),
                channel(scene.2, dmin.2, gammas.2))
    }

    /// The scene patches as a rendered negative, plus a border of bare film
    /// base — the rebate every real scan should include. The border is 20% of
    /// the area, comfortably above the solver's 2% Dmin percentile.
    static func negativeImage(dmin: (Double, Double, Double),
                              gammas: (Double, Double, Double),
                              size: Int = 200) -> CIImage {
        let patches = scene()
        let cols = 5, rows = 2
        let border = size / 10
        let cellW = (size - 2 * border) / cols
        let cellH = (size - 2 * border) / rows
        var pixels = [Float](repeating: 0, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let inX = x - border, inY = y - border
                let t: (Double, Double, Double)
                if inX < 0 || inY < 0 || inX >= cellW * cols || inY >= cellH * rows {
                    t = dmin // bare base: the rebate
                } else {
                    let index = min((inY / cellH) * cols + (inX / cellW), patches.count - 1)
                    t = transmittance(of: patches[index].linear, dmin: dmin, gammas: gammas)
                }
                let i = (y * size + x) * 4
                pixels[i] = Float(t.0); pixels[i + 1] = Float(t.1)
                pixels[i + 2] = Float(t.2); pixels[i + 3] = 1
            }
        }
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(bitmapData: data, bytesPerRow: size * 16,
                       size: CGSize(width: size, height: size), format: .RGBAf,
                       colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
    }

    /// The canonical crossover fixture: cyan shadows, warm highlights. No
    /// single per-channel gain can neutralize both ends of this.
    static let crossoverGammas = (0.55, 0.62, 0.70)
    static let c41Base = (0.55, 0.30, 0.13) // linear transmittance of the mask
}
