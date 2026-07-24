import CoreImage

/// Content-aware remove via cached exemplar inpainting.
///
/// Uses a CPU PatchMatch-style search so the feature works without requiring
/// the Metal toolchain at build time. Results are memoised per spot geometry.
enum PatchMatchInpainter {
    private static let cacheLock = NSLock()
    private static var cache: [String: CIImage] = [:]
    private static let cacheLimit = 12

    static func apply(
        _ spot: RetouchSpot, to image: CIImage, context: CIContext
    ) -> CIImage {
        let extent = image.extent
        guard !extent.isInfinite,
              let cgImage = context.createCGImage(image, from: extent) else { return image }

        let key = cacheKey(spot: spot, extent: extent)
        cacheLock.lock()
        if let cached = cache[key] {
            cacheLock.unlock()
            return composite(cached, over: image, spot: spot, extent: extent)
        }
        cacheLock.unlock()

        guard let inpainted = inpaint(cgImage: cgImage, spot: spot) else { return image }
        let result = CIImage(cgImage: inpainted)

        cacheLock.lock()
        if cache.count >= cacheLimit { cache.removeAll() }
        cache[key] = result
        cacheLock.unlock()

        return composite(result, over: image, spot: spot, extent: extent)
    }

    static func invalidateAll() {
        cacheLock.lock()
        cache.removeAll()
        cacheLock.unlock()
    }

    // MARK: CPU PatchMatch

    private static func inpaint(cgImage: CGImage, spot: RetouchSpot) -> CGImage? {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 8, height > 8 else { return nil }

        var pixels = rasterize(cgImage)
        var mask = buildMask(spot: spot, width: width, height: height)
        let patchRadius = 4
        let searchRadius = min(32, max(width, height) / 4)

        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                guard mask[index] > 0.5 else { continue }

                var bestScore = Double.greatestFiniteMagnitude
                var bestX = x
                var bestY = y

                var sy = max(patchRadius, y - searchRadius)
                while sy <= min(height - patchRadius - 1, y + searchRadius) {
                    var sx = max(patchRadius, x - searchRadius)
                    while sx <= min(width - patchRadius - 1, x + searchRadius) {
                        if mask[sy * width + sx] > 0.5 { sx += patchRadius; continue }
                        let score = patchScore(
                            pixels: pixels, mask: mask,
                            destX: x, destY: y, sourceX: sx, sourceY: sy,
                            width: width, height: height, radius: patchRadius
                        )
                        if score < bestScore {
                            bestScore = score
                            bestX = sx
                            bestY = sy
                        }
                        sx += patchRadius
                    }
                    sy += patchRadius
                }

                let sourceIndex = (bestY * width + bestX) * 4
                let destIndex = index * 4
                pixels[destIndex] = pixels[sourceIndex]
                pixels[destIndex + 1] = pixels[sourceIndex + 1]
                pixels[destIndex + 2] = pixels[sourceIndex + 2]
            }
        }

        return imageFromPixels(pixels, width: width, height: height)
    }

    private static func patchScore(
        pixels: [UInt8], mask: [Double],
        destX: Int, destY: Int, sourceX: Int, sourceY: Int,
        width: Int, height: Int, radius: Int
    ) -> Double {
        var sum = 0.0
        var count = 0
        for dy in -radius...radius {
            for dx in -radius...radius {
                let tx = destX + dx
                let ty = destY + dy
                let px = sourceX + dx
                let py = sourceY + dy
                guard tx >= 0, ty >= 0, tx < width, ty < height,
                      px >= 0, py >= 0, px < width, py < height else { continue }
                guard mask[ty * width + tx] > 0.5 else { continue }
                let ti = (ty * width + tx) * 4
                let pi = (py * width + px) * 4
                let dr = Double(pixels[ti]) - Double(pixels[pi])
                let dg = Double(pixels[ti + 1]) - Double(pixels[pi + 1])
                let db = Double(pixels[ti + 2]) - Double(pixels[pi + 2])
                sum += dr * dr + dg * dg + db * db
                count += 1
            }
        }
        return count > 0 ? sum / Double(count) : .greatestFiniteMagnitude
    }

    private static func rasterize(_ image: CGImage) -> [UInt8] {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return pixels }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }

    private static func imageFromPixels(_ pixels: [UInt8], width: Int, height: Int) -> CGImage? {
        var copy = pixels
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &copy, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        return ctx.makeImage()
    }

    private static func buildMask(spot: RetouchSpot, width: Int, height: Int) -> [Double] {
        var mask = [Double](repeating: 0, count: width * height)
        let radius = max(spot.radius * Double(width), 2)

        func paint(cx: Double, cy: Double) {
            let centerX = Int(cx * Double(width))
            let centerY = Int((1 - cy) * Double(height))
            let r = Int(radius)
            for y in (centerY - r)...(centerY + r) {
                for x in (centerX - r)...(centerX + r) {
                    guard x >= 0, y >= 0, x < width, y < height else { continue }
                    if hypot(Double(x - centerX), Double(y - centerY)) <= radius {
                        mask[y * width + x] = 1
                    }
                }
            }
        }

        switch spot.kind {
        case .circle:
            paint(cx: spot.center.x, cy: spot.center.y)
        case .stroke:
            for point in spot.strokePoints {
                paint(cx: point.x, cy: point.y)
            }
        }
        return mask
    }

    private static func composite(
        _ inpainted: CIImage, over background: CIImage,
        spot: RetouchSpot, extent: CGRect
    ) -> CIImage {
        guard let mask = RetouchRenderer.alphaMask(for: spot, extent: extent) else {
            return inpainted.cropped(to: extent)
        }
        let blend = CIFilter.blendWithMask()
        blend.inputImage = inpainted
        blend.backgroundImage = background
        blend.maskImage = mask
        return blend.outputImage?.cropped(to: extent) ?? background
    }

    private static func cacheKey(spot: RetouchSpot, extent: CGRect) -> String {
        [
            spot.id.uuidString,
            spot.mode.rawValue,
            spot.kind.rawValue,
            String(format: "%.4f", spot.center.x),
            String(format: "%.4f", spot.center.y),
            String(format: "%.4f", spot.radius),
            String(spot.strokePoints.count),
            String(format: "%.0f", extent.width),
            String(format: "%.0f", extent.height),
        ].joined(separator: "-")
    }
}
