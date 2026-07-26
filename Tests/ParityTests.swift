import CoreImage
import Foundation
import XCTest
@testable import PhotoEditor

/// Measured comparison against Adobe Lightroom CC renders. Gated: without
/// the exported fixtures (see docs/PARITY.md) every test skips. The
/// comparison feeds LIGHTROOM'S OWN neutral export through our PV2 stack, so
/// Adobe's camera profile sits on both sides and cancels — what's measured
/// is purely the slider math. Exact equality is not the claim; bounded
/// behavioral equivalence is, with tolerances ratcheted down over time.
final class ParityTests: XCTestCase {
    private func loadFixture(_ name: String) -> CIImage? {
        let url = ParitySupport.fixturesDir.appendingPathComponent(name)
        return CIImage(contentsOf: url)
    }

    /// Validates the ΔE2000 transcription against the published Sharma, Wu &
    /// Dalal (2005) test-data pairs before trusting it for anything else.
    /// These are independent of this codebase — if the transcription is
    /// wrong, fix the transcription, never these reference values.
    func testCIEDE2000AgainstReferencePairs() {
        let cases: [((Double, Double, Double), (Double, Double, Double), Double)] = [
            ((50, 2.6772, -79.7751), (50, 0, -82.7485), 2.0425),
            ((50, 3.1571, -77.2803), (50, 0, -82.7485), 2.8615),
            ((50, 2.5, 0), (73, 25, -18), 27.1492),
        ]
        for (lab1, lab2, expected) in cases {
            let got = DeltaE.ciede2000(lab1, lab2)
            XCTAssertEqual(got, expected, accuracy: 0.01,
                           "ΔE2000(\(lab1), \(lab2)) = \(got), expected \(expected)")
        }
    }

    /// The manifest the generator emits must decode with `ParityCase` and
    /// contain all 17 presets — checked independently of the gated fixture
    /// test so this is verifiable without any exported TIFFs present.
    func testManifestDecodes() throws {
        let manifestURL = ParitySupport.fixturesDir.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: manifestURL)
        let cases = try JSONDecoder().decode([ParityCase].self, from: data)
        XCTAssertEqual(cases.count, 17)
    }

    func testParityAgainstLightroom() throws {
        guard let neutral = loadFixture("neutral.tif") else {
            throw XCTSkip("no parity fixtures — run scripts/make-parity-presets.swift and follow docs/PARITY.md")
        }
        let manifestURL = ParitySupport.fixturesDir.appendingPathComponent("manifest.json")
        let cases = try JSONDecoder().decode([ParityCase].self, from: Data(contentsOf: manifestURL))
        let renderer = EditRenderer()
        var failures: [String] = []

        for c in cases {
            guard let reference = loadFixture(c.fixture) else { continue }
            var stack = EditStack()
            c.apply(to: &stack)
            let ours = renderer.render(source: neutral, stack: stack)

            let ourLab = ParitySupport.labPixels(of: ours)
            let refLab = ParitySupport.labPixels(of: reference)
            guard ourLab.count == refLab.count else {
                failures.append("\(c.fixture): pixel count mismatch"); continue
            }
            var deltas: [Double] = []
            var bands: [Int: [Double]] = [0: [], 1: [], 2: []]   // shadows/mids/highlights by ref L
            for (o, r) in zip(ourLab, refLab) {
                let d = DeltaE.ciede2000(o, r)
                deltas.append(d)
                bands[min(2, Int(r.0 / 34))]?.append(d)
            }
            let mean = deltas.reduce(0, +) / Double(deltas.count)
            let maxD = deltas.max() ?? 0
            func bandMean(_ i: Int) -> Double {
                let b = bands[i] ?? []; return b.isEmpty ? 0 : b.reduce(0, +) / Double(b.count)
            }
            let report = String(format: "%@  ΔE mean %.2f max %.2f  [sh %.2f  mid %.2f  hi %.2f]",
                                c.fixture, mean, maxD, bandMean(0), bandMean(1), bandMean(2))
            print("PARITY: \(report)")
            if let mt = c.meanTolerance, mean > mt { failures.append(report + "  mean > \(mt)") }
            if let xt = c.maxTolerance, maxD > xt { failures.append(report + "  max > \(xt)") }
        }
        XCTAssertTrue(failures.isEmpty, "parity failures:\n" + failures.joined(separator: "\n"))
    }
}
