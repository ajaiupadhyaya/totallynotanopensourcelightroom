import CoreImage
import Foundation

/// Memoizes the "developed source": the film-negative conversion plus
/// geometry, the prefix of the render chain that changes rarely.
///
/// Dragging a Light or Color slider rebuilds the whole `CIImage` graph every
/// tick. Graph *construction* is cheap, but Core Image caches intermediate
/// GPU results keyed on node identity — so handing it the **same** `CIImage`
/// instance for the unchanged film+geometry prefix lets it reuse the rendered
/// intermediate instead of re-running the conversion for every tick of an
/// exposure drag. On a film scan that prefix is the most expensive part of the
/// chain (color-space brackets, matrix, crop).
///
/// One entry suffices: edits are a stream of changes to one photo, so "same
/// prefix as the last render" is the overwhelmingly common case.
final class DevelopedSourceCache {
    private struct Key: Equatable {
        let source: ObjectIdentifier
        let film: FilmNegativeSettings
        let geometry: Geometry
    }

    private var key: Key?
    private var developed: CIImage?
    /// Kept so the source can't be deallocated while its ObjectIdentifier is
    /// used as a cache key (identifiers of dead objects can be recycled).
    private var retainedSource: CIImage?

    func developed(
        from source: CIImage, film: FilmNegativeSettings, geometry: Geometry
    ) -> CIImage {
        let newKey = Key(source: ObjectIdentifier(source), film: film, geometry: geometry)
        if let developed, key == newKey { return developed }

        var image = FilmNegativeConverter.convert(source, settings: film)
        image = GeometryTransform.apply(image, geometry: geometry)
        key = newKey
        retainedSource = source
        developed = image
        return image
    }
}
