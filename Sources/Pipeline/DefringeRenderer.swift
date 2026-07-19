import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Removes purple/green chromatic-aberration fringes.
///
/// The fix is a hue-targeted desaturation (a small color cube) applied **only
/// along edges**: an edge mask gates the corrected image over the original, so
/// legitimately purple or green subject matter away from any high-contrast
/// edge is untouched at any strength.
enum DefringeRenderer {
    static func apply(_ settings: Defringe, to image: CIImage) -> CIImage {
        guard !settings.isNeutral else { return image }
        let extent = image.extent
        guard !extent.isInfinite, extent.width >= 1, extent.height >= 1 else { return image }

        guard let cube = DefringeCubeCache.shared.filter(for: settings),
              let mask = edgeMask(of: image) else { return image }

        cube.setValue(image, forKey: kCIInputImageKey)
        guard let defringed = cube.outputImage else { return image }

        let blend = CIFilter.blendWithMask()
        blend.inputImage = defringed
        blend.backgroundImage = image
        blend.maskImage = mask
        return blend.outputImage?.cropped(to: extent) ?? image
    }

    // MARK: Edge mask

    /// White where the image has strong luminance edges, black in flat areas.
    ///
    /// The gain is an affine scale anchored at zero (`CIColorMatrix`), not a
    /// contrast boost — `CIColorControls.contrast` pivots at 0.5 and would
    /// crush the small edge signal to black. The blur then widens the mask a
    /// few pixels, because a fringe sits *beside* an edge, not on it.
    private static func edgeMask(of image: CIImage) -> CIImage? {
        let extent = image.extent

        let edges = CIFilter.edges()
        edges.inputImage = image
        edges.intensity = 4
        guard let edged = edges.outputImage else { return nil }

        let mono = CIFilter.colorControls()
        mono.inputImage = edged
        mono.saturation = 0
        guard let gray = mono.outputImage else { return nil }

        let gain = CIFilter.colorMatrix()
        gain.inputImage = gray
        let g: CGFloat = 6
        gain.rVector = CIVector(x: g, y: 0, z: 0, w: 0)
        gain.gVector = CIVector(x: 0, y: g, z: 0, w: 0)
        gain.bVector = CIVector(x: 0, y: 0, z: g, w: 0)
        gain.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        guard let amplified = gain.outputImage else { return nil }

        let clamp = CIFilter.colorClamp()
        clamp.inputImage = amplified
        clamp.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        clamp.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
        guard let clamped = clamp.outputImage else { return nil }

        let blur = CIFilter.gaussianBlur()
        blur.inputImage = clamped.clampedToExtent()
        blur.radius = 2
        guard let widened = blur.outputImage?.cropped(to: extent) else { return nil }

        let toAlpha = CIFilter.maskToAlpha()
        toAlpha.inputImage = widened
        return toAlpha.outputImage
    }
}

/// Builds and memoizes the defringe color cube for the current settings.
final class DefringeCubeCache {
    static let shared = DefringeCubeCache()

    private var settings: Defringe?
    private var cachedFilter: CIFilter?

    func filter(for settings: Defringe) -> CIFilter? {
        if let cachedFilter, self.settings == settings { return cachedFilter }
        guard let filter = Self.buildFilter(settings) else { return nil }
        self.settings = settings
        cachedFilter = filter
        return filter
    }

    /// A 32³ cube that desaturates colors whose hue lies in the purple and/or
    /// green fringe bands, proportionally to the slider strengths.
    ///
    /// The suppression ramps in with saturation (smoothstep over the first
    /// 0.2) — the GPU interpolates between grid points, so a hard cutoff at
    /// zero saturation would let chromatic neighbors drag true grays.
    private static func buildFilter(_ settings: Defringe) -> CIFilter? {
        let size = 32
        var cube = [Float]()
        cube.reserveCapacity(size * size * size * 4)

        let purpleStrength = settings.purple / 100
        let greenStrength = settings.green / 100

        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let red = Double(r) / Double(size - 1)
                    let green = Double(g) / Double(size - 1)
                    let blue = Double(b) / Double(size - 1)

                    var (hue, sat, value) = rgbToHSV(red, green, blue)

                    // Purple fringes center near 285°, green near 120°.
                    let purpleWeight = bandWeight(hue: hue, center: 285, width: 60)
                    let greenWeight = bandWeight(hue: hue, center: 120, width: 55)
                    var suppression = purpleWeight * purpleStrength
                        + greenWeight * greenStrength
                    suppression = min(suppression, 1)
                    suppression *= smoothstep(min(sat / 0.2, 1))

                    sat *= (1 - suppression)
                    let (nr, ng, nb) = hsvToRGB(hue, sat, value)

                    cube.append(Float(nr))
                    cube.append(Float(ng))
                    cube.append(Float(nb))
                    cube.append(1)
                }
            }
        }

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let filter = CIFilter(name: "CIColorCubeWithColorSpace")
        filter?.setValue(size, forKey: "inputCubeDimension")
        filter?.setValue(Data(bytes: cube, count: cube.count * MemoryLayout<Float>.stride),
                         forKey: "inputCubeData")
        filter?.setValue(colorSpace, forKey: "inputColorSpace")
        return filter
    }

    /// 1 at the band's center hue, cosine-fading to 0 at ±`width` degrees.
    private static func bandWeight(hue: Double, center: Double, width: Double) -> Double {
        var distance = abs(hue - center)
        if distance > 180 { distance = 360 - distance }
        guard distance < width else { return 0 }
        return 0.5 * (1 + cos(.pi * distance / width))
    }

    private static func smoothstep(_ x: Double) -> Double {
        let t = min(max(x, 0), 1)
        return t * t * (3 - 2 * t)
    }

    // MARK: HSV

    private static func rgbToHSV(
        _ r: Double, _ g: Double, _ b: Double
    ) -> (hue: Double, saturation: Double, value: Double) {
        let maxC = max(r, max(g, b))
        let minC = min(r, min(g, b))
        let delta = maxC - minC

        var hue = 0.0
        if delta > 0 {
            if maxC == r {
                hue = 60 * ((g - b) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxC == g {
                hue = 60 * ((b - r) / delta + 2)
            } else {
                hue = 60 * ((r - g) / delta + 4)
            }
            if hue < 0 { hue += 360 }
        }
        let saturation = maxC > 0 ? delta / maxC : 0
        return (hue, saturation, maxC)
    }

    private static func hsvToRGB(
        _ h: Double, _ s: Double, _ v: Double
    ) -> (Double, Double, Double) {
        let c = v * s
        let x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = v - c

        let (r, g, b): (Double, Double, Double)
        switch h {
        case ..<60: (r, g, b) = (c, x, 0)
        case ..<120: (r, g, b) = (x, c, 0)
        case ..<180: (r, g, b) = (0, c, x)
        case ..<240: (r, g, b) = (0, x, c)
        case ..<300: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        return (r + m, g + m, b + m)
    }
}
