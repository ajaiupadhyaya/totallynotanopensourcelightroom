import CoreGraphics
import XCTest
@testable import PhotoEditor

/// Verifies the library workflow: copy/paste settings across frames, presets,
/// culling metadata, and their persistence.
final class WorkflowTests: XCTestCase {
    private func developedStack() -> EditStack {
        var stack = EditStack()
        stack.exposure = 1.2
        stack.contrast = 30
        stack.vibrance = 25
        stack.color.mixer[.orange].saturation = 40
        stack.color.grading.shadows.hue = 220
        stack.color.grading.shadows.saturation = 30
        stack.grainAmount = 35
        stack.geometry.cropRect = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        stack.filmNegative.isEnabled = true
        stack.filmNegative.baseColor = FilmColor(red: 0.99, green: 0.60, blue: 0.34)
        stack.filmNegative.stockContrast = 8
        return stack
    }

    // MARK: Transfer semantics

    func testApplyingCarriesTheLookAcross() {
        let source = developedStack()
        let result = EditStack().applying(source)

        XCTAssertEqual(result.exposure, 1.2, accuracy: 1e-9)
        XCTAssertEqual(result.contrast, 30, accuracy: 1e-9)
        XCTAssertEqual(result.vibrance, 25, accuracy: 1e-9)
        XCTAssertEqual(result.color.mixer[.orange].saturation, 40, accuracy: 1e-9)
        XCTAssertEqual(result.color.grading.shadows.saturation, 30, accuracy: 1e-9)
        XCTAssertEqual(result.grainAmount, 35, accuracy: 1e-9)
    }

    func testApplyingLeavesTheFramesOwnCropAlone() {
        // Every frame is composed individually, so pasting a look must not
        // paste the crop.
        var target = EditStack()
        target.geometry.cropRect = CGRect(x: 0, y: 0, width: 0.5, height: 0.5)

        let result = target.applying(developedStack())
        XCTAssertEqual(result.geometry.cropRect,
                       CGRect(x: 0, y: 0, width: 0.5, height: 0.5),
                       "The target's own crop must survive a paste.")
    }

    func testApplyingLeavesTheFramesOwnFilmBaseAlone() {
        // Each negative needs its own base sample; carrying one frame's base
        // across a roll would put a color cast on every other frame.
        var target = EditStack()
        let ownBase = FilmColor(red: 0.92, green: 0.55, blue: 0.30)
        target.filmNegative.baseColor = ownBase

        let result = target.applying(developedStack())
        XCTAssertEqual(result.filmNegative.baseColor, ownBase)
        XCTAssertEqual(result.filmNegative.stockContrast, 8,
                       "Stock character should still transfer.")
        XCTAssertTrue(result.filmNegative.isEnabled)
    }

    func testEverythingOptionsAlsoTransferCropAndBase() {
        let result = EditStack().applying(developedStack(), options: .everything)
        XCTAssertEqual(result.geometry.cropRect,
                       CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8))
        XCTAssertEqual(result.filmNegative.baseColor,
                       FilmColor(red: 0.99, green: 0.60, blue: 0.34))
    }

    func testDeselectingACategorySkipsIt() {
        var options = EditTransferOptions()
        options.effects = false
        options.colorGrading = false

        let result = EditStack().applying(developedStack(), options: options)
        XCTAssertEqual(result.exposure, 1.2, accuracy: 1e-9)
        XCTAssertEqual(result.grainAmount, 0, "Effects were deselected.")
        XCTAssertEqual(result.color.grading.shadows.saturation, 0,
                       "Grading was deselected.")
    }

    // MARK: Culling metadata

    func testRatingFlagAndLabelRoundTrip() throws {
        let store = try TestSupport.inMemoryCatalog()
        var entry = TestSupport.makeEntry(fileURL: URL(fileURLWithPath: "/tmp/a.jpg"))
        entry.rating = 4
        entry.flag = .picked
        entry.colorLabel = .yellow
        try store.save(entry)

        let fetched = try XCTUnwrap(store.entry(id: entry.id))
        XCTAssertEqual(fetched.rating, 4)
        XCTAssertEqual(fetched.flag, .picked)
        XCTAssertEqual(fetched.colorLabel, .yellow)
    }

    func testNewEntriesDefaultToUnratedAndUnflagged() {
        let entry = TestSupport.makeEntry(fileURL: URL(fileURLWithPath: "/tmp/a.jpg"))
        XCTAssertEqual(entry.rating, 0)
        XCTAssertEqual(entry.flag, .unflagged)
        XCTAssertEqual(entry.colorLabel, .none)
    }

    func testCatalogEntryJSONWithoutCullingFieldsStillDecodes() throws {
        let legacy = """
        {"id":"\(UUID().uuidString)","fileURL":"file:///tmp/a.jpg",
         "dateImported":0,"editStack":{"exposure":1}}
        """.data(using: .utf8)!

        let entry = try JSONDecoder().decode(CatalogEntry.self, from: legacy)
        XCTAssertEqual(entry.rating, 0)
        XCTAssertEqual(entry.flag, .unflagged)
        XCTAssertEqual(entry.editStack.exposure, 1, accuracy: 1e-9)
    }

    // MARK: Presets

    func testPresetsRoundTrip() throws {
        let store = try TestSupport.inMemoryCatalog()
        let preset = DevelopPreset(name: "Portra Warm", group: "Film",
                                   editStack: developedStack())
        try store.savePreset(preset)

        let fetched = try XCTUnwrap(store.allPresets().first)
        XCTAssertEqual(fetched.name, "Portra Warm")
        XCTAssertEqual(fetched.group, "Film")
        XCTAssertEqual(fetched.editStack.exposure, 1.2, accuracy: 1e-9)
        XCTAssertEqual(fetched.editStack.color.mixer[.orange].saturation, 40, accuracy: 1e-9)
    }

    func testPresetsAreOrderedByGroupThenName() throws {
        let store = try TestSupport.inMemoryCatalog()
        try store.savePreset(DevelopPreset(name: "Zeta", group: "A", editStack: EditStack()))
        try store.savePreset(DevelopPreset(name: "Alpha", group: "B", editStack: EditStack()))
        try store.savePreset(DevelopPreset(name: "Alpha", group: "A", editStack: EditStack()))

        let names = try store.allPresets().map { "\($0.group)/\($0.name)" }
        XCTAssertEqual(names, ["A/Alpha", "A/Zeta", "B/Alpha"])
    }

    func testDeletingAPreset() throws {
        let store = try TestSupport.inMemoryCatalog()
        let preset = DevelopPreset(name: "Temp", editStack: EditStack())
        try store.savePreset(preset)
        try store.deletePreset(id: preset.id)
        XCTAssertTrue(try store.allPresets().isEmpty)
    }

    // MARK: Migration

    func testExistingCatalogsMigrateWithoutLosingRows() throws {
        // A catalog created, closed, and reopened must run the newer migrations
        // and keep its entries -- upgrading the app can't drop the library.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pemig-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("catalog.sqlite").path

        let id = UUID()
        do {
            let store = try CatalogStore(path: path)
            var entry = TestSupport.makeEntry(fileURL: URL(fileURLWithPath: "/tmp/a.jpg"))
            entry = CatalogEntry(id: id, fileURL: entry.fileURL,
                                 dateImported: entry.dateImported,
                                 editStack: entry.editStack, thumbnailPath: nil)
            try store.save(entry)
        }

        let reopened = try CatalogStore(path: path)
        let fetched = try XCTUnwrap(reopened.entry(id: id))
        XCTAssertEqual(fetched.rating, 0)
        XCTAssertTrue(try reopened.allPresets().isEmpty)
    }
}
