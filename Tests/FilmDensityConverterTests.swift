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
    ///
    /// Run twice: once at the identity fold (contrast 2 → gradeScale 1.0,
    /// exposure 0, warmth/tint 0 → printOffset (0,0,0) on every channel) and
    /// once away from it (contrast 3, exposure 1, warmth 24, tint −8). The
    /// CPU-side foldings in `FilmDensityConverter` (`gamma × gradeScale`,
    /// `printOffset = printOffsets(exposureEV:warmth:tint:)`) are otherwise
    /// untested by this file — every other settings object here leaves them
    /// all at their identity value, so a wrong fold (grade applied to `dmax`
    /// instead of `gamma`, `pow(2, ·)` instead of `log10(2)`, a sign flip, or
    /// the float3 printOffset collapsing back to one scalar) would leave the
    /// whole suite green. Nonzero warmth/tint here is what actually exercises
    /// the per-channel float3 fold at non-identity values — a run with both
    /// still at 0 would pass even if the kernel silently ignored them.
    func testKernelAgreesWithTheSwiftModel() {
        assertKernelAgreesWithSwiftModel(densitySettings())

        var graded = densitySettings()
        graded.print.contrast = 3
        graded.print.exposure = 1
        graded.print.warmth = 24
        graded.print.tint = -8
        assertKernelAgreesWithSwiftModel(graded)

        // Third leg: non-neutral toning (Task 3). Every slider the profile
        // writes is nonzero, so a kernel that silently ignored the new
        // punch/fade/glow/toeChroma arguments — or marshaled them in the
        // wrong order — diverges from the Swift model here.
        var lab = densitySettings()
        lab.print.applyToneProfile(.labStandard)
        assertKernelAgreesWithSwiftModel(lab)

        // Fourth leg: cast + zone trims at a non-unit grade + a stale legacy
        // EV (Tasks 4/5). Proves the CPU folds (cast through the effective
        // gamma, trims folded per channel into the kernel's zone math, legacy
        // EV folded pre-curve on renderVersion 2) and the kernel describe one
        // model. ALL THREE zones carry a nonzero trim on DISTINCT channels
        // with distinct signs — the group review proved the original
        // shadow-only leg left trimM/trimH (and zoneHighStart/zoneHighFull)
        // output-inert, so a converter that transposed the mid/high trim
        // vectors, or a kernel that swapped the wM/wH weights, passed the
        // whole suite. With distinct channels per zone, any zone swap,
        // channel swap, or marshal transposition diverges here. The nonzero
        // stack-level `exposure` pins the v2 fold's magnitude, which the
        // never-clips test deliberately does not.
        var cast = densitySettings()
        cast.print.contrast = 3
        cast.print.castRed = 40
        cast.print.shadowTrim.red = 60
        cast.print.midTrim.green = -50
        cast.print.highTrim.blue = 40
        cast.exposure = 0.5
        assertKernelAgreesWithSwiftModel(cast)
    }

    private func assertKernelAgreesWithSwiftModel(
        _ settings: FilmNegativeSettings, file: StaticString = #filePath, line: UInt = #line
    ) {
        let width = 256
        // A neutral ramp of transmittances scaled by the (linear) base color,
        // spanning base (x=width-1) down to deep density (x=0).
        var pixels = [Float](repeating: 0, count: width * 4)
        let dminLin = (PaperResponse.srgbDecode(settings.baseColor.red),
                       PaperResponse.srgbDecode(settings.baseColor.green),
                       PaperResponse.srgbDecode(settings.baseColor.blue))
        // Mirrors FilmDensityConverter's own CPU-side folding exactly, so this
        // helper exercises whatever `settings.print` carries, not just the
        // identity case.
        let grade = PaperResponse.gradeScale(settings.print.contrast)
        let gammaEffective = (settings.print.gamma.red * grade,
                              settings.print.gamma.green * grade,
                              settings.print.gamma.blue * grade)
        let v2 = settings.print.renderVersion >= 2
        var printOffset = PaperResponse.printOffsets(
            exposureEV: settings.print.exposure + (v2 ? settings.exposure : 0),
            warmth: settings.print.warmth,
            tint: settings.print.tint, balancedTint: v2)
        // Cast folds through the EFFECTIVE gamma; the grade pivot through the
        // UN-graded gamma — both exactly as FilmDensityConverter folds them.
        printOffset.0 += gammaEffective.0 * PaperResponse.castDensity(settings.print.castRed)
        printOffset.1 += gammaEffective.1 * PaperResponse.castDensity(settings.print.castGreen)
        printOffset.2 += gammaEffective.2 * PaperResponse.castDensity(settings.print.castBlue)
        if v2, let pivot = settings.print.gradePivot {
            printOffset.0 += settings.print.gamma.red * (1 - grade)
                * (pivot.red - settings.print.dmax.red)
            printOffset.1 += settings.print.gamma.green * (1 - grade)
                * (pivot.green - settings.print.dmax.green)
            printOffset.2 += settings.print.gamma.blue * (1 - grade)
                * (pivot.blue - settings.print.dmax.blue)
        }
        // Zone trims arrive at develop() already folded through the effective
        // gamma, mirroring the converter's kernel marshaling.
        let shadowTrim = (gammaEffective.0 * PaperResponse.zoneTrimDensity(settings.print.shadowTrim.red),
                          gammaEffective.1 * PaperResponse.zoneTrimDensity(settings.print.shadowTrim.green),
                          gammaEffective.2 * PaperResponse.zoneTrimDensity(settings.print.shadowTrim.blue))
        let midTrim = (gammaEffective.0 * PaperResponse.zoneTrimDensity(settings.print.midTrim.red),
                       gammaEffective.1 * PaperResponse.zoneTrimDensity(settings.print.midTrim.green),
                       gammaEffective.2 * PaperResponse.zoneTrimDensity(settings.print.midTrim.blue))
        let highTrim = (gammaEffective.0 * PaperResponse.zoneTrimDensity(settings.print.highTrim.red),
                        gammaEffective.1 * PaperResponse.zoneTrimDensity(settings.print.highTrim.green),
                        gammaEffective.2 * PaperResponse.zoneTrimDensity(settings.print.highTrim.blue))
        let dmax = (settings.print.dmax.red, settings.print.dmax.green, settings.print.dmax.blue)
        let p = PaperResponse.kneeP(shoulder: settings.print.shoulder)
        let q = PaperResponse.kneeQ(toe: settings.print.toe)
        let satScale = 1.0 + settings.print.saturation / 100.0
        var expected = [(Double, Double, Double)]()
        for x in 0..<width {
            let frac = Double(x) / Double(width - 1)          // 0…1
            let transmit = pow(10.0, -2.5 * (1 - frac))        // density 2.5 … 0
            let t = (dminLin.0 * transmit, dminLin.1 * transmit, dminLin.2 * transmit)
            expected.append(PaperResponse.develop(
                t, dminLinear: dminLin, dmax: dmax, gammaEffective: gammaEffective,
                printOffset: printOffset, p: p, q: q, satScale: satScale,
                shadowTrim: shadowTrim, midTrim: midTrim, highTrim: highTrim,
                punch: PaperResponse.punchAmount(settings.print.punch),
                fade: PaperResponse.fadeLift(settings.print.fade),
                glow: PaperResponse.glowDrop(settings.print.glow),
                toeChroma: PaperResponse.toeChromaWeight(settings.print.toeChroma)))
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
                           "red diverges from PaperResponse at column \(x)", file: file, line: line)
            XCTAssertEqual(Double(buffer[x * 4 + 1]), expected[x].1, accuracy: 2e-3,
                           file: file, line: line)
            XCTAssertEqual(Double(buffer[x * 4 + 2]), expected[x].2, accuracy: 2e-3,
                           file: file, line: line)
        }
    }

    /// Cast folds through the EFFECTIVE gamma (grade included): a +cast on red
    /// is exactly a density offset, so the render must equal the pure model
    /// developed with printOffset.red += gammaEffective.red · castDensity.
    func testCastFoldMatchesTheDensityOffsetSemantics() {
        var settings = densitySettings()
        settings.print.contrast = 3            // non-unit grade — the fold's hard case
        settings.print.castRed = 60
        let grade = PaperResponse.gradeScale(settings.print.contrast)
        let dminLin = (PaperResponse.srgbDecode(settings.baseColor.red),
                       PaperResponse.srgbDecode(settings.baseColor.green),
                       PaperResponse.srgbDecode(settings.baseColor.blue))
        let t = (dminLin.0 * 0.1, dminLin.1 * 0.1, dminLin.2 * 0.1)
        let scan = TestSupport.solidImage(redLinear: t.0, greenLinear: t.1, blueLinear: t.2)
        let rendered = TestSupport.readLinearColor(
            FilmDensityConverter.convert(scan, settings: settings), context: context)
        var offset = PaperResponse.printOffsets(exposureEV: settings.print.exposure,
                                                warmth: settings.print.warmth,
                                                tint: settings.print.tint,
                                                balancedTint: true)
        offset.0 += settings.print.gamma.red * grade * PaperResponse.castDensity(60)
        let expected = PaperResponse.develop(
            t, dminLinear: dminLin,
            dmax: (settings.print.dmax.red, settings.print.dmax.green, settings.print.dmax.blue),
            gammaEffective: (settings.print.gamma.red * grade,
                             settings.print.gamma.green * grade,
                             settings.print.gamma.blue * grade),
            printOffset: offset,
            p: PaperResponse.kneeP(shoulder: settings.print.shoulder),
            q: PaperResponse.kneeQ(toe: settings.print.toe),
            satScale: 1.0 + settings.print.saturation / 100.0)
        XCTAssertEqual(rendered.red, expected.0, accuracy: 2e-3)
        XCTAssertEqual(rendered.green, expected.1, accuracy: 2e-3)
        XCTAssertEqual(rendered.blue, expected.2, accuracy: 2e-3)
    }

    /// renderVersion 2 restores the never-clips contract with a nonzero legacy
    /// EV: the same +2 EV that pushes a v1 render past 1.0 stays under 1.0 on
    /// v2, because it now runs through the paper curve.
    ///
    /// The probe is a DENSE patch (density 1.7, near Dmax), built in linear
    /// space: on a negative the dense areas are the print's near-whites, which
    /// is the only place a post-curve multiply has anything to push past 1.0
    /// (the base renders near BLACK — see
    /// ``testBaseRendersNearBlackAndLightboxBelowIt`` — where ×2EV clips
    /// nothing). On v2 the folded EV lands this patch at ≈0.9999 — under the
    /// shoulder's strict ceiling; on v1 the same patch renders mid-grey
    /// (≈0.46) and the frozen post-curve ×4 pushes it to ≈1.8.
    func testV2FoldsLegacyExposureBeforeThePaperCurve() throws {
        var v2 = densitySettings()
        v2.exposure = 2
        let dminLin = (PaperResponse.srgbDecode(v2.baseColor.red),
                       PaperResponse.srgbDecode(v2.baseColor.green),
                       PaperResponse.srgbDecode(v2.baseColor.blue))
        let transmit = pow(10.0, -1.7)
        let scan = TestSupport.solidImage(redLinear: dminLin.0 * transmit,
                                          greenLinear: dminLin.1 * transmit,
                                          blueLinear: dminLin.2 * transmit)
        let v2Out = TestSupport.readLinearColor(
            FilmDensityConverter.convert(scan, settings: v2), context: context)
        XCTAssertLessThan(max(v2Out.red, max(v2Out.green, v2Out.blue)), 1.0,
                          "v2 must never clip, even with a stale legacy EV")

        var v1JSON = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(v2)) as! [String: Any]
        var printDict = v1JSON["print"] as! [String: Any]
        printDict.removeValue(forKey: "renderVersion") // decode → 1
        v1JSON["print"] = printDict
        let v1 = try JSONDecoder().decode(
            FilmNegativeSettings.self,
            from: JSONSerialization.data(withJSONObject: v1JSON))
        XCTAssertEqual(v1.print.renderVersion, 1)
        let v1Out = TestSupport.readLinearColor(
            FilmNegativeConverter.convert(scan, settings: v1), context: context)
        XCTAssertGreaterThan(max(v1Out.red, max(v1Out.green, v1Out.blue)), 1.0,
                             "the frozen v1 misfeature must stay frozen — the "
                             + "post-curve ×2EV multiply clips a dense patch past 1.0")
    }

    /// Grade pivot: with the pivot set to the (synthetic) median density,
    /// raising Contrast leaves that density's render invariant while still
    /// steepening the curve around it.
    func testGradePivotHoldsTheMidUnderContrast() {
        var settings = densitySettings()
        let pivotD = 1.1
        settings.print.gradePivot = DensityTriple(red: pivotD, green: pivotD, blue: pivotD)
        let dminLin = PaperResponse.srgbDecode(settings.baseColor.red)
        func render(_ density: Double, contrast: Double) -> Double {
            var s = settings
            s.print.contrast = contrast
            let t = dminLin * pow(10, -density)
            let g = PaperResponse.srgbDecode(s.baseColor.green) * pow(10, -density)
            let b = PaperResponse.srgbDecode(s.baseColor.blue) * pow(10, -density)
            let scan = TestSupport.solidImage(redLinear: t, greenLinear: g, blueLinear: b)
            return TestSupport.readLinearColor(
                FilmDensityConverter.convert(scan, settings: s), context: context).red
        }
        XCTAssertEqual(render(pivotD, contrast: 4), render(pivotD, contrast: 2),
                       accuracy: 2e-3, "the pivot density must not move with grade")
        let below2 = render(0.6, contrast: 2), below4 = render(0.6, contrast: 4)
        XCTAssertLessThan(below4, below2 - 1e-3,
                          "grade 4 must darken below the pivot (steeper curve)")
        let above2 = render(1.6, contrast: 2), above4 = render(1.6, contrast: 4)
        XCTAssertGreaterThan(above4, above2 + 1e-3,
                             "grade 4 must brighten above the pivot")
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
    /// the old converter, not the density engine. Proven two ways: (1) the
    /// dispatch actually branches on `conversionModel` — flipping it to
    /// `.density` on the *same* settings must change the render, or this
    /// whole test would pass even if the dispatch ignored the field; (2) the
    /// matrix render matches the closed form `FilmNegativeConverter`'s own
    /// doc comment gives for unit-gain inversion.
    func testMatrixStacksStillRenderThroughTheFrozenPath() throws {
        let old = #"{"isEnabled": true, "type": "colorNegative"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(FilmNegativeSettings.self, from: old)
        XCTAssertEqual(decoded.conversionModel, .matrix)

        let scan = TestSupport.solidImage(red: 0.6, green: 0.4, blue: 0.3)
        let matrixResult = TestSupport.readColor(
            FilmNegativeConverter.convert(scan, settings: decoded), context: context)

        // (1) The branch is load-bearing: same settings, only the model
        // flipped, must render differently — otherwise this test would pass
        // even with `if settings.conversionModel == .density && ...` deleted.
        var density = decoded
        density.conversionModel = .density
        let densityResult = TestSupport.readColor(
            FilmNegativeConverter.convert(scan, settings: density), context: context)
        let totalDivergence = abs(matrixResult.red - densityResult.red)
            + abs(matrixResult.green - densityResult.green)
            + abs(matrixResult.blue - densityResult.blue)
        XCTAssertGreaterThan(totalDivergence, 0.05,
                             "the matrix and density renders must differ, or the dispatch isn't " +
                             "actually branching on conversionModel")

        // (2) Pin the matrix render against the closed form: unit gain
        // collapses `balanced = -(g/b)·x + g` to `1 − x/b`, evaluated in the
        // gamma-encoded domain the legacy converter brackets its math in
        // (`enc` mirrors the CILinearToSRGBToneCurve round trip the pipeline
        // itself does, rather than assuming the raw literal is already its
        // own encoding).
        let base = decoded.baseColor
        func enc(_ x: Double) -> Double { PaperResponse.srgbEncode(PaperResponse.srgbDecode(x)) }
        let expected = (red: 1 - enc(0.6) / base.red,
                        green: 1 - enc(0.4) / base.green,
                        blue: 1 - enc(0.3) / base.blue)
        // 0.01: the legacy path's exact CIColorMatrix + tone-curve filter
        // chain need not be bit-identical to this pure-math closed form.
        XCTAssertEqual(matrixResult.red, expected.red, accuracy: 0.01)
        XCTAssertEqual(matrixResult.green, expected.green, accuracy: 0.01)
        XCTAssertEqual(matrixResult.blue, expected.blue, accuracy: 0.01)
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
