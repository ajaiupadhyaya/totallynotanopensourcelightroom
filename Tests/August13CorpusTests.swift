import CoreImage
import XCTest
@testable import PhotoEditor

/// The 2026-08-13 batch — the first corpus that is half **iPhone ProRAW DNG**
/// rather than HEIC/JPEG, and so the first real-file exercise of the film
/// path's RAW branch. Until now the RAW decode was verified by reasoning and
/// synthetic fixtures only (see the PV2 notes): `CIRAWFilter` in the sensor
/// domain, `RawDecodePolicy`'s version gating, and now the RAW 9 runtime
/// opt-in had never met an actual raw negative.
///
/// Runs the gesture the user actually performs — `EditorModel.enableFilmNegative()`
/// — rather than re-deriving Auto's steps here. That routes through frame
/// detection, the density solve, the crop write-back and the v2 semantics in
/// exactly the order the button does, so a divergence between this evidence
/// and the app is impossible by construction.
///
/// Gated on the corpus like every other real-scan suite: skips cleanly
/// elsewhere.
final class August13CorpusTests: XCTestCase {
    private static let dir =
        NSString("~/Desktop/all film/negatives aug 13th").expandingTildeInPath

    /// Beside the minilab artifacts, not over them — the pending acceptance
    /// sheet is still awaiting the user's taste pass.
    static let artifactDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("artifacts/aug13", isDirectory: true)

    private let context = CIContext()

    private static func filesOrSkip(suffix: String, count: Int) throws -> [URL] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir),
              isDir.boolValue,
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
            throw XCTSkip("corpus not present on this machine: \(dir)")
        }
        let matches = names.filter { $0.lowercased().hasSuffix(suffix) }.sorted()
        guard !matches.isEmpty else {
            throw XCTSkip("no \(suffix) files in \(dir)")
        }
        return matches.prefix(count).map {
            URL(fileURLWithPath: dir).appendingPathComponent($0)
        }
    }

    /// One frame, through the real gesture, with the render written out for
    /// the user's eye. Asserts sanity only — the picture is judged by a human.
    @discardableResult
    private func autoConvert(url: URL, label: String) throws -> Double {
        guard let scan = ImageDecoder.loadPreviewImage(from: url, maxDimension: 1600,
                                                       processVersion: 2) else {
            XCTFail("\(label): could not decode \(url.lastPathComponent)")
            return .nan
        }
        let catalog = try TestSupport.inMemoryCatalog()
        let entry = TestSupport.makeEntry(fileURL: url)
        try catalog.save(entry)
        let model = EditorModel(entry: entry, catalog: catalog,
                                thumbnails: TestSupport.tempThumbnails(),
                                commitDelay: 60)

        // THE gesture. Everything below only measures what it produced.
        model.enableFilmNegative()

        let film = model.editStack.filmNegative
        XCTAssertTrue(film.isEnabled, "\(label): Auto left the conversion off")

        let out = EditRenderer().render(source: scan, stack: model.editStack)
        let pixels = try XCTUnwrap(AutoInvert.linearPixels(of: out, side: 64,
                                                           context: context),
                                   "\(label): render produced no pixels")
        let lumas = pixels.map { 0.2126 * $0.0 + 0.7152 * $0.1 + 0.0722 * $0.2 }.sorted()
        let median = lumas[lumas.count / 2]

        print("AUG13 \(label): crop=\(model.editStack.geometry.cropRect) "
              + "base=\(film.baseOrigin) dmax=\(film.print.dmax) "
              + "gamma=\(film.print.gamma) EV=\(film.print.exposure) "
              + "profile=\(film.print.toneProfile) "
              + "terms=\(model.lastSolveDegradedTerms) medianLuma=\(median)")

        XCTAssertGreaterThan(median, 0.01, "\(label): renders black (\(median))")
        XCTAssertLessThan(median, 0.7, "\(label): renders blown (\(median))")

        try FileManager.default.createDirectory(at: Self.artifactDir,
                                                withIntermediateDirectories: true)
        try context.writeJPEGRepresentation(
            of: out,
            to: Self.artifactDir.appendingPathComponent("\(label).jpg"),
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)

        // The negative as it arrived, for the before/after pair.
        try context.writeJPEGRepresentation(
            of: scan,
            to: Self.artifactDir.appendingPathComponent("\(label)-before.jpg"),
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return median
    }

    func testHEICFramesConvertThroughTheRealAutoGesture() throws {
        let files = try Self.filesOrSkip(suffix: ".heic", count: 3)
        try files.forEach {
            try autoConvert(url: $0,
                            label: "aug13-\($0.deletingPathExtension().lastPathComponent)-heic")
        }
    }

    /// The new path. A ProRAW capture decodes through `CIRAWFilter`, so the
    /// scan Auto measures is the sensor-domain render, not a baked JPEG —
    /// different white balance, different tone, and (with RAW 9 available)
    /// a different decoder version entirely.
    func testProRAWFramesConvertThroughTheRealAutoGesture() throws {
        let files = try Self.filesOrSkip(suffix: ".dng", count: 3)
        try files.forEach {
            try autoConvert(url: $0,
                            label: "aug13-\($0.deletingPathExtension().lastPathComponent)-dng")
        }
    }

    /// A contact sheet of everything above, so the pass is one page.
    func testZZContactSheet() throws {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: Self.artifactDir.path),
              !names.filter({ $0.hasSuffix(".jpg") && !$0.hasSuffix("-before.jpg") }).isEmpty
        else {
            throw XCTSkip("no artifacts — the corpus tests did not run")
        }
        let converted = names.filter { $0.hasSuffix(".jpg") && !$0.hasSuffix("-before.jpg") }
            .sorted()
        var html = "<!doctype html><meta charset=\"utf-8\">"
            + "<title>2026-08-13 corpus — one-click Auto</title>"
            + "<style>body{background:#161616;color:#e2e8f0;"
            + "font:13px -apple-system,sans-serif;padding:24px}"
            + "td{padding:6px;vertical-align:top}img{width:420px}"
            + "h1{font-weight:600}.l{font:11px ui-monospace,monospace;"
            + "color:#94a3b8}</style>"
            + "<h1>2026-08-13 negatives — one-click Auto (detect, solve, crop)</h1>"
            + "<table>"
        for name in converted {
            let base = String(name.dropLast(4))
            html += "<tr><td class=l>" + base + "</td>"
                + "<td><div class=l>scan</div><img src=\"" + base + "-before.jpg\"></td>"
                + "<td><div class=l>Auto</div><img src=\"" + name + "\"></td></tr>"
        }
        html += "</table>"
        try html.write(to: Self.artifactDir.appendingPathComponent("contact-sheet.html"),
                       atomically: true, encoding: .utf8)
    }
}
