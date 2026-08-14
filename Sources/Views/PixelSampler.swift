import CoreGraphics

/// A sampled preview colour: display-referred sRGB components plus Rec. 709
/// luma, all 0…1.
struct PixelReading: Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var luma: Double
}

/// Nearest-pixel colour sampling over a CGImage, via one small RGBA8 redraw.
///
/// Built once per preview image and then read per mouse move — the redraw
/// (≤ 320 px) is the whole cost, and it happens off the per-event path. Unit
/// points are **bottom-left origin**, the canvas's image convention
/// (`EditCanvas.clickGesture` produces the same), so every caller passes the
/// point it already has; the row flip happens here, once.
struct PixelSampler {
    private let pixels: [UInt8]
    private let width: Int
    private let height: Int

    init?(image: CGImage, maxDimension: Int = 320) {
        let scale = min(1, Double(maxDimension) / Double(max(image.width, image.height, 1)))
        width = max(Int(Double(image.width) * scale), 1)
        height = max(Int(Double(image.height) * scale), 1)
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &buffer, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        pixels = buffer
    }

    func reading(atUnitPoint point: CGPoint) -> PixelReading {
        let x = Int((min(max(point.x, 0), 1) * CGFloat(width - 1)).rounded())
        // Unit y is bottom-up; rows are top-down.
        let row = (height - 1) - Int((min(max(point.y, 0), 1) * CGFloat(height - 1)).rounded())
        let i = (row * width + x) * 4
        let r = Double(pixels[i]) / 255
        let g = Double(pixels[i + 1]) / 255
        let b = Double(pixels[i + 2]) / 255
        return PixelReading(red: r, green: g, blue: b,
                            luma: ColorScience.luminance(r, g, b))
    }
}
