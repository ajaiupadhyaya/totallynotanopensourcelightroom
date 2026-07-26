import CoreImage
import Foundation

/// Memoizes the "developed source": the film-negative conversion, geometry,
/// defringe, and retouch — the prefix of the render chain that changes rarely.
///
/// Dragging a Light or Color slider rebuilds the whole `CIImage` graph every
/// tick. Graph *construction* is cheap, but Core Image caches intermediate
/// GPU results keyed on node identity — so handing it the **same** `CIImage`
/// instance for the unchanged prefix lets it reuse the rendered intermediate
/// instead of re-running the conversion for every tick of an exposure drag.
///
/// Memoizing here also matters for correctness of *cost*: heal spots read two
/// small GPU averages back to the CPU. Behind this cache that read-back happens
/// once per retouch edit, not once per slider tick.
///
/// One entry suffices: edits are a stream of changes to one photo, so "same
/// prefix as the last render" is the overwhelmingly common case.
/// Memoizes the *sensor-domain develop*: the `CIRAWFilter` output for one set
/// of ``RawDevelopSettings``.
///
/// This exists to make ``DevelopedSourceCache`` reachable at all on a RAW.
/// That cache keys on `ObjectIdentifier(source)`, and `CIRAWFilter.outputImage`
/// hands back a fresh `CIImage` on every access — so reconfiguring the filter
/// and re-reading it on each slider tick produced a new identity every tick,
/// and the film/geometry/defringe/retouch prefix behind it was rebuilt (heal
/// spots' GPU read-backs included) for every tick of a Contrast drag that
/// cannot possibly have changed it.
///
/// `RawDevelopSettings` is `Equatable` precisely so the develop can be skipped
/// when the four sensor-domain fields are unchanged, which is the overwhelming
/// majority of ticks: only temperature, tint, exposure, and boost are in it.
final class RawDevelopCache {
    private struct Key: Equatable {
        let filter: ObjectIdentifier
        let settings: RawDevelopSettings
    }

    private var key: Key?
    private var image: CIImage?
    /// Kept for the same reason ``DevelopedSourceCache`` retains its source:
    /// a dead object's ObjectIdentifier can be recycled by a live one.
    private var retainedFilter: AnyObject?

    /// - Parameter develop: applies the settings to the filter and returns its
    ///   output. Called only on a miss.
    /// - Returns: The developed image — the *same instance* as last time when
    ///   nothing sensor-domain has changed.
    func image(filter: AnyObject, settings: RawDevelopSettings,
               develop: () -> CIImage) -> CIImage {
        let newKey = Key(filter: ObjectIdentifier(filter), settings: settings)
        if let image, key == newKey { return image }

        let developed = develop()
        key = newKey
        retainedFilter = filter
        image = developed
        return developed
    }
}

final class DevelopedSourceCache {
    private struct Key: Equatable {
        let source: ObjectIdentifier
        let film: FilmNegativeSettings
        let geometry: Geometry
        let defringe: Defringe
        let retouch: [RetouchSpot]
    }

    private var key: Key?
    private var developed: CIImage?
    /// Kept so the source can't be deallocated while its ObjectIdentifier is
    /// used as a cache key (identifiers of dead objects can be recycled).
    private var retainedSource: CIImage?

    func developed(
        from source: CIImage,
        film: FilmNegativeSettings,
        geometry: Geometry,
        defringe: Defringe,
        retouch: [RetouchSpot],
        context: CIContext
    ) -> CIImage {
        let newKey = Key(source: ObjectIdentifier(source), film: film,
                         geometry: geometry, defringe: defringe, retouch: retouch)
        if let developed, key == newKey { return developed }

        var image = FilmNegativeConverter.convert(source, settings: film)
        image = GeometryTransform.apply(image, geometry: geometry)
        image = DefringeRenderer.apply(defringe, to: image)
        image = RetouchRenderer.apply(retouch, to: image, context: context)
        key = newKey
        retainedSource = source
        developed = image
        return image
    }
}
