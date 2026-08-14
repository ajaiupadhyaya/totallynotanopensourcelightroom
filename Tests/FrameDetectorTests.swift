import CoreImage
import XCTest
@testable import PhotoEditor

final class FrameDetectorTests: XCTestCase {
    private let context = CIContext()

    /// A synthetic lightbox scan: the FilmSim negative composited at a KNOWN,
    /// deliberately off-centre position over a bright surround. Off-centre so
    /// the test pins the coordinate conversion — a vertically flipped rect
    /// lands in the wrong place and fails position, not just size.
    private func lightboxScan(filmOrigin: CGPoint = CGPoint(x: 24, y: 56),
                              surround: (Double, Double, Double) = (0.97, 0.97, 0.99),
                              dmin: (Double, Double, Double) = FilmSim.c41Base) -> CIImage {
        let film = FilmSim.negativeImage(dmin: dmin,
                                         gammas: FilmSim.crossoverGammas, size: 128)
        let backlight = CIImage(color: CIColor(red: surround.0, green: surround.1,
                                               blue: surround.2))
            .cropped(to: CGRect(x: 0, y: 0, width: 256, height: 256))
        return film
            .transformed(by: CGAffineTransform(translationX: filmOrigin.x,
                                               y: filmOrigin.y))
            .composited(over: backlight)
    }

    func testDetectsTheFilmRectangleWhereItActuallyIs() throws {
        let scan = lightboxScan()
        let frame = try XCTUnwrap(FrameDetector.detect(scan: scan, context: context))
        // Film occupies x 24–152, y 24–152 of 256 → unit [0.09375, 0.59375]
        // on x, [0.21875, 0.71875] on y (bottom-left origin). One downsample
        // cell at 128 over 256 px = 2 px = ~0.008 unit; allow a few.
        XCTAssertEqual(frame.rect.minX, 24.0 / 256.0, accuracy: 0.03)
        XCTAssertEqual(frame.rect.maxX, 152.0 / 256.0, accuracy: 0.03)
        XCTAssertEqual(frame.rect.minY, 56.0 / 256.0, accuracy: 0.03,
                       "wrong minY — if maxY matches 1-minY instead, the row "
                       + "orientation conversion is flipped")
        XCTAssertEqual(frame.rect.maxY, 184.0 / 256.0, accuracy: 0.03)
        XCTAssertGreaterThan(frame.backlightFraction, 0.5)
    }

    func testRebateRingLandsOnTheFilmBase() throws {
        let scan = lightboxScan()
        let frame = try XCTUnwrap(FrameDetector.detect(scan: scan, context: context))
        let rebate = try XCTUnwrap(frame.rebateBase, "the ring must read as film")
        // Display-encoded, within a few percent of the known base.
        XCTAssertEqual(rebate.red, PaperResponse.srgbEncode(FilmSim.c41Base.0),
                       accuracy: 0.04)
        XCTAssertEqual(rebate.green, PaperResponse.srgbEncode(FilmSim.c41Base.1),
                       accuracy: 0.04)
        XCTAssertEqual(rebate.blue, PaperResponse.srgbEncode(FilmSim.c41Base.2),
                       accuracy: 0.04)
    }

    /// A B&W negative has no orange mask — the classifier must not depend on
    /// chroma. Neutral base, same geometry.
    func testDetectsANeutralBaseNegative() throws {
        let scan = lightboxScan(dmin: (0.55, 0.55, 0.55))
        let frame = try XCTUnwrap(FrameDetector.detect(scan: scan, context: context))
        XCTAssertEqual(frame.rect.minX, 24.0 / 256.0, accuracy: 0.03)
        XCTAssertEqual(frame.rect.maxY, 184.0 / 256.0, accuracy: 0.03)
    }

    /// A film-filling scan has nothing to detect: nil, so Auto behaves
    /// exactly as today.
    func testFilmFillingScanReturnsNil() {
        let probe = FilmSim.negativeImage(dmin: FilmSim.c41Base,
                                          gammas: FilmSim.crossoverGammas, size: 128)
        XCTAssertNil(FrameDetector.detect(scan: probe, context: context))
    }

    /// A flat field is unimodal — no lightbox mode to separate. nil, never a
    /// confident wrong box.
    func testFlatFieldReturnsNil() {
        let flat = TestSupport.solidImage(red: 0.5, green: 0.5, blue: 0.5, size: 96)
        XCTAssertNil(FrameDetector.detect(scan: flat, context: context))
    }

    // MARK: Corpus (gated)

    /// The Aug 9 batch: hand-measured film bounds (rebate included) span
    /// x ∈ [0.13, 0.89], top-down y ∈ [0.16, 0.89] → bottom-left-origin
    /// y ∈ [0.11, 0.84]. The detected box must sit inside the hand-measured
    /// OUTER bounds (it may not eat lightbox) and contain the known interior.
    func testDetectsTheFilmOnTheAugustNinthCorpus() throws {
        let dir = NSString("~/Desktop/all film/Negatives august 9th").expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir),
              isDir.boolValue,
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
            throw XCTSkip("corpus not present on this machine")
        }
        let files = names.filter { $0.lowercased().hasSuffix(".heic") }.sorted().prefix(3)
        guard !files.isEmpty else { throw XCTSkip("no HEICs in corpus") }
        for name in files {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
            guard let scan = ImageDecoder.loadPreviewImage(from: url, maxDimension: 1600,
                                                           processVersion: 2) else {
                XCTFail("could not decode \(name)"); continue
            }
            let frame = try XCTUnwrap(FrameDetector.detect(scan: scan, context: context),
                                      "\(name): detector found nothing on a lightbox scan")
            // Inside the outer bounds (with slack for the hand measurement)…
            XCTAssertGreaterThan(frame.rect.minX, 0.08, name)
            XCTAssertLessThan(frame.rect.maxX, 0.94, name)
            XCTAssertGreaterThan(frame.rect.minY, 0.06, name)
            XCTAssertLessThan(frame.rect.maxY, 0.89, name)
            // …and containing the known picture interior.
            let interior = CGRect(x: 0.30, y: 0.30, width: 0.40, height: 0.35)
            XCTAssertTrue(frame.rect.contains(interior),
                          "\(name): detected \(frame.rect) does not contain the interior")
            print("FRAMEDETECT \(name): rect=\(frame.rect) "
                  + "backlight=\(frame.backlightFraction) rebate=\(String(describing: frame.rebateBase))")

            // End to end: Auto through the detected crop must land the frame
            // in the plausible-positive band the manual demo crop achieves —
            // this is the one-click promise, proven on the user's own scans.
            var stack = EditStack()
            stack.geometry.cropRect = frame.rect
            let cropped = GeometryTransform.apply(scan, geometry: stack.geometry)
            let solution = try XCTUnwrap(
                AutoInvert.solve(scan: cropped, sampledBase: frame.rebateBase,
                                 profile: .labStandard, context: context),
                "\(name): solve through the detected crop failed")
            stack.filmNegative.isEnabled = true
            stack.filmNegative.conversionModel = .density
            stack.filmNegative.print.applyToneProfile(.labStandard)
            stack.filmNegative.baseColor = solution.baseColor
            stack.filmNegative.baseOrigin = solution.baseOrigin
            stack.filmNegative.print.dmax = solution.dmax
            stack.filmNegative.print.gamma = solution.gamma
            stack.filmNegative.print.exposure = solution.printExposure
            stack.filmNegative.print.gradePivot = solution.medianDensity
            stack.filmNegative.print.castRed = solution.cast.red
            stack.filmNegative.print.castGreen = solution.cast.green
            stack.filmNegative.print.castBlue = solution.cast.blue
            let out = EditRenderer().render(source: scan, stack: stack)
            let px = try XCTUnwrap(AutoInvert.linearPixels(of: out, side: 64,
                                                           context: context))
            let lumas = px.map { 0.2126 * $0.0 + 0.7152 * $0.1 + 0.0722 * $0.2 }.sorted()
            let median = lumas[lumas.count / 2]
            print("FRAMEDETECT \(name): detectedAuto medianLuma=\(median)")
            XCTAssertGreaterThan(median, 0.05,
                                 "\(name): detection-Auto renders black")
            XCTAssertLessThan(median, 0.7,
                              "\(name): detection-Auto renders blown")
            // The artifact joins the acceptance sheet's -detected column.
            try? FileManager.default.createDirectory(at: RealScanTests.artifactDir,
                                                     withIntermediateDirectories: true)
            let dest = RealScanTests.artifactDir.appendingPathComponent(
                "aug9-\(name.replacingOccurrences(of: ".HEIC", with: ""))-detected.jpg")
            try context.writeJPEGRepresentation(
                of: out, to: dest,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
    }

    /// The whole gesture, synthetically: enable on an uncropped lightbox
    /// composite, and Auto detects, crops, solves, and says so — one write.
    func testAutoDetectsAndCropsInOneGesture() throws {
        let scan = lightboxScan()
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lightbox-fixture-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try context.writePNGRepresentation(
            of: scan, to: url, format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let catalog = try TestSupport.inMemoryCatalog()
        let entry = TestSupport.makeEntry(fileURL: url)
        try catalog.save(entry)
        let model = EditorModel(entry: entry, catalog: catalog,
                                thumbnails: TestSupport.tempThumbnails(),
                                commitDelay: 60)
        model.enableFilmNegative()
        let crop = model.editStack.geometry.cropRect
        XCTAssertNotEqual(crop, .unitFrame, "Auto must write the detected crop")
        XCTAssertEqual(crop.minX, 24.0 / 256.0, accuracy: 0.04)
        XCTAssertEqual(crop.maxY, 184.0 / 256.0, accuracy: 0.04)
        XCTAssertTrue(model.editStack.filmNegative.isEnabled)
        XCTAssertEqual(model.editStack.filmNegative.baseOrigin, .estimated,
                       "a detector-supplied base is estimated, not user-sampled")
        XCTAssertTrue(model.lastSolveDegradedTerms.contains {
            $0.contains("frame detected")
        }, "the caption must say a crop was written")
        // One undo step reverts crop AND conversion together.
        model.commitEdit()
        model.undo()
        XCTAssertEqual(model.editStack.geometry.cropRect, .unitFrame,
                       "undo must revert the detected crop with the conversion")
        XCTAssertFalse(model.editStack.filmNegative.isEnabled)
    }

    /// A negative held further from the phone: the lit rectangle is a SMALL
    /// share of a mostly-dark tabletop. Measured on IMG_7191 (2026-08-13
    /// corpus) — the lightbox spans 21.3% of the frame, the thin picture area
    /// classifies as backlight frame-wide so the film-fraction run cannot
    /// form, and the lightbox fallback is the designed answer.
    ///
    /// Built as pixels, not a composite, because the failure needs the film
    /// to read THIN — the exact condition a well-behaved synthetic negative
    /// does not reproduce.
    ///
    /// This is the case where cropping matters MOST: refusing it hands Auto a
    /// frame that is four-fifths tabletop, and the solve reads that dark
    /// surround as maximum density (measured: dmax 2.7, print EV 4.69, a
    /// blown render carrying no degradation warning).
    func testDetectsASmallLightboxOnADarkTable() {
        let width = 128, height = 96
        let rows = 13..<70, cols = 45..<91
        var pixels = [(Double, Double, Double)](repeating: (0.02, 0.02, 0.025),
                                                count: width * height)
        for row in rows {
            for col in cols {
                // Thin base: bright and neutral, so the chroma cue reads it as
                // backlight (nothing orange survives) while the absolute luma
                // floor does not — every pixel-wise cue loses this film.
                // Every fifth pixel is dense picture, which keeps a film
                // signal present but far below the 0.5 run threshold.
                pixels[row * width + col] = (row + col).isMultiple(of: 5)
                    ? (0.06, 0.04, 0.02)
                    : (0.5, 0.5, 0.52)
            }
        }
        let lightboxArea = Double(rows.count * cols.count) / Double(width * height)
        XCTAssertLessThan(lightboxArea, FrameDetector.minimumBoxAreaFraction,
                          "precondition: this scan is the sub-25% case")

        let frame = FrameDetector.detect(pixels: pixels, width: width, height: height)
        let rect = try? XCTUnwrap(frame?.rect,
                                  "a small lit rectangle on a dark table is a "
                                  + "lightbox scan — refusing it is what blew "
                                  + "IMG_7191")
        XCTAssertEqual(rect?.minX ?? -1, Double(cols.lowerBound) / Double(width),
                       accuracy: 0.02)
        XCTAssertEqual(rect?.width ?? -1, Double(cols.count) / Double(width),
                       accuracy: 0.02)
        XCTAssertEqual(rect?.minY ?? -1,
                       Double(height - rows.upperBound) / Double(height),
                       accuracy: 0.02)
        XCTAssertEqual(rect?.height ?? -1, Double(rows.count) / Double(height),
                       accuracy: 0.02)
        XCTAssertNil(frame?.rebateBase,
                     "the fallback does not know where the rebate is")
    }
}

