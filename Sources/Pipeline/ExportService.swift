import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import UniformTypeIdentifiers

/// How an edited photo should be written to a new file.
struct ExportSettings: Codable, Equatable {
    enum Format: String, Codable, CaseIterable, Identifiable {
        case jpeg, heif, png, tiff

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .jpeg: "JPEG"
            case .heif: "HEIF"
            case .png: "PNG"
            case .tiff: "TIFF"
            }
        }

        var fileExtension: String {
            switch self {
            case .jpeg: "jpg"
            case .heif: "heic"
            case .png: "png"
            case .tiff: "tiff"
            }
        }

        /// Only lossy formats have a meaningful quality setting.
        var supportsQuality: Bool {
            self == .jpeg || self == .heif
        }
    }

    /// The color profile embedded in the exported file. sRGB is the safe
    /// default for anything that will be viewed outside a color-managed app.
    enum ColorProfile: String, Codable, CaseIterable, Identifiable {
        case sRGB, displayP3, adobeRGB

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .sRGB: "sRGB"
            case .displayP3: "Display P3"
            case .adobeRGB: "Adobe RGB (1998)"
            }
        }

        var colorSpace: CGColorSpace {
            let name: CFString = switch self {
            case .sRGB: CGColorSpace.sRGB
            case .displayP3: CGColorSpace.displayP3
            case .adobeRGB: CGColorSpace.adobeRGB1998
            }
            return CGColorSpace(name: name) ?? CGColorSpaceCreateDeviceRGB()
        }
    }

    var format: Format = .jpeg

    /// Compression quality for lossy formats, `0...1`.
    var quality: Double = 0.9

    var colorProfile: ColorProfile = .sRGB

    /// Longest-edge limit in pixels. `nil` exports at full resolution; we never
    /// upscale, so a value larger than the original is a no-op.
    var maxDimension: Double?

    /// Output sharpening matched to how the file will be viewed.
    var outputSharpening: OutputSharpening = .none

    /// Sharpening applied at the very end of export, sized to the output.
    ///
    /// Resampling softens an image, and how much sharpening it needs back
    /// depends on the medium: a print is viewed at arm's length on diffusing
    /// paper and takes more, a screen image at 100% takes little, and a heavily
    /// compressed web file wants a fine radius because a coarse one gives the
    /// encoder halos to spend bits on. This is applied *after* any resize, so
    /// it is calibrated to the pixels actually written.
    enum OutputSharpening: String, Codable, CaseIterable, Identifiable {
        case none, screen, web, print

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .none: "None"
            case .screen: "Screen"
            case .web: "Web (compressed)"
            case .print: "Print"
            }
        }

        /// Unsharp-mask radius in pixels.
        var radius: Double {
            switch self {
            case .none: 0
            case .screen: 0.8
            case .web: 0.6
            case .print: 1.4
            }
        }

        var intensity: Double {
            switch self {
            case .none: 0
            case .screen: 0.45
            case .web: 0.35
            case .print: 0.85
            }
        }
    }
}

enum ExportError: Error, LocalizedError {
    case sourceUnreadable(URL)
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .sourceUnreadable(let url):
            "Could not read the original file at \(url.path)."
        case .encodingFailed:
            "Could not encode the exported image."
        }
    }
}

/// Renders an edit stack against the **full-resolution** original and writes the
/// result to a new file.
///
/// This is the one place where edits become pixels. It is deliberately separate
/// from the preview path: the preview is downsampled for responsiveness, while
/// export always re-decodes the untouched original at full size and replays the
/// same ``EditStack`` through the same ``EditRenderer``. The source file is
/// never modified.
struct ExportService {
    let renderer: EditRenderer

    init(renderer: EditRenderer = EditRenderer()) {
        self.renderer = renderer
    }

    /// Suggests a filename for an exported photo: the original's base name plus
    /// the target format's extension.
    static func suggestedFileName(for sourceURL: URL, settings: ExportSettings) -> String {
        let base = sourceURL.deletingPathExtension().lastPathComponent
        return "\(base).\(settings.format.fileExtension)"
    }

    /// Renders `stack` against the original at `sourceURL` and writes it to
    /// `destination`.
    func export(
        sourceURL: URL,
        stack: EditStack,
        settings: ExportSettings,
        to destination: URL
    ) throws {
        guard let source = ImageDecoder.loadFullImage(from: sourceURL) else {
            throw ExportError.sourceUnreadable(sourceURL)
        }

        var image = renderer.render(source: source, stack: stack)
        if let maxDimension = settings.maxDimension, maxDimension > 0 {
            image = ImageDecoder.downsampled(image, maxDimension: CGFloat(maxDimension))
        }
        image = applyOutputSharpening(image, settings: settings)

        let data = try encode(image, settings: settings)
        try data.write(to: destination, options: .atomic)
    }

    /// Applies output sharpening after resizing, so its radius is in output
    /// pixels rather than source pixels.
    func applyOutputSharpening(_ image: CIImage, settings: ExportSettings) -> CIImage {
        let sharpening = settings.outputSharpening
        guard sharpening != .none else { return image }

        let filter = CIFilter.unsharpMask()
        filter.inputImage = image
        filter.radius = Float(sharpening.radius)
        filter.intensity = Float(sharpening.intensity)
        return filter.outputImage ?? image
    }

    /// Encodes a rendered image into the target container, embedding the chosen
    /// color profile.
    func encode(_ image: CIImage, settings: ExportSettings) throws -> Data {
        let space = settings.colorProfile.colorSpace
        let context = renderer.context
        let options: [CIImageRepresentationOption: Any] = settings.format.supportsQuality
            ? [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption:
                min(max(settings.quality, 0), 1)]
            : [:]

        let data: Data? = switch settings.format {
        case .jpeg:
            context.jpegRepresentation(of: image, colorSpace: space, options: options)
        case .heif:
            context.heifRepresentation(of: image, format: .RGBA8,
                                       colorSpace: space, options: options)
        case .png:
            context.pngRepresentation(of: image, format: .RGBA8,
                                      colorSpace: space, options: options)
        case .tiff:
            context.tiffRepresentation(of: image, format: .RGBA8,
                                       colorSpace: space, options: options)
        }

        guard let data, !data.isEmpty else { throw ExportError.encodingFailed }
        return data
    }
}
