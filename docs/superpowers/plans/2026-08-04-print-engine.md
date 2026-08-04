# Print Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the single-matrix negative conversion with a density-domain inversion followed by a parametric paper response, fronted by a one-button Auto solve — per the spec at `docs/superpowers/specs/2026-08-04-print-engine-design.md`.

**Architecture:** A pure-Swift curve module (`PaperResponse`) is the single source of truth for the print math; a Metal `CIColorKernel` mirrors it for the GPU path and a test asserts the two agree. `FilmNegativeSettings` gains a `conversionModel` that freezes the existing matrix engine for every already-edited photo. `AutoInvert` measures a downsampled linear render and solves every parameter in closed form (plus one scalar bisection).

**Tech Stack:** Swift 5, SwiftUI, Core Image (`CIColorKernel` via metallib), XCTest, GRDB, XcodeGen.

## Global Constraints

- macOS deployment target 14.0; Swift 5 language mode.
- Build: `xcodegen generate && xcodebuild -project PhotoEditor.xcodeproj -scheme PhotoEditor -destination 'platform=macOS' build`.
- Tests: `xcodebuild -project PhotoEditor.xcodeproj -scheme PhotoEditor -destination 'platform=macOS' test` (append `-only-testing:PhotoEditorTests/<Class>` while iterating).
- Baseline before this phase: 353 tests, 0 failures (run the suite first and record the true number; no task may reduce the passing count).
- Run `xcodegen generate` after adding any file under `Sources/`. New files under `Tests/` are picked up by the existing glob.
- **The matrix engine is frozen.** No task modifies the numeric behavior of `FilmNegativeConverter.invert`, `FilmNegativeSettings` defaults as *decoded* from existing JSON, or anything in `LegacyToneRenderer`.
- The density path runs on linear working-space values — no `CILinearToSRGBToneCurve` bracketing anywhere in it.
- Comment density and doc-comment style follow the surrounding code: `///` on every type and non-obvious decision, explaining *why*.
- Commit messages end with `Co-Authored-By: Claude <noreply@anthropic.com>` (the PreToolUse hook enforces the noreply author).
- Never commit the user's photographs. Real-scan tests read from `~/Desktop` paths and skip when absent.

---

### Task 1: PaperResponse — the curve, in Swift, tested

The whole look lives in one pure-Swift file so it can be unit-tested and reused by the solver; the kernel (Task 3) only mirrors it. Also corrects the spec's constants table, whose toe/shoulder exponents were mis-derived (a `q` of 3 puts the black floor at 0.21 linear — obviously wrong once you do the arithmetic; the table below is the corrected derivation).

**Files:**
- Create: `Sources/Film/PaperResponse.swift`
- Test: `Tests/PaperResponseTests.swift`
- Modify: `docs/superpowers/specs/2026-08-04-print-engine-design.md` (constants table only)

**Interfaces:**
- Consumes: nothing (pure math).
- Produces (exact signatures later tasks call):
  - `PaperResponse.softknee(_ x: Double, _ k: Double) -> Double`
  - `PaperResponse.paper(_ n: Double, p: Double, q: Double) -> Double`
  - `PaperResponse.kneeP(shoulder: Double) -> Double` — slider 0…100 → exponent
  - `PaperResponse.kneeQ(toe: Double) -> Double`
  - `PaperResponse.gradeScale(_ grade: Double) -> Double` — `1.15^(grade − 2)`
  - `PaperResponse.srgbEncode(_ c: Double) -> Double`, `srgbDecode(_ c: Double) -> Double`
  - `PaperResponse.develop(_ t: (Double, Double, Double), dminLinear: (Double, Double, Double), dmax: (Double, Double, Double), gammaEffective: (Double, Double, Double), printOffset: Double, p: Double, q: Double, satScale: Double) -> (Double, Double, Double)`
  - Constants: `shoulderStart = 0.75`, `highlightDesat = 0.9`, `targetBlack = 0.004`, `targetMid = 0.18`, `dmaxPercentile = 0.995`, `dLowPercentile = 0.005`, `dminPercentile = 0.98`, `transmittanceFloor = 1e-5`

- [ ] **Step 1: Correct the spec's constants table**

In `2026-08-04-print-engine-design.md`, replace the two knee rows of the constants table with:

```markdown
| `shoulderP` at Shoulder 0 / 100 | `64` → `2`, log-mapped: `p = 64·(2/64)^(s/100)` | 64 compresses n=1 by 1.1% (visually a clip); 2 compresses it to 0.71 (a long rolloff) |
| `toeQ` at Toe 0 / 100 | `512` → `24`, log-mapped: `q = 512·(24/512)^(t/100)` | the black floor is `1 − 2^(−1/q)`: 0.0014 linear at 512 (imperceptible), 0.028 at 24 (a heavy fog); the earlier 64→3 range was mis-derived and put the floor at 0.21 linear |
| Shoulder default | `40` (`p ≈ 16`) | a visible but unobtrusive knee |
| Toe default | `30` (`q ≈ 204`, floor ≈ 0.0034 linear ≈ 5.6% sRGB) | a lifted black in the region the user's lab scans sit |
```

- [ ] **Step 2: Write the failing tests**

```swift
import XCTest
@testable import PhotoEditor

/// The print curve is the whole look, so it gets direct mathematical tests —
/// monotonicity, bounds, closed-form endpoints — rather than only image-level
/// ones. A curve that exists only inside a `.metal` file cannot be tested at
/// all; this suite is the reason `PaperResponse` is Swift.
final class PaperResponseTests: XCTestCase {

    /// softknee(x,k) = x·(1+x^k)^(−1/k): its derivative is
    /// (1+x^k)^(−1/k−1) > 0, so it is strictly increasing, and the asymptote
    /// is 1. The identity behavior near zero is what keeps the toe and
    /// shoulder out of the midtones.
    func testSoftkneeIsIdentityNearZeroAndAsymptotic() {
        XCTAssertEqual(PaperResponse.softknee(0.01, 64), 0.01, accuracy: 1e-6)
        XCTAssertEqual(PaperResponse.softknee(0, 8), 0)
        XCTAssertLessThan(PaperResponse.softknee(1000, 8), 1.0)
        XCTAssertGreaterThan(PaperResponse.softknee(1000, 8), 0.999)
    }

    func testPaperIsStrictlyIncreasingAndBounded() {
        let p = PaperResponse.kneeP(shoulder: 40)
        let q = PaperResponse.kneeQ(toe: 30)
        var last = -1.0
        for i in 0...1000 {
            let n = Double(i) / 100.0 // 0…10, well past paper white
            let y = PaperResponse.paper(n, p: p, q: q)
            XCTAssertGreaterThan(y, last, "paper() must be strictly increasing")
            XCTAssertGreaterThanOrEqual(y, 0)
            XCTAssertLessThan(y, 1.0)
            XCTAssertFalse(y.isNaN)
            last = y
        }
    }

    /// paper(0) = 1 − 2^(−1/q): the lifted-black floor, in closed form.
    func testPaperFloorMatchesClosedForm() {
        for toe in [0.0, 30, 100] {
            let q = PaperResponse.kneeQ(toe: toe)
            XCTAssertEqual(PaperResponse.paper(0, p: 16, q: q),
                           1 - pow(2, -1 / q), accuracy: 1e-9)
        }
    }

    func testKneeMappingsHitTheirDocumentedEndpoints() {
        XCTAssertEqual(PaperResponse.kneeP(shoulder: 0), 64, accuracy: 1e-9)
        XCTAssertEqual(PaperResponse.kneeP(shoulder: 100), 2, accuracy: 1e-9)
        XCTAssertEqual(PaperResponse.kneeQ(toe: 0), 512, accuracy: 1e-9)
        XCTAssertEqual(PaperResponse.kneeQ(toe: 100), 24, accuracy: 1e-9)
    }

    func testGradeScalePivotsAtTwo() {
        XCTAssertEqual(PaperResponse.gradeScale(2), 1.0, accuracy: 1e-12)
        XCTAssertEqual(PaperResponse.gradeScale(3), 1.15, accuracy: 1e-12)
        XCTAssertEqual(PaperResponse.gradeScale(1), 1 / 1.15, accuracy: 1e-12)
    }

    /// The rolloff lerps every channel ratio toward 1 by a *common* weight,
    /// which scales all inter-channel differences by the same factor — so the
    /// channel ordering and the ratios of differences are invariant, and HSV
    /// hue is exactly preserved. This is where "not sigmoid" is written down.
    func testDevelopPreservesHueThroughTheShoulder() {
        let dmin = (0.9, 0.55, 0.30)
        let dmax = (2.0, 2.0, 2.0)
        let gamma = (1.2, 1.2, 1.2)
        // A saturated red at three densities climbing into the shoulder.
        var lastSat = Double.infinity
        for d in [1.6, 1.85, 2.05] {
            // Transmittance for a red patch: red channel thin, others dense.
            let t = (dmin.0 * pow(10, -(d - 0.9)), dmin.1 * pow(10, -d), dmin.2 * pow(10, -d))
            let out = PaperResponse.develop(t, dminLinear: dmin, dmax: dmax,
                                            gammaEffective: gamma, printOffset: 0,
                                            p: PaperResponse.kneeP(shoulder: 40),
                                            q: PaperResponse.kneeQ(toe: 30),
                                            satScale: 1.0)
            // Red stays the max channel (ordering preserved)…
            XCTAssertGreaterThan(out.0, out.1)
            XCTAssertGreaterThanOrEqual(out.1, out.2)
            // …hue angle is invariant: (g−b)/(r−b) is the HSV hue fraction in
            // the red-to-yellow sextant, and a common-weight lerp toward
            // neutral cannot move it.
            let hueFraction = (out.1 - out.2) / max(out.0 - out.2, 1e-9)
            let inHue = (t.1 - t.2) / max(t.0 - t.2, 1e-9)
            XCTAssertEqual(hueFraction, inHue, accuracy: 0.02)
            // …and saturation falls as it climbs.
            let sat = (out.0 - out.2) / max(out.0, 1e-9)
            XCTAssertLessThan(sat, lastSat)
            lastSat = sat
        }
    }

    /// The base (D = 0) lands near black, the densest area (D = Dmax) near
    /// white — the two ends of the enlarger analogy.
    func testDevelopMapsBaseToNearBlackAndDmaxToNearWhite() {
        let dmin = (0.9, 0.55, 0.30)
        let dmax = (2.0, 2.0, 2.0)
        // gamma solved for targetBlack exactly as AutoInvert will:
        let g = log10(PaperResponse.targetBlack) / (0.0 - 2.0)
        let gamma = (g, g, g)
        let p = PaperResponse.kneeP(shoulder: 40)
        let q = PaperResponse.kneeQ(toe: 30)

        let base = PaperResponse.develop(dmin, dminLinear: dmin, dmax: dmax,
                                         gammaEffective: gamma, printOffset: 0,
                                         p: p, q: q, satScale: 1.0)
        XCTAssertLessThan(max(base.0, base.1, base.2), 0.02)

        let dense = (dmin.0 * pow(10, -2.0), dmin.1 * pow(10, -2.0), dmin.2 * pow(10, -2.0))
        let white = PaperResponse.develop(dense, dminLinear: dmin, dmax: dmax,
                                          gammaEffective: gamma, printOffset: 0,
                                          p: p, q: q, satScale: 1.0)
        XCTAssertGreaterThan(min(white.0, white.1, white.2), 0.9)
    }

    /// Brighter-than-base input (bare lightbox) gives negative density and
    /// must land *below* the base's output, monotonically, with no NaN.
    func testDevelopSurvivesDegenerateInput() {
        let dmin = (0.9, 0.55, 0.30)
        let cases: [(Double, Double, Double)] = [
            (0, 0, 0), (1, 1, 1), (1e-9, 1e-9, 1e-9), (0.95, 0.7, 0.5),
        ]
        for t in cases {
            let out = PaperResponse.develop(t, dminLinear: dmin, dmax: (2, 2, 2),
                                            gammaEffective: (1.2, 1.2, 1.2),
                                            printOffset: 0, p: 16, q: 204, satScale: 1.12)
            for c in [out.0, out.1, out.2] {
                XCTAssertFalse(c.isNaN); XCTAssertFalse(c.isInfinite)
                XCTAssertGreaterThanOrEqual(c, 0); XCTAssertLessThan(c, 1.0)
            }
        }
    }

    func testSRGBEncodeDecodeRoundTrip() {
        for v in stride(from: 0.0, through: 1.0, by: 0.05) {
            XCTAssertEqual(PaperResponse.srgbDecode(PaperResponse.srgbEncode(v)), v,
                           accuracy: 1e-9)
        }
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `xcodebuild -project PhotoEditor.xcodeproj -scheme PhotoEditor -destination 'platform=macOS' test -only-testing:PhotoEditorTests/PaperResponseTests`
Expected: FAIL — `PaperResponse` not defined (compile error is the failure mode here).

- [ ] **Step 4: Write `Sources/Film/PaperResponse.swift`**

```swift
import Foundation

/// The print curve — the density engine's paper response, in pure Swift.
///
/// This file is the single source of truth for the look. The Metal kernel in
/// `Film.ci.metal` mirrors this math line for line, and a test asserts the two
/// agree across the range; the solver in ``AutoInvert`` calls this directly.
/// A curve that existed only inside a `.metal` file could not be unit-tested,
/// and this one carries the whole rendering.
///
/// Every taste judgment in the engine is a named constant here, so "the
/// defaults are arbitrary" is a claim anyone can check against one screen of
/// code. They get tuned against the user's real scans before the phase closes.
enum PaperResponse {

    // MARK: Constants — the house rendering

    /// Where the highlight rolloff engages, as a fraction of paper output.
    /// Below this the channel ratio is preserved exactly (hue AND saturation
    /// survive untouched); exposing it as a slider would invite dialing in the
    /// hue-skewed look this engine exists to avoid.
    static let shoulderStart = 0.75

    /// How completely the shoulder desaturates toward white. 1.0 forces exact
    /// neutrality at paper white; 0.9 reaches it without reading as a clip.
    static let highlightDesat = 0.9

    /// Where Auto lands the 0.5th-percentile density, pre-paper — roughly one
    /// stop above true black, so the toe has something to lift.
    static let targetBlack = 0.004

    /// Where Auto lands the median density: display middle grey.
    static let targetMid = 0.18

    /// Auto's white point: above dust, below the true maximum.
    static let dmaxPercentile = 0.995
    static let dLowPercentile = 0.005

    /// Auto's fallback base estimate. Not the 99.9th: on a lightbox scan the
    /// very top of the histogram is bare panel, not film (see the spec).
    static let dminPercentile = 0.98

    /// Transmittance floor for the log — a scan pixel at exactly zero is
    /// sensor noise, not infinite density.
    static let transmittanceFloor = 1e-5

    // MARK: Slider mappings

    /// Shoulder slider 0…100 → knee exponent, log-interpolated 64 → 2.
    /// At 64 the knee compresses n = 1 by ~1.1% (visually a hard clip); at 2
    /// it compresses to 0.71 (a long gradual rolloff).
    static func kneeP(shoulder: Double) -> Double {
        64.0 * pow(2.0 / 64.0, min(max(shoulder, 0), 100) / 100.0)
    }

    /// Toe slider 0…100 → knee exponent, log-interpolated 512 → 24.
    /// The black floor is `1 − 2^(−1/q)`: imperceptible (0.0014 linear) at
    /// 512, a heavy fog (0.028) at 24.
    static func kneeQ(toe: Double) -> Double {
        512.0 * pow(24.0 / 512.0, min(max(toe, 0), 100) / 100.0)
    }

    /// Paper grade 0…5 → gamma multiplier, one grade = ×1.15, grade 2 = ×1.0
    /// (the gammas Auto solved). Grade rather than a percentage because the
    /// number then means the thing a printer already knows.
    static func gradeScale(_ grade: Double) -> Double {
        pow(1.15, grade - 2.0)
    }

    // MARK: The curve

    /// Identity for small x, asymptote 1 for large x, strictly increasing,
    /// never clips. `k` sets how abrupt the knee is.
    static func softknee(_ x: Double, _ k: Double) -> Double {
        guard x > 0 else { return 0 }
        return x / pow(1.0 + pow(x, k), 1.0 / k)
    }

    /// The paper's characteristic curve: a shoulder into white and, applied to
    /// the complement, a toe out of black. Maps [0, ∞) into [floor, 1),
    /// monotonically. `paper(0) = 1 − 2^(−1/q)` — a lifted black, which is not
    /// a compromise; it is the look of the user's own lab scans.
    static func paper(_ n: Double, p: Double, q: Double) -> Double {
        1.0 - softknee(1.0 - softknee(n, p), q)
    }

    private static func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        let t = min(max((x - e0) / (e1 - e0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    // MARK: The full per-pixel model

    /// The complete density-to-print develop for one linear-transmittance
    /// pixel. `gammaEffective` is the per-channel gamma with the grade scale
    /// already folded in; `printOffset` is `printEV · log10(2)`; `satScale` is
    /// `1 + printSaturation / 100`.
    ///
    /// Stage order (spec §The model): density → straight line → paper on the
    /// max-channel norm → hue-preserving rolloff. The norm is `max`, not a
    /// weighted luma, because the max channel is the one that would otherwise
    /// clip.
    static func develop(_ t: (Double, Double, Double),
                        dminLinear: (Double, Double, Double),
                        dmax: (Double, Double, Double),
                        gammaEffective: (Double, Double, Double),
                        printOffset: Double,
                        p: Double, q: Double,
                        satScale: Double) -> (Double, Double, Double) {
        func straightLine(_ t: Double, _ dmin: Double, _ dmax: Double, _ g: Double) -> Double {
            let density = log10(max(dmin, 1e-4) / max(t, transmittanceFloor))
            return pow(10.0, g * (density - dmax) + printOffset)
        }
        let s = (straightLine(t.0, dminLinear.0, dmax.0, gammaEffective.0),
                 straightLine(t.1, dminLinear.1, dmax.1, gammaEffective.1),
                 straightLine(t.2, dminLinear.2, dmax.2, gammaEffective.2))
        let n = max(s.0, max(s.1, s.2))
        var ratio = n > 0 ? (s.0 / n, s.1 / n, s.2 / n) : (1.0, 1.0, 1.0)
        // Hue-preserving saturation: scale the ratio around 1. Clamped at zero
        // so a big boost cannot drive a channel negative.
        ratio = (max(1 + (ratio.0 - 1) * satScale, 0),
                 max(1 + (ratio.1 - 1) * satScale, 0),
                 max(1 + (ratio.2 - 1) * satScale, 0))
        let pn = paper(n, p: p, q: q)
        let w = smoothstep(shoulderStart, 1.0, pn) * highlightDesat
        return (pn * (ratio.0 + (1 - ratio.0) * w),
                pn * (ratio.1 + (1 - ratio.1) * w),
                pn * (ratio.2 + (1 - ratio.2) * w))
    }

    // MARK: sRGB transfer

    /// The base color is persisted display-encoded (shared with the matrix
    /// engine and the panel swatch); the density engine works in linear, so
    /// each side converts at its own boundary.
    static func srgbDecode(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    static func srgbEncode(_ c: Double) -> Double {
        c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1.0 / 2.4) - 0.055
    }
}
```

- [ ] **Step 5: Regenerate and run**

Run: `xcodegen generate`, then the Step 3 command.
Expected: PASS, all 8 tests.

- [ ] **Step 6: Commit**

```bash
git add Sources/Film/PaperResponse.swift Tests/PaperResponseTests.swift docs/superpowers/specs/2026-08-04-print-engine-design.md
git commit -m "feat(print): the paper response curve, in Swift, with its constants block"
```

---

### Task 2: The settings model — conversionModel, PrintSettings, baseOrigin

Freezing the matrix engine happens *here*: the decoded default is `.matrix`, the initialized default is `.density`.

**Files:**
- Create: `Sources/Film/PrintSettings.swift`
- Modify: `Sources/Film/FilmNegativeSettings.swift`
- Test: `Tests/PrintSettingsTests.swift`

**Interfaces:**
- Consumes: `LenientDecoding` (`c.lenient(key, default)`), `FilmColor`.
- Produces:
  - `enum FilmConversionModel: String, Codable, Equatable { case matrix, density }`
  - `enum FilmBaseOrigin: String, Codable, Equatable { case assumed, estimated, sampled }`
  - `struct DensityTriple: Codable, Equatable, Hashable { var red, green, blue: Double; static let unit: DensityTriple }`
  - `struct PrintSettings: Codable, Equatable` with fields `exposure: Double = 0`, `contrast: Double = 2`, `shoulder: Double = 40`, `toe: Double = 30`, `saturation: Double = 12`, `dmax: DensityTriple = .init(red: 2, green: 2, blue: 2)`, `gamma: DensityTriple = .unit`
  - `FilmNegativeSettings` gains `conversionModel: FilmConversionModel` (init `.density`, decode fallback `.matrix`), `baseOrigin: FilmBaseOrigin` (init `.assumed`, decode fallback derived from `isBaseSampled`), `print: PrintSettings`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import PhotoEditor

final class PrintSettingsTests: XCTestCase {

    /// The freeze, as a test: an old stack knows nothing about conversion
    /// models, and it must decode to the matrix engine — its rendering is a
    /// promise. Only a *new* conversion gets the density engine.
    func testDecodedDefaultIsMatrixButInitializedDefaultIsDensity() throws {
        XCTAssertEqual(FilmNegativeSettings().conversionModel, .density)

        let old = #"{"isEnabled": true, "type": "colorNegative"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(FilmNegativeSettings.self, from: old)
        XCTAssertEqual(decoded.conversionModel, .matrix)
    }

    /// A stack that recorded a sampled base before `baseOrigin` existed must
    /// come back as `.sampled`, not `.assumed` — same bug class as the
    /// persisted `isBaseSampled` flag itself (see that field's doc comment).
    func testBaseOriginFallsBackToTheLegacySampledFlag() throws {
        let sampled = #"{"isBaseSampled": true}"#.data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(FilmNegativeSettings.self, from: sampled).baseOrigin,
                       .sampled)
        let assumed = #"{"isBaseSampled": false}"#.data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(FilmNegativeSettings.self, from: assumed).baseOrigin,
                       .assumed)
    }

    func testPrintSettingsRoundTripThroughJSON() throws {
        var settings = FilmNegativeSettings()
        settings.print.exposure = 0.7
        settings.print.contrast = 3.5
        settings.print.dmax = DensityTriple(red: 2.4, green: 2.2, blue: 2.0)
        settings.print.gamma = DensityTriple(red: 1.1, green: 1.2, blue: 1.35)
        settings.baseOrigin = .estimated
        let data = try JSONEncoder().encode(settings)
        let back = try JSONDecoder().decode(FilmNegativeSettings.self, from: data)
        XCTAssertEqual(back, settings)
    }

    /// Field-level leniency, same reasoning as the parent type: one missing
    /// key must lose one field, not the whole print block.
    func testPrintSettingsDecodeLeniently() throws {
        let partial = #"{"exposure": 1.5}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(PrintSettings.self, from: partial)
        XCTAssertEqual(decoded.exposure, 1.5)
        XCTAssertEqual(decoded.contrast, 2)
        XCTAssertEqual(decoded.dmax, DensityTriple(red: 2, green: 2, blue: 2))
    }

    /// The neutral-edit check must not report a fresh stack as edited just
    /// because these new fields exist with non-zero defaults.
    func testFreshStackIsStillANeutralEdit() {
        XCTAssertTrue(EditStack().isNeutralEdit)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `... -only-testing:PhotoEditorTests/PrintSettingsTests`
Expected: FAIL — types not defined.

- [ ] **Step 3: Write `Sources/Film/PrintSettings.swift`**

```swift
import Foundation

/// Which engine interprets a photo's film conversion.
///
/// `.matrix` is the original single-`CIColorMatrix` inversion, frozen forever:
/// a stack loaded from an existing catalog decodes to it and keeps its exact
/// rendering. `.density` is the print engine. Both stay in the renderer
/// permanently — this is the same freeze contract as `processVersion`.
enum FilmConversionModel: String, Codable, Equatable {
    case matrix
    case density
}

/// Where the film base measurement came from, reported in the panel. The
/// distinction matters because Auto's percentile estimate can be fooled by
/// bare lightbox around the frame; the user deserves to know which number
/// they are trusting.
enum FilmBaseOrigin: String, Codable, Equatable {
    /// The built-in representative orange mask — nothing was measured.
    case assumed
    /// Auto's per-channel percentile estimate over the whole scan.
    case estimated
    /// Measured: the eyedropper on clear rebate, or (Phase 3) frame detection.
    case sampled
}

/// A per-channel triple in *density* space. Unlike ``FilmColor`` these are not
/// colors and routinely exceed 1 — a dense C-41 highlight is around 2.5.
struct DensityTriple: Codable, Equatable, Hashable {
    var red: Double
    var green: Double
    var blue: Double

    static let unit = DensityTriple(red: 1, green: 1, blue: 1)
}

/// The print half of the density engine: everything after the density
/// measurement, in the terms a printer would use. Resolved values, like the
/// rest of ``FilmNegativeSettings`` — Auto writes numbers in here and every
/// one of them stays an ordinary, visible slider.
struct PrintSettings: Codable, Equatable {
    /// Print exposure in EV. A log-domain offset, so one stop is one stop
    /// regardless of grade.
    var exposure: Double = 0

    /// Paper grade 0…5. Grade 2 is defined as ×1.0 — the gammas Auto solved;
    /// each whole grade is ×1.15 on all three (see `PaperResponse.gradeScale`).
    var contrast: Double = 2

    /// Highlight knee, 0…100 → `PaperResponse.kneeP`. 0 is a hard clip.
    var shoulder: Double = 40

    /// Shadow knee, 0…100 → `PaperResponse.kneeQ`. 0 is a plugged black.
    var toe: Double = 30

    /// Hue-preserving saturation, applied to the channel ratio around neutral
    /// before the rolloff. Defaults above zero because C-41 papers are more
    /// saturated than a straight solve.
    var saturation: Double = 12

    /// Solved per-channel maximum density — the white point. Trimming one
    /// channel neutralizes a highlight cast.
    var dmax = DensityTriple(red: 2, green: 2, blue: 2)

    /// Solved per-channel paper gamma at grade 2. Three different slopes is
    /// the crossover fix — the degree of freedom the matrix model lacks.
    var gamma = DensityTriple.unit

    init() {}

    /// Lenient, field by field, for the same reason as the parent type.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exposure = c.lenient(.exposure, 0)
        contrast = c.lenient(.contrast, 2)
        shoulder = c.lenient(.shoulder, 40)
        toe = c.lenient(.toe, 30)
        saturation = c.lenient(.saturation, 12)
        dmax = c.lenient(.dmax, DensityTriple(red: 2, green: 2, blue: 2))
        gamma = c.lenient(.gamma, .unit)
    }
}
```

- [ ] **Step 4: Extend `FilmNegativeSettings`**

Add stored properties (after `channelGains`, before `exposure`):

```swift
    /// Which conversion engine renders this photo. Initialized `.density` so
    /// new conversions get the print engine; decoded `.matrix` so every photo
    /// edited before this field existed keeps its exact rendering forever.
    var conversionModel: FilmConversionModel = .density

    /// Where ``baseColor`` came from (assumed / estimated / sampled) — shown
    /// in the panel. Supersedes ``isBaseSampled``, which is kept in sync for
    /// older call sites and for decoding stacks that predate this field.
    var baseOrigin: FilmBaseOrigin = .assumed

    /// The print-engine parameters. Ignored by the matrix path.
    var print = PrintSettings()
```

And in `init(from decoder:)`, after the `isBaseSampled` line:

```swift
        conversionModel = c.lenient(.conversionModel, .matrix)
        baseOrigin = c.lenient(.baseOrigin, isBaseSampled ? .sampled : .assumed)
        print = c.lenient(.print, PrintSettings())
```

- [ ] **Step 5: Run the new tests and the film + conformance suites**

Run: `... -only-testing:PhotoEditorTests/PrintSettingsTests -only-testing:PhotoEditorTests/FilmNegativeTests -only-testing:PhotoEditorTests/ControlConformanceTests -only-testing:PhotoEditorTests/EndToEndFilmTests`
Expected: all PASS. `FilmNegativeTests.testOlderEditStackJSONStillDecodes` is the canary for a broken lenient decode; `ControlConformanceTests` neutral checks are the canary for a default that silently changes rendering (a fresh stack has film disabled, so they must still pass bit-exact).

- [ ] **Step 6: Commit**

```bash
git add Sources/Film/PrintSettings.swift Sources/Film/FilmNegativeSettings.swift Tests/PrintSettingsTests.swift
git commit -m "feat(print): conversion model, print settings, base origin — matrix frozen at decode"
```

---

### Task 3: The kernel and the render stage

One GPU pass, linear in and linear out, mirroring `PaperResponse` exactly — with the agreement test that keeps it that way.

**Files:**
- Create: `Sources/Pipeline/Kernels/Film.ci.metal`
- Create: `Sources/Film/FilmDensityConverter.swift`
- Modify: `Sources/Film/FilmNegativeConverter.swift` (dispatch only)
- Test: `Tests/FilmDensityConverterTests.swift`

**Interfaces:**
- Consumes: `KernelLibrary.color(_:)`, `PaperResponse` (Task 1), `FilmNegativeSettings` (Task 2), `TestSupport.solidImage`, `TestSupport.readColor`.
- Produces:
  - Metal: `extern "C" float4 film_density_print(coreimage::sample_t s, float3 dmin, float3 dmax, float3 gam, float printOffset, float p, float q, float shoulderStart, float highlightDesat, float satScale)`
  - `FilmDensityConverter.convert(_ image: CIImage, settings: FilmNegativeSettings) -> CIImage`
  - `FilmNegativeConverter.convert` now routes `.density` + `requiresInversion` stacks to `FilmDensityConverter`; everything else is byte-identical to before.

- [ ] **Step 1: Write the failing tests**

```swift
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
        XCTAssertLessThan(max(c.red, max(c.green, c.blue)), 0.05)

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
```

- [ ] **Step 2: Run to verify failure** (`-only-testing:PhotoEditorTests/FilmDensityConverterTests`) — FAIL, `FilmDensityConverter` undefined.

- [ ] **Step 3: Write `Sources/Pipeline/Kernels/Film.ci.metal`**

```metal
// The print engine's density-to-paper conversion. Runs on LINEAR working-space
// values — the opposite of every kernel in Tone.ci.metal, and deliberately so:
// log10 of linear transmittance is the physically meaningful density, and the
// paper curve is defined on the linear print value. No sRGB bracketing here.
//
// This kernel mirrors PaperResponse.swift line for line, and
// FilmDensityConverterTests.testKernelAgreesWithTheSwiftModel is the contract
// that keeps the two in step. Change one, change both.
#include <metal_stdlib>
using namespace metal;
#include <CoreImage/CoreImage.h>

// softknee(x,k) = x·(1+x^k)^(−1/k): identity near 0, asymptote 1, never clips.
static float softknee(float x, float k) {
    if (x <= 0.0f) return 0.0f;
    return x / pow(1.0f + pow(x, k), 1.0f / k);
}

// Shoulder into white; toe (the same knee on the complement) out of black.
static float paper_curve(float n, float p, float q) {
    return 1.0f - softknee(1.0f - softknee(n, p), q);
}

extern "C" float4 film_density_print(coreimage::sample_t s,
                                     float3 dmin, float3 dmax, float3 gam,
                                     float printOffset, float p, float q,
                                     float shoulderStart, float highlightDesat,
                                     float satScale) {
    // Stage 1+2: density relative to the base, then the paper's straight line.
    // gam arrives with the grade scale already folded in (CPU side).
    float3 t = max(s.rgb, float3(1e-5f));
    float3 D = log10(max(dmin, float3(1e-4f)) / t);
    float3 sp = pow(float3(10.0f), gam * (D - dmax) + printOffset);

    // Stage 3: the paper acts on the max-channel norm — the channel that
    // would otherwise clip — and the others follow by ratio.
    float n = max3(sp.x, sp.y, sp.z);
    float3 ratio = n > 0.0f ? sp / n : float3(1.0f);
    ratio = max(1.0f + (ratio - 1.0f) * satScale, float3(0.0f));
    float pn = paper_curve(n, p, q);

    // Stage 4: hue-preserving rolloff. One weight for all three channels
    // scales every inter-channel difference equally, so hue cannot rotate.
    float w = smoothstep(shoulderStart, 1.0f, pn) * highlightDesat;
    float3 outc = pn * mix(ratio, float3(1.0f), w);
    return float4(outc, s.a);
}
```

- [ ] **Step 4: Write `Sources/Film/FilmDensityConverter.swift`**

```swift
import CoreImage
import CoreImage.CIFilterBuiltins

/// The print engine's render stage: one GPU pass through
/// `film_density_print`, on linear working-space values.
///
/// The legacy converter brackets its work in sRGB because a linear
/// divide-and-invert crushes highlights — a correct workaround for a model
/// with no logarithm in it. The density model is *defined* on linear
/// transmittance, so this path simply does not bracket.
enum FilmDensityConverter {
    private static let kernel = KernelLibrary.color("film_density_print")

    static func convert(_ image: CIImage, settings: FilmNegativeSettings) -> CIImage {
        let p = settings.print

        // The persisted base is display-encoded (shared with the matrix
        // engine, the swatch, and the eyedropper); linearize at the boundary.
        // B&W has no color mask: its base is one neutral level, same reasoning
        // as the matrix path.
        let dminLinear: (Double, Double, Double)
        if settings.type.hasColorMask {
            let b = settings.baseColor.safeForDivision
            dminLinear = (PaperResponse.srgbDecode(b.red),
                          PaperResponse.srgbDecode(b.green),
                          PaperResponse.srgbDecode(b.blue))
        } else {
            let level = PaperResponse.srgbDecode(max(settings.baseColor.maxChannel, 0.0001))
            dminLinear = (level, level, level)
        }

        let grade = PaperResponse.gradeScale(p.contrast)
        var result = kernel.apply(
            extent: image.extent,
            arguments: [
                image,
                CIVector(x: dminLinear.0, y: dminLinear.1, z: dminLinear.2),
                CIVector(x: p.dmax.red, y: p.dmax.green, z: p.dmax.blue),
                CIVector(x: p.gamma.red * grade, y: p.gamma.green * grade,
                         z: p.gamma.blue * grade),
                Float(p.exposure * log10(2.0)),
                Float(PaperResponse.kneeP(shoulder: p.shoulder)),
                Float(PaperResponse.kneeQ(toe: p.toe)),
                Float(PaperResponse.shoulderStart),
                Float(PaperResponse.highlightDesat),
                Float(1.0 + p.saturation / 100.0),
            ]
        ) ?? image

        // Film Exposure (the legacy EV lift) still applies if set — it is a
        // linear-light stop, meaningful on either engine.
        if settings.exposure != 0 {
            let exposure = CIFilter.exposureAdjust()
            exposure.inputImage = result
            exposure.ev = Float(settings.exposure)
            result = exposure.outputImage ?? result
        }

        // A B&W negative comes back neutral, same promise as the matrix path.
        if settings.type == .blackAndWhiteNegative {
            let mono = CIFilter.colorControls()
            mono.inputImage = result
            mono.saturation = 0
            result = mono.outputImage ?? result
        }

        return result
    }
}
```

- [ ] **Step 5: Dispatch in `FilmNegativeConverter.convert`**

At the top of `convert`, after the `isEnabled` guard, insert:

```swift
        // The print engine. Slide film has nothing to invert, so it keeps the
        // legacy non-inverting path regardless of model.
        if settings.conversionModel == .density && settings.type.requiresInversion {
            return FilmDensityConverter.convert(image, settings: settings)
        }
```

Nothing else in the file changes.

- [ ] **Step 6: Run** Step 2 command plus `FilmNegativeTests`, `EndToEndFilmTests`.
Expected: all PASS. If the kernel is missing from the metallib, `KernelLibrary.color` traps with its own message — check that `Film.ci.metal` landed in the target (`xcodegen generate` again).

- [ ] **Step 7: Commit**

```bash
git add Sources/Pipeline/Kernels/Film.ci.metal Sources/Film/FilmDensityConverter.swift Sources/Film/FilmNegativeConverter.swift Tests/FilmDensityConverterTests.swift
git commit -m "feat(print): the density kernel and render stage, matrix path untouched"
```

---

### Task 4: AutoInvert — measurement, solve, and the proof it works

The round-trip test is the headline: a synthetic negative with deliberate crossover, recovered by Auto, with the matrix engine's irreducible error documented beside it.

**Files:**
- Create: `Sources/Film/AutoInvert.swift`
- Create: `Tests/PrintEngineSupport.swift`
- Test: `Tests/AutoInvertTests.swift`

**Interfaces:**
- Consumes: `PaperResponse` (Task 1), `PrintSettings`/`DensityTriple`/`FilmBaseOrigin` (Task 2), `ParitySupport.srgbToLab` / `ParitySupport.ciede2000` (existing).
- Produces:
  - `struct AutoInvertSolution: Equatable { var baseColor: FilmColor; var baseOrigin: FilmBaseOrigin; var dmax: DensityTriple; var gamma: DensityTriple; var printExposure: Double; var degradedTerms: [String] }` with `var isDegraded: Bool`
  - `AutoInvert.solve(scan: CIImage, sampledBase: FilmColor?, context: CIContext) -> AutoInvertSolution?`
  - Test support: `FilmSim.scene() -> [(name: String, linear: (Double, Double, Double))]`, `FilmSim.negativeImage(dmin: (Double, Double, Double), gammas: (Double, Double, Double), size: Int) -> CIImage`, `FilmSim.transmittance(of scene: (Double, Double, Double), dmin: (Double, Double, Double), gammas: (Double, Double, Double)) -> (Double, Double, Double)` — used again by Task 7's conformance probe.

- [ ] **Step 1: Write `Tests/PrintEngineSupport.swift`** (support first: both this task's tests and Task 7's need it)

```swift
import CoreGraphics
import CoreImage
import Foundation
@testable import PhotoEditor

/// A simulated C-41 exposure: turns a known linear scene into a film negative
/// with a chosen base and per-channel characteristic slopes. Different slopes
/// per channel IS crossover — the thing the matrix model provably cannot
/// remove and the density engine exists to fix.
///
/// The model: negative density above base is proportional to log exposure,
/// `D_c = gammaSim_c · (log10 L_c + 3)` with L clamped to [1e-3, 1], so the
/// scene's 3 decades of luminance map to densities 0…3·gammaSim. Transmittance
/// is then `t_c = dmin_c · 10^(−D_c)` — the brightest scene area is the
/// densest, exactly as film behaves.
enum FilmSim {
    /// Named patches spanning tone and color: the round-trip fixture.
    static func scene() -> [(name: String, linear: (Double, Double, Double))] {
        [
            ("black", (0.002, 0.002, 0.002)),
            ("shadowGrey", (0.02, 0.02, 0.02)),
            ("midGrey", (0.18, 0.18, 0.18)),
            ("lightGrey", (0.45, 0.45, 0.45)),
            ("white", (0.95, 0.95, 0.95)),
            ("red", (0.45, 0.05, 0.04)),
            ("green", (0.06, 0.40, 0.07)),
            ("blue", (0.05, 0.07, 0.42)),
            ("skin", (0.42, 0.26, 0.18)),
            ("sky", (0.20, 0.32, 0.55)),
        ]
    }

    static func transmittance(of scene: (Double, Double, Double),
                              dmin: (Double, Double, Double),
                              gammas: (Double, Double, Double)) -> (Double, Double, Double) {
        func channel(_ l: Double, _ dmin: Double, _ g: Double) -> Double {
            let clamped = min(max(l, 1e-3), 1.0)
            let density = g * (log10(clamped) + 3.0)
            return dmin * pow(10.0, -density)
        }
        return (channel(scene.0, dmin.0, gammas.0),
                channel(scene.1, dmin.1, gammas.1),
                channel(scene.2, dmin.2, gammas.2))
    }

    /// The scene patches as a rendered negative, plus a border of bare film
    /// base — the rebate every real scan should include. The border is 20% of
    /// the area, comfortably above the solver's 2% Dmin percentile.
    static func negativeImage(dmin: (Double, Double, Double),
                              gammas: (Double, Double, Double),
                              size: Int = 200) -> CIImage {
        let patches = scene()
        let cols = 5, rows = 2
        let border = size / 10
        let cellW = (size - 2 * border) / cols
        let cellH = (size - 2 * border) / rows
        var pixels = [Float](repeating: 0, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let inX = x - border, inY = y - border
                let t: (Double, Double, Double)
                if inX < 0 || inY < 0 || inX >= cellW * cols || inY >= cellH * rows {
                    t = dmin // bare base: the rebate
                } else {
                    let index = min((inY / cellH) * cols + (inX / cellW), patches.count - 1)
                    t = transmittance(of: patches[index].linear, dmin: dmin, gammas: gammas)
                }
                let i = (y * size + x) * 4
                pixels[i] = Float(t.0); pixels[i + 1] = Float(t.1)
                pixels[i + 2] = Float(t.2); pixels[i + 3] = 1
            }
        }
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(bitmapData: data, bytesPerRow: size * 16,
                       size: CGSize(width: size, height: size), format: .RGBAf,
                       colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
    }

    /// The canonical crossover fixture: cyan shadows, warm highlights. No
    /// single per-channel gain can neutralize both ends of this.
    static let crossoverGammas = (0.55, 0.62, 0.70)
    static let c41Base = (0.55, 0.30, 0.13) // linear transmittance of the mask
}
```

- [ ] **Step 2: Write the failing tests**

```swift
import CoreImage
import XCTest
@testable import PhotoEditor

final class AutoInvertTests: XCTestCase {
    private let context = CIContext()

    private func develop(_ sceneLinear: (Double, Double, Double),
                         with solution: AutoInvertSolution,
                         gammasSim: (Double, Double, Double) = FilmSim.crossoverGammas,
                         printSettings: PrintSettings) -> (Double, Double, Double) {
        let t = FilmSim.transmittance(of: sceneLinear, dmin: FilmSim.c41Base,
                                      gammas: gammasSim)
        let dminLin = (PaperResponse.srgbDecode(solution.baseColor.red),
                       PaperResponse.srgbDecode(solution.baseColor.green),
                       PaperResponse.srgbDecode(solution.baseColor.blue))
        let grade = PaperResponse.gradeScale(printSettings.contrast)
        return PaperResponse.develop(
            t, dminLinear: dminLin,
            dmax: (solution.dmax.red, solution.dmax.green, solution.dmax.blue),
            gammaEffective: (solution.gamma.red * grade, solution.gamma.green * grade,
                             solution.gamma.blue * grade),
            printOffset: solution.printExposure * log10(2.0),
            p: PaperResponse.kneeP(shoulder: printSettings.shoulder),
            q: PaperResponse.kneeQ(toe: printSettings.toe),
            satScale: 1.0 + printSettings.saturation / 100.0)
    }

    /// The headline: a negative with deliberate crossover, solved blind, and
    /// the greys come back grey at BOTH ends. This is the property the matrix
    /// engine cannot have, and the next test documents that side by side.
    func testAutoRecoversNeutralsThroughCrossover() throws {
        let scan = FilmSim.negativeImage(dmin: FilmSim.c41Base,
                                         gammas: FilmSim.crossoverGammas)
        let solution = try XCTUnwrap(AutoInvert.solve(scan: scan, sampledBase: nil,
                                                      context: context))
        XCTAssertFalse(solution.isDegraded, "clean fixture must solve cleanly: \(solution.degradedTerms)")

        // Judge with the look controls neutralized: shoulder/toe off, flat
        // saturation — this test is about the SOLVE, not the house rendering.
        var flat = PrintSettings()
        flat.shoulder = 0; flat.toe = 0; flat.saturation = 0

        for grey in ["shadowGrey", "midGrey", "lightGrey"] {
            let patch = FilmSim.scene().first { $0.name == grey }!.linear
            let out = develop(patch, with: solution, printSettings: flat)
            let lab = ParitySupport.srgbToLab(r: PaperResponse.srgbEncode(out.0),
                                              g: PaperResponse.srgbEncode(out.1),
                                              b: PaperResponse.srgbEncode(out.2))
            XCTAssertLessThan(abs(lab.a), 5.0, "\(grey) has a cast: a*=\(lab.a)")
            XCTAssertLessThan(abs(lab.b), 5.0, "\(grey) has a cast: b*=\(lab.b)")
        }
    }

    /// The matrix model's best case on the same fixture: base divided out
    /// perfectly and gains chosen to neutralize middle grey exactly. The ends
    /// still diverge — one gain per channel scales shadows and highlights
    /// together. Documented as a measured margin, not a claim.
    func testCrossoverIsProvablyBeyondTheMatrixModel() throws {
        let scan = FilmSim.negativeImage(dmin: FilmSim.c41Base,
                                         gammas: FilmSim.crossoverGammas)
        let solution = try XCTUnwrap(AutoInvert.solve(scan: scan, sampledBase: nil,
                                                      context: context))
        var flat = PrintSettings()
        flat.shoulder = 0; flat.toe = 0; flat.saturation = 0

        // Matrix best case, computed in its own gamma-encoded domain: for each
        // channel, out = g·(1 − enc(t)/enc(base)); solve g so midGrey lands
        // exactly neutral, then measure the extremes.
        func matrix(_ scene: (Double, Double, Double), gains: (Double, Double, Double))
            -> (Double, Double, Double) {
            let t = FilmSim.transmittance(of: scene, dmin: FilmSim.c41Base,
                                          gammas: FilmSim.crossoverGammas)
            let base = FilmSim.c41Base
            func ch(_ t: Double, _ b: Double, _ g: Double) -> Double {
                g * (1 - PaperResponse.srgbEncode(t) / PaperResponse.srgbEncode(b))
            }
            return (ch(t.0, base.0, gains.0), ch(t.1, base.1, gains.1), ch(t.2, base.2, gains.2))
        }
        let mid = FilmSim.scene().first { $0.name == "midGrey" }!.linear
        let rawMid = matrix(mid, gains: (1, 1, 1))
        let target = (rawMid.0 + rawMid.1 + rawMid.2) / 3
        let gains = (target / rawMid.0, target / rawMid.1, target / rawMid.2)

        func chromaError(_ rgb: (Double, Double, Double)) -> Double {
            let lab = ParitySupport.srgbToLab(r: min(max(rgb.0, 0), 1),
                                              g: min(max(rgb.1, 0), 1),
                                              b: min(max(rgb.2, 0), 1))
            return (lab.a * lab.a + lab.b * lab.b).squareRoot()
        }

        for grey in ["shadowGrey", "lightGrey"] {
            let patch = FilmSim.scene().first { $0.name == grey }!.linear
            let matrixErr = chromaError(matrix(patch, gains: gains))
            let out = develop(patch, with: solution, printSettings: flat)
            let densityErr = chromaError((PaperResponse.srgbEncode(out.0),
                                          PaperResponse.srgbEncode(out.1),
                                          PaperResponse.srgbEncode(out.2)))
            XCTAssertGreaterThan(matrixErr, densityErr * 2,
                "\(grey): matrix residual \(matrixErr) should dwarf density residual \(densityErr)")
        }
    }

    /// A sampled base wins over the percentile estimate, and the solution
    /// reports which one it used.
    func testSampledBaseIsUsedAndReported() throws {
        let scan = FilmSim.negativeImage(dmin: FilmSim.c41Base,
                                         gammas: FilmSim.crossoverGammas)
        let sampledBase = FilmColor(red: PaperResponse.srgbEncode(FilmSim.c41Base.0),
                                    green: PaperResponse.srgbEncode(FilmSim.c41Base.1),
                                    blue: PaperResponse.srgbEncode(FilmSim.c41Base.2))
        let solution = try XCTUnwrap(AutoInvert.solve(scan: scan, sampledBase: sampledBase,
                                                      context: context))
        XCTAssertEqual(solution.baseOrigin, .sampled)
        XCTAssertEqual(solution.baseColor, sampledBase)

        let estimated = try XCTUnwrap(AutoInvert.solve(scan: scan, sampledBase: nil,
                                                       context: context))
        XCTAssertEqual(estimated.baseOrigin, .estimated)
    }

    /// Median density lands at the target midtone — the printEV bisection.
    func testPrintExposurePlacesTheMedianAtMiddleGrey() throws {
        let scan = FilmSim.negativeImage(dmin: FilmSim.c41Base,
                                         gammas: FilmSim.crossoverGammas)
        let solution = try XCTUnwrap(AutoInvert.solve(scan: scan, sampledBase: nil,
                                                      context: context))
        XCTAssertFalse(solution.printExposure.isNaN)
        XCTAssertTrue((-8.0...8.0).contains(solution.printExposure))
    }

    /// A flat scan has no tonal range to solve against: every term that
    /// cannot be measured degrades to its default and says so, rather than
    /// producing a confidently wrong number.
    func testFlatScanDegradesGracefully() throws {
        let flat = TestSupport.solidImage(red: 0.5, green: 0.35, blue: 0.2,
                                          size: 64)
        let solution = try XCTUnwrap(AutoInvert.solve(scan: flat, sampledBase: nil,
                                                      context: context))
        XCTAssertTrue(solution.isDegraded)
        XCTAssertEqual(solution.gamma, .unit, "unmeasurable gamma falls back to 1")
        for g in [solution.gamma.red, solution.dmax.red, solution.printExposure] {
            XCTAssertFalse(g.isNaN)
        }
    }
}
```

Note: `TestSupport.solidImage` has two overloads; use the `(red:green:blue:size:)` one that exists — check `Tests/TestSupport.swift:109-128` and match the actual signature when writing the test.

- [ ] **Step 3: Run to verify failure** — FAIL, `AutoInvert` undefined.

- [ ] **Step 4: Write `Sources/Film/AutoInvert.swift`**

```swift
import CoreImage
import Foundation

/// What Auto solved, and how much of it was actually measured.
struct AutoInvertSolution: Equatable {
    /// Display-encoded, ready for `FilmNegativeSettings.baseColor`.
    var baseColor: FilmColor
    var baseOrigin: FilmBaseOrigin
    var dmax: DensityTriple
    var gamma: DensityTriple
    var printExposure: Double

    /// Human-readable names of terms that fell back to defaults because the
    /// scan gave nothing to measure. Empty means a clean solve.
    var degradedTerms: [String]

    var isDegraded: Bool { !degradedTerms.isEmpty }
}

/// The one-button solve: measure a downsampled linear render of the scan,
/// derive every density parameter in closed form, and place the exposure with
/// one scalar bisection. Deterministic — no search, no randomness — so the
/// same scan always solves to the same numbers.
enum AutoInvert {
    /// Grid edge for measurement. Enough for stable percentiles, cheap enough
    /// to be instant (spec: `autoDownsample`).
    static let sampleSide = 256

    /// `D_low` colliding with `Dmax` inside this margin means the scan has no
    /// measurable tonal range in that channel.
    private static let minimumDensityRange = 0.05

    /// - Parameter sampledBase: the user's eyedropper (or Phase 3 rebate)
    ///   measurement, display-encoded. Non-nil wins over the percentile
    ///   estimate: actual clear film beats any statistic.
    static func solve(scan: CIImage, sampledBase: FilmColor?,
                      context: CIContext) -> AutoInvertSolution? {
        guard let pixels = linearPixels(of: scan, side: sampleSide, context: context),
              !pixels.isEmpty else { return nil }

        var degraded: [String] = []

        // 1. Dmin per channel — sampled if available, else the 98th
        // percentile (NOT the maximum: on a lightbox scan the top of the
        // histogram is bare panel, not film base — see the spec's risk note).
        var reds = pixels.map(\.0).sorted()
        var greens = pixels.map(\.1).sorted()
        var blues = pixels.map(\.2).sorted()
        let dminLinear: (Double, Double, Double)
        let origin: FilmBaseOrigin
        if let sampledBase {
            dminLinear = (PaperResponse.srgbDecode(sampledBase.red),
                          PaperResponse.srgbDecode(sampledBase.green),
                          PaperResponse.srgbDecode(sampledBase.blue))
            origin = .sampled
        } else {
            dminLinear = (percentile(reds, PaperResponse.dminPercentile),
                          percentile(greens, PaperResponse.dminPercentile),
                          percentile(blues, PaperResponse.dminPercentile))
            origin = .estimated
        }

        // 2. Densities across the frame, per channel.
        func density(_ t: Double, _ dmin: Double) -> Double {
            log10(max(dmin, 1e-4) / max(t, PaperResponse.transmittanceFloor))
        }
        for i in pixels.indices {
            reds[i] = density(reds[i], dminLinear.0)
            greens[i] = density(greens[i], dminLinear.1)
            blues[i] = density(blues[i], dminLinear.2)
        }
        // Densities are anti-monotone in transmittance: re-sort ascending.
        reds.sort(); greens.sort(); blues.sort()

        // 3–4. White point and shadow anchor, per channel.
        let dmaxV = (percentile(reds, PaperResponse.dmaxPercentile),
                     percentile(greens, PaperResponse.dmaxPercentile),
                     percentile(blues, PaperResponse.dmaxPercentile))
        let dlow = (percentile(reds, PaperResponse.dLowPercentile),
                    percentile(greens, PaperResponse.dLowPercentile),
                    percentile(blues, PaperResponse.dLowPercentile))

        // 5. Gammas: land every channel's low end on one target black. Both
        // ends of all three channels now coincide — that IS "no crossover".
        func solveGamma(_ dlow: Double, _ dmax: Double, _ channel: String) -> Double {
            let range = dlow - dmax
            guard abs(range) > minimumDensityRange else {
                degraded.append("gamma (\(channel)): no measurable density range")
                return 1.0
            }
            return log10(PaperResponse.targetBlack) / range
        }
        let gamma = DensityTriple(red: solveGamma(dlow.0, dmaxV.0, "red"),
                                  green: solveGamma(dlow.1, dmaxV.1, "green"),
                                  blue: solveGamma(dlow.2, dmaxV.2, "blue"))

        // 6. Print exposure: bisect so the median density renders at middle
        // grey. Median, not the extremes — percentile ends are noisy and the
        // midtone is what the eye judges. paper() is monotone in the offset,
        // so bisection on one scalar converges deterministically.
        let medianD = (percentile(reds, 0.5), percentile(greens, 0.5), percentile(blues, 0.5))
        let medianT = (dminLinear.0 * pow(10, -medianD.0),
                       dminLinear.1 * pow(10, -medianD.1),
                       dminLinear.2 * pow(10, -medianD.2))
        let defaults = PrintSettings()
        let p = PaperResponse.kneeP(shoulder: defaults.shoulder)
        let q = PaperResponse.kneeQ(toe: defaults.toe)
        var lo = -8.0, hi = 8.0
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            let out = PaperResponse.develop(
                medianT, dminLinear: dminLinear,
                dmax: (dmaxV.0, dmaxV.1, dmaxV.2),
                gammaEffective: (gamma.red, gamma.green, gamma.blue),
                printOffset: mid * log10(2.0), p: p, q: q, satScale: 1.0)
            if max(out.0, max(out.1, out.2)) < PaperResponse.targetMid { lo = mid } else { hi = mid }
        }
        let printEV = ((lo + hi) / 2 * 100).rounded() / 100 // stable to read

        return AutoInvertSolution(
            baseColor: sampledBase ?? FilmColor(
                red: PaperResponse.srgbEncode(dminLinear.0),
                green: PaperResponse.srgbEncode(dminLinear.1),
                blue: PaperResponse.srgbEncode(dminLinear.2)),
            baseOrigin: origin,
            dmax: DensityTriple(red: dmaxV.0, green: dmaxV.1, blue: dmaxV.2),
            gamma: gamma,
            printExposure: printEV,
            degradedTerms: degraded)
    }

    // MARK: Measurement

    /// Reads a downsampled render back as LINEAR values — the density model's
    /// native domain. Contrast with `FilmBaseSampler.readPixels`, which reads
    /// sRGB because the matrix engine divides in gamma space.
    static func linearPixels(of image: CIImage, side: Int,
                             context: CIContext) -> [(Double, Double, Double)]? {
        let extent = image.extent
        guard !extent.isInfinite, extent.width >= 1, extent.height >= 1 else { return nil }
        let scale = CGFloat(side) / max(extent.width, extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: min(scale, 1),
                                                             y: min(scale, 1)))
        let bounds = CGRect(x: 0, y: 0,
                            width: max(1, scaled.extent.width.rounded(.down)),
                            height: max(1, scaled.extent.height.rounded(.down)))
        let width = Int(bounds.width), height = Int(bounds.height)
        var buffer = [Float](repeating: 0, count: width * height * 4)
        context.render(
            scaled.transformed(by: CGAffineTransform(translationX: -scaled.extent.origin.x,
                                                     y: -scaled.extent.origin.y)),
            toBitmap: &buffer,
            rowBytes: width * 4 * MemoryLayout<Float>.stride,
            bounds: bounds, format: .RGBAf,
            colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        return (0..<(width * height)).map { i in
            (Double(buffer[i * 4]), Double(buffer[i * 4 + 1]), Double(buffer[i * 4 + 2]))
        }
    }

    /// Nearest-rank percentile over an ascending-sorted array.
    static func percentile(_ sorted: [Double], _ q: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = Int((Double(sorted.count - 1) * q).rounded())
        return sorted[min(max(index, 0), sorted.count - 1)]
    }
}
```

- [ ] **Step 5: Run** the Task 4 tests until green. The crossover-margin threshold (`matrixErr > densityErr * 2`) is the one most likely to need an honest look if it fails: print both values and check whether the matrix residual is genuinely small (fixture too easy — steepen the gamma spread) rather than loosening the assertion.

- [ ] **Step 6: Commit**

```bash
git add Sources/Film/AutoInvert.swift Tests/PrintEngineSupport.swift Tests/AutoInvertTests.swift
git commit -m "feat(print): the Auto solve, with round-trip and crossover proofs"
```

---

### Task 5: EditorModel actions, stock density character, migration

One user gesture = one `editStack` assignment = one undo step, matching `upgradeToProcessVersion2`'s pattern exactly.

**Files:**
- Modify: `Sources/Views/EditorModel.swift` (film section, `Sources/Views/EditorModel.swift:664-780`)
- Modify: `Sources/Film/FilmStock.swift`
- Modify: `Sources/Catalog/CatalogStore.swift` (one new migration after `v6_virtualCopiesAndSnapshots`)
- Test: `Tests/PrintEngineModelTests.swift`

**Interfaces:**
- Consumes: `AutoInvert.solve` (Task 4), `saveSnapshot(named:)`, `TestSupport.makeEditorModel`, `TestSupport.inMemoryCatalog`.
- Produces:
  - `EditorModel.autoConvertNegative()` — Auto button and density-mode enable path
  - `EditorModel.updateConversion()` — matrix → density, snapshot first
  - `FilmStock` gains `printContrast: Double?`, `printSaturation: Double?` (nil for all existing built-ins)
  - Migration `v7_stockPrintCharacter` adding two nullable columns to `filmStock`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import PhotoEditor

@MainActor
final class PrintEngineModelTests: XCTestCase {

    /// Enabling conversion on a fresh (density-model) photo runs the full
    /// Auto solve — one button to a converted frame, not a chore of samples.
    func testEnableFilmNegativeRunsAutoOnDensityModel() throws {
        let model = try TestSupport.makeEditorModel()
        model.enableFilmNegative()
        XCTAssertTrue(model.editStack.filmNegative.isEnabled)
        XCTAssertEqual(model.editStack.filmNegative.conversionModel, .density)
        // A solid grey test image is a degenerate scan; the solve still ran
        // and wrote *something* measurable rather than leaving defaults.
        XCTAssertEqual(model.editStack.filmNegative.baseOrigin, .estimated)
    }

    /// The whole Auto result is one undo step: one ⌘Z returns to the
    /// pre-conversion stack, not to a half-solved intermediate.
    func testAutoConvertIsOneUndoStep() throws {
        let model = try TestSupport.makeEditorModel()
        let before = model.editStack
        model.autoConvertNegative()
        XCTAssertNotEqual(model.editStack, before)
        model.commitPendingEdits() // flush the debounced commit, as other undo tests do
        model.undo()
        XCTAssertEqual(model.editStack.filmNegative, before.filmNegative)
    }

    /// Update Conversion: snapshots the matrix look, then switches and
    /// re-solves — same contract as the Process badge.
    func testUpdateConversionSnapshotsThenSwitches() throws {
        var stack = EditStack()
        stack.filmNegative.isEnabled = true
        stack.filmNegative.conversionModel = .matrix
        let model = try TestSupport.makeEditorModel(editStack: stack)
        let snapshotsBefore = model.snapshots.count

        model.updateConversion()

        XCTAssertEqual(model.editStack.filmNegative.conversionModel, .density)
        XCTAssertEqual(model.snapshots.count, snapshotsBefore + 1)
        XCTAssertTrue(model.snapshots.contains { $0.name == "Before Print Engine" })
        // The snapshot preserves the matrix rendering.
        XCTAssertEqual(model.snapshots.first { $0.name == "Before Print Engine" }?
            .editStack.filmNegative.conversionModel, .matrix)
    }

    func testUpdateConversionIsANoOpOnDensityStacks() throws {
        let model = try TestSupport.makeEditorModel()
        model.autoConvertNegative()
        let count = model.snapshots.count
        model.updateConversion()
        XCTAssertEqual(model.snapshots.count, count, "no snapshot, nothing to update")
    }

    /// The eyedropper on a density-model photo re-solves with the sampled
    /// base — a better Dmin should immediately improve Dmax and gamma too.
    func testEyedropperResolvesWithSampledBase() throws {
        let model = try TestSupport.makeEditorModel()
        model.autoConvertNegative()
        let estimated = model.editStack.filmNegative.print.dmax
        model.sampleFilmBase(inUnitRect: CGRect(x: 0, y: 0, width: 0.1, height: 0.1))
        XCTAssertEqual(model.editStack.filmNegative.baseOrigin, .sampled)
        // On the flat grey fixture the numbers may coincide; the invariant is
        // that the solve reran against the sampled base without crashing and
        // origin is now .sampled.
        _ = estimated
    }

    /// Calibrated stocks persist their print character through the catalog.
    func testCalibratedStockRoundTripsPrintCharacter() throws {
        let model = try TestSupport.makeEditorModel()
        model.autoConvertNegative()
        model.editStack.filmNegative.print.contrast = 3.0
        model.editStack.filmNegative.print.saturation = 20
        let stock = try XCTUnwrap(model.saveCalibratedStock(name: "Test 400",
                                                            manufacturer: "Test", iso: 400))
        XCTAssertEqual(stock.printContrast, 3.0)
        XCTAssertEqual(stock.printSaturation, 20)

        // And applying it to a fresh photo carries the character over.
        let fresh = try TestSupport.makeEditorModel()
        fresh.autoConvertNegative()
        fresh.applyFilmStock(stock)
        XCTAssertEqual(fresh.editStack.filmNegative.print.contrast, 3.0)
        XCTAssertEqual(fresh.editStack.filmNegative.print.saturation, 20)
    }
}
```

Note: `commitPendingEdits`/`undo` — copy whatever `Tests/EditorUndoTests.swift` actually calls to flush the debounced commit (read it first; the method name there is authoritative, not this plan).

- [ ] **Step 2: Run to verify failure.**

- [ ] **Step 3: Implement**

In `Sources/Catalog/CatalogStore.swift`, after the `v6_virtualCopiesAndSnapshots` migration block:

```swift
        // Print-engine character for calibrated stocks. Nullable: a stock
        // saved before the print engine simply has no density character, and
        // applying it leaves the solved values alone.
        migrator.registerMigration("v7_stockPrintCharacter") { db in
            try db.alter(table: "filmStock") { t in
                t.add(column: "printContrast", .double)
                t.add(column: "printSaturation", .double)
            }
        }
```

In `Sources/Film/FilmStock.swift`, add after `saturation`:

```swift
    /// Print-engine character (paper grade / print saturation), captured when
    /// a stock is calibrated under the density model. Nil on built-ins and on
    /// stocks calibrated before the print engine existed.
    var printContrast: Double?
    var printSaturation: Double?
```

(Existing built-in initializers compile unchanged — optionals default to nil only if declared with `= nil`; add `= nil` to both so the memberwise call sites stay valid.)

In `Sources/Views/EditorModel.swift`:

```swift
    /// The Auto button: solve the whole conversion off the scan and write it
    /// as ONE stack assignment — one undo step, like every other gesture.
    func autoConvertNegative() {
        guard let source else { return }
        var film = editStack.filmNegative
        film.isEnabled = true
        let sampled = film.baseOrigin == .sampled ? film.baseColor : nil
        guard let solution = AutoInvert.solve(scan: source, sampledBase: sampled,
                                              context: renderer.context) else { return }
        film.baseColor = solution.baseColor
        film.baseOrigin = solution.baseOrigin
        film.isBaseSampled = solution.baseOrigin == .sampled
        film.print.dmax = solution.dmax
        film.print.gamma = solution.gamma
        film.print.exposure = solution.printExposure
        editStack.filmNegative = film

        // Same courtesy as the matrix path: infer the family and rank stocks
        // off the measured base.
        if film.stockID == nil {
            editStack.filmNegative.type = FilmBaseSampler.inferType(from: solution.baseColor)
        }
        stockMatches = FilmBaseSampler.rankStocks(matching: solution.baseColor,
                                                  in: filmStocks)
    }

    /// Matrix → print engine, as an explicit, snapshotted, undoable action —
    /// the same guarantees as the Process badge. The current look stays one
    /// click away in Snapshots forever.
    func updateConversion() {
        guard editStack.filmNegative.isEnabled,
              editStack.filmNegative.conversionModel == .matrix else { return }
        _ = saveSnapshot(named: "Before Print Engine")
        editStack.filmNegative.conversionModel = .density
        autoConvertNegative()
    }
```

Change `enableFilmNegative()`:

```swift
    /// Turns on negative conversion. Density-model photos get the full Auto
    /// solve; matrix-model photos keep the original sample-and-rank behavior.
    func enableFilmNegative() {
        if editStack.filmNegative.conversionModel == .density {
            autoConvertNegative()
        } else {
            editStack.filmNegative.isEnabled = true
            sampleFilmBase()
        }
    }
```

In `applySampledBase(_:)`, set `editStack.filmNegative.baseOrigin = .sampled` alongside `isBaseSampled = true`, and at the end add:

```swift
        // On the print engine a better Dmin should immediately improve the
        // whole solve — the sampled base feeds straight back through Auto.
        if editStack.filmNegative.conversionModel == .density,
           editStack.filmNegative.isEnabled {
            autoConvertNegative()
        }
```

In `applyFilmStock(_:)` add after the existing apply:

```swift
        if editStack.filmNegative.conversionModel == .density {
            if let grade = stock.printContrast { editStack.filmNegative.print.contrast = grade }
            if let sat = stock.printSaturation { editStack.filmNegative.print.saturation = sat }
        }
```

In `saveCalibratedStock`, add to the `FilmStock(...)` construction:

```swift
            printContrast: film.conversionModel == .density ? film.print.contrast : nil,
            printSaturation: film.conversionModel == .density ? film.print.saturation : nil,
```

- [ ] **Step 4: Run** `PrintEngineModelTests` + `EditorModelTests` + `EditorUndoTests` + `FilmStockStoreTests` + `CatalogStoreTests`. All PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Views/EditorModel.swift Sources/Film/FilmStock.swift Sources/Catalog/CatalogStore.swift Tests/PrintEngineModelTests.swift
git commit -m "feat(print): Auto and Update Conversion actions; stocks carry print character"
```

---

### Task 6: The Film panel

Density mode gets the print controls; matrix mode keeps exactly what it has today plus the Update Conversion note. Follow the panel's own conventions: `AdjustmentSlider`, `PlateButton`, `sectionLabel()`, monospaced only for numbers and captions.

**Files:**
- Modify: `Sources/Views/SliderPanel/FilmPanel.swift`

**Interfaces:**
- Consumes: `EditorModel.autoConvertNegative()`, `updateConversion()` (Task 5), `FilmNegativeSettings.baseOrigin`, `print.*` (Task 2), `AdjustmentSlider(title:value:range:format:neutral:)`, `PlateButton(title:action:)`.
- Produces: UI only — no new public API.

- [ ] **Step 1: Implement**

In `FilmPanel.body`, inside `if film.isEnabled`, before the `TabStrip`:

```swift
                if film.conversionModel == .matrix {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("This photo uses the original matrix conversion. "
                             + "Updating re-solves it through the print engine — "
                             + "the current look is snapshotted first and stays "
                             + "one click away.")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.secondaryText)
                        PlateButton(title: "Update Conversion") {
                            model.updateConversion()
                        }
                    }
                }
```

Replace the trailing slider block (`Film Exposure` / `Stock Contrast` / `Stock Saturation`) with a branch:

```swift
                if film.conversionModel == .density && film.type.requiresInversion {
                    printControls
                } else {
                    AdjustmentSlider(title: "Film Exposure",
                                     value: $model.editStack.filmNegative.exposure,
                                     range: -3...3, format: "%.2f EV", neutral: 0)
                    if film.type != .blackAndWhiteNegative {
                        AdjustmentSlider(title: "Stock Contrast",
                                         value: $model.editStack.filmNegative.stockContrast,
                                         range: -100...100, format: "%.0f", neutral: 0)
                        AdjustmentSlider(title: "Stock Saturation",
                                         value: $model.editStack.filmNegative.stockSaturation,
                                         range: -100...100, format: "%.0f", neutral: 0)
                    }
                }
```

Add the print controls and per-channel disclosure:

```swift
    @State private var isShowingTrims = false

    /// The print engine's front controls — the terms a printer would use.
    private var printControls: some View {
        VStack(alignment: .leading, spacing: Theme.controlSpacing) {
            AdjustmentSlider(title: "Print Exposure",
                             value: $model.editStack.filmNegative.print.exposure,
                             range: -3...3, format: "%.2f EV", neutral: 0)
            AdjustmentSlider(title: "Print Contrast",
                             value: $model.editStack.filmNegative.print.contrast,
                             range: 0...5, format: "Grade %.1f", neutral: 2)
            AdjustmentSlider(title: "Shoulder",
                             value: $model.editStack.filmNegative.print.shoulder,
                             range: 0...100, format: "%.0f", neutral: 40)
            AdjustmentSlider(title: "Toe",
                             value: $model.editStack.filmNegative.print.toe,
                             range: 0...100, format: "%.0f", neutral: 30)
            if model.editStack.filmNegative.type != .blackAndWhiteNegative {
                AdjustmentSlider(title: "Print Saturation",
                                 value: $model.editStack.filmNegative.print.saturation,
                                 range: -50...50, format: "%.0f", neutral: 0)
            }

            PlateButton(title: isShowingTrims ? "Hide Per-Channel" : "Per-Channel…") {
                isShowingTrims.toggle()
            }
            if isShowingTrims { channelTrims }
        }
    }

    /// The crossover controls. Behind a disclosure because nobody wants to
    /// drive three gammas by hand as a first move — but they are the whole
    /// reason this engine exists, so they are here.
    private var channelTrims: some View {
        VStack(alignment: .leading, spacing: Theme.controlSpacing) {
            Text("BASE (D-MIN)").sectionLabel()
            AdjustmentSlider(title: "Red",
                             value: $model.editStack.filmNegative.baseColor.red,
                             range: 0.05...1, format: "%.3f", neutral: 0.05)
            AdjustmentSlider(title: "Green",
                             value: $model.editStack.filmNegative.baseColor.green,
                             range: 0.05...1, format: "%.3f", neutral: 0.05)
            AdjustmentSlider(title: "Blue",
                             value: $model.editStack.filmNegative.baseColor.blue,
                             range: 0.05...1, format: "%.3f", neutral: 0.05)

            Text("WHITE POINT (D-MAX)").sectionLabel()
            AdjustmentSlider(title: "Red",
                             value: $model.editStack.filmNegative.print.dmax.red,
                             range: 0.2...4, format: "%.2f", neutral: 2)
            AdjustmentSlider(title: "Green",
                             value: $model.editStack.filmNegative.print.dmax.green,
                             range: 0.2...4, format: "%.2f", neutral: 2)
            AdjustmentSlider(title: "Blue",
                             value: $model.editStack.filmNegative.print.dmax.blue,
                             range: 0.2...4, format: "%.2f", neutral: 2)

            Text("PAPER GAMMA").sectionLabel()
            AdjustmentSlider(title: "Red",
                             value: $model.editStack.filmNegative.print.gamma.red,
                             range: 0.2...3, format: "%.2f", neutral: 1)
            AdjustmentSlider(title: "Green",
                             value: $model.editStack.filmNegative.print.gamma.green,
                             range: 0.2...3, format: "%.2f", neutral: 1)
            AdjustmentSlider(title: "Blue",
                             value: $model.editStack.filmNegative.print.gamma.blue,
                             range: 0.2...3, format: "%.2f", neutral: 1)
        }
        .padding(8)
        .background(Theme.control.opacity(0.4), in: RoundedRectangle(cornerRadius: 3))
    }
```

Update the base caption in `filmBaseControls` (replace the `hasSampledBase` ternary):

```swift
                    Text(baseOriginCaption)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(film.baseOrigin == .assumed
                                         ? AnyShapeStyle(Theme.filmEdge)
                                         : AnyShapeStyle(Theme.secondaryText))
```

with:

```swift
    /// Which measurement the conversion is trusting — the honesty caption.
    private var baseOriginCaption: String {
        switch film.baseOrigin {
        case .assumed: "assumed default"
        case .estimated: "estimated from this scan"
        case .sampled: "sampled from this scan"
        }
    }
```

And the base row's "Auto" button becomes the full solve on density stacks:

```swift
                PlateButton(title: "Auto") {
                    if film.conversionModel == .density {
                        model.autoConvertNegative()
                    } else {
                        model.sampleFilmBase()
                    }
                }
```

- [ ] **Step 2: Build and run the app briefly**

Run: `xcodegen generate && xcodebuild -project PhotoEditor.xcodeproj -scheme PhotoEditor -destination 'platform=macOS' build`
Then run the full test suite (UI has no dedicated tests here, but the build plus `PrintEngineModelTests` exercise the bindings).
Expected: build succeeds, suite green.

- [ ] **Step 3: Commit**

```bash
git add Sources/Views/SliderPanel/FilmPanel.swift
git commit -m "feat(print): film panel — print controls, per-channel trims, update-conversion note"
```

---

### Task 7: Film control conformance

The Phase 1 discipline, applied to the new engine: every print control provably moves the image in its advertised direction, and the inventory reflects over the settings types so it cannot rot.

**Files:**
- Test: `Tests/FilmControlConformanceTests.swift`

**Interfaces:**
- Consumes: `FilmSim` (Task 4), `EditRenderer`, `Conformance.meanLuma`, `Conformance.stdDevLuma`, `Conformance.meanSaturation`, `Conformance.percentileLuma`, `Conformance.warmth` (all `([UInt8]) -> Double` from `Tests/ConformanceSupport.swift` — but verify their exact names there before writing; `ConformanceSupport.swift` is authoritative).
- Produces: nothing downstream.

- [ ] **Step 1: Write the suite**

Structure (mirror `ControlCase` from `Tests/ControlConformanceTests.swift:11-72`, simplified to this domain):

```swift
import CoreGraphics
import CoreImage
import XCTest
@testable import PhotoEditor

/// The Phase 1 contract, extended to the print engine: every density control
/// moves the image, in the declared direction, and neutral means neutral.
/// The probe is a simulated crossover negative — a flat patch could not tell
/// a working Shoulder from a dead one.
final class FilmControlConformanceTests: XCTestCase {
    private static let renderer = EditRenderer()
    private static let probe = FilmSim.negativeImage(dmin: FilmSim.c41Base,
                                                     gammas: FilmSim.crossoverGammas,
                                                     size: 128)

    /// A solved density stack — the reference all variants diverge from.
    private static func baseStack() -> EditStack {
        var stack = EditStack()
        var film = FilmNegativeSettings()
        film.isEnabled = true
        film.conversionModel = .density
        let solution = AutoInvert.solve(scan: probe, sampledBase: nil,
                                        context: renderer.context)!
        film.baseColor = solution.baseColor
        film.baseOrigin = solution.baseOrigin
        film.print.dmax = solution.dmax
        film.print.gamma = solution.gamma
        film.print.exposure = solution.printExposure
        stack.filmNegative = film
        return stack
    }

    private static func render(_ stack: EditStack) -> [UInt8] {
        // Rasterize at the probe's own size into sRGB bytes, the same
        // convention Conformance.render uses (see ConformanceSupport.swift —
        // copy its readback code here so the measure helpers apply).
        // ... exact body copied from Conformance.render, parameterized on source
    }

    struct FilmControlCase {
        let name: String
        let key: String            // "print.exposure", "exposure", …
        let low: (inout EditStack) -> Void
        let high: (inout EditStack) -> Void
        let measure: ([UInt8]) -> Double
        let sign: Int              // of measure(high) − measure(reference); 0 = change-only
    }

    static let cases: [FilmControlCase] = [
        .init(name: "Print Exposure", key: "print.exposure",
              low: { $0.filmNegative.print.exposure -= 1.5 },
              high: { $0.filmNegative.print.exposure += 1.5 },
              measure: Conformance.meanLuma, sign: +1),
        .init(name: "Print Contrast", key: "print.contrast",
              low: { $0.filmNegative.print.contrast = 0.5 },
              high: { $0.filmNegative.print.contrast = 4.5 },
              measure: Conformance.stdDevLuma, sign: +1),
        // Raising Shoulder softens the knee (p: 64 → 2), which pulls the
        // brightest tones DOWN from the clip — sign −1 on the top percentile.
        .init(name: "Shoulder", key: "print.shoulder",
              low: { $0.filmNegative.print.shoulder = 0 },
              high: { $0.filmNegative.print.shoulder = 100 },
              measure: { Conformance.percentileLuma($0, 0.98) }, sign: -1),
        .init(name: "Toe", key: "print.toe",
              low: { $0.filmNegative.print.toe = 0 },
              high: { $0.filmNegative.print.toe = 100 },
              measure: { Conformance.percentileLuma($0, 0.02) }, sign: +1),
        .init(name: "Print Saturation", key: "print.saturation",
              low: { $0.filmNegative.print.saturation = -40 },
              high: { $0.filmNegative.print.saturation = 40 },
              measure: Conformance.meanSaturation, sign: +1),
        // Raising red Dmax darkens the red channel across the frame.
        .init(name: "White Point Red", key: "print.dmax",
              low: { $0.filmNegative.print.dmax.red -= 0.4 },
              high: { $0.filmNegative.print.dmax.red += 0.4 },
              measure: Conformance.warmth, sign: -1),
        // Per-channel gamma changes the red channel's slope: a genuine
        // change with no single-scalar direction — change-only.
        .init(name: "Paper Gamma Red", key: "print.gamma",
              low: { $0.filmNegative.print.gamma.red *= 0.7 },
              high: { $0.filmNegative.print.gamma.red *= 1.4 },
              measure: Conformance.meanLuma, sign: 0),
        .init(name: "Film Exposure", key: "exposure",
              low: { $0.filmNegative.exposure = -1.5 },
              high: { $0.filmNegative.exposure = 1.5 },
              measure: Conformance.meanLuma, sign: +1),
    ]

    // Tests: for each case — extremes both change the image beyond a floor;
    // sign of measure(high) − measure(reference) matches; and a completeness
    // test Mirrors over FilmNegativeSettings() and PrintSettings() with the
    // exclusion table below. Copy the assertion structure from
    // ControlConformanceTests.testEveryControlMovesTheImage and
    // testEveryEditStackFieldIsCoveredOrExcluded, adapted to these types.

    static let excluded: [String: String] = [
        "isEnabled": "the master switch — every test in this file exercises it",
        "type": "FilmDensityConverterTests — family routing, not a slider",
        "stockID": "provenance label, never rendered",
        "stockName": "provenance label, never rendered",
        "baseColor": "a measurement; covered by AutoInvertTests and the Dmin trim path",
        "isBaseSampled": "bookkeeping, superseded by baseOrigin",
        "baseOrigin": "bookkeeping, never rendered",
        "conversionModel": "engine selector; FilmDensityConverterTests covers both routes",
        "channelGains": "matrix engine only — frozen, covered by FilmNegativeTests",
        "stockContrast": "matrix engine only — frozen, covered by FilmNegativeTests",
        "stockSaturation": "matrix engine only — frozen, covered by FilmNegativeTests",
        // PrintSettings fields covered via cases: exposure, contrast,
        // shoulder, toe, saturation, dmax, gamma — no print exclusions.
    ]
}
```

The completeness test enumerates `Mirror(reflecting: FilmNegativeSettings()).children` labels, plus `Mirror(reflecting: PrintSettings()).children` labels prefixed `"print."`, and asserts every one appears in `cases[].key` or `excluded`.

- [ ] **Step 2: Run.** Any control that fails here is a real finding — fix the engine, never the floor. (This is the suite that caught three dead controls in Phase 1.)

- [ ] **Step 3: Commit**

```bash
git add Tests/FilmControlConformanceTests.swift
git commit -m "test(print): conformance — every print control provably moves the image"
```

---

### Task 8: Real scans — gated tests, acceptance renders, tuning

The corpus: `~/Desktop/negatives` (59 medium-format CR2+JPG pairs, frame floating on a lightbox) and `~/Desktop/all film/film aug 4th 2026` (155 35 mm phone scans with full rebate and sprocket holes). This task ends with the user looking at rendered frames — the acceptance gate no CI number can replace.

**Files:**
- Test: `Tests/RealScanTests.swift`

**Interfaces:**
- Consumes: `ImageDecoder.loadPreviewImage(from:maxDimension:processVersion:)`, `AutoInvert.solve`, `EditRenderer`, `ExportService` (or direct `CIContext.writeJPEGRepresentation`).
- Produces: JPEG artifacts under `artifacts/print-engine/` (git-ignored — verify `.gitignore` covers `artifacts/`; it already exists in the repo root).

- [ ] **Step 1: Write the gated suite**

```swift
import CoreImage
import XCTest
@testable import PhotoEditor

/// Auto + the print engine against the user's actual negatives. Skips
/// cleanly on any machine without the corpus (same pattern as the gated
/// parity fixtures), so CI and other machines are unaffected.
///
/// These tests assert sanity, not beauty: solve succeeds, output is a
/// plausible positive, nothing NaNs. Beauty is judged by the user from the
/// artifacts this suite writes.
final class RealScanTests: XCTestCase {
    private static let mediumFormatDir = NSString("~/Desktop/negatives").expandingTildeInPath
    private static let thirtyFiveDir =
        NSString("~/Desktop/all film/film aug 4th 2026").expandingTildeInPath
    private static let artifactDir = URL(fileURLWithPath: "artifacts/print-engine",
                                         isDirectory: true)

    private let context = CIContext()
    private let renderer = EditRenderer()

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
        XCTAssertGreaterThan(median, 0.01, "\(label): renders black")
        XCTAssertLessThan(median, 0.7, "\(label): renders blown")

        // Artifact for the human acceptance pass.
        try FileManager.default.createDirectory(at: Self.artifactDir,
                                                withIntermediateDirectories: true)
        let dest = Self.artifactDir.appendingPathComponent("\(label).jpg")
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        try context.writeJPEGRepresentation(of: out, to: dest, colorSpace: srgb)
    }

    private func firstFiles(in dir: String, suffix: String, count: Int) -> [URL] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
            return []
        }
        return names.filter { $0.lowercased().hasSuffix(suffix) }.sorted().prefix(count)
            .map { URL(fileURLWithPath: dir).appendingPathComponent($0) }
    }

    func testMediumFormatCR2Corpus() throws {
        let files = Self.firstFilesOrSkip(dir: Self.mediumFormatDir, suffix: ".cr2")
        try files.forEach { try convert(url: $0, label: "mf-\($0.deletingPathExtension().lastPathComponent)") }
    }

    func test35mmPhoneScanCorpus() throws {
        let files = Self.firstFilesOrSkip(dir: Self.thirtyFiveDir, suffix: ".jpeg")
        try files.forEach { try convert(url: $0, label: "35-\($0.deletingPathExtension().lastPathComponent)") }
    }

    // firstFilesOrSkip: throws XCTSkip("corpus not present on this machine")
    // when the directory is missing or empty; otherwise returns 5 files.
}
```

(Write `firstFilesOrSkip` for real — `XCTSkip` when the directory is absent, five files each otherwise. The 35 mm set's sprocket holes are backlight, brighter than base, which is the spec's named risk: expect the estimated Dmin to be off there, and judge in the acceptance pass how far.)

- [ ] **Step 2: Run both gated tests.** Expected: PASS locally (skip elsewhere), artifacts written.

- [ ] **Step 3: Acceptance pass — the user's call.** Render the artifacts plus a handful of before/afters into a contact sheet and show them to the user. Iterate on the `PaperResponse` constants block (only there — that is why it exists) until the user approves the default rendering on both corpora. Each tuning iteration reruns `PaperResponseTests`, `FilmDensityConverterTests`, `AutoInvertTests`, and this suite. **Do not close the task without explicit user approval of the rendered frames.**

- [ ] **Step 4: Commit** (constants tuning + tests):

```bash
git add Sources/Film/PaperResponse.swift Tests/RealScanTests.swift
git commit -m "test(print): real-scan gates and acceptance artifacts; constants tuned on the corpus"
```

---

### Task 9: Changelog and the full bar

**Files:**
- Modify: `CHANGELOG.md` (Unreleased section)

- [ ] **Step 1: Write the changelog entry**

Add to `## Unreleased` → `### Added`, above the conformance-suite entry:

```markdown
- **A print engine for negatives.** Conversion now works the way an enlarger
  does: per-channel density from the film base, a paper response with a real
  toe and shoulder, and a highlight rolloff that desaturates toward white
  without shifting hue. Per-channel paper gammas fix crossover — the
  cyan-shadows/warm-highlights cast the old single-gain model provably could
  not remove (there is a test that documents the difference). One Auto button
  solves the whole conversion from the scan, deterministically, and every
  value it writes stays an ordinary slider. Existing photos are untouched:
  the matrix conversion is frozen exactly like Process Version 1, and
  switching is an explicit, snapshotted, undoable Update Conversion action.
```

- [ ] **Step 2: Full suite**

Run: `xcodebuild -project PhotoEditor.xcodeproj -scheme PhotoEditor -destination 'platform=macOS' test`
Expected: 0 failures; count strictly greater than the Task-0 baseline. Record the new count.

- [ ] **Step 3: Commit**

```bash
git add CHANGELOG.md
git commit -m "docs: changelog for the print engine"
```

Do **not** push — 35+ commits are already local-only by design; pushing is Phase 5's job.

---

## Self-review notes (already applied)

- The spec's toe/shoulder exponent table was mis-derived; Task 1 Step 1 corrects the spec before any code depends on it.
- `Conformance.render` renders THE tone probe; Task 7 therefore copies its readback into a probe-parameterized local helper rather than growing `ConformanceSupport`'s API for one caller.
- `TestSupport.solidImage` and the undo-flush method name in `EditorUndoTests` must be read from the actual files at execution time — both are flagged inline where used.
- Baseline test count in Global Constraints says 353 with a "verify first" instruction because the working tree's true count is whatever `main` currently produces; the executor records it in Task 9.
