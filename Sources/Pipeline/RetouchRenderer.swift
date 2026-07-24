import CoreImage
import CoreImage.CIFilterBuiltins

/// Applies spot-removal corrections by compositing a shifted copy of the image
/// over itself through a feathered mask, or content-aware inpainting for remove.
enum RetouchRenderer {
    static func apply(
        _ spots: [RetouchSpot], to image: CIImage, context: CIContext
    ) -> CIImage {
        var result = image
        for spot in spots where spot.isEnabled {
            result = apply(spot, to: result, context: context)
        }
        return result
    }

    static func apply(
        _ spot: RetouchSpot, to image: CIImage, context: CIContext
    ) -> CIImage {
        let extent = image.extent
        guard !extent.isInfinite, extent.width >= 1, extent.height >= 1 else { return image }

        if spot.mode == .remove {
            return PatchMatchInpainter.apply(spot, to: image, context: context)
        }

        let centerPoint = spot.effectiveCenter
        let radius = max(spot.radius * extent.width, 1)
        let center = CGPoint(
            x: extent.origin.x + centerPoint.x * extent.width,
            y: extent.origin.y + centerPoint.y * extent.height
        )
        var offset = CGVector(
            dx: spot.sourceOffset.dx * extent.width,
            dy: spot.sourceOffset.dy * extent.height
        )

        if spot.mode == .heal, offset == .zero {
            offset = autoSourceOffset(for: spot, image: image, context: context)
        }

        var patch = image
            .clampedToExtent()
            .transformed(by: CGAffineTransform(translationX: -offset.dx, y: -offset.dy))
            .cropped(to: extent)

        if spot.mode == .heal {
            patch = colorMatched(patch,
                                 to: image,
                                 center: center,
                                 radius: radius,
                                 offset: offset,
                                 context: context)
        }

        guard var mask = regionMask(for: spot, center: center, extent: extent) else { return image }
        if spot.opacity < 0.999 {
            mask = scaledMask(mask, opacity: spot.opacity, extent: extent)
        }

        let blend = CIFilter.blendWithMask()
        blend.inputImage = patch
        blend.backgroundImage = image
        blend.maskImage = mask
        return blend.outputImage?.cropped(to: extent) ?? image
    }

    // MARK: Auto source

    /// Finds the best-matching source patch in a ring around the destination.
    static func autoSourceOffset(
        for spot: RetouchSpot, image: CIImage, context: CIContext
    ) -> CGVector {
        let extent = image.extent
        let center = spot.effectiveCenter
        let patchRadius = max(spot.radius * extent.width, 4)
        let destCenter = CGPoint(
            x: extent.origin.x + center.x * extent.width,
            y: extent.origin.y + center.y * extent.height
        )
        let sampleSize = patchRadius * 2
        let destRect = CGRect(
            x: destCenter.x - patchRadius, y: destCenter.y - patchRadius,
            width: sampleSize, height: sampleSize
        ).integral.intersection(extent)
        guard let destPatch = cropBitmap(image, rect: destRect, context: context) else {
            return CGVector(dx: patchRadius * 1.5, dy: 0)
        }

        var bestScore = Double.greatestFiniteMagnitude
        var bestOffset = CGVector(dx: patchRadius * 1.5, dy: 0)
        let searchRadius = patchRadius * 4
        let step = max(patchRadius * 0.75, 6)

        var dy = -searchRadius
        while dy <= searchRadius {
            var dx = -searchRadius
            while dx <= searchRadius {
                let distance = hypot(dx, dy)
                if distance < patchRadius * 1.2 || distance > searchRadius { dx += step; continue }
                let sourceRect = destRect.offsetBy(dx: dx, dy: dy).intersection(extent)
                guard sourceRect.width >= sampleSize * 0.8, sourceRect.height >= sampleSize * 0.8,
                      let sourcePatch = cropBitmap(image, rect: sourceRect, context: context)
                else { dx += step; continue }
                let score = patchDistance(destPatch, sourcePatch)
                if score < bestScore {
                    bestScore = score
                    bestOffset = CGVector(dx: dx, dy: dy)
                }
                dx += step
            }
            dy += step
        }
        return bestOffset
    }

    private static func cropBitmap(
        _ image: CIImage, rect: CGRect, context: CIContext
    ) -> [Float]? {
        let clamped = rect.intersection(image.extent).integral
        guard clamped.width >= 2, clamped.height >= 2,
              let cg = context.createCGImage(image, from: clamped) else { return nil }
        let width = cg.width
        let height = cg.height
        var pixels = [Float](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 32,
            bytesPerRow: width * 4 * MemoryLayout<Float>.stride, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
        ) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }

    private static func patchDistance(_ a: [Float], _ b: [Float]) -> Double {
        let count = min(a.count, b.count) / 4
        guard count > 0 else { return .greatestFiniteMagnitude }
        var sum = 0.0
        for index in 0..<count {
            let base = index * 4
            let dr = Double(a[base] - b[base])
            let dg = Double(a[base + 1] - b[base + 1])
            let db = Double(a[base + 2] - b[base + 2])
            sum += dr * dr + dg * dg + db * db
        }
        return sum / Double(count)
    }

    // MARK: Heal color matching

    private static func colorMatched(
        _ patch: CIImage,
        to image: CIImage,
        center: CGPoint,
        radius: CGFloat,
        offset: CGVector,
        context: CIContext
    ) -> CIImage {
        let surround = radius * 2
        let destRect = CGRect(
            x: center.x - surround, y: center.y - surround,
            width: surround * 2, height: surround * 2
        )
        let sourceRect = CGRect(
            x: center.x + offset.dx - radius, y: center.y + offset.dy - radius,
            width: radius * 2, height: radius * 2
        )

        guard let dest = averageLinear(of: image, in: destRect, context: context),
              let source = averageLinear(of: image, in: sourceRect, context: context)
        else { return patch }

        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = patch
        matrix.rVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        matrix.gVector = CIVector(x: 0, y: 1, z: 0, w: 0)
        matrix.bVector = CIVector(x: 0, y: 0, z: 1, w: 0)
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        matrix.biasVector = CIVector(
            x: CGFloat(dest.red - source.red),
            y: CGFloat(dest.green - source.green),
            z: CGFloat(dest.blue - source.blue),
            w: 0
        )
        return matrix.outputImage ?? patch
    }

    private static func averageLinear(
        of image: CIImage, in rect: CGRect, context: CIContext
    ) -> (red: Double, green: Double, blue: Double)? {
        let clamped = rect.intersection(image.extent).integral.intersection(image.extent)
        guard !clamped.isNull, clamped.width >= 1, clamped.height >= 1 else { return nil }

        let filter = CIFilter.areaAverage()
        filter.inputImage = image
        filter.extent = clamped
        guard let output = filter.outputImage else { return nil }

        var buffer = [Float](repeating: 0, count: 4)
        context.render(
            output,
            toBitmap: &buffer,
            rowBytes: 4 * MemoryLayout<Float>.stride,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBAf,
            colorSpace: nil
        )
        return (Double(buffer[0]), Double(buffer[1]), Double(buffer[2]))
    }

    // MARK: Masks

    static func alphaMask(for spot: RetouchSpot, extent: CGRect) -> CIImage? {
        let center = CGPoint(
            x: extent.origin.x + spot.effectiveCenter.x * extent.width,
            y: extent.origin.y + spot.effectiveCenter.y * extent.height
        )
        guard var mask = regionMask(for: spot, center: center, extent: extent) else { return nil }
        if spot.opacity < 0.999 {
            mask = scaledMask(mask, opacity: spot.opacity, extent: extent)
        }
        return mask
    }

    private static func regionMask(
        for spot: RetouchSpot, center: CGPoint, extent: CGRect
    ) -> CIImage? {
        switch spot.kind {
        case .circle:
            return circularMask(center: center, radius: max(spot.radius * extent.width, 1),
                                feather: spot.feather)
        case .stroke:
            return strokeMask(points: spot.strokePoints, radius: spot.radius,
                              feather: spot.feather, extent: extent)
        }
    }

    private static func circularMask(
        center: CGPoint, radius: CGFloat, feather: Double
    ) -> CIImage? {
        let clampedFeather = min(max(feather, 0), 1)
        let inner = max(min(radius * (1 - clampedFeather), radius - 0.5), 0)

        let gradient = CIFilter.radialGradient()
        gradient.center = center
        gradient.radius0 = Float(inner)
        gradient.radius1 = Float(radius)
        gradient.color0 = CIColor.white
        gradient.color1 = CIColor.black
        guard let circle = gradient.outputImage else { return nil }

        let toAlpha = CIFilter.maskToAlpha()
        toAlpha.inputImage = circle
        return toAlpha.outputImage
    }

    private static func strokeMask(
        points: [CGPoint], radius: Double, feather: Double, extent: CGRect
    ) -> CIImage? {
        guard !points.isEmpty else { return nil }
        var result = CIImage(color: .black).cropped(to: extent)
        let brushRadius = max(radius * extent.width, 1)
        let inner = max(min(brushRadius * (1 - feather), brushRadius - 0.5), 0)

        for point in interpolatedPoints(points, unitStep: max(radius * 0.45, 0.002)) {
            let center = CGPoint(
                x: extent.origin.x + point.x * extent.width,
                y: extent.origin.y + point.y * extent.height
            )
            let dab = CIFilter.radialGradient()
            dab.center = center
            dab.radius0 = Float(inner)
            dab.radius1 = Float(brushRadius)
            dab.color0 = .white
            dab.color1 = .black
            guard let image = dab.outputImage?.cropped(to: extent) else { continue }
            let composite = CIFilter.maximumCompositing()
            composite.inputImage = image
            composite.backgroundImage = result
            result = composite.outputImage?.cropped(to: extent) ?? result
        }

        let toAlpha = CIFilter.maskToAlpha()
        toAlpha.inputImage = result
        return toAlpha.outputImage
    }

    private static func interpolatedPoints(
        _ points: [CGPoint], unitStep: Double
    ) -> [CGPoint] {
        guard var previous = points.first else { return [] }
        var output = [previous]
        for point in points.dropFirst() {
            let distance = hypot(point.x - previous.x, point.y - previous.y)
            let segments = max(Int(ceil(distance / unitStep)), 1)
            for index in 1...segments {
                let t = CGFloat(index) / CGFloat(segments)
                output.append(CGPoint(
                    x: previous.x + (point.x - previous.x) * t,
                    y: previous.y + (point.y - previous.y) * t
                ))
            }
            previous = point
        }
        return output
    }

    private static func scaledMask(_ mask: CIImage, opacity: Double, extent: CGRect) -> CIImage {
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = mask
        let scale = CGFloat(opacity)
        matrix.rVector = CIVector(x: scale, y: 0, z: 0, w: 0)
        matrix.gVector = CIVector(x: 0, y: scale, z: 0, w: 0)
        matrix.bVector = CIVector(x: 0, y: 0, z: scale, w: 0)
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        return matrix.outputImage?.cropped(to: extent) ?? mask
    }
}
