import CoreImage

/// Memoises colour-range cubes.
///
/// A 64³ cube is 262,144 entries built on the CPU. Dragging the tolerance
/// slider would otherwise rebuild it on every tick, which is the difference
/// between a live control and a stuttering one. Mirrors ``ColorCubeCache``.
final class RangeMaskCubeCache {
    static let shared = RangeMaskCubeCache()

    private struct Key: Hashable {
        let red, green, blue: Double
        let tolerance, falloff: Double
    }

    private var cache: [Key: CIFilter] = [:]
    private let lock = NSLock()
    private let limit = 24

    func filter(color: MaskColor, tolerance: Double, falloff: Double) -> CIFilter? {
        let key = Key(red: color.red, green: color.green, blue: color.blue,
                      tolerance: tolerance, falloff: falloff)
        lock.lock()
        defer { lock.unlock() }

        if let cached = cache[key] { return cached }

        guard let filter = CIFilter(name: "CIColorCube") else { return nil }
        let dimension = 64
        filter.setValue(dimension, forKey: "inputCubeDimension")
        filter.setValue(
            RangeMaskBuilder.colorCubeData(color: color, tolerance: tolerance,
                                           falloff: falloff, dimension: dimension),
            forKey: "inputCubeData"
        )

        // Bounded so a long session of sampling cannot grow without limit.
        if cache.count >= limit { cache.removeAll() }
        cache[key] = filter
        return filter
    }
}
