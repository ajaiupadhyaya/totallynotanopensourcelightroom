import Foundation
import XCTest
@testable import PhotoEditor

/// What the catalog does at library scale.
///
/// The suite has always exercised the catalog at a handful of rows, which
/// proves correctness and says nothing about behaviour at the size of a real
/// library. A shoebox of negatives is ~10k frames; a working photographer's
/// Lightroom catalog is routinely 100k–500k. Nothing here had ever been
/// measured there.
///
/// The sweep is gated so the normal suite stays fast: set `CATALOG_SCALE_ROWS`
/// to a row count to run it.
///
/// ```sh
/// CATALOG_SCALE_ROWS=250000 xcodebuild -project PhotoEditor.xcodeproj \
///   -scheme PhotoEditor -destination 'platform=macOS' \
///   -only-testing:PhotoEditorTests/CatalogScaleTests/testScaleSweep test
/// ```
///
/// The ungated tests below run at a size small enough to be cheap but large
/// enough to catch a regression in the *shape* of the cost, not its constant.
final class CatalogScaleTests: XCTestCase {

    // MARK: Fixtures

    /// A catalog on disk in a temp directory, deleted when the test ends.
    /// On-disk rather than in-memory on purpose: page cache, journal and
    /// fsync behaviour are part of what is being measured.
    private func makeOnDiskStore() throws -> (store: CatalogStore, path: String) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("catalog-scale-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let path = dir.appendingPathComponent("catalog.sqlite").path
        return (try CatalogStore(path: path), path)
    }

    /// Synthetic entries shaped like a real library rather than like a test:
    /// a spread of ratings, flags and labels, a realistic mix of camera bodies,
    /// virtual copies on a minority of files, and — the part that matters most
    /// for row cost — a mix of untouched and heavily-edited stacks.
    private func makeEntries(count: Int) -> [CatalogEntry] {
        let cameras = [
            ("Nikon", "NIKON Z 7", "NIKKOR Z 50mm f/1.8 S"),
            ("Canon", "Canon EOS R5", "RF24-70mm F2.8 L IS USM"),
            ("FUJIFILM", "X-T5", "XF35mmF1.4 R"),
            ("SONY", "ILCE-7RM4", "FE 85mm F1.4 GM"),
            ("Epson", "Perfection V850", nil),
        ]
        let labels = ColorLabel.allCases
        let flags = PickFlag.allCases

        var entries: [CatalogEntry] = []
        entries.reserveCapacity(count)

        // A fixed epoch keeps the fixture deterministic — no Date() anywhere,
        // so two runs produce identical rows and timings stay comparable.
        let epoch = Date(timeIntervalSince1970: 1_600_000_000)

        var fileIndex = 0
        while entries.count < count {
            let camera = cameras[fileIndex % cameras.count]
            let url = URL(fileURLWithPath: "/Volumes/Photos/2026/roll-\(fileIndex / 36)/frame-\(fileIndex).dng")

            // Every 7th file also carries a virtual copy, so the grouping path
            // in allEntries() is exercised rather than short-circuited.
            let copies = (fileIndex % 7 == 0) ? 2 : 1

            for copyNumber in 0..<copies where entries.count < count {
                var entry = CatalogEntry(
                    id: UUID(),
                    fileURL: url,
                    dateImported: epoch.addingTimeInterval(Double(fileIndex)),
                    editStack: Self.stack(heavy: fileIndex % 4 == 0),
                    thumbnailPath: URL(fileURLWithPath: "/tmp/thumbs/\(fileIndex)-\(copyNumber).jpg"),
                    rating: fileIndex % 6,
                    flag: flags[fileIndex % flags.count],
                    colorLabel: labels[fileIndex % labels.count],
                    cameraMake: camera.0,
                    cameraModel: camera.1,
                    lensModel: camera.2,
                    iso: [100, 200, 400, 800, 1600, 3200][fileIndex % 6],
                    captureDate: epoch.addingTimeInterval(Double(fileIndex) * 37)
                )
                entry.copyNumber = copyNumber
                entries.append(entry)
            }
            fileIndex += 1
        }
        return entries
    }

    /// An untouched stack, or one carrying the kind of edit that makes a row
    /// expensive: local adjustments with mask components and retouch spots.
    private static func stack(heavy: Bool) -> EditStack {
        var stack = EditStack()
        stack.exposure = 0.35
        stack.contrast = 12
        guard heavy else { return stack }

        stack.localAdjustments = (0..<4).map { i in
            var adjustment = LocalAdjustment()
            adjustment.exposure = Double(i) * 0.1
            return adjustment
        }
        stack.retouch = (0..<12).map { _ in RetouchSpot() }
        return stack
    }

    // MARK: Instruments

    private func time(_ body: () throws -> Void) rethrows -> TimeInterval {
        let start = DispatchTime.now().uptimeNanoseconds
        try body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
    }

    /// Resident set size, for the "does loading the library fit in memory"
    /// question. Approximate by nature — allocator behaviour and autorelease
    /// timing both blur it — so it is reported, never asserted on.
    private func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }

    private func mb(_ bytes: UInt64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    private func fileSize(_ path: String) -> UInt64 {
        let keys: [FileAttributeKey] = [.size]
        var total: UInt64 = 0
        // -wal and -shm hold real bytes too; count what the library costs on disk.
        for suffix in ["", "-wal", "-shm"] {
            let attributes = try? FileManager.default.attributesOfItem(atPath: path + suffix)
            if let size = attributes?[keys[0]] as? UInt64 { total += size }
        }
        return total
    }

    // MARK: The gated sweep

    func testScaleSweep() throws {
        guard let raw = ProcessInfo.processInfo.environment["CATALOG_SCALE_ROWS"],
              let rows = Int(raw) else {
            throw XCTSkip("Set CATALOG_SCALE_ROWS to run the scale sweep.")
        }

        let (store, path) = try makeOnDiskStore()
        let entries = makeEntries(count: rows)

        // How big is one row, really? The editStack JSON dominates it.
        let encoder = JSONEncoder()
        let stackBytes = try entries.map { try encoder.encode($0.editStack).count }
        let averageStack = stackBytes.reduce(0, +) / max(stackBytes.count, 1)

        let seedSeconds = try time { try store.save(entries) }

        let beforeLoad = residentBytes()
        var loaded: [CatalogEntry] = []
        let loadSeconds = try time { loaded = try store.allEntries() }
        let afterLoad = residentBytes()
        XCTAssertEqual(loaded.count, rows)

        // Second call, warm: is the cost the query or the decode + sort?
        let warmSeconds = try time { _ = try store.allEntries() }

        // What the grid actually needs: one screenful, ordered, from an index.
        let pageSeconds = try time {
            _ = try store.recentEntries(limit: 200, offset: 0)
        }
        let deepPageSeconds = try time {
            _ = try store.recentEntries(limit: 200, offset: max(rows - 200, 0))
        }

        let lookupID = loaded[rows / 2].id
        let lookupSeconds = try time { _ = try store.entry(id: lookupID) }

        let countSeconds = try time { _ = try store.entryCount() }

        print("""

        ┌─ CATALOG SCALE ─────────────────────────────────────────────
        │ rows                    \(rows)
        │ avg editStack JSON      \(averageStack) B
        │ database on disk        \(mb(fileSize(path)))
        ├─ writes ────────────────────────────────────────────────────
        │ bulk seed (1 txn)       \(String(format: "%.3f s", seedSeconds))  \
        (\(String(format: "%.0f", Double(rows) / max(seedSeconds, 0.000001))) rows/s)
        ├─ reads ─────────────────────────────────────────────────────
        │ allEntries() cold       \(String(format: "%.3f s", loadSeconds))
        │ allEntries() warm       \(String(format: "%.3f s", warmSeconds))
        │ recentEntries(200)      \(String(format: "%.4f s", pageSeconds))
        │ recentEntries(200) deep \(String(format: "%.4f s", deepPageSeconds))
        │ entry(id:)              \(String(format: "%.4f s", lookupSeconds))
        │ entryCount()            \(String(format: "%.4f s", countSeconds))
        ├─ memory ────────────────────────────────────────────────────
        │ RSS delta over load     \(mb(afterLoad &- beforeLoad))
        └─────────────────────────────────────────────────────────────

        """)
    }

    // MARK: Ungated guards

    /// The paged accessor must agree with the full sort, or paging silently
    /// reorders someone's library. Checked against `allEntries()` at a size
    /// where computing both is cheap.
    func testPagedFetchMatchesFullOrdering() throws {
        let (store, _) = try makeOnDiskStore()
        try store.save(makeEntries(count: 500))

        let all = try store.allEntries()
        var paged: [CatalogEntry] = []
        var offset = 0
        while true {
            let page = try store.recentEntries(limit: 64, offset: offset)
            if page.isEmpty { break }
            paged.append(contentsOf: page)
            offset += 64
        }

        XCTAssertEqual(paged.map(\.id), all.map(\.id),
                       "Paged fetch must produce the same order as the full fetch.")
    }

    /// Paging must not degrade as the offset moves deep into the library —
    /// the ordering has to come from an index, not from sorting every row and
    /// discarding all but a screenful.
    func testDeepPagingDoesNotDegrade() throws {
        let (store, _) = try makeOnDiskStore()
        let rows = 20_000
        try store.save(makeEntries(count: rows))

        // Warm the page cache so this measures the query, not first-touch IO.
        _ = try store.recentEntries(limit: 200, offset: 0)

        let shallow = try time { _ = try store.recentEntries(limit: 200, offset: 0) }
        let deep = try time { _ = try store.recentEntries(limit: 200, offset: rows - 200) }

        // Generous: catching an O(n) scan per page, not micro-regressions.
        XCTAssertLessThan(deep, max(shallow * 25, 0.05),
                          "Deep paging cost \(deep)s vs \(shallow)s shallow — the ordering is not coming from an index.")
    }

    /// `entryCount()` must not load the library to count it.
    func testCountDoesNotLoadEveryRow() throws {
        let (store, _) = try makeOnDiskStore()
        try store.save(makeEntries(count: 20_000))

        let counted = try time { XCTAssertEqual(try store.entryCount(), 20_000) }
        XCTAssertLessThan(counted, 0.05,
                          "Counting took \(counted)s — that is a table load, not a COUNT.")
    }
}
