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
    /// Throws away the `SourceImage`'s RAW provenance, so this is only for
    /// callers that will never edit in the sensor domain. `processVersion` is
    /// still required: it selects the RAW *decode* policy, which differs
    /// between PV1 and PV2 (see ``RawDecodePolicy``).
    ///
    /// - Returns: The decoded image, or `nil` if the file could not be read as
    ///   an image (including a RAW format this machine cannot decode).
    static func loadFullImage(from url: URL, processVersion: Int) -> CIImage? {
        loadSource(from: url, maxDimension: nil, processVersion: processVersion)?.image
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
    static func loadPreviewImage(from url: URL, maxDimension: CGFloat = 1600,
                                 processVersion: Int) -> CIImage? {
        loadSource(from: url, maxDimension: maxDimension,
                   processVersion: processVersion)?.image
    }

    /// Loads a file as a `SourceImage`, decoding RAW under the process
    /// version's frozen decode policy (see ``RawDecodePolicy``).
    ///
    /// Under PV2 a RAW keeps its `CIRAWFilter` so white balance, exposure, and
    /// the baseline boost can act on sensor data. Under PV1 it is decoded at
    /// Apple's defaults, full-size, and downsampled afterwards — byte for byte
    /// what the pre-PV2 decoder did — and handed back as `.rendered`, because
    /// the PV1 chain never reaches the filter.
    ///
    /// `processVersion` has no default on purpose: silently decoding somebody's
    /// PV1 photo under PV2's policy is exactly the bug this parameter exists to
    /// prevent, so every call site has to state which look it wants.
    static func loadSource(from url: URL, maxDimension: CGFloat?,
                           processVersion: Int) -> SourceImage? {
        if isRAW(url), let filter = CIRAWFilter(imageURL: url) {
            let policy = RawDecodePolicy(processVersion: processVersion)
            if policy.disablesGamutMapping { filter.isGamutMappingEnabled = false }
            if let edrAmount = policy.edrAmount {
                filter.extendedDynamicRangeAmount = Float(edrAmount)
            }
            if policy.usesScaleFactorPreviews {
                if let maxDimension {
                    let native = max(filter.nativeSize.width, filter.nativeSize.height)
                    if native > maxDimension && native > 0 {
                        filter.scaleFactor = Float(maxDimension / native)
                    }
                }
                return .raw(filter)
            }
            if let image = filter.outputImage {
                guard let maxDimension else { return .rendered(image) }
                return .rendered(downsampled(image, maxDimension: maxDimension))
            }
            // outputImage nil: fall through to ImageIO, as the pre-PV2 decoder
            // did for a RAW that CIRAWFilter accepted but could not render.
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
