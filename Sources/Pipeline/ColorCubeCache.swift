import CoreImage
import Foundation

/// Caches the most recently built color LUT.
///
/// Building the cube walks 32³ entries doing HSL round trips — cheap in
/// absolute terms, but it would otherwise run on *every* slider tick, including
/// the many ticks that don't touch a color setting at all. Since the cube is a
/// pure function of ``ColorSettings``, remembering the last one collapses a
/// whole drag of the exposure slider to zero rebuilds.
///
/// A single entry is enough: edits arrive as a stream of small changes to one
/// photo, so the hit rate on "same settings as last time" is very high and a
/// larger cache would just hold memory.
final class ColorCubeCache {
    private var cachedSettings: ColorSettings?
    private var cachedFilter: CIFilter?

    /// Returns a filter applying `settings`, or `nil` if they're neutral.
    func filter(for settings: ColorSettings) -> CIFilter? {
        if let cachedSettings, cachedSettings == settings {
            return cachedFilter
        }
        let filter = ColorCubeBuilder.makeFilter(for: settings)
        cachedSettings = settings
        cachedFilter = filter
        return filter
    }
}
