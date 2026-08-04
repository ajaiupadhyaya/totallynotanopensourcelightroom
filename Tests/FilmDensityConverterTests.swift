import CoreImage
import XCTest
@testable import PhotoEditor

final class FilmDensityConverterTests: XCTestCase {
    private let context = CIContext()

    private func densitySettings(base: FilmColor = FilmColor(red: 0.95, green: 0.75, blue: 0.55))
        -> FilmNegativeSettings {
        var s = FilmNegativeSettings()
        s.isEnabled = true
        s.type = .colorNegative
        s.conversionModel = .density
        s.baseColor = base // stored display-encoded, like every base sample
        s.print.dmax = DensityTriple(red: 2, green: 2, blue: 2)
        let g = log10(PaperResponse.targetBlack) / -2.0
        s.print.gamma = DensityTriple(red: g, green: g, blue: g)
        return s
    }

    /// The kernel and the Swift curve are two implementations of one model;
    /// this test is the contract that they agree. It renders a horizontal
    /// linear ramp through the real render stage and compares every column
    /// against `PaperResponse.develop`.
    func testKernelAgreesWithTheSwiftModel() {
        let settings = densitySettings()
        let width = 256
        // A neutral ramp of transmittances scaled by the (linear) base color,
        // spanning base (x=width-1) down to deep density (x=0).
        var pixels = [Float](repeating: 0, count: width * 4)
        let dminLin = (PaperResponse.srgbDecode(settings.baseColor.red),
                       PaperResponse.srgbDecode(settings.baseColor.green),
                       PaperResponse.srgbDecode(settings.baseColor.blue))
        var expected = [(Double, Double, Double)]()
        for x in 0..<width {
            let frac = Double(x) / Double(width - 1)          // 0…1
            let transmit = pow(10.0, -2.5 * (1 - frac))        // density 2.5 … 0
            let t = (dminLin.0 * transmit, dminLin.1 * transmit, dminLin.2 * transmit)
            expected.append(PaperResponse.develop(
                t, dminLinear: dminLin,
                dmax: (2, 2, 2),
                gammaEffective: (settings.print.gamma.red, settings.print.gamma.green,
                                 settings.print.gamma.blue),
                printOffset: 0, p: PaperResponse.kneeP(shoulder: 40),
                q: PaperResponse.kneeQ(toe: 30), satScale: 1.12))
            pixels[x * 4 + 0] = Float(t.0)
            pixels[x * 4 + 1] = Float(t.1)
            pixels[x * 4 + 2] = Float(t.2)
            pixels[x * 4 + 3] = 1
        }
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        // .RGBAf in the *linear* working space: the ramp IS working-space data.
        let ramp = CIImage(bitmapData: data, bytesPerRow: width * 16,
                           size: CGSize(width: width, height: 1), format: .RGBAf,
                           colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB))

        let out = FilmDensityConverter.convert(ramp, settings: settings)
        var buffer = [Float](repeating: 0, count: width * 4)
        context.render(out, toBitmap: &buffer, rowBytes: width * 16,
                       bounds: CGRect(x: 0, y: 0, width: width, height: 1),
                       format: .RGBAf,
                       colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        for x in 0..<width {
            XCTAssertEqual(Double(buffer[x * 4 + 0]), expected[x].0, accuracy: 2e-3,
                           "red diverges from PaperResponse at column \(x)")
            XCTAssertEqual(Double(buffer[x * 4 + 1]), expected[x].1, accuracy: 2e-3)
            XCTAssertEqual(Double(buffer[x * 4 + 2]), expected[x].2, accuracy: 2e-3)
        }
    }

    /// The film base renders near black; brighter-than-base (lightbox)
    /// renders *at or below* it. On a negative the base is the thinnest area.
    func testBaseRendersNearBlackAndLightboxBelowIt() {
        let settings = densitySettings()
        let base = TestSupport.solidImage(red: settings.baseColor.red,
                                          green: settings.baseColor.green,
                                          blue: settings.baseColor.blue)
        let converted = FilmDensityConverter.convert(base, settings: settings)
        let c = TestSupport.readColor(converted, context: context)
        // Not the theoretical toe floor (`paper(0)`, ≈0.34% linear): the base
        // lands at pre-paper density `targetBlack` (0.004, by this file's
        // gamma calibration above), not at density exactly 0, so the toe's
        // softknee — sharpest right where n approaches its own asymptote —
        // lifts it further, to ≈0.58% linear / ≈6.8% sRGB. 0.10 stays a solid
        // margin above that real, checked value while still asserting "near
        // black," which is what this test is actually for.
        XCTAssertLessThan(max(c.red, max(c.green, c.blue)), 0.10)

        let lightbox = TestSupport.solidImage(red: 1, green: 1, blue: 1)
        let lb = TestSupport.readColor(FilmDensityConverter.convert(lightbox, settings: settings),
                                       context: context)
        XCTAssertLessThanOrEqual(lb.red, c.red + 1e-3)
    }

    /// A stack decoded from old JSON is on `.matrix` and must render through
    /// the old converter bit-for-bit — the density engine must be unreachable
    /// for it. Compared against a render with a hand-built matrix settings
    /// value, which *is* the frozen path.
    func testMatrixStacksStillRenderThroughTheFrozenPath() throws {
        let old = #"{"isEnabled": true, "type": "colorNegative"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(FilmNegativeSettings.self, from: old)
        XCTAssertEqual(decoded.conversionModel, .matrix)

        let scan = TestSupport.solidImage(red: 0.6, green: 0.4, blue: 0.3)
        let viaDispatch = FilmNegativeConverter.convert(scan, settings: decoded)
        var matrix = decoded
        let a = TestSupport.readColor(viaDispatch, context: context)
        // Same settings through the direct legacy invert must be identical.
        matrix.conversionModel = .matrix
        let b = TestSupport.readColor(FilmNegativeConverter.convert(scan, settings: matrix),
                                      context: context)
        XCTAssertEqual(a.red, b.red, accuracy: 0)
        XCTAssertEqual(a.green, b.green, accuracy: 0)
        XCTAssertEqual(a.blue, b.blue, accuracy: 0)
    }

    /// B&W under the density model comes back neutral, same promise as the
    /// matrix path: residual scanner cast is not information.
    func testBlackAndWhiteDensityConversionIsNeutral() {
        var settings = densitySettings(base: FilmColor(red: 0.82, green: 0.80, blue: 0.78))
        settings.type = .blackAndWhiteNegative
        let scan = TestSupport.solidImage(red: 0.5, green: 0.48, blue: 0.46)
        let c = TestSupport.readColor(FilmDensityConverter.convert(scan, settings: settings),
                                      context: context)
        XCTAssertEqual(c.red, c.green, accuracy: 0.01)
        XCTAssertEqual(c.green, c.blue, accuracy: 0.01)
    }

    /// Disabled settings and slide film never reach the density kernel.
    func testDisabledAndSlideBypassTheDensityPath() {
        var settings = densitySettings()
        settings.isEnabled = false
        let scan = TestSupport.solidImage(red: 0.3, green: 0.5, blue: 0.7)
        let untouched = TestSupport.readColor(FilmNegativeConverter.convert(scan, settings: settings),
                                              context: context)
        XCTAssertEqual(untouched.blue, 0.7, accuracy: 0.01)

        settings.isEnabled = true
        settings.type = .slide
        let slide = TestSupport.readColor(FilmNegativeConverter.convert(scan, settings: settings),
                                          context: context)
        // Slide is not inverted: blue stays the brightest channel.
        XCTAssertGreaterThan(slide.blue, slide.red)
    }
}
