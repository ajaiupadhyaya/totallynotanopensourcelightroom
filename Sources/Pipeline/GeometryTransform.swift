import CoreImage
import Foundation

/// Applies crop, rotation, straightening, and flips to an image.
///
/// Order matters and mirrors how the controls are meant to be used: flip, then
/// quarter-turn rotation, then fine straightening, then the crop. Because the
/// crop is stored in normalized coordinates it is applied *last*, against
/// whatever frame the earlier steps produced — so the same stack crops the
/// preview and the full-resolution export to the same region.
enum GeometryTransform {
    static func apply(_ image: CIImage, geometry: Geometry) -> CIImage {
        guard !geometry.isIdentity, !image.extent.isInfinite else { return image }

        var result = image
        result = applyFlips(result, geometry: geometry)

        if geometry.rotation != .none {
            result = rotate(result, degrees: Double(geometry.rotation.rawValue))
        }

        if geometry.straightenAngle != 0 {
            result = straighten(result, degrees: geometry.straightenAngle)
        }

        if geometry.cropRect != .unitFrame {
            result = crop(result, to: geometry.cropRect)
        }

        return result
    }

    // MARK: Steps

    private static func applyFlips(_ image: CIImage, geometry: Geometry) -> CIImage {
        guard geometry.flipHorizontal || geometry.flipVertical else { return image }
        let extent = image.extent
        let transform = CGAffineTransform(
            scaleX: geometry.flipHorizontal ? -1 : 1,
            y: geometry.flipVertical ? -1 : 1
        )
        return image
            .transformed(by: transform)
            .transformed(by: CGAffineTransform(
                translationX: geometry.flipHorizontal ? extent.maxX + extent.minX : 0,
                y: geometry.flipVertical ? extent.maxY + extent.minY : 0
            ))
    }

    /// Rotates about the image's center, then moves the result back to a
    /// non-negative origin so downstream extents stay simple.
    private static func rotate(_ image: CIImage, degrees: Double) -> CIImage {
        let radians = degrees * .pi / 180
        let extent = image.extent
        let toOrigin = CGAffineTransform(translationX: -extent.midX, y: -extent.midY)
        let rotation = CGAffineTransform(rotationAngle: CGFloat(radians))
        let rotated = image.transformed(by: toOrigin.concatenating(rotation))
        return normalizedOrigin(rotated)
    }

    /// Rotates by a fine angle and trims away the empty corners the rotation
    /// exposes, keeping the largest centered rectangle of the original aspect
    /// ratio — the same thing Lightroom does when you straighten.
    private static func straighten(_ image: CIImage, degrees: Double) -> CIImage {
        let original = image.extent
        let rotated = rotate(image, degrees: degrees)

        let inscribed = largestInscribedSize(
            width: original.width, height: original.height,
            radians: degrees * .pi / 180
        )
        let rotatedExtent = rotated.extent
        let rect = CGRect(
            x: rotatedExtent.midX - inscribed.width / 2,
            y: rotatedExtent.midY - inscribed.height / 2,
            width: inscribed.width,
            height: inscribed.height
        ).intersection(rotatedExtent)

        guard !rect.isNull, rect.width >= 1, rect.height >= 1 else { return rotated }
        return normalizedOrigin(rotated.cropped(to: rect))
    }

    private static func crop(_ image: CIImage, to unitRect: CGRect) -> CIImage {
        let extent = image.extent
        let rect = CGRect(
            x: extent.origin.x + unitRect.origin.x * extent.width,
            y: extent.origin.y + unitRect.origin.y * extent.height,
            width: unitRect.width * extent.width,
            height: unitRect.height * extent.height
        ).intersection(extent)

        guard !rect.isNull, rect.width >= 1, rect.height >= 1 else { return image }
        return normalizedOrigin(image.cropped(to: rect))
    }

    /// Moves an image so its extent starts at the origin.
    private static func normalizedOrigin(_ image: CIImage) -> CIImage {
        let extent = image.extent
        guard !extent.isInfinite, extent.origin != .zero else { return image }
        return image.transformed(by: CGAffineTransform(
            translationX: -extent.origin.x, y: -extent.origin.y
        ))
    }

    // MARK: Math

    /// The largest rectangle of the same aspect ratio that fits inside a
    /// `width × height` rectangle rotated by `radians`.
    ///
    /// This is the standard closed-form solution; the first branch covers the
    /// degenerate case where the rotated rectangle is so thin that the
    /// inscribed rectangle is limited by the short side alone.
    static func largestInscribedSize(
        width: CGFloat, height: CGFloat, radians: Double
    ) -> CGSize {
        guard width > 0, height > 0 else { return .zero }

        let sinA = abs(sin(radians))
        let cosA = abs(cos(radians))
        let widthIsLonger = width >= height
        let longSide = widthIsLonger ? width : height
        let shortSide = widthIsLonger ? height : width

        if shortSide <= 2 * sinA * cosA * longSide || abs(sinA - cosA) < 1e-10 {
            let half = 0.5 * shortSide
            guard sinA > 1e-10, cosA > 1e-10 else { return CGSize(width: width, height: height) }
            return widthIsLonger
                ? CGSize(width: half / sinA, height: half / cosA)
                : CGSize(width: half / cosA, height: half / sinA)
        }

        let cos2A = cosA * cosA - sinA * sinA
        return CGSize(
            width: (width * cosA - height * sinA) / cos2A,
            height: (height * cosA - width * sinA) / cos2A
        )
    }
}
