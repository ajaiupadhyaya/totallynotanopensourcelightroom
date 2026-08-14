import CoreGraphics

/// The free-zoom arithmetic, kept pure so the anchor invariant is provable.
///
/// The canvas's layout contract (see `EditCanvas.imageRect(in:)`): the drawn
/// frame is `imageSize × scale`, centred in the viewport plus `panOffset`.
/// Every function here works against exactly that formula — change one side
/// and these tests and the canvas fail together, loudly.
enum ZoomMath {
    /// Continuous zoom bounds: 25%…400%.
    static let minimumZoom = 0.25
    static let maximumZoom = 4.0

    /// The classic stops stay as detents inside the continuous range. Fit is
    /// the fourth detent, expressed as `nil` (the stop-jump value).
    static let detents: [Double] = [0.5, 1.0, 2.0]

    /// Relative width of a detent's capture band. 3% feels magnetic without
    /// making 96% unreachable.
    static let detentTolerance = 0.03

    /// One point of precise scroll sweeps this fraction of an octave — a full
    /// flick is about a doubling. A taste constant; verified in-app.
    static let wheelOctavesPerPoint = 1.0 / 250.0

    /// Mirrors `EditCanvas.imageRect(in:)`'s fit computation exactly: fill
    /// the inset viewport, but never enlarge (`min(…, 1)`).
    static func fitScale(imageSize: CGSize, viewport: CGSize, inset: CGFloat) -> Double {
        guard imageSize.width > 0, imageSize.height > 0,
              viewport.width > 0, viewport.height > 0 else { return 1 }
        let available = CGSize(width: max(viewport.width - inset * 2, 40),
                               height: max(viewport.height - inset * 2, 40))
        return Double(min(available.width / imageSize.width,
                          available.height / imageSize.height, 1))
    }

    static func clamped(_ proposed: Double) -> Double {
        min(max(proposed, minimumZoom), maximumZoom)
    }

    /// Detent snapping. Returns `nil` for "snap to Fit" — the caller writes
    /// `zoomLevel = nil`, exactly the value the stop-jump paths use.
    ///
    /// Fit is tested BEFORE the 25% floor and floors the range itself, because
    /// a big frame in a small window fits well below 25% — 4000×3000 in an
    /// 800×600 viewport fits at 0.18 — and clamping first would put Fit out of
    /// reach of the gesture on exactly the ordinary case, leaving "zoom out
    /// until you can see the whole picture" arithmetically impossible.
    static func snapped(_ proposed: Double, fitScale: Double) -> Double? {
        if fitScale > 0, abs(proposed - fitScale) / fitScale < detentTolerance { return nil }
        let floor = fitScale > 0 ? min(minimumZoom, fitScale) : minimumZoom
        let scale = min(max(proposed, floor), maximumZoom)
        if fitScale > 0, abs(scale - fitScale) / fitScale < detentTolerance { return nil }
        for detent in detents where abs(scale - detent) / detent < detentTolerance {
            return detent
        }
        return scale
    }

    /// The pan that keeps the image point under `anchor` stationary across
    /// `oldScale → newScale`. Anchor and pans are in viewport points
    /// (top-left origin, the layout's own space).
    static func pan(anchoring anchor: CGPoint, viewport: CGSize, imageSize: CGSize,
                    oldScale: Double, oldPan: CGSize, newScale: Double) -> CGSize {
        let oldDrawn = CGSize(width: imageSize.width * oldScale,
                              height: imageSize.height * oldScale)
        let newDrawn = CGSize(width: imageSize.width * newScale,
                              height: imageSize.height * newScale)
        guard oldDrawn.width > 0, oldDrawn.height > 0 else { return oldPan }
        let oldOrigin = CGPoint(x: (viewport.width - oldDrawn.width) / 2 + oldPan.width,
                                y: (viewport.height - oldDrawn.height) / 2 + oldPan.height)
        // The image-relative point under the pointer…
        let u = CGPoint(x: (anchor.x - oldOrigin.x) / oldDrawn.width,
                        y: (anchor.y - oldOrigin.y) / oldDrawn.height)
        // …pinned in place at the new scale.
        return CGSize(
            width: anchor.x - u.x * newDrawn.width - (viewport.width - newDrawn.width) / 2,
            height: anchor.y - u.y * newDrawn.height - (viewport.height - newDrawn.height) / 2
        )
    }
}

/// The navigator's geometry: which part of the frame is on screen, and the
/// pan that centres a clicked point. Unit space is the frame's own, top-left
/// origin — the space the thumbnail is drawn in. Same layout contract as
/// `ZoomMath`, including the pan clamp `EditCanvas.clampedPan` applies.
enum NavigatorMath {
    static func visibleUnitRect(viewport: CGSize, imageSize: CGSize,
                                scale: Double, pan: CGSize) -> CGRect {
        let drawn = CGSize(width: imageSize.width * scale,
                           height: imageSize.height * scale)
        guard drawn.width > 0, drawn.height > 0 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        func limit(_ drawnLength: CGFloat, _ viewportLength: CGFloat) -> CGFloat {
            max((drawnLength - viewportLength) / 2, 0)
        }
        let clamped = CGSize(
            width: min(max(pan.width, -limit(drawn.width, viewport.width)),
                       limit(drawn.width, viewport.width)),
            height: min(max(pan.height, -limit(drawn.height, viewport.height)),
                        limit(drawn.height, viewport.height))
        )
        let origin = CGPoint(x: (viewport.width - drawn.width) / 2 + clamped.width,
                             y: (viewport.height - drawn.height) / 2 + clamped.height)
        return CGRect(x: (0 - origin.x) / drawn.width,
                      y: (0 - origin.y) / drawn.height,
                      width: viewport.width / drawn.width,
                      height: viewport.height / drawn.height)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// The pan that puts unit point `p` at the viewport's centre. Falls out
    /// of the layout formula as `drawn × (0.5 − p)`.
    static func pan(centeringUnitPoint p: CGPoint, imageSize: CGSize, scale: Double) -> CGSize {
        CGSize(width: imageSize.width * scale * (0.5 - p.x),
               height: imageSize.height * scale * (0.5 - p.y))
    }
}
