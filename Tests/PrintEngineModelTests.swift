import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import PhotoEditor

/// Verifies the `EditorModel` actions that drive the print engine: the Auto
/// button, Update Conversion (matrix → density), the eyedropper re-solve, and
/// calibrated stocks carrying print character through the catalog.
@MainActor
final class PrintEngineModelTests: XCTestCase {

    /// Enabling conversion on a fresh (density-model) photo runs the full
    /// Auto solve — one button to a converted frame, not a chore of samples.
    func testEnableFilmNegativeRunsAutoOnDensityModel() throws {
        let model = try TestSupport.makeEditorModel()
        model.enableFilmNegative()
        XCTAssertTrue(model.editStack.filmNegative.isEnabled)
        XCTAssertEqual(model.editStack.filmNegative.conversionModel, .density)
        // A solid grey test image is a degenerate scan; the solve still ran
        // and wrote *something* measurable rather than leaving defaults.
        XCTAssertEqual(model.editStack.filmNegative.baseOrigin, .estimated)
    }

    /// The whole Auto result is one undo step: one Cmd-Z returns to the
    /// pre-conversion stack, not to a half-solved intermediate.
    func testAutoConvertIsOneUndoStep() throws {
        let model = try TestSupport.makeEditorModel()
        let before = model.editStack
        model.autoConvertNegative()
        XCTAssertNotEqual(model.editStack, before)
        model.commitEdit() // flush the debounced commit, as EditorUndoTests does
        model.undo()
        XCTAssertEqual(model.editStack.filmNegative, before.filmNegative)
    }

    /// Update Conversion: snapshots the matrix look, then switches and
    /// re-solves — same contract as the Process badge.
    func testUpdateConversionSnapshotsThenSwitches() throws {
        var stack = EditStack()
        stack.filmNegative.isEnabled = true
        stack.filmNegative.conversionModel = .matrix
        let model = try TestSupport.makeEditorModel(editStack: stack)
        let snapshotsBefore = model.snapshots.count

        model.updateConversion()

        XCTAssertEqual(model.editStack.filmNegative.conversionModel, .density)
        XCTAssertEqual(model.snapshots.count, snapshotsBefore + 1)
        XCTAssertTrue(model.snapshots.contains { $0.name == "Before Print Engine" })
        // The snapshot preserves the matrix rendering.
        XCTAssertEqual(model.snapshots.first { $0.name == "Before Print Engine" }?
            .editStack.filmNegative.conversionModel, .matrix)
    }

    func testUpdateConversionIsANoOpOnDensityStacks() throws {
        let model = try TestSupport.makeEditorModel()
        model.autoConvertNegative()
        let count = model.snapshots.count
        model.updateConversion()
        XCTAssertEqual(model.snapshots.count, count, "no snapshot, nothing to update")
    }

    /// Slide film is already a positive — `FilmDensityConverter`'s inversion
    /// dispatch requires `type.requiresInversion`, so a slide-type matrix
    /// stack renders identically under either engine. Offering "Update
    /// Conversion" there would still snapshot and run a real (if pointless)
    /// solve, so `updateConversion()` must be a complete no-op on it — same
    /// guard as `FilmPanel`'s note, defended again here so the action isn't
    /// only as safe as the view that happens to call it.
    func testUpdateConversionIsANoOpOnSlideMatrixStacks() throws {
        var stack = EditStack()
        stack.filmNegative.isEnabled = true
        stack.filmNegative.conversionModel = .matrix
        stack.filmNegative.type = .slide
        let model = try TestSupport.makeEditorModel(editStack: stack)
        let before = model.editStack
        let snapshotsBefore = model.snapshots.count

        model.updateConversion()

        XCTAssertEqual(model.editStack, before, "slide stacks under matrix should be untouched")
        XCTAssertEqual(model.editStack.filmNegative.conversionModel, .matrix)
        XCTAssertEqual(model.snapshots.count, snapshotsBefore, "no snapshot, nothing to update")
    }

    /// The legacy Film Exposure field (`filmNegative.exposure`) is a
    /// matrix-era placement aid, invisible in the density panel, that
    /// `FilmDensityConverter` still applies as a post-kernel EV lift
    /// (Sources/Film/FilmDensityConverter.swift). A matrix photo carrying a
    /// nonzero legacy exposure that runs Update Conversion must not carry
    /// that stale, invisible lift into the density solve — Auto places
    /// exposure itself (`print.exposure`), and a leftover EV would silently
    /// fight it. The pre-update look (legacy exposure included) must still
    /// be recoverable from the snapshot Update Conversion takes.
    func testUpdateConversionClearsLegacyExposureButSnapshotPreservesIt() throws {
        var stack = EditStack()
        stack.filmNegative.isEnabled = true
        stack.filmNegative.conversionModel = .matrix
        stack.filmNegative.exposure = 1.5
        let model = try TestSupport.makeEditorModel(editStack: stack)

        model.updateConversion()

        XCTAssertEqual(model.editStack.filmNegative.conversionModel, .density)
        XCTAssertEqual(model.editStack.filmNegative.exposure, 0,
                       "the stale matrix-era EV lift must not survive into the density solve")
        XCTAssertEqual(model.snapshots.first { $0.name == "Before Print Engine" }?
            .editStack.filmNegative.exposure, 1.5,
            "the pre-update look, legacy exposure included, must stay recoverable")
    }

    /// The eyedropper on a density-model photo re-solves with the sampled
    /// base — a better Dmin should immediately improve Dmax, gamma, and
    /// exposure too.
    ///
    /// Needs a fixture with real tonal structure, not the flat-grey default:
    /// on a flat image every possible sample coincides with Auto's own
    /// percentile estimate, so a test built on it can't tell "the re-solve
    /// ran and changed nothing because the numbers happen to agree" apart
    /// from "the re-solve never ran at all" — asserting only `baseOrigin ==
    /// .sampled` would stay green even with the re-solve deleted, since
    /// `applySampledBase` writes that field unconditionally.
    ///
    /// `makeTempDetailPNG`'s checkerboard (see `TestSupport`) gives two
    /// distinct block values, 40 and 215, evenly split — so Auto's unsampled
    /// 98th-percentile Dmin estimate lands in the bright (215) group. The
    /// corner sampled below is the dark (40) group instead (verified
    /// empirically against `EditorModel`'s actual bottom-left-origin
    /// `CIImage` orientation — the *other* diagonal corner coincides with
    /// the bright estimate and would silently reintroduce the vacuous case),
    /// so the sampled base is genuinely far from what Auto already had, and
    /// every print-side output the re-solve touches has to move.
    func testEyedropperResolvesWithSampledBase() throws {
        let url = try TestSupport.makeTempDetailPNG()
        let catalog = try TestSupport.inMemoryCatalog()
        let entry = TestSupport.makeEntry(fileURL: url)
        try catalog.save(entry)
        let model = EditorModel(entry: entry, catalog: catalog,
                                thumbnails: TestSupport.tempThumbnails(), commitDelay: 60)

        model.autoConvertNegative()
        let solvedDmax = model.editStack.filmNegative.print.dmax
        let solvedGamma = model.editStack.filmNegative.print.gamma
        let solvedExposure = model.editStack.filmNegative.print.exposure

        model.sampleFilmBase(inUnitRect: CGRect(x: 0, y: 0.9, width: 0.1, height: 0.1))

        XCTAssertEqual(model.editStack.filmNegative.baseOrigin, .sampled)
        // dmax/gamma/exposure are written only by the density re-solve —
        // applySampledBase itself never touches them — so this fails if the
        // `conversionModel == .density` re-solve gate is ever deleted.
        let resolveRan = model.editStack.filmNegative.print.dmax != solvedDmax
            || model.editStack.filmNegative.print.gamma != solvedGamma
            || model.editStack.filmNegative.print.exposure != solvedExposure
        XCTAssertTrue(resolveRan,
                      "sampling a base far from Auto's estimate should move the re-solved print values")
    }

    /// Calibrated stocks persist their print character through the catalog.
    func testCalibratedStockRoundTripsPrintCharacter() throws {
        let model = try TestSupport.makeEditorModel()
        model.autoConvertNegative()
        model.editStack.filmNegative.print.contrast = 3.0
        model.editStack.filmNegative.print.saturation = 20
        let stock = try XCTUnwrap(model.saveCalibratedStock(name: "Test 400",
                                                            manufacturer: "Test", iso: 400))
        XCTAssertEqual(stock.printContrast, 3.0)
        XCTAssertEqual(stock.printSaturation, 20)

        // And applying it to a fresh photo carries the character over.
        let fresh = try TestSupport.makeEditorModel()
        fresh.autoConvertNegative()
        fresh.applyFilmStock(stock)
        XCTAssertEqual(fresh.editStack.filmNegative.print.contrast, 3.0)
        XCTAssertEqual(fresh.editStack.filmNegative.print.saturation, 20)
    }

    // MARK: Crop-aware Auto (Fix 2)

    /// Reproduces the medium-format corpus defect directly: a real negative
    /// holder mask is the densest thing in the frame, so a blind (uncropped)
    /// solve lets it set Dmax and dominate the median instead of the film.
    /// `autoConvertNegative` measures the geometry-cropped scan so that a
    /// user's crop — the one signal in the whole stack that says exactly
    /// which pixels are film — excludes the holder from the measurement.
    ///
    /// Built from `FilmSim`'s own patch grid (its natural Dmax, printed as a
    /// diagnostic while verifying Fix 1's no-op, is ~(1.64, 1.85, 2.08)) with
    /// the composite's holder driven deliberately far past that (~2.6–3.0),
    /// so "the holder no longer sets Dmax" is a real, large before/after
    /// move, not a coin flip near the boundary.
    ///
    /// The holder is deliberately given a slight red-warm tint (see
    /// `makeHolderMaskedNegativePNG`), not the perfectly neutral near-black
    /// this fixture used before Fix 3 existed. A perfectly neutral holder
    /// (`r ≈ g ≈ b`) is now excluded by Fix 3's chroma gate on its own —
    /// confirmed directly: with a neutral holder byte, this test's `blind`
    /// and `cropped` Dmax became bit-identical (both landed on what used to
    /// be only the cropped answer), because the chroma gate had already done
    /// the crop's job. That's Fix 3 working, not a bug, but it stops this
    /// test from isolating Fix 2 — a warm-tinted holder survives the chroma
    /// gate (its blue/red ratio sits at ≈0.33, comfortably under the 0.9
    /// gate) while remaining exactly as dense a contaminant, so only the
    /// *crop* removes it here.
    func testAutoConvertMeasuresTheCroppedFrameNotTheFullOne() throws {
        let (url, centerCropRect) = try Self.makeHolderMaskedNegativePNG()
        let catalog = try TestSupport.inMemoryCatalog()

        // Blind: no crop set, so Auto measures the full frame — holder border
        // included, exactly the corpus defect.
        let blindEntry = TestSupport.makeEntry(fileURL: url)
        try catalog.save(blindEntry)
        let blindModel = EditorModel(entry: blindEntry, catalog: catalog,
                                     thumbnails: TestSupport.tempThumbnails(), commitDelay: 60)
        blindModel.autoConvertNegative()
        let blindDmax = blindModel.editStack.filmNegative.print.dmax
        let blindExposure = blindModel.editStack.filmNegative.print.exposure

        // Cropped: same file, a crop already set to the center (film-only)
        // region before Auto ever runs — the darkroom order, crop then convert.
        var croppedStack = EditStack()
        croppedStack.geometry.cropRect = centerCropRect
        let croppedEntry = TestSupport.makeEntry(fileURL: url, editStack: croppedStack)
        try catalog.save(croppedEntry)
        let croppedModel = EditorModel(entry: croppedEntry, catalog: catalog,
                                       thumbnails: TestSupport.tempThumbnails(), commitDelay: 60)
        croppedModel.autoConvertNegative()
        let croppedDmax = croppedModel.editStack.filmNegative.print.dmax
        let croppedExposure = croppedModel.editStack.filmNegative.print.exposure

        // Printed unconditionally so the measured before/after numbers are on
        // the record without re-running anything (same discipline as
        // RealScanTests' per-frame diagnostics).
        print("CROP-AWARE-AUTO blind:   dmax=\(blindDmax) exposure=\(blindExposure)")
        print("CROP-AWARE-AUTO cropped: dmax=\(croppedDmax) exposure=\(croppedExposure)")

        XCTAssertNotEqual(blindDmax, croppedDmax,
                          "cropping out the holder should change the measured white point")
        XCTAssertNotEqual(blindExposure, croppedExposure,
                          "cropping out the holder should change the solved print exposure")

        // The holder is denser than anything in the real image, so excluding
        // it must LOWER every channel's measured Dmax, not merely change it.
        XCTAssertLessThan(croppedDmax.red, blindDmax.red,
                          "red Dmax should drop once the holder is cropped out")
        XCTAssertLessThan(croppedDmax.green, blindDmax.green,
                          "green Dmax should drop once the holder is cropped out")
        XCTAssertLessThan(croppedDmax.blue, blindDmax.blue,
                          "blue Dmax should drop once the holder is cropped out")
    }

    /// Builds an 8-bit sRGB PNG: `FilmSim`'s scene patch grid confined to the
    /// center half of the frame (by area, a quarter of it — `[0.25, 0.75]` in
    /// both axes), surrounded by a solid near-black border simulating a
    /// physical negative-holder mask. Returns the file URL and the unit-space
    /// crop rect that exactly bounds the center region.
    ///
    /// Pixel values are written as sRGB-encoded transmittance, the same way a
    /// real scan file stores a negative — not `FilmSim.negativeImage`'s raw
    /// linear buffer, which is built for in-memory `CIImage` fixtures read
    /// straight back through `AutoInvert.linearPixels` and would decode wrong
    /// if it round-tripped through an ordinary (gamma-tagged) PNG file.
    private static func makeHolderMaskedNegativePNG(size: Int = 200) throws -> (url: URL, centerCropRect: CGRect) {
        let dmin = FilmSim.c41Base
        let gammas = FilmSim.crossoverGammas
        let patches = FilmSim.scene()
        let cols = 5, rows = 2

        let centerCropRect = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let centerStart = size / 4
        let centerSize = size / 2
        let cellW = max(1, centerSize / cols)
        let cellH = max(1, centerSize / rows)

        // Near-black holder bytes, ALREADY display-encoded (this is what
        // gets written straight to the file — a physical holder as a camera
        // would actually capture it, not a linear transmittance run through
        // the encoder). Slightly red-warm rather than perfectly neutral —
        // see the test's doc comment for why: a perfectly neutral near-black
        // (r=g=b) is excluded by Fix 3's chroma gate on its own (blue/red =
        // 1.0, over its 0.9 ceiling), which would stop this fixture from
        // isolating Fix 2. At (3, 1, 1) the blue/red ratio is ≈0.33 — well
        // under the gate, so the chroma gate leaves it alone — while still
        // decoding to a density well past the patch grid's own densest patch
        // in every channel (see the test's doc comment for the margin).
        let holderRedByte: UInt8 = 3
        let holderGreenByte: UInt8 = 1
        let holderBlueByte: UInt8 = 1

        func encodeByte(_ linear: Double) -> UInt8 {
            let s = PaperResponse.srgbEncode(min(max(linear, 0), 1))
            return UInt8((min(max(s, 0), 1) * 255).rounded())
        }

        let bytesPerPixel = 4
        let rowBytes = size * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: size * rowBytes)
        for y in 0..<size {
            for x in 0..<size {
                let i = y * rowBytes + x * bytesPerPixel
                let inCenterX = x >= centerStart && x < centerStart + centerSize
                let inCenterY = y >= centerStart && y < centerStart + centerSize
                if inCenterX && inCenterY {
                    let cx = x - centerStart, cy = y - centerStart
                    let col = min(cx / cellW, cols - 1), row = min(cy / cellH, rows - 1)
                    let patch = patches[row * cols + col].linear
                    let t = FilmSim.transmittance(of: patch, dmin: dmin, gammas: gammas)
                    pixels[i] = encodeByte(t.0)
                    pixels[i + 1] = encodeByte(t.1)
                    pixels[i + 2] = encodeByte(t.2)
                } else {
                    pixels[i] = holderRedByte; pixels[i + 1] = holderGreenByte; pixels[i + 2] = holderBlueByte
                }
                pixels[i + 3] = 255
            }
        }

        let context = CGContext(
            data: &pixels, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: rowBytes, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        let cgImage = try XCTUnwrap(context?.makeImage())

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("petest-holder-\(UUID().uuidString).png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, cgImage, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return (url, centerCropRect)
    }
}
