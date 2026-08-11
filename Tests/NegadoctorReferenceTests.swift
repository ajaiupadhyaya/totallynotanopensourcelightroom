import Foundation
import XCTest
@testable import PhotoEditor

/// Reference renders through the user's own darktable negadoctor sidecars —
/// the independent ground truth the Minilab spec's validation section calls
/// for. Gated three ways: darktable-cli present, corpus present, sidecars
/// present. Asserts only that the render ran and produced pixels; the
/// comparison is the acceptance sheet's job, judged by a human.
final class NegadoctorReferenceTests: XCTestCase {
    private static let corpusDir = NSString("~/Desktop/negatives").expandingTildeInPath

    private static let cliCandidates = [
        "/opt/homebrew/bin/darktable-cli",
        "/usr/local/bin/darktable-cli",
        "/Applications/darktable.app/Contents/MacOS/darktable-cli",
    ]

    func testRenderNegadoctorReferences() throws {
        guard let cli = Self.cliCandidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else {
            throw XCTSkip("darktable-cli not installed — brew install --cask darktable")
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: Self.corpusDir, isDirectory: &isDir),
              isDir.boolValue else {
            throw XCTSkip("corpus not present on this machine: \(Self.corpusDir)")
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: Self.corpusDir)) ?? []
        // First 5 CR2s that carry an XMP sidecar (<name>.cr2.xmp preferred,
        // <name>.xmp accepted). ~10–30 s per frame — the count stays small.
        let pairs: [(cr2: URL, xmp: URL)] = names
            .filter { $0.lowercased().hasSuffix(".cr2") }.sorted()
            .compactMap { name in
                let cr2 = URL(fileURLWithPath: Self.corpusDir).appendingPathComponent(name)
                let sidecars = [cr2.path + ".xmp",
                                cr2.deletingPathExtension().path + ".xmp"]
                guard let xmp = sidecars.first(where: {
                    FileManager.default.fileExists(atPath: $0)
                }) else { return nil }
                return (cr2, URL(fileURLWithPath: xmp))
            }
            .prefix(5).map { $0 }
        guard !pairs.isEmpty else {
            throw XCTSkip("no CR2s with XMP sidecars in \(Self.corpusDir)")
        }

        try FileManager.default.createDirectory(at: RealScanTests.artifactDir,
                                                withIntermediateDirectories: true)
        let configDir = NSTemporaryDirectory() + "dt-config"
        for (cr2, xmp) in pairs {
            let name = cr2.deletingPathExtension().lastPathComponent
            let out = RealScanTests.artifactDir.appendingPathComponent("ref-\(name).jpg")
            try? FileManager.default.removeItem(at: out) // darktable refuses to overwrite
            let p = Process()
            p.executableURL = URL(fileURLWithPath: cli)
            p.arguments = [cr2.path, xmp.path, out.path, "--width", "1600",
                           "--core", "--library", ":memory:", "--configdir", configDir]
            let quiet = Pipe()
            p.standardOutput = quiet
            p.standardError = quiet
            try p.run()
            p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0, "darktable-cli failed on \(name)")
            let size = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size]
                        as? Int) ?? 0
            XCTAssertGreaterThan(size ?? 0, 0, "ref-\(name).jpg is empty")
        }
    }
}
