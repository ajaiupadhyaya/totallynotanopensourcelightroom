import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Persists ML-generated masks beside thumbnails so they are not recomputed
/// every time a mask is toggled or a slider moves.
final class MLMaskCache {
    static let shared = MLMaskCache()

    private let directory: URL
    private var memory: [String: CIImage] = [:]
    private let lock = NSLock()
    private let limit = 16

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                   in: .userDomainMask).first!
            self.directory = support
                .appendingPathComponent("PhotoEditor/ml-masks", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.directory,
                                                 withIntermediateDirectories: true)
    }

    func load(kind: SubjectMaskProvider.Kind, environment: MLMaskEnvironment) -> CIImage? {
        let key = cacheKey(kind: kind, environment: environment)
        lock.lock()
        if let cached = memory[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let url = fileURL(kind: kind, environment: environment)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }

        let image = CIImage(cgImage: cgImage)
        lock.lock()
        if memory.count >= limit { memory.removeAll() }
        memory[key] = image
        lock.unlock()
        return image
    }

    func store(
        _ mask: CIImage, kind: SubjectMaskProvider.Kind,
        environment: MLMaskEnvironment, context: CIContext
    ) {
        let extent = mask.extent
        guard !extent.isInfinite, let cgImage = context.createCGImage(mask, from: extent) else {
            return
        }
        let url = fileURL(kind: kind, environment: environment)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else { return }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { return }

        let key = cacheKey(kind: kind, environment: environment)
        lock.lock()
        if memory.count >= limit { memory.removeAll() }
        memory[key] = mask
        lock.unlock()
    }

    func invalidate(entryID: UUID) {
        lock.lock()
        memory = memory.filter { !$0.key.hasPrefix(entryID.uuidString) }
        lock.unlock()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }
        for file in files where file.lastPathComponent.hasPrefix(entryID.uuidString) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func cacheKey(kind: SubjectMaskProvider.Kind, environment: MLMaskEnvironment) -> String {
        "\(environment.entryID.uuidString)-\(environment.geometryToken)-\(kind.rawValue)"
    }

    private func fileURL(kind: SubjectMaskProvider.Kind, environment: MLMaskEnvironment) -> URL {
        directory.appendingPathComponent("\(cacheKey(kind: kind, environment: environment)).png")
    }
}
