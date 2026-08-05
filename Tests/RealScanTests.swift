import CoreImage
import XCTest
@testable import PhotoEditor

/// Auto + the print engine against the user's actual negatives. Skips
/// cleanly on any machine without the corpus (same pattern as the gated
/// parity fixtures), so CI and other machines are unaffected.
///
/// These tests assert sanity, not beauty: solve succeeds, output is a
/// plausible positive, nothing NaNs. Beauty is judged by the user from the
/// artifacts this suite writes to `artifacts/print-engine/`.
final class RealScanTests: XCTestCase {
    private static let mediumFormatDir = NSString("~/Desktop/negatives").expandingTildeInPath
    private static let thirtyFiveDir =
        NSString("~/Desktop/all film/film aug 4th 2026").expandingTildeInPath
    // Anchored to this source file, not the process's working directory:
    // under `xcodebuild test` the test host's cwd is not the repo root (it
    // resolved to "/", which is read-only), so a bare relative path failed
    // every write. Same pattern as `ParitySupport.fixturesDir`.
    private static let artifactDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("artifacts/print-engine", isDirectory: true)

    private let context = CIContext()
    private let renderer = EditRenderer()

    /// Solves, renders, and writes one frame's JPEG for the human acceptance
    /// pass. Asserts only sanity — solve succeeds, the histogram isn't empty,
    /// and the median display luma sits in a wide plausible-positive band.
    /// Every measured number is printed so a test-log read gives the numbers
    /// the acceptance pass needs without re-running anything.
    private func convert(url: URL, label: String) throws {
        guard let scan = ImageDecoder.loadPreviewImage(from: url, maxDimension: 1600,
                                                       processVersion: 2) else {
            XCTFail("could not decode \(url.lastPathComponent)"); return
        }
        let solution = try XCTUnwrap(AutoInvert.solve(scan: scan, sampledBase: nil,
                                                      context: context),
                                     "\(label): solve returned nil")
        var stack = EditStack()
        stack.filmNegative.isEnabled = true
        stack.filmNegative.conversionModel = .density
        stack.filmNegative.baseColor = solution.baseColor
        stack.filmNegative.baseOrigin = solution.baseOrigin
        stack.filmNegative.print.dmax = solution.dmax
        stack.filmNegative.print.gamma = solution.gamma
        stack.filmNegative.print.exposure = solution.printExposure

        let out = renderer.render(source: scan, stack: stack)
        let histogram = renderer.histogram(of: out)
        XCTAssertFalse(histogram.red.isEmpty, "\(label): render produced nothing")

        // A converted negative should be a plausible positive: not still
        // inverted-orange, not black, not blown. Median display luma in a
        // wide sane band is the cheapest useful assertion.
        let pixels = try XCTUnwrap(AutoInvert.linearPixels(of: out, side: 64,
                                                           context: context))
        let lumas = pixels.map { 0.2126 * $0.0 + 0.7152 * $0.1 + 0.0722 * $0.2 }.sorted()
        let median = lumas[lumas.count / 2]

        // Printed unconditionally (pass or fail) — this is the data the
        // human acceptance pass reads off the test log: which Dmin source
        // Auto picked, which terms degraded, and where the frame landed.
        print("REALSCAN \(label): base=\(solution.baseOrigin) degraded=\(solution.degradedTerms) "
              + "dmax=\(solution.dmax) gamma=\(solution.gamma) EV=\(solution.printExposure) "
              + "medianLuma=\(median)")

        XCTAssertGreaterThan(median, 0.01,
                             "\(label): renders black (median luma \(median))")
        XCTAssertLessThan(median, 0.7,
                          "\(label): renders blown (median luma \(median))")

        // Artifact for the human acceptance pass.
        try FileManager.default.createDirectory(at: Self.artifactDir,
                                                withIntermediateDirectories: true)
        let dest = Self.artifactDir.appendingPathComponent("\(label).jpg")
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        try context.writeJPEGRepresentation(of: out, to: dest, colorSpace: srgb)
    }

    /// Returns the first `count` files (sorted, case-insensitive suffix
    /// match) in `dir` as full URLs, or skips the test cleanly when the
    /// corpus isn't present on this machine — the directory is missing, or
    /// present but empty of matching files.
    private static func firstFilesOrSkip(dir: String, suffix: String,
                                         count: Int = 5) throws -> [URL] {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: dir, isDirectory: &isDirectory)
        guard exists, isDirectory.boolValue,
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
            throw XCTSkip("corpus not present on this machine: \(dir)")
        }
        let matches = names.filter { $0.lowercased().hasSuffix(suffix) }.sorted()
        guard !matches.isEmpty else {
            throw XCTSkip("corpus not present on this machine: no \(suffix) files in \(dir)")
        }
        return matches.prefix(count).map { URL(fileURLWithPath: dir).appendingPathComponent($0) }
    }

    func testMediumFormatCR2Corpus() throws {
        let files = try Self.firstFilesOrSkip(dir: Self.mediumFormatDir, suffix: ".cr2")
        try files.forEach { try convert(url: $0, label: "mf-\($0.deletingPathExtension().lastPathComponent)") }
    }

    func test35mmPhoneScanCorpus() throws {
        let files = try Self.firstFilesOrSkip(dir: Self.thirtyFiveDir, suffix: ".jpeg")
        try files.forEach { try convert(url: $0, label: "35-\($0.deletingPathExtension().lastPathComponent)") }
    }
}
