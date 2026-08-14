import XCTest
@testable import PhotoEditor

/// The free-zoom arithmetic: the anchor invariant, the detents, the clamp,
/// the fit law, and the navigator's geometry. All pure — no canvas needed.
final class ZoomMathTests: XCTestCase {
    private let viewport = CGSize(width: 800, height: 600)
    private let image = CGSize(width: 4000, height: 3000)

    /// The point under the pointer must not move when the scale changes —
    /// the entire reason gesture zoom exists. The layout formula here is the
    /// same one EditCanvas.imageRect(in:) uses: centred plus pan.
    func testAnchorStaysUnderThePointerAcrossAZoomStep() {
        let anchor = CGPoint(x: 530, y: 210)
        let s0 = 0.7, s1 = 1.13
        let pan0 = CGSize(width: -40, height: 25)
        func origin(_ scale: Double, _ pan: CGSize) -> CGPoint {
            CGPoint(x: (viewport.width - image.width * scale) / 2 + pan.width,
                    y: (viewport.height - image.height * scale) / 2 + pan.height)
        }
        let u = CGPoint(x: (anchor.x - origin(s0, pan0).x) / (image.width * s0),
                        y: (anchor.y - origin(s0, pan0).y) / (image.height * s0))
        let pan1 = ZoomMath.pan(anchoring: anchor, viewport: viewport, imageSize: image,
                                oldScale: s0, oldPan: pan0, newScale: s1)
        XCTAssertEqual(origin(s1, pan1).x + u.x * image.width * s1, anchor.x, accuracy: 1e-9)
        XCTAssertEqual(origin(s1, pan1).y + u.y * image.height * s1, anchor.y, accuracy: 1e-9)
    }

    func testSnappingCatchesTheFourStopsAndOnlyThem() {
        XCTAssertEqual(ZoomMath.snapped(1.01, fitScale: 0.18), 1.0)
        XCTAssertEqual(ZoomMath.snapped(0.505, fitScale: 0.18), 0.5)
        XCTAssertEqual(ZoomMath.snapped(1.98, fitScale: 0.18), 2.0)
        XCTAssertNil(ZoomMath.snapped(0.181, fitScale: 0.18),
                     "near the fit scale snaps to Fit — nil, the stop-jump value")
        XCTAssertEqual(ZoomMath.snapped(1.31, fitScale: 0.18), 1.31,
                       "between detents the zoom is genuinely continuous")
    }

    func testClampingBoundsTheGestureRange() {
        XCTAssertEqual(ZoomMath.clamped(0.01), 0.25)
        XCTAssertEqual(ZoomMath.clamped(11), 4.0)
    }

    /// The existing law restated over the extracted function: a frame smaller
    /// than the viewport shows at its own size, never interpolated up.
    func testFitNeverEnlarges() {
        XCTAssertEqual(ZoomMath.fitScale(imageSize: CGSize(width: 200, height: 100),
                                         viewport: viewport, inset: 28), 1.0)
        XCTAssertLessThan(ZoomMath.fitScale(imageSize: image, viewport: viewport, inset: 28), 1.0)
    }

    func testNavigatorRectAndCenteringRoundTrip() {
        let pan = NavigatorMath.pan(centeringUnitPoint: CGPoint(x: 0.7, y: 0.4),
                                    imageSize: image, scale: 2.0)
        let visible = NavigatorMath.visibleUnitRect(viewport: viewport, imageSize: image,
                                                    scale: 2.0, pan: pan)
        XCTAssertEqual(visible.midX, 0.7, accuracy: 1e-6)
        XCTAssertEqual(visible.midY, 0.4, accuracy: 1e-6)
    }

    func testNavigatorRectClampsLikeTheCanvasDoes() {
        let visible = NavigatorMath.visibleUnitRect(viewport: viewport, imageSize: image,
                                                    scale: 2.0,
                                                    pan: CGSize(width: 1e6, height: 0))
        XCTAssertEqual(visible.minX, 0, accuracy: 1e-9,
                       "an over-panned rect must clamp exactly where clampedPan clamps the image")
    }
}

/// Gesture zoom against the live model: the one behaviour the old didSet
/// forbade — a zoom that keeps its pan — plus proof the stop-jump reset stays.
@MainActor
final class GestureZoomModelTests: XCTestCase {
    private func makeEditor() throws -> (editor: EditorModel, url: URL) {
        let url = try TestSupport.makeTempPNG(gray: 128)
        let catalog = try TestSupport.inMemoryCatalog()
        let entry = TestSupport.makeEntry(fileURL: url)
        try catalog.save(entry)
        return (EditorModel(entry: entry, catalog: catalog,
                            thumbnails: TestSupport.tempThumbnails(), commitDelay: 60), url)
    }

    func testGestureZoomKeepsItsAnchoredPanAndStopJumpsStillRecentre() throws {
        let (editor, url) = try makeEditor()
        defer { try? FileManager.default.removeItem(at: url) }

        editor.applyGestureZoom(scale: 2.0, pan: CGSize(width: 33, height: -12))
        XCTAssertEqual(editor.zoomLevel, 2.0)
        XCTAssertEqual(editor.panOffset, CGSize(width: 33, height: -12),
                       "the anchored pan must survive the zoom write")

        editor.zoomLevel = 1.0 // menu / TabStrip / double-click path
        XCTAssertEqual(editor.panOffset, .zero, "stop-jumps keep today's centre-reset")
    }

    func testGestureZoomToFitClearsThePan() throws {
        let (editor, url) = try makeEditor()
        defer { try? FileManager.default.removeItem(at: url) }
        editor.applyGestureZoom(scale: 2.0, pan: CGSize(width: 33, height: 0))
        editor.applyGestureZoom(scale: nil, pan: CGSize(width: 99, height: 99))
        XCTAssertNil(editor.zoomLevel)
        XCTAssertEqual(editor.panOffset, .zero, "Fit is centred by definition")
    }

    func testZoomStepWalksTheLadder() throws {
        let (editor, url) = try makeEditor()
        defer { try? FileManager.default.removeItem(at: url) }
        editor.zoomStep(1)
        XCTAssertEqual(editor.zoomLevel, 1.0, "from Fit, zoom-in enters at 100% — the double-click convention")
        editor.zoomStep(1)
        XCTAssertEqual(editor.zoomLevel, 2.0)
        editor.zoomLevel = 0.7
        editor.zoomStep(-1)
        XCTAssertEqual(editor.zoomLevel, 0.5, "a free value steps to the nearest rung in the travel direction")
    }
}
