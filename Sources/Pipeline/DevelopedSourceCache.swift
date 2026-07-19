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
