import CoreImage
import Foundation
import UniformTypeIdentifiers

/// Loads image files off disk into `CIImage`s.
///
/// Standard formats (JPEG, PNG, HEIC, TIFF…) go through ImageIO. Camera RAW
/// files are routed through `CIRAWFilter`, which decodes the sensor data and
/// applies Apple's baseline demosaic//color rendering — the decoded result is
/// still just a `CIImage`, so the rest of the pipeline is unchanged.
///
/// Nothing here ever writes to the source file.
enum ImageDecoder {
    /// True when the file's type conforms to `public.camera-raw-image`.
    ///
    /// Type identification is delegated to the system rather than a hardcoded
    /// extension list, so any RAW format the installed macOS understands is
    /// picked up automatically.
    static func isRAW(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else {
            return false
        }
        return type.conforms(to: .rawImage)
    }

    /// Decodes a file at full resolution, honoring EXIF orientation.
    ///
    /// - Returns: The decoded image, or `nil` if the file could not be read as
    ///   an image (including a RAW format this machine cannot decode).
    static func loadFullImage(from url: URL) -> CIImage? {
        if isRAW(url), let raw = loadRAW(from: url) {
            return raw
        }
        return CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
    }

    /// Loads an image as a `CIImage`, honoring its EXIF orientation and
    /// downsampled so the longest edge is at most `maxDimension` points.
    ///
    /// Downsampling keeps the live preview responsive as sliders move. Export
    /// uses ``loadFullImage(from:)`` instead so the written file is rendered
    /// from the full-resolution original, never from this preview.
    ///
    /// - Returns: A preview-scaled `CIImage`, or `nil` if the file could not
    ///   be decoded as an image.
    static func loadPreviewImage(from url: URL, maxDimension: CGFloat = 1600) -> CIImage? {
        guard let image = loadFullImage(from: url) else { return nil }
        return downsampled(image, maxDimension: maxDimension)
    }

    /// Scales an image down so its longest edge is at most `maxDimension`.
    /// Images already at or below that size are returned untouched (we never
    /// upscale).
    static func downsampled(_ image: CIImage, maxDimension: CGFloat) -> CIImage {
        let longestEdge = max(image.extent.width, image.extent.height)
        guard longestEdge.isFinite, longestEdge > 0, longestEdge > maxDimension else {
            return image
        }
        let scale = maxDimension / longestEdge
        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    // MARK: Private

    /// Decodes a camera RAW file via `CIRAWFilter`.
    ///
    /// The filter's defaults are Apple's baseline rendering for the camera
    /// model — a reasonable neutral starting point, since our own adjustments
    /// are applied downstream on top of it. RAW-specific controls (per-file
    /// demosaic and noise-reduction parameters) are deliberately not exposed;
    /// the edit stack stays format-independent.
    private static func loadRAW(from url: URL) -> CIImage? {
        guard let filter = CIRAWFilter(imageURL: url) else { return nil }
        return filter.outputImage
    }
}
