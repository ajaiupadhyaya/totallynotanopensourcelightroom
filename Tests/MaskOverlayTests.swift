import CoreImage
import XCTest
@testable import PhotoEditor

/// The overlay is a viewing aid. It must be obvious on screen and absent from
/// every exported pixel.
final class MaskOverlayTests: XCTestCase {
    private let extent = CGRect(x: 0, y: 0, width: 100, height: 100)

    private func source() -> CIImage {
        TestSupport.solidImage(red: 0.5, green: 0.5, blue: 0.5, size: 100)
    }

    private func fullMask() -> CIImage {
        CIImage(color: .white).cropped(to: extent)
    }

    func testOverlayTintsTowardRed() {
        let tinted = MaskOverlay.tinted(source(), mask: fullMask(), extent: extent)
        let color = TestSupport.readColor(tinted.cropped(to: CGRect(x: 40, y: 40, width: 20, height: 20)))

        XCTAssertGreaterThan(color.red, color.green + 0.1, "A selected area must read red.")
        XCTAssertGreaterThan(color.red, color.blue + 0.1)
    }

    func testUnselectedAreasAreLeftAlone() {
        let empty = CIImage(color: .black).cropped(to: extent)
        let tinted = MaskOverlay.tinted(source(), mask: empty, extent: extent)
        let color = TestSupport.readColor(tinted.cropped(to: CGRect(x: 40, y: 40, width: 20, height: 20)))

        XCTAssertEqual(color.red, 0.5, accuracy: 0.02)
        XCTAssertEqual(color.green, 0.5, accuracy: 0.02)
    }

    /// The important one. Export renders through `EditRenderer` from the edit
    /// stack, so proving the overlay changes neither is proving it can never
    /// reach an exported pixel.
    func testOverlayChangesNeitherTheEditStackNorTheRenderer() throws {
        let url = try TestSupport.makeTempPNG()
        defer { try? FileManager.default.removeItem(at: url) }
        let catalog = try TestSupport.inMemoryCatalog()
        let entry = TestSupport.makeEntry(fileURL: url)
        try catalog.save(entry)

        let editor = EditorModel(entry: entry, catalog: catalog,
                                 thumbnails: TestSupport.tempThumbnails(), commitDelay: 60)
        editor.addLocalAdjustment(.radial)
        editor.editStack.localAdjustments[0].exposure = -1

        let renderer = EditRenderer()
        let stackBefore = editor.editStack
        let plain = renderer.render(source: source(), stack: editor.editStack)

        editor.isShowingMaskOverlay = true

        XCTAssertEqual(editor.editStack, stackBefore,
                       "Toggling a viewing aid must not touch the edit stack.")

        let withOverlay = renderer.render(source: source(), stack: editor.editStack)
        let probe = CGRect(x: 40, y: 40, width: 20, height: 20)
        XCTAssertEqual(TestSupport.readColor(plain.cropped(to: probe)).red,
                       TestSupport.readColor(withOverlay.cropped(to: probe)).red,
                       accuracy: 1e-6,
                       "The renderer export uses must be blind to the overlay.")
    }
}
