import CoreImage
import Foundation

/// Renders large previews as fixed-size tiles so 100%+ zoom can use the
/// full-resolution original without holding one giant render in memory.
enum PreviewTileRenderer {
    static let tileSize = 512

    static func shouldTile(_ image: CIImage) -> Bool {
        let extent = image.extent
        return max(extent.width, extent.height) > CGFloat(tileSize * 2)
    }

    /// Renders `source` through the develop stack, splitting the frame into
    /// tiles when it exceeds ``tileSize``.
    static func render(
        source: CIImage,
        stack: EditStack,
        renderer: EditRenderer,
        mlEnvironment: MLMaskEnvironment?
    ) -> CIImage {
        let extent = source.extent
        guard shouldTile(source) else {
            return renderer.render(source: source, stack: stack, mlEnvironment: mlEnvironment)
        }

        let originX = Int(floor(extent.origin.x))
        let originY = Int(floor(extent.origin.y))
        let width = Int(ceil(extent.width))
        let height = Int(ceil(extent.height))

        var composite: CIImage?
        for y in stride(from: 0, to: height, by: tileSize) {
            for x in stride(from: 0, to: width, by: tileSize) {
                let tileWidth = min(tileSize, width - x)
                let tileHeight = min(tileSize, height - y)
                let tileRect = CGRect(
                    x: CGFloat(originX + x),
                    y: CGFloat(originY + y),
                    width: CGFloat(tileWidth),
                    height: CGFloat(tileHeight)
                )
                let tileSource = source.cropped(to: tileRect)
                let rendered = renderer.render(
                    source: tileSource, stack: stack, mlEnvironment: mlEnvironment
                )
                composite = composite.map { over($0, rendered) } ?? rendered
            }
        }
        return composite?.cropped(to: extent)
            ?? renderer.render(source: source, stack: stack, mlEnvironment: mlEnvironment)
    }

    private static func over(_ base: CIImage, _ tile: CIImage) -> CIImage {
        let filter = CIFilter.sourceOverCompositing()
        filter.inputImage = tile
        filter.backgroundImage = base
        return filter.outputImage ?? base
    }
}
