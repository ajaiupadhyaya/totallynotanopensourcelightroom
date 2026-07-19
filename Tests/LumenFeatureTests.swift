import CoreImage
import XCTest
@testable import PhotoEditor

/// Covers the features added from the Lumen specification: keyboard culling,
/// capture-metadata indexing and search, focus peaking, and output sharpening.
@MainActor
final class LumenFeatureTests: XCTestCase {
    // MARK: Capture metadata

    func testCaptureMetadataRoundTripsAndIsIndexed() throws {
        let store = try TestSupport.inMemoryCatalog()
        var entry = TestSupport.makeEntry(fileURL: URL(fileURLWithPath: "/tmp/a.jpg"))
        entry.cameraMake = "Nikon"
        entry.cameraModel = "FM2"
        entry.lensModel = "50mm f/1.4"
        entry.iso = 400
        entry.captureDate = Date(timeIntervalSince1970: 1_000_000)
        try store.save(entry)

        let fetched = try XCTUnwrap(store.entry(id: entry.id))
        XCTAssertEqual(fetched.cameraModel, "FM2")
        XCTAssertEqual(fetched.lensModel, "50mm f/1.4")
        XCTAssertEqual(fetched.iso, 400)
    }

    func testCatalogRowsWithoutMetadataStillDecode() throws {
        let legacy = """
        {"id":"\(UUID().uuidString)","fileURL":"file:///tmp/a.jpg",
         "dateImported":0,"editStack":{},"rating":3}
        """.data(using: .utf8)!

        let entry = try JSONDecoder().decode(CatalogEntry.self, from: legacy)
        XCTAssertEqual(entry.rating, 3)
        XCTAssertNil(entry.cameraModel)
        XCTAssertNil(entry.iso)
    }

    // MARK: Search & filter

    private func entry(
        name: String, camera: String? = nil, lens: String? = nil,
        rating: Int = 0, flag: PickFlag = .unflagged, label: ColorLabel = .none
    ) -> CatalogEntry {
        var entry = TestSupport.makeEntry(fileURL: URL(fileURLWithPath: "/tmp/\(name)"))
        entry.cameraModel = camera
        entry.lensModel = lens
        entry.rating = rating
        entry.flag = flag
        entry.colorLabel = label
        return entry
    }

    func testSearchMatchesFileNameCameraAndLens() {
        let filter = LibraryFilter()
        let frame = entry(name: "roll12-04.tiff", camera: "Lubitel 166U", lens: "Triplet 75mm")

        XCTAssertTrue(filter.matches(frame, search: "roll12"))
        XCTAssertTrue(filter.matches(frame, search: "lubitel"), "Search should be case-insensitive.")
        XCTAssertTrue(filter.matches(frame, search: "Triplet"))
        XCTAssertFalse(filter.matches(frame, search: "Hasselblad"))
    }

    func testEmptySearchMatchesEverything() {
        let filter = LibraryFilter()
        XCTAssertTrue(filter.matches(entry(name: "a.jpg"), search: "   "))
    }

    func testFiltersCombine() {
        var filter = LibraryFilter()
        filter.minimumRating = 3
        filter.flag = .picked

        XCTAssertTrue(filter.matches(entry(name: "a", rating: 4, flag: .picked)))
        XCTAssertFalse(filter.matches(entry(name: "b", rating: 2, flag: .picked)),
                       "Rating below the minimum should be excluded.")
        XCTAssertFalse(filter.matches(entry(name: "c", rating: 4, flag: .rejected)),
                       "A non-matching flag should be excluded.")
    }

    // MARK: Keyboard culling

    private func makeApp() -> AppModel { AppModel() }

    func testNumberKeysSetAndToggleRatings() throws {
        let app = makeApp()
        guard let entry = app.importPhoto(from: try TestSupport.makeTempPNG()) else {
            return XCTFail("import failed")
        }
        defer { app.removeFromLibrary(entry) }

        XCTAssertTrue(CullingCommands.handle(key: "4", on: [entry], app: app))
        XCTAssertEqual(app.entries.first { $0.id == entry.id }?.rating, 4)

        // Pressing the same rating again clears it.
        let rated = try XCTUnwrap(app.entries.first { $0.id == entry.id })
        CullingCommands.handle(key: "4", on: [rated], app: app)
        XCTAssertEqual(app.entries.first { $0.id == entry.id }?.rating, 0)
    }

    func testPAndXToggleFlags() throws {
        let app = makeApp()
        guard let entry = app.importPhoto(from: try TestSupport.makeTempPNG()) else {
            return XCTFail("import failed")
        }
        defer { app.removeFromLibrary(entry) }

        CullingCommands.handle(key: "p", on: [entry], app: app)
        XCTAssertEqual(app.entries.first { $0.id == entry.id }?.flag, .picked)

        let picked = try XCTUnwrap(app.entries.first { $0.id == entry.id })
        CullingCommands.handle(key: "x", on: [picked], app: app)
        XCTAssertEqual(app.entries.first { $0.id == entry.id }?.flag, .rejected,
                       "X should override a pick, not toggle back to unflagged.")
    }

    func testColorLabelKeys() throws {
        let app = makeApp()
        guard let entry = app.importPhoto(from: try TestSupport.makeTempPNG()) else {
            return XCTFail("import failed")
        }
        defer { app.removeFromLibrary(entry) }

        CullingCommands.handle(key: "8", on: [entry], app: app)
        XCTAssertEqual(app.entries.first { $0.id == entry.id }?.colorLabel, .green)
    }

    func testUnhandledKeysAreReportedSoCallersCanFallThrough() {
        let app = makeApp()
        let frame = entry(name: "a.jpg")
        XCTAssertFalse(CullingCommands.handle(key: "q", on: [frame], app: app))
        XCTAssertFalse(CullingCommands.handle(key: "1", on: [], app: app),
                       "No targets means nothing to handle.")
    }

    // MARK: Focus peaking

    func testFocusPeakingTintsEdgesAndLeavesFlatAreasAlone() {
        // A hard edge should pick up the tint; a flat field should not.
        let dark = TestSupport.solidImage(red: 0.2, green: 0.2, blue: 0.2,
                                          in: CGRect(x: 0, y: 0, width: 64, height: 128))
        let bright = TestSupport.solidImage(red: 0.9, green: 0.9, blue: 0.9,
                                            in: CGRect(x: 64, y: 0, width: 64, height: 128))
        let edged = bright.composited(over: dark)
            .cropped(to: CGRect(x: 0, y: 0, width: 128, height: 128))

        let peaked = FocusPeaking.overlay(on: edged)
        let atEdge = TestSupport.readColor(
            peaked.cropped(to: CGRect(x: 62, y: 40, width: 4, height: 40))
        )
        XCTAssertGreaterThan(atEdge.green, atEdge.red + 0.1,
                             "The edge should pick up the green peaking tint.")

        let flat = TestSupport.solidImage(red: 0.5, green: 0.5, blue: 0.5, size: 96)
        let flatPeaked = TestSupport.readColor(
            FocusPeaking.overlay(on: flat).cropped(to: CGRect(x: 20, y: 20, width: 40, height: 40))
        )
        XCTAssertEqual(flatPeaked.green, flatPeaked.red, accuracy: 0.05,
                       "A flat area has no detail to peak on.")
    }

    func testFocusPeakingIsPreviewOnlyAndNeverExported() throws {
        // Peaking is a viewing aid; it must not reach a written file.
        let source = try TestSupport.makeTempPNG(gray: 128, size: 64)
        defer { try? FileManager.default.removeItem(at: source) }
        let catalog = try TestSupport.inMemoryCatalog()
        let entry = TestSupport.makeEntry(fileURL: source)
        try catalog.save(entry)

        let editor = EditorModel(entry: entry, catalog: catalog,
                                 thumbnails: TestSupport.tempThumbnails(), commitDelay: 60)
        editor.isFocusPeakingEnabled = true

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("peek-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: destination) }
        var settings = ExportSettings()
        settings.format = .png
        try editor.export(settings: settings, to: destination)

        let exported = try XCTUnwrap(CIImage(contentsOf: destination))
        let color = TestSupport.readColor(exported)
        XCTAssertEqual(color.red, color.green, accuracy: 0.02,
                       "The exported file must not carry the peaking overlay.")
    }

    // MARK: Output sharpening

    func testOutputSharpeningStrengthensAnEdge() {
        let service = ExportService()
        let dark = TestSupport.solidImage(red: 0.3, green: 0.3, blue: 0.3,
                                          in: CGRect(x: 0, y: 0, width: 64, height: 128))
        let bright = TestSupport.solidImage(red: 0.7, green: 0.7, blue: 0.7,
                                            in: CGRect(x: 64, y: 0, width: 64, height: 128))
        let edged = bright.composited(over: dark)
            .cropped(to: CGRect(x: 0, y: 0, width: 128, height: 128))

        // Sample immediately either side of the edge: an unsharp mask's
        // overshoot lives within about a radius of the transition, so wider
        // samples further out average it away.
        func contrastAcrossEdge(_ image: CIImage) -> Double {
            let left = TestSupport.readColor(
                image.cropped(to: CGRect(x: 62, y: 32, width: 2, height: 64)))
            let right = TestSupport.readColor(
                image.cropped(to: CGRect(x: 64, y: 32, width: 2, height: 64)))
            return right.red - left.red
        }

        var settings = ExportSettings()
        settings.outputSharpening = .print
        let sharpened = service.applyOutputSharpening(edged, settings: settings)

        XCTAssertGreaterThan(contrastAcrossEdge(sharpened), contrastAcrossEdge(edged))
    }

    func testNoneSharpeningIsAnExactNoOp() {
        let service = ExportService()
        let image = TestSupport.solidImage(red: 0.4, green: 0.5, blue: 0.6, size: 32)
        var settings = ExportSettings()
        settings.outputSharpening = .none

        let result = TestSupport.readColor(service.applyOutputSharpening(image, settings: settings))
        XCTAssertEqual(result.red, 0.4, accuracy: 0.001)
        XCTAssertEqual(result.blue, 0.6, accuracy: 0.001)
    }

    func testPrintSharpensMoreThanWeb() {
        XCTAssertGreaterThan(ExportSettings.OutputSharpening.print.intensity,
                             ExportSettings.OutputSharpening.web.intensity)
        XCTAssertGreaterThan(ExportSettings.OutputSharpening.print.radius,
                             ExportSettings.OutputSharpening.web.radius,
                             "A compressed web file wants a finer radius than a print.")
    }

    func testExportSettingsRoundTripIncludingSharpening() throws {
        var settings = ExportSettings()
        settings.outputSharpening = .print
        settings.format = .tiff

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(ExportSettings.self, from: data)
        XCTAssertEqual(decoded.outputSharpening, .print)
        XCTAssertEqual(decoded.format, .tiff)
    }
}
