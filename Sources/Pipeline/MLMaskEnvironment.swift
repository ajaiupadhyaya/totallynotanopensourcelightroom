import Foundation

/// Identifies a photograph and its geometry for ML mask disk caching.
///
/// Masks are generated once per photo geometry and invalidated when crop or
/// rotate changes — the same stability contract as ``DevelopedSourceCache``.
struct MLMaskEnvironment: Equatable {
    let entryID: UUID
    let geometry: Geometry

    /// Stable filename component derived from geometry.
    var geometryToken: String {
        let g = geometry
        return [
            String(format: "%.4f", g.cropRect.origin.x),
            String(format: "%.4f", g.cropRect.origin.y),
            String(format: "%.4f", g.cropRect.size.width),
            String(format: "%.4f", g.cropRect.size.height),
            String(g.rotation.rawValue),
            String(format: "%.2f", g.straightenAngle),
            g.flipHorizontal ? "H" : "",
            g.flipVertical ? "V" : "",
        ].joined(separator: "_")
    }
}
