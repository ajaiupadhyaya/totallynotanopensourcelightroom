import CoreGraphics
import XCTest
@testable import PhotoEditor

/// The histogram-drag ↔ slider binding, as pure functions: region geometry,
/// the keyPath identity that makes co-movement structural, and the drag law.
final class HistogramRegionTests: XCTestCase {
    func testRegionsPartitionTheAxisInOrder() {
        XCTAssertEqual(HistogramRegion.region(atUnitX: 0.05), .blacks)
        XCTAssertEqual(HistogramRegion.region(atUnitX: 0.25), .shadows)
        XCTAssertEqual(HistogramRegion.region(atUnitX: 0.50), .exposure)
        XCTAssertEqual(HistogramRegion.region(atUnitX: 0.75), .highlights)
        XCTAssertEqual(HistogramRegion.region(atUnitX: 0.95), .whites)
        XCTAssertEqual(HistogramRegion.region(atUnitX: -1), .blacks, "clamped, never nil")
        XCTAssertEqual(HistogramRegion.region(atUnitX: 2), .whites)
    }

    /// The whole feature in one assertion: the drag writes the field the
    /// slider binds. Not "a similar field" — the same key path.
    func testRegionsBindTheLightPanelsOwnFields() {
        XCTAssertEqual(HistogramRegion.blacks.keyPath, \EditStack.blacks)
        XCTAssertEqual(HistogramRegion.shadows.keyPath, \EditStack.shadows)
        XCTAssertEqual(HistogramRegion.exposure.keyPath, \EditStack.exposure)
        XCTAssertEqual(HistogramRegion.highlights.keyPath, \EditStack.highlights)
        XCTAssertEqual(HistogramRegion.whites.keyPath, \EditStack.whites)
    }

    func testDragLawIsLinearRightwardPositiveAndClamped() {
        // A full-width sweep covers `sweepFraction` of the control's whole
        // range — a taste constant, verified in-app. Shadows spans 200 units
        // (−100…100), so a full-width drag from centre lands exactly on +100.
        let sweep = 200.0 * HistogramRegion.sweepFraction
        XCTAssertEqual(HistogramRegion.shadows.value(startingFrom: 0, draggedByUnitDelta: 1),
                       sweep, accuracy: 1e-9)
        XCTAssertLessThan(HistogramRegion.blacks.value(startingFrom: 0, draggedByUnitDelta: -0.3),
                          0, "dragging left must darken")
        XCTAssertEqual(HistogramRegion.exposure.value(startingFrom: 2.9, draggedByUnitDelta: 1),
                       3.0, "clamped to the slider's own range")
    }
}

@MainActor
final class HistogramDragModelTests: XCTestCase {
    func testDragWritesTheFieldOnceAndCommitsOneUndoStep() throws {
        let editor = try TestSupport.makeEditorModel()
        editor.setLightValue(.exposure, to: 0.8)
        editor.setLightValue(.exposure, to: 1.2) // second tick of the same gesture
        XCTAssertEqual(editor.editStack.exposure, 1.2)
        editor.commitEdit()
        XCTAssertEqual(editor.undoDepth, 1, "a drag burst is one undo step, like a slider")
    }
}

final class ChannelClipFlagTests: XCTestCase {
    private func spiked(_ spikeAtTop: Bool) -> [Float] {
        var bins = [Float](repeating: 0.1, count: 256)
        bins[spikeAtTop ? 255 : 0] = 40
        return bins
    }

    func testOnlyTheSpikedChannelLights() {
        let h = Histogram(red: spiked(false),
                          green: [Float](repeating: 0.1, count: 256),
                          blue: [Float](repeating: 0.1, count: 256))
        XCTAssertTrue(h.shadowClipFlags.red)
        XCTAssertFalse(h.shadowClipFlags.green)
        XCTAssertFalse(h.shadowClipFlags.blue)
        XCTAssertFalse(h.highlightClipFlags.any)
    }

    /// A blown red channel on a sunset must light the red flag even when the
    /// pooled three-channel diagnostic stays quiet — that is the point of
    /// per-channel flags. The pooled `isClippingHighlights` semantics are
    /// untouched (HistogramScaleTests keeps pinning them).
    ///
    /// The arithmetic, because it is delicate: red carries 255 bins of 0.1
    /// plus a 0.5 top bin, so its own edge fraction is 0.5/26 ≈ 1.9% — well
    /// over the 0.5% threshold. Green and blue are flat at 2.0, which puts
    /// 512 units of mass under a 2.0 edge each (0.39%, quiet) and dilutes the
    /// pooled reading to 4.5/1050 ≈ 0.43% — under the same threshold.
    func testAPerChannelClipCanLightWithoutThePooledDiagnostic() {
        var red = [Float](repeating: 0.1, count: 256)
        red[255] = 0.5
        let flat = [Float](repeating: 2.0, count: 256)
        let h = Histogram(red: red, green: flat, blue: flat)
        XCTAssertTrue(h.highlightClipFlags.red)
        XCTAssertFalse(h.highlightClipFlags.green)
        XCTAssertFalse(h.isClippingHighlights,
                       "diluted below the pooled threshold — per-channel still reports")
    }
}

final class PixelSamplerTests: XCTestCase {
    /// A 2×2 image with distinct corners proves both axes and the y-flip:
    /// sampler unit points are bottom-left (the canvas's image convention),
    /// CGImage rows are top-down.
    private func cornerImage() throws -> CGImage {
        var pixels: [UInt8] = [
            255, 0, 0, 255,   0, 255, 0, 255,   // top row:    red, green
            0, 0, 255, 255,   255, 255, 255, 255, // bottom row: blue, white
        ]
        let context = CGContext(
            data: &pixels, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        return try XCTUnwrap(context?.makeImage())
    }

    func testSamplesTheRightPixelWithABottomLeftOrigin() throws {
        let sampler = try XCTUnwrap(PixelSampler(image: try cornerImage()))
        let bottomLeft = sampler.reading(atUnitPoint: CGPoint(x: 0.01, y: 0.01))
        XCTAssertGreaterThan(bottomLeft.blue, 0.9, "bottom-left is the blue pixel")
        let topLeft = sampler.reading(atUnitPoint: CGPoint(x: 0.01, y: 0.99))
        XCTAssertGreaterThan(topLeft.red, 0.9, "top-left is the red pixel")
    }

    func testLumaIsRec709OfTheSample() throws {
        let sampler = try XCTUnwrap(PixelSampler(image: try cornerImage()))
        let white = sampler.reading(atUnitPoint: CGPoint(x: 0.99, y: 0.01))
        XCTAssertEqual(white.luma, 1.0, accuracy: 0.02)
    }
}
