import Foundation

/// The non-destructive edit description for a single photo.
///
/// This is the source of truth for how an imported image should *look* — the
/// original file on disk is never modified. Every preview is produced by
/// replaying this stack against the untouched original through a Core Image
/// filter chain (see ``EditRenderer``). Because it is `Codable`, the whole
/// edit history for a photo is just a small JSON blob to persist later.
///
/// Fields are added incrementally, one phase at a time. Right now (Phase 1)
/// only global exposure and contrast exist. Phase 2 adds white balance,
/// saturation, highlights/shadows, and the tone curve — deliberately *not*
/// pre-declared here, so the model never carries fields nothing renders yet.
struct EditStack: Codable, Equatable {
    /// Exposure adjustment in EV stops. `0` leaves the image unchanged.
    var exposure: Double = 0

    /// Contrast adjustment on a `-100...100` scale. `0` leaves it unchanged.
    var contrast: Double = 0
}
