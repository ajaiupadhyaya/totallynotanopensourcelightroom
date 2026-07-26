import CoreImage
import XCTest
@testable import PhotoEditor

/// Verifies the canvas tools: the white-balance neutral picker, the film-base
/// eyedropper routing, crop-mode rendering, and histogram clipping detection.
@MainActor
final class CanvasToolTests: XCTestCase {
    // MARK: Color temperature estimation

    func testNeutralGrayReadsAsD65() throws {
        let wb = try XCTUnwrap(ColorScience.temperatureAndTint(ofRed: 0.5, green: 0.5, blue: 0.5))
        XCTAssertEqual(wb.temperature, 6500, accuracy: 350,
                       "sRGB's white point is D65; gray should read near 6500 K.")
        XCTAssertEqual(wb.tint, 0, accuracy: 12)
    }

    func testWarmColorsReadWarmerThanCoolColors() throws {
        let warm = try XCTUnwrap(ColorScience.temperatureAndTint(
            ofRed: 0.62, green: 0.5, blue: 0.38))
        let cool = try XCTUnwrap(ColorScience.temperatureAndTint(
            ofRed: 0.38, green: 0.5, blue: 0.62))
        XCTAssertLessThan(warm.temperature, cool.temperature,
                          "A warm cast means a low-CCT illuminant.")
    }

    func testNearBlackYieldsNothing() {
        XCTAssertNil(ColorScience.temperatureAndTint(ofRed: 0.001, green: 0.001, blue: 0.002),
                     "Colors too dark to carry chromaticity must not produce a guess.")
    }

    // MARK: The picker end to end

    private func makeEditor(imageColor: (Double, Double, Double)) throws
        -> (editor: EditorModel, url: URL) {
        // Write a solid-color PNG of the given color.
        let size = 64
        var pixels = [UInt8](repeating: 255, count: size * size * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = UInt8(imageColor.0 * 255)
            pixels[i + 1] = UInt8(imageColor.1 * 255)
            pixels[i + 2] = UInt8(imageColor.2 * 255)
        }
        let context = CGContext(
            data: &pixels, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let cgImage = context.makeImage()!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pewb-\(UUID().uuidString).png")
        let dest = CGImageDestinationCreateWithURL(
            url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cgImage, nil)
        CGImageDestinationFinalize(dest)

        let catalog = try TestSupport.inMemoryCatalog()
        let entry = TestSupport.makeEntry(fileURL: url)
        try catalog.save(entry)
        let editor = EditorModel(entry: entry, catalog: catalog,
                                 thumbnails: TestSupport.tempThumbnails(), commitDelay: 60)
        return (editor, url)
    }

    func testPickingAWarmGrayNeutralizesIt() throws {
        // The photo is a gray card shot under warm light.
        let (editor, url) = try makeEditor(imageColor: (0.62, 0.52, 0.40))
        defer { try? FileManager.default.removeItem(at: url) }

        // The picker is only switched off for sensor-domain RAW; a rendered
        // source keeps it, and that is what this test measures.
        XCTAssertFalse(editor.isSensorDomainWB)

        editor.canvasPicker = .whiteBalance
        editor.handleCanvasClick(atUnitPoint: CGPoint(x: 0.5, y: 0.5))

        XCTAssertNil(editor.canvasPicker, "A completed pick should end picker mode.")
        XCTAssertLessThan(editor.editStack.whiteBalanceTemp, 6200,
                          "A warm cast must set a warm illuminant estimate.")

        // The corrected render should be far more neutral than the original.
        let corrected = TestSupport.readColor(
            CIImage(cgImage: try XCTUnwrap(editor.displayImage))
        )
        let castBefore = 0.62 - 0.40
        let castAfter = abs(corrected.red - corrected.blue)
        XCTAssertLessThan(castAfter, castBefore / 2,
                          "Picking the neutral should remove most of the cast.")
    }

    func testFilmBasePickRoutesToSampling() throws {
        let (editor, url) = try makeEditor(imageColor: (1.0, 0.61, 0.36))
        defer { try? FileManager.default.removeItem(at: url) }

        editor.editStack.filmNegative.isEnabled = true
        editor.canvasPicker = .filmBase
        editor.handleCanvasClick(atUnitPoint: CGPoint(x: 0.5, y: 0.5))

        XCTAssertNil(editor.canvasPicker)
        XCTAssertTrue(editor.hasSampledBase)
        XCTAssertEqual(editor.editStack.filmNegative.baseColor.red, 1.0, accuracy: 0.05)
        XCTAssertEqual(editor.editStack.filmNegative.baseColor.green, 0.61, accuracy: 0.05)
    }

    func testClickWithNoActivePickerDoesNothing() throws {
        let (editor, url) = try makeEditor(imageColor: (0.5, 0.5, 0.5))
        defer { try? FileManager.default.removeItem(at: url) }

        let before = editor.editStack
        editor.handleCanvasClick(atUnitPoint: CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(editor.editStack, before)
    }

    // MARK: Crop mode

    func testCropModeShowsTheFullFrame() throws {
        let (editor, url) = try makeEditor(imageColor: (0.5, 0.5, 0.5))
        defer { try? FileManager.default.removeItem(at: url) }

        editor.editStack.geometry.cropRect = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let croppedWidth = try XCTUnwrap(editor.displayImage).width

        editor.isCropping = true
        let fullWidth = try XCTUnwrap(editor.displayImage).width

        XCTAssertEqual(fullWidth, croppedWidth * 2,
                       "Crop mode must render the uncropped frame for recomposing.")

        editor.isCropping = false
        XCTAssertEqual(try XCTUnwrap(editor.displayImage).width, croppedWidth,
                       "Leaving crop mode restores the cropped view.")
    }

    // MARK: Histogram clipping

    /// Clipping means pixels have reached pure black, not merely "very dark".
    /// Pulling a *midtone* down six stops leaves it around 8-bit value 4 — deep
    /// shadow with detail still in it, which must not raise the alarm. So the
    /// frame here starts in the shadows, where six stops genuinely crushes it.
    func testCrushedShadowsTripTheShadowIndicator() {
        let renderer = EditRenderer()
        var stack = EditStack()
        stack.exposure = -6

        let source = TestSupport.solidImage(red: 0.05, green: 0.05, blue: 0.05, size: 64)
        let histogram = renderer.histogram(of: renderer.render(source: source, stack: stack))

        XCTAssertTrue(histogram.isClippingShadows)
        XCTAssertFalse(histogram.isClippingHighlights)
    }

    /// The complement, and the reason the case above had to be re-grounded:
    /// deep shadow is not clipped shadow.
    func testDeepButRecoverableShadowsDoNotTripTheIndicator() {
        let renderer = EditRenderer()
        var stack = EditStack()
        stack.exposure = -6

        let source = TestSupport.solidImage(red: 0.3, green: 0.3, blue: 0.3, size: 64)
        let histogram = renderer.histogram(of: renderer.render(source: source, stack: stack))

        XCTAssertFalse(histogram.isClippingShadows,
                       "A midtone pulled down six stops still holds detail.")
    }

    func testBlownHighlightsTripTheHighlightIndicator() {
        let renderer = EditRenderer()
        var stack = EditStack()
        stack.exposure = 6 // blow everything out

        let source = TestSupport.solidImage(red: 0.7, green: 0.7, blue: 0.7, size: 64)
        let histogram = renderer.histogram(of: renderer.render(source: source, stack: stack))

        XCTAssertTrue(histogram.isClippingHighlights)
        XCTAssertFalse(histogram.isClippingShadows)
    }

    func testAWellExposedFrameTripsNeither() {
        let renderer = EditRenderer()
        let source = TestSupport.solidImage(red: 0.45, green: 0.5, blue: 0.55, size: 64)
        let histogram = renderer.histogram(of: renderer.render(source: source, stack: EditStack()))

        XCTAssertFalse(histogram.isClippingShadows)
        XCTAssertFalse(histogram.isClippingHighlights)
    }
}

// MARK: - Canvas placement

/// The Metal canvas places the develop graph into the drawable. Getting this
/// wrong is invisible to every other test — the picture still renders, just in
/// the wrong place, the wrong size, or upside down.
///
/// `target` is given in drawable pixels with a top-left origin (the coordinates
/// the layout and the overlays use); the transform produces Core Image's
/// bottom-left space. That single conversion is what these tests pin down.
final class CanvasPlacementTests: XCTestCase {
    private typealias Coordinator = MetalCanvasView.Coordinator

    private func place(
        _ extent: CGRect, into target: CGRect, drawableHeight: CGFloat
    ) -> CGRect {
        extent.applying(Coordinator.placement(
            of: extent, into: target, drawableHeight: drawableHeight
        ))
    }

    func testFillsATargetOfMatchingAspect() {
        let placed = place(CGRect(x: 0, y: 0, width: 100, height: 100),
                           into: CGRect(x: 0, y: 0, width: 100, height: 100),
                           drawableHeight: 400)

        XCTAssertEqual(placed.width, 100, accuracy: 0.01)
        XCTAssertEqual(placed.height, 100, accuracy: 0.01)
    }

    /// The flip. A target at the *top* of the drawable must land at a *high*
    /// Core Image y, because CI counts upward from the bottom. This is the
    /// assertion that catches an upside-down canvas.
    func testATargetAtTheTopLandsHighInCoreImageSpace() {
        let top = place(CGRect(x: 0, y: 0, width: 100, height: 100),
                        into: CGRect(x: 0, y: 0, width: 100, height: 100),
                        drawableHeight: 400)
        let bottom = place(CGRect(x: 0, y: 0, width: 100, height: 100),
                           into: CGRect(x: 0, y: 300, width: 100, height: 100),
                           drawableHeight: 400)

        XCTAssertEqual(top.minY, 300, accuracy: 0.01, "Top of the window is high in CI space.")
        XCTAssertEqual(bottom.minY, 0, accuracy: 0.01, "Bottom of the window is CI zero.")
    }

    func testScalesToFitWithoutDistortingAspect() {
        let placed = place(CGRect(x: 0, y: 0, width: 200, height: 100),
                           into: CGRect(x: 0, y: 0, width: 400, height: 400),
                           drawableHeight: 400)

        XCTAssertEqual(placed.width, 400, accuracy: 0.01)
        XCTAssertEqual(placed.height, 200, accuracy: 0.01, "Aspect must be preserved.")
        XCTAssertEqual(placed.midY, 200, accuracy: 0.01, "And centred in the target.")
    }

    func testCentresWithinAWiderTarget() {
        let placed = place(CGRect(x: 0, y: 0, width: 100, height: 100),
                           into: CGRect(x: 0, y: 0, width: 300, height: 100),
                           drawableHeight: 100)

        XCTAssertEqual(placed.midX, 150, accuracy: 0.01)
        XCTAssertEqual(placed.width, 100, accuracy: 0.01)
    }

    func testHonoursATargetOffsetFromTheOrigin() {
        let placed = place(CGRect(x: 0, y: 0, width: 100, height: 100),
                           into: CGRect(x: 250, y: 100, width: 100, height: 100),
                           drawableHeight: 400)

        XCTAssertEqual(placed.minX, 250, accuracy: 0.01, "Panning must actually move it.")
        XCTAssertEqual(placed.minY, 200, accuracy: 0.01)
    }

    /// A straightened or perspective-corrected graph has a non-zero origin.
    /// Scaling it without normalizing first scales the offset too, sliding the
    /// photograph off the canvas.
    func testHandlesAGraphWhoseExtentDoesNotStartAtZero() {
        let extent = CGRect(x: 512, y: 256, width: 200, height: 100)
        let placed = place(extent,
                           into: CGRect(x: 0, y: 0, width: 400, height: 400),
                           drawableHeight: 400)

        XCTAssertEqual(placed.width, 400, accuracy: 0.01)
        XCTAssertEqual(placed.minX, 0, accuracy: 0.01, "Offset must not survive the scale.")
        XCTAssertEqual(placed.midY, 200, accuracy: 0.01)
    }

    func testDegenerateSizesAreIdentityRatherThanNaN() {
        XCTAssertEqual(
            Coordinator.placement(of: .zero,
                                  into: CGRect(x: 0, y: 0, width: 10, height: 10),
                                  drawableHeight: 10),
            .identity
        )
        XCTAssertEqual(
            Coordinator.placement(of: CGRect(x: 0, y: 0, width: 10, height: 10),
                                  into: .zero, drawableHeight: 10),
            .identity
        )
    }
}

// MARK: - Histogram measurement space

/// A histogram is read by a person, so it has to describe the photograph the
/// way it is displayed. Measuring it in the linear working space instead pushes
/// ordinary tones into the bottom bins and reports heavy shadow clipping on a
/// frame that has none.
final class HistogramSpaceTests: XCTestCase {
    private let renderer = EditRenderer()

    private func histogram(ofSRGBGrey value: Double) -> Histogram {
        let source = TestSupport.solidImage(red: value, green: value, blue: value, size: 64)
        return renderer.histogram(of: renderer.render(source: source, stack: EditStack()))
    }

    private func peakBin(_ bins: [Float]) -> Int {
        bins.indices.max { bins[$0] < bins[$1] } ?? 0
    }

    func testMidGreySitsInTheMiddleOfTheHistogram() {
        let bin = peakBin(histogram(ofSRGBGrey: 0.5).green)
        XCTAssertGreaterThan(bin, 100, "sRGB 50% grey must land mid-histogram, not in the shadows.")
        XCTAssertLessThan(bin, 160)
    }

    func testADarkButNotBlackFrameDoesNotReportShadowClipping() {
        let histogram = self.histogram(ofSRGBGrey: 0.03)

        XCTAssertFalse(histogram.isClippingShadows,
                       "A dark grey frame contains no pure black and must not read as crushed.")
        XCTAssertLessThan(histogram.shadowClippedFraction, 0.05)
    }

    func testATrulyBlackFrameStillReportsShadowClipping() {
        XCTAssertTrue(histogram(ofSRGBGrey: 0).isClippingShadows,
                      "Genuine black must still trip the diagnostic.")
    }

    func testAWhiteFrameReportsHighlightClipping() {
        XCTAssertTrue(histogram(ofSRGBGrey: 1).isClippingHighlights)
    }

    func testBrighteningMovesTheHistogramRight() {
        let source = TestSupport.solidImage(red: 0.3, green: 0.3, blue: 0.3, size: 64)
        var brighter = EditStack()
        brighter.exposure = 1.0

        let base = peakBin(renderer.histogram(of: renderer.render(source: source, stack: EditStack())).green)
        let lifted = peakBin(renderer.histogram(of: renderer.render(source: source, stack: brighter)).green)

        XCTAssertGreaterThan(lifted, base + 10, "A stop of exposure must visibly shift the histogram.")
    }
}

// MARK: - Histogram display scale

/// A photograph with a black surround — a scan with its rebate, a night frame,
/// a silhouette — piles a large share of its pixels into the bottom bin. If the
/// graph scales to that spike, the tones of the actual subject collapse into a
/// sliver and the histogram stops doing its job.
final class HistogramScaleTests: XCTestCase {
    func testAClippedSpikeDoesNotFlattenTheRestOfTheGraph() {
        var bins = [Float](repeating: 0.1, count: 256)
        bins[0] = 40 // a third of the frame crushed to black

        let histogram = Histogram(red: bins, green: bins, blue: bins)

        XCTAssertEqual(histogram.peak, 0.1, accuracy: 0.001,
                       "Scale must come from the picture, not from the clipped spike.")
    }

    func testTheEndBinsStillDriveTheClippingReadout() {
        var bins = [Float](repeating: 0.1, count: 256)
        bins[0] = 40

        let histogram = Histogram(red: bins, green: bins, blue: bins)

        XCTAssertTrue(histogram.isClippingShadows,
                      "Excluding the spike from the scale must not hide it from the diagnostic.")
        XCTAssertFalse(histogram.isClippingHighlights)
    }

    func testAFlatHistogramStillHasAUsableScale() {
        let histogram = Histogram(red: [0, 0, 0], green: [0, 0, 0], blue: [0, 0, 0])
        XCTAssertEqual(histogram.peak, 1, "Peak must never be zero — callers divide by it.")
    }

    func testAVeryShortHistogramFallsBackToItsOwnMaximum() {
        let histogram = Histogram(red: [3, 7], green: [1, 2], blue: [0, 1])
        XCTAssertEqual(histogram.peak, 7, accuracy: 0.001)
    }
}
