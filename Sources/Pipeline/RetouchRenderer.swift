import CoreImage
import CoreImage.CIFilterBuiltins

/// Applies spot-removal corrections by compositing a shifted copy of the image
/// over itself through a feathered circular mask.
///
/// Clone is exactly that composite. Heal additionally measures the average
/// color around the destination and of the source patch, and biases the copied
/// pixels by the difference — so a patch borrowed from a slightly darker piece
/// of sky still disappears into its new surroundings.
///
/// Spots apply in order, each sampling the image as retouched so far, so a
/// later spot can safely borrow from an area an earlier spot cleaned up.
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

        let radius = max(spot.radius * extent.width, 1)
        let center = CGPoint(
            x: extent.origin.x + spot.center.x * extent.width,
            y: extent.origin.y + spot.center.y * extent.height
        )
        let offset = CGVector(
            dx: spot.sourceOffset.dx * extent.width,
            dy: spot.sourceOffset.dy * extent.height
        )

        // Shift the image so the source region lands on the destination: the
        // pixel shown at p is image(p + offset). Clamping first keeps a source
        // near the frame edge from dragging transparency in.
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

        guard let mask = circularMask(center: center,
                                      radius: radius,
                                      feather: spot.feather) else { return image }

        let blend = CIFilter.blendWithMask()
        blend.inputImage = patch
        blend.backgroundImage = image
        blend.maskImage = mask
        return blend.outputImage?.cropped(to: extent) ?? image
    }

    // MARK: Heal color matching

    /// Shifts the patch by (destination-surround average − source average),
    /// per channel, so the copied texture takes on the local tone it lands in.
    ///
    /// Averages are read back in the **linear working space** (`colorSpace:
    /// nil`) because the bias is applied by `CIColorMatrix`, which operates on
    /// working-space values — a bias measured in gamma-encoded sRGB would
    /// over-correct shadows and under-correct highlights.
    private static func colorMatched(
        _ patch: CIImage,
        to image: CIImage,
        center: CGPoint,
        radius: CGFloat,
        offset: CGVector,
        context: CIContext
    ) -> CIImage {
        // The destination sample rect is twice the spot radius on every side,
        // so the defect being removed is a minority of the average and the
        // surrounding tone dominates.
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

    // MARK: Mask

    /// A feathered white circle on black, converted to the alpha mask
    /// `CIBlendWithMask` actually reads.
    private static func circularMask(
        center: CGPoint, radius: CGFloat, feather: Double
    ) -> CIImage? {
        let clampedFeather = min(max(feather, 0), 1)
        // Never let the inner radius reach the outer one: CIRadialGradient
        // with radius0 == radius1 does not draw a hard-edged circle, it
        // degenerates into a soft falloff. Half a pixel of transition is
        // visually hard and keeps the gradient well-defined.
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
}
