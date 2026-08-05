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

    /// A rough demonstration crop confining Auto's measurement to the medium
    /// format corpus's film interior, excluding the negative-holder mask that
    /// (per the Fix 2 finding) otherwise dominates the frame and sets Dmax.
    ///
    /// One shared unit rect (Core Image's bottom-left origin — see
    /// `CanvasArea.swift`'s `CropOverlay` doc comment) applied across all 5
    /// scans, not fitted per-frame. Verified empirically against the rendered
    /// (blind) artifacts for mf-IMG_4308/4310/4311/4312/4313: probing column
    /// and row brightness restricted to the opposite axis's interior found
    /// the holder/white-margin boundary consistently around x ∈ [0.25, 0.80]
    /// and, top-down, y ∈ [0.13, 0.92] across all five — this rect sits
    /// safely inside that on every edge (x: 0.30–0.72; top-down y: 0.15–0.90,
    /// i.e. bottom-left-origin y: 0.10–0.85). Re-cropping the rendered
    /// artifacts to this exact rect (see the fix report) shows clean frame
    /// interior with no holder or white margin on either sample checked.
    private static let mediumFormatDemoCropRect = CGRect(x: 0.30, y: 0.10, width: 0.42, height: 0.75)

    private let context = CIContext()
    private let renderer = EditRenderer()

    /// Solves, renders, and writes one frame's JPEG for the human acceptance
    /// pass. Asserts only sanity — solve succeeds, the histogram isn't empty,
    /// and the median display luma sits in a wide plausible-positive band.
    /// Every measured number is printed so a test-log read gives the numbers
    /// the acceptance pass needs without re-running anything.
    ///
    /// - Parameter cropRect: when non-nil, set on the stack's geometry before
    ///   Auto runs — mirrors `EditorModel.autoConvertNegative`'s crop-aware
    ///   measurement (Fix 2): the solve sees only the geometry-cropped scan,
    ///   and because `EditRenderer` applies the same crop after film
    ///   conversion (see `DevelopedSourceCache`), the written artifact is
    ///   cropped too — an honest end-to-end demonstration, not just a solve
    ///   that quietly measures differently while the JPEG stays uncropped.
    private func convert(url: URL, label: String, cropRect: CGRect? = nil) throws {
        guard let scan = ImageDecoder.loadPreviewImage(from: url, maxDimension: 1600,
                                                       processVersion: 2) else {
            XCTFail("could not decode \(url.lastPathComponent)"); return
        }
        var stack = EditStack()
        if let cropRect {
            stack.geometry.cropRect = cropRect
        }
        let measured = GeometryTransform.apply(scan, geometry: stack.geometry)
        let solution = try XCTUnwrap(AutoInvert.solve(scan: measured, sampledBase: nil,
                                                      context: context),
                                     "\(label): solve returned nil")
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

    /// Renders each medium-format frame twice: blind (Auto measures the full
    /// frame, holder included — the corpus defect) and cropped (Auto measures
    /// only `mediumFormatDemoCropRect`'s film interior — Fix 2). Both land as
    /// artifacts so the acceptance pass can compare them directly; keeping
    /// the blind renders is deliberate before/after evidence, not an oversight.
    func testMediumFormatCR2Corpus() throws {
        let files = try Self.firstFilesOrSkip(dir: Self.mediumFormatDir, suffix: ".cr2")
        try files.forEach {
            let name = $0.deletingPathExtension().lastPathComponent
            try convert(url: $0, label: "mf-\(name)")
            try convert(url: $0, label: "mf-\(name)-cropped", cropRect: Self.mediumFormatDemoCropRect)
        }
    }

    func test35mmPhoneScanCorpus() throws {
        let files = try Self.firstFilesOrSkip(dir: Self.thirtyFiveDir, suffix: ".jpeg")
        try files.forEach { try convert(url: $0, label: "35-\($0.deletingPathExtension().lastPathComponent)") }
    }
}
