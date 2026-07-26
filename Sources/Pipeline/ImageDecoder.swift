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
        loadSource(from: url, maxDimension: nil)?.image
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
        loadSource(from: url, maxDimension: maxDimension)?.image
    }

    /// Loads a file as a `SourceImage`. RAW files keep their `CIRAWFilter`
    /// (configured for PV2: gamut mapping off so out-of-gamut color survives,
    /// EDR headroom on so highlights above 1.0 survive, decoded at
    /// `maxDimension` via `scaleFactor` rather than decode-then-downsample).
    /// Everything else decodes through ImageIO as before.
    static func loadSource(from url: URL, maxDimension: CGFloat?) -> SourceImage? {
        if isRAW(url), let filter = CIRAWFilter(imageURL: url) {
            filter.isGamutMappingEnabled = false
            filter.extendedDynamicRangeAmount = 1.0
            if let maxDimension {
                let native = max(filter.nativeSize.width, filter.nativeSize.height)
                if native > maxDimension && native > 0 {
                    filter.scaleFactor = Float(maxDimension / native)
                }
            }
            return .raw(filter)
        }
        guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            return nil
        }
        if let maxDimension {
            return .rendered(downsampled(image, maxDimension: maxDimension))
        }
        return .rendered(image)
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
}
