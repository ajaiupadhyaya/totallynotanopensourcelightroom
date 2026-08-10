import CoreImage
import XCTest
@testable import PhotoEditor

/// Bit-stability contract for renderVersion 1 (the Phase 2 print engine).
/// Records the current outputs once (TEST_RUNNER_GOLDEN_RECORD=1), then
/// asserts every future build reproduces them. The lattice covers the pure
/// Swift model; the ramp covers the kernel + FilmDensityConverter marshaling.
final class PaperResponseGoldenTests: XCTestCase {
    private static let fixturesDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/Golden", isDirectory: true)
    private static var isRecording: Bool {
        ProcessInfo.processInfo.environment["GOLDEN_RECORD"] == "1"
    }

    private struct LatticeCase: Codable {
        var label: String
        var dmin: [Double]      // linear
        var dmax: [Double]
        var gamma: [Double]     // grade already folded
        var offset: [Double]
        var p: Double
        var q: Double
        var satScale: Double
    }

    /// Deterministic settings variants spanning the parameter space the
    /// solver and panel actually produce.
    private static func latticeCases() -> [LatticeCase] {
        let defaults = PrintSettings()
        let g = log10(PaperResponse.targetBlack) / -2.0
        func offsets(_ ev: Double, _ w: Double, _ t: Double) -> [Double] {
            let o = PaperResponse.printOffsets(exposureEV: ev, warmth: w, tint: t)
            return [o.0, o.1, o.2]
        }
        let dminC41 = [0.55, 0.30, 0.13].map(PaperResponse.srgbEncode)
            .map(PaperResponse.srgbDecode) // exercises the round trip literally
        return [
            LatticeCase(label: "defaults", dmin: dminC41, dmax: [2, 2, 2],
                        gamma: [g, g, g],
                        offset: offsets(0, defaults.warmth, defaults.tint),
                        p: PaperResponse.kneeP(shoulder: defaults.shoulder),
                        q: PaperResponse.kneeQ(toe: defaults.toe),
                        satScale: 1.0 + defaults.saturation / 100.0),
            LatticeCase(label: "graded-warm", dmin: dminC41, dmax: [2.4, 2.2, 1.9],
                        gamma: [g * PaperResponse.gradeScale(3) * 1.1,
                                g * PaperResponse.gradeScale(3),
                                g * PaperResponse.gradeScale(3) * 0.9],
                        offset: offsets(1, 100, -80),
                        p: PaperResponse.kneeP(shoulder: 0),
                        q: PaperResponse.kneeQ(toe: 100),
                        satScale: 0.6),
            LatticeCase(label: "flat-neutral", dmin: [0.8, 0.8, 0.8], dmax: [1.5, 1.5, 1.5],
                        gamma: [g, g, g], offset: offsets(-1, 0, 0),
                        p: PaperResponse.kneeP(shoulder: 100),
                        q: PaperResponse.kneeQ(toe: 0),
                        satScale: 1.4),
        ]
    }

    /// 61 transmittance steps per case per channel-shape: density 0…3 relative
    /// to base, plus a colour skew so the max-norm/ratio path is exercised.
    private static func latticeOutputs() -> [Double] {
        var out: [Double] = []
        for c in latticeCases() {
            for i in 0...60 {
                let d = Double(i) / 20.0 // density 0…3
                let t = (c.dmin[0] * pow(10, -d),
                         c.dmin[1] * pow(10, -d * 1.08),
                         c.dmin[2] * pow(10, -d * 0.92))
                let r = PaperResponse.develop(
                    t, dminLinear: (c.dmin[0], c.dmin[1], c.dmin[2]),
                    dmax: (c.dmax[0], c.dmax[1], c.dmax[2]),
                    gammaEffective: (c.gamma[0], c.gamma[1], c.gamma[2]),
                    printOffset: (c.offset[0], c.offset[1], c.offset[2]),
                    p: c.p, q: c.q, satScale: c.satScale)
                out.append(contentsOf: [r.0, r.1, r.2])
            }
        }
        return out
    }

    func testSwiftModelMatchesTheGoldenLattice() throws {
        let url = Self.fixturesDir.appendingPathComponent("paper-response-lattice.json")
        let current = Self.latticeOutputs()
        if Self.isRecording {
            try FileManager.default.createDirectory(at: Self.fixturesDir,
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(current).write(to: url)
            throw XCTSkip("recorded \(current.count) golden values — commit the fixture and re-run without GOLDEN_RECORD")
        }
        let recorded = try JSONDecoder().decode([Double].self,
                                                from: Data(contentsOf: url))
        XCTAssertEqual(recorded.count, current.count,
                       "the lattice shape changed — that is a golden-contract break, not a tolerance issue")
        for (i, (r, c)) in zip(recorded, current).enumerated() {
            XCTAssertEqual(c, r, accuracy: max(abs(r) * 1e-12, 1e-15),
                           "renderVersion 1 output changed at lattice index \(i)")
        }
    }

    /// End-to-end: a stack decoded from pre-Minilab JSON (renderVersion will
    /// decode 1) rendered through FilmDensityConverter on the deterministic
    /// ramp from FilmDensityConverterTests. GPU floats: 1e-4 band, which is
    /// still far below any visible change and far above driver noise.
    func testDensityRenderMatchesTheGoldenRamp() throws {
        let url = Self.fixturesDir.appendingPathComponent("density-render-ramp.json")
        let old = """
        {"isEnabled": true, "type": "colorNegative", "conversionModel": "density",
         "baseColor": {"red": 0.95, "green": 0.75, "blue": 0.55},
         "print": {"contrast": 3, "exposure": 0.5, "warmth": 24, "tint": -8,
                   "dmax": {"red": 2.1, "green": 2.0, "blue": 1.9},
                   "gamma": {"red": 1.15, "green": 1.2, "blue": 1.3}},
         "exposure": 0.25}
        """.data(using: .utf8)!
        let settings = try JSONDecoder().decode(FilmNegativeSettings.self, from: old)
        let width = 256
        let context = CIContext()
        var pixels = [Float](repeating: 0, count: width * 4)
        let dminLin = (PaperResponse.srgbDecode(settings.baseColor.red),
                       PaperResponse.srgbDecode(settings.baseColor.green),
                       PaperResponse.srgbDecode(settings.baseColor.blue))
        for x in 0..<width {
            let frac = Double(x) / Double(width - 1)
            let transmit = pow(10.0, -2.5 * (1 - frac))
            pixels[x * 4 + 0] = Float(dminLin.0 * transmit)
            pixels[x * 4 + 1] = Float(dminLin.1 * transmit)
            pixels[x * 4 + 2] = Float(dminLin.2 * transmit)
            pixels[x * 4 + 3] = 1
        }
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        let ramp = CIImage(bitmapData: data, bytesPerRow: width * 16,
                           size: CGSize(width: width, height: 1), format: .RGBAf,
                           colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        let out = FilmDensityConverter.convert(ramp, settings: settings)
        var buffer = [Float](repeating: 0, count: width * 4)
        context.render(out, toBitmap: &buffer, rowBytes: width * 16,
                       bounds: CGRect(x: 0, y: 0, width: width, height: 1),
                       format: .RGBAf,
                       colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        let current = buffer.map(Double.init)
        if Self.isRecording {
            try FileManager.default.createDirectory(at: Self.fixturesDir,
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(current).write(to: url)
            throw XCTSkip("recorded render golden — commit the fixture and re-run without GOLDEN_RECORD")
        }
        let recorded = try JSONDecoder().decode([Double].self, from: Data(contentsOf: url))
        XCTAssertEqual(recorded.count, current.count)
        for (i, (r, c)) in zip(recorded, current).enumerated() where i % 4 != 3 {
            XCTAssertEqual(c, r, accuracy: 1e-4,
                           "legacy-decoded density render changed at ramp column \(i / 4)")
        }
    }
}
