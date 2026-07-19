import Foundation
import ImageIO

/// Read-only capture metadata pulled from a file's EXIF/TIFF tags.
///
/// Purely informational — nothing here feeds the render pipeline, and nothing
/// is ever written back to the original file.
struct PhotoMetadata: Equatable {
    var pixelWidth: Int?
    var pixelHeight: Int?
    var cameraMake: String?
    var cameraModel: String?
    var lensModel: String?
    var focalLength: Double?
    var aperture: Double?
    var shutterSpeed: Double?
    var iso: Int?
    var captureDate: Date?
    var colorProfile: String?

    /// Human-readable dimensions, e.g. "6000 × 4000".
    var dimensions: String? {
        guard let pixelWidth, let pixelHeight else { return nil }
        return "\(pixelWidth) × \(pixelHeight)"
    }

    var camera: String? {
        let parts = [cameraMake, cameraModel].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Shutter speed as photographers write it: "1/250" or "2s".
    var shutterDescription: String? {
        guard let shutterSpeed, shutterSpeed > 0 else { return nil }
        if shutterSpeed >= 1 {
            return String(format: "%.1fs", shutterSpeed)
        }
        return "1/\(Int((1 / shutterSpeed).rounded()))"
    }

    var apertureDescription: String? {
        guard let aperture else { return nil }
        return String(format: "ƒ/%.1f", aperture)
    }

    var focalLengthDescription: String? {
        guard let focalLength else { return nil }
        return String(format: "%.0fmm", focalLength)
    }

    /// Reads metadata without decoding pixels.
    static func read(from url: URL) -> PhotoMetadata {
        var metadata = PhotoMetadata()
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any]
        else { return metadata }

        metadata.pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int
        metadata.pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int
        metadata.colorProfile = properties[kCGImagePropertyProfileName] as? String

        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            metadata.cameraMake = tiff[kCGImagePropertyTIFFMake] as? String
            metadata.cameraModel = tiff[kCGImagePropertyTIFFModel] as? String
        }

        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            metadata.lensModel = exif[kCGImagePropertyExifLensModel] as? String
            metadata.focalLength = exif[kCGImagePropertyExifFocalLength] as? Double
            metadata.aperture = exif[kCGImagePropertyExifFNumber] as? Double
            metadata.shutterSpeed = exif[kCGImagePropertyExifExposureTime] as? Double
            if let isoValues = exif[kCGImagePropertyExifISOSpeedRatings] as? [Int] {
                metadata.iso = isoValues.first
            }
            if let dateString = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
                metadata.captureDate = exifDateFormatter.date(from: dateString)
            }
        }

        return metadata
    }

    /// EXIF stores dates as "yyyy:MM:dd HH:mm:ss" in an unspecified zone.
    private static let exifDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}
