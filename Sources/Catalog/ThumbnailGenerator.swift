import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Generates and stores library thumbnails as small PNGs on disk, one per
/// catalog entry (named by the entry's id). Thumbnails let the library grid
/// render quickly and survive relaunches without re-decoding every original.
struct ThumbnailGenerator {
    /// Directory the thumbnail PNGs are written into.
    let directory: URL

    /// Longest-edge size, in pixels, of a generated thumbnail.
    var maxDimension: CGFloat = 320

    /// The on-disk location of the thumbnail for a given entry id.
    func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).png")
    }

    /// Writes a downsampled PNG thumbnail of `cgImage` for `id` and returns its
    /// URL. Used to refresh a thumbnail from an already-rendered (edited)
    /// preview.
    @discardableResult
    func write(_ cgImage: CGImage, id: UUID) -> URL? {
        ensureDirectory()
        guard let scaled = Self.downsample(cgImage, maxDimension: maxDimension) else {
            return nil
        }
        let destinationURL = url(for: id)
        guard let destination = CGImageDestinationCreateWithURL(
            destinationURL as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, scaled, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return destinationURL
    }

    /// Removes an entry's thumbnail file, if any.
    func remove(id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    /// Loads an image file and produces an orientation-corrected thumbnail
    /// `CGImage` directly via ImageIO. Used for the initial import thumbnail,
    /// before any edits exist.
    static func thumbnailCGImage(for fileURL: URL, maxDimension: CGFloat = 320) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private func ensureDirectory() {
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
    }

    private static func downsample(_ cgImage: CGImage, maxDimension: CGFloat) -> CGImage? {
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let longestEdge = max(width, height)
        guard longestEdge > maxDimension else { return cgImage }

        let scale = maxDimension / longestEdge
        let newWidth = max(Int(width * scale), 1)
        let newHeight = max(Int(height * scale), 1)
        guard let context = CGContext(
            data: nil,
            width: newWidth,
            height: newHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        return context.makeImage()
    }
}
