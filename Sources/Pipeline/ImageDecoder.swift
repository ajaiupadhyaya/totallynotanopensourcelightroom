import CoreImage
import Foundation

/// Loads image files off disk into `CIImage`s.
///
/// Phase 0/1 handles standard formats (JPEG, PNG, HEIC, TIFF…) through
/// ImageIO. RAW decoding via `CIRAWFilter` is a Phase 4 concern and is
/// intentionally absent here.
enum ImageDecoder {
    /// Loads an image as a `CIImage`, honoring its EXIF orientation and
    /// downsampled so the longest edge is at most `maxDimension` points.
    ///
    /// Downsampling keeps the live preview responsive as sliders move; the
    /// full-resolution render path used for export is a separate Phase 5
    /// concern and deliberately does not exist yet.
    ///
    /// - Returns: A preview-scaled `CIImage`, or `nil` if the file could not
    ///   be decoded as an image.
    static func loadPreviewImage(from url: URL, maxDimension: CGFloat = 1600) -> CIImage? {
        guard let image = CIImage(contentsOf: url,
                                  options: [.applyOrientationProperty: true]) else {
            return nil
        }

        let longestEdge = max(image.extent.width, image.extent.height)
        guard longestEdge > maxDimension, longestEdge.isFinite, longestEdge > 0 else {
            return image
        }

        let scale = maxDimension / longestEdge
        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }
}
