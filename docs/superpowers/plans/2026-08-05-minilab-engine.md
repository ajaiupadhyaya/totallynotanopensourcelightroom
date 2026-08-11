# The Minilab Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the density-engine negative conversion render like a finished lab scan (tone profiles + auto-toning), give it working cast-removal tools, and make frames of one roll convert consistently (roll-level analysis) — while every existing photo renders bit-identically.

**Architecture:** No third conversion engine. `PrintSettings` grows new fields whose decode-defaults are mathematical identities (`renderVersion` decodes 1 / initializes 2 — the `conversionModel` asymmetric-default trick), the one-pass `film_density_print` kernel grows matching parameters that are exact no-ops at neutral, and `AutoInvert` splits into measure/solve so a new `RollAnalysis` can aggregate per-frame measurements into roll-level constants (per-channel Dmin + gamma) with only print EV solved per frame. Spec: `docs/superpowers/specs/2026-08-05-minilab-engine-design.md`.

**Tech Stack:** Swift 5 / SwiftUI, Core Image (`CIColorKernel` in `Sources/Pipeline/Kernels/Film.ci.metal`, compiled at build time via `-fcikernel`), GRDB/SQLite catalog, XcodeGen, XCTest.

## Global Constraints

- **XcodeGen owns the project.** After creating or deleting ANY source/test file, run `xcodegen generate` before building. `project.yml` is the source of truth.
- **Build/test command** (from repo root `~/Documents/totallynotanopensourcelightroom`):
  `xcodebuild -project PhotoEditor.xcodeproj -scheme PhotoEditor -destination 'platform=macOS' -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO test -only-testing:PhotoEditorTests/<ClassName>`
  Run **scoped** (`-only-testing:`) per step; run the full suite (drop `-only-testing:`) at most once per task — repeated consecutive full runs can exhaust GPU/XPC services. First full run after touching `.ci.metal` files can take minutes (cold Metal shader cache).
- **`PaperResponse.swift` and `Film.ci.metal` change in lockstep** — `FilmDensityConverterTests.testKernelAgreesWithTheSwiftModel` is the contract. `max3` is unavailable in this Metal environment (use `max(x, max(y, z))`); sRGB helpers stay duplicated per `.ci.metal` translation unit.
- **Every new persisted field decodes leniently** (`c.lenient(.key, fallback)` — see `Sources/Models/LenientDecoding.swift`) with a fallback that reproduces pre-change rendering.
- **Every new stored property of `FilmNegativeSettings` or `PrintSettings`** must get a `FilmControlCase` row or an explicit exclusion in `Tests/FilmControlConformanceTests.swift` — the reflection completeness test fails the build otherwise. Signs are MEASURED against the renderer before being declared (house discipline; see that file's block comment).
- **Frozen forever:** the `.matrix` engine, PV1 (`LegacyToneRenderer`), and now `renderVersion` 1 density output (enforced by the Task 1 goldens). Never edit frozen paths.
- **`editStack` gestures are single-assignment:** build all mutations on a local `var`, write `editStack.filmNegative` (or `editStack`) exactly once — one undo step, one render (`EditorModel.autoConvertNegative` is the reference pattern).
- **The persisted film base color is display-encoded sRGB** (shared with the matrix engine, swatch, eyedropper); the density engine linearizes at its boundary via `PaperResponse.srgbDecode`. Solved bases are re-encoded via `srgbEncode` before storing.
- **Corpus-dependent tests gate with `XCTSkip`** (pattern: `RealScanTests.firstFilesOrSkip`). Corpora: `~/Desktop/negatives` (59 CR2 6×6) and `~/Desktop/all film/film aug 4th 2026` (155 35mm JPEGs).
- **Commit per task**, message style `feat(film): …` / `test(film): …`; the PreToolUse hook enforces the noreply git author — fix repo config, never route around it.
- SWIFT_VERSION is pinned 5.0; add **no** dependencies.
- Panel copy follows the house voice: monospace only for measured values; honesty captions state provenance.

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `Sources/Film/PaperResponse.swift` | modify | All new curve math + named taste constants + slider→amount mappings |
| `Sources/Pipeline/Kernels/Film.ci.metal` | modify | GPU mirror of the above |
| `Sources/Film/PrintSettings.swift` | modify | `FilmToneProfile`, `renderVersion`, toning/cast/trim fields, profile application |
| `Sources/Film/FilmDensityConverter.swift` | modify | CPU-side folds (cast, grade pivot, legacy EV, balanced tint) + kernel marshaling |
| `Sources/Film/AutoInvert.swift` | modify | measure/solve split, profile-aware solve, auto colour balance, `gradePivot` |
| `Sources/Film/CastSolver.swift` | create | Closed-form neutral-picker / auto-WB cast math (pure) |
| `Sources/Film/RollAnalysis.swift` | create | Roll-level constant solve from pooled frame measurements (pure) |
| `Sources/Models/Roll.swift` | create | `Roll` GRDB record + `RollConversion` Codable |
| `Sources/Catalog/CatalogStore.swift` | modify | Migration `v8_rolls`, roll CRUD, entry↔roll assignment |
| `Sources/Models/CatalogEntry.swift` | modify | `rollID`, `frameNumber` |
| `Sources/Views/RollModel.swift` | create | Roll actions (create/assign/convert) — kept out of the 1174-line EditorModel |
| `Sources/Views/EditorModel.swift` | modify | Profile apply, neutral-cast picker, roll-aware Auto |
| `Sources/Views/SliderPanel/FilmPanel.swift` | modify | Profile strip, Punch/Fade/Glow, cast group, zone trims |
| `Sources/Views/CanvasArea.swift` | modify | Picker prompt for the neutral-cast eyedropper |
| `Sources/Views/LibrarySidebar.swift` | modify | Roll context-menu items + roll edge print |
| `Sources/App/EditorCommands.swift` | modify | Menu-bar entries for roll actions |
| `Tests/PaperResponseGoldenTests.swift` | create | Task 1 bit-stability goldens |
| `Tests/Fixtures/Golden/*.json` | create | Committed golden recordings |
| `Tests/CastSolverTests.swift` | create | Cast math + injected-cast neutralization |
| `Tests/RollAnalysisTests.swift` | create | Synthetic-roll consistency proofs |
| `Tests/RollModelTests.swift` | create | Catalog-integration roll workflow |
| `Tests/NegadoctorReferenceTests.swift` | create | Gated darktable-cli reference renders |
| `Tests/RollConsistencyTests.swift` | create | Gated real-corpus variance metric |
| existing test files | modify | `PrintSettingsTests`, `FilmDensityConverterTests`, `FilmControlConformanceTests`, `AutoInvertTests`, `CatalogStoreTests`, `RealScanTests` |

---

### Task 1: Golden bit-stability tests (the safety net)

Record today's rendering — pure-Swift math lattice AND an end-to-end kernel ramp — **before any math changes**. Every later task keeps these green, which is the executable form of "existing photos render identically."

**Files:**
- Create: `Tests/PaperResponseGoldenTests.swift`
- Create (recorded): `Tests/Fixtures/Golden/paper-response-lattice.json`, `Tests/Fixtures/Golden/density-render-ramp.json`

**Interfaces:**
- Consumes: `PaperResponse.develop(_:dminLinear:dmax:gammaEffective:printOffset:p:q:satScale:)`, `FilmDensityConverter.convert(_:settings:)` exactly as they exist at `db28ada`/`7b4f677`.
- Produces: two committed JSON fixtures + a test class later tasks must keep green. Later tasks call `develop()` with new **defaulted** parameters, so these call sites never change.

- [x] **Step 1: Write the golden test class (record-or-assert)**

```swift
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
```

Note the ramp stack carries nonzero `exposure` (legacy EV) and non-default `print` values on purpose: it freezes exactly the semantics Task 5 changes for renderVersion **2**, proving v1 keeps them.

- [x] **Step 2: Add the file to the project and record**

Run: `xcodegen generate`
Run: `TEST_RUNNER_GOLDEN_RECORD=1 xcodebuild -project PhotoEditor.xcodeproj -scheme PhotoEditor -destination 'platform=macOS' -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO test -only-testing:PhotoEditorTests/PaperResponseGoldenTests`
Expected: both tests SKIP with "recorded … commit the fixture"; two JSON files appear under `Tests/Fixtures/Golden/`.

- [x] **Step 3: Re-run in assert mode to verify green**

Run: same command without `TEST_RUNNER_GOLDEN_RECORD=1`.
Expected: PASS (2 tests).

- [x] **Step 4: Verify the goldens actually bite**

Temporarily change `PaperResponse.shoulderStart` from `0.75` to `0.76`, re-run the class. Expected: `testSwiftModelMatchesTheGoldenLattice` FAILS. Revert the constant, re-run. Expected: PASS. (Do not skip this — an unfalsifiable golden is decoration.)

- [x] **Step 5: Commit**

```bash
git add Tests/PaperResponseGoldenTests.swift Tests/Fixtures/Golden project.yml PhotoEditor.xcodeproj
git commit -m "test(film): golden bit-stability contract for the renderVersion 1 print engine"
```

---

### Task 2: PaperResponse math extensions (pure Swift, defaulted-neutral)

Add the new curve math to the Swift model only, as **defaulted parameters** that are exact identities at their defaults — old call sites (including Task 1's goldens and `AutoInvert`) compile unchanged and produce bit-identical output.

**Files:**
- Modify: `Sources/Film/PaperResponse.swift`
- Test: `Tests/PaperResponseTests.swift` (append)

**Interfaces:**
- Produces (Task 3/4/5/6 rely on these exact names):
  - Constants: `punchFullScale = 1.0`, `fadeFullScale = 0.06`, `glowFullScale = 0.06`, `toeChromaFull = 0.9`, `toeStart = 0.02`, `toeEnd = 0.10`, `zoneShadowEnd = 0.15`, `zoneShadowFade = 0.45`, `zoneHighStart = 0.55`, `zoneHighFull = 0.85`, `castFullScaleEV = 0.5`, `zoneTrimFullScaleEV = 0.25`
  - Mappings: `punchAmount(_:)`, `fadeLift(_:)`, `glowDrop(_:)`, `toeChromaWeight(_:)`, `castDensity(_:)`, `zoneTrimDensity(_:)` (each `(Double) -> Double`, slider −100/0…100 in, amount out)
  - `printOffsets(exposureEV:warmth:tint:balancedTint:)` — new `balancedTint: Bool = false` parameter
  - `develop(...)` gains defaulted params: `shadowTrim/midTrim/highTrim: (Double, Double, Double) = (0, 0, 0)` (pre-folded log-domain offsets, see Task 4), `punch/fade/glow/toeChroma: Double = 0` (amounts, not sliders)

- [x] **Step 1: Write failing tests for the new math**

Append to `Tests/PaperResponseTests.swift`:

```swift
// MARK: Minilab extensions (Task 2)

/// Every new develop() parameter at its default is an exact no-op — the
/// same outputs as the pre-Minilab model, to the double's last bit. This is
/// what lets renderVersion 1 photos keep their rendering through shared code.
func testNewParametersDefaultToExactIdentity() {
    let dmin = (0.55, 0.30, 0.13)
    for i in 0...60 {
        let d = Double(i) / 20.0
        let t = (dmin.0 * pow(10, -d), dmin.1 * pow(10, -d * 1.1), dmin.2 * pow(10, -d * 0.9))
        let g = log10(PaperResponse.targetBlack) / -2.0
        let a = PaperResponse.develop(t, dminLinear: dmin, dmax: (2, 2, 2),
                                      gammaEffective: (g, g, g),
                                      printOffset: (0.05, 0.02, -0.03),
                                      p: 16, q: 204, satScale: 1.12)
        let b = PaperResponse.develop(t, dminLinear: dmin, dmax: (2, 2, 2),
                                      gammaEffective: (g, g, g),
                                      printOffset: (0.05, 0.02, -0.03),
                                      p: 16, q: 204, satScale: 1.12,
                                      shadowTrim: (0, 0, 0), midTrim: (0, 0, 0),
                                      highTrim: (0, 0, 0),
                                      punch: 0, fade: 0, glow: 0, toeChroma: 0)
        XCTAssertEqual(a.0, b.0); XCTAssertEqual(a.1, b.1); XCTAssertEqual(a.2, b.2)
    }
}

/// The punch S-curve is monotone at full strength (punchFullScale = 1.0 was
/// chosen for exactly this margin: the cubic's worst slope is 1 − a·0.82).
func testPunchStaysMonotoneAtFullStrength() {
    let g = log10(PaperResponse.targetBlack) / -2.0
    var last = -Double.infinity
    for i in 0...4000 {
        let d = Double(i) / 4000.0 * 3.0
        let t = 0.55 * pow(10, -d)
        let out = PaperResponse.develop((t, t, t), dminLinear: (0.55, 0.55, 0.55),
                                        dmax: (2, 2, 2), gammaEffective: (g, g, g),
                                        printOffset: (0, 0, 0), p: 16, q: 204,
                                        satScale: 1.0,
                                        punch: PaperResponse.punchAmount(100)).0
        XCTAssertGreaterThanOrEqual(out, last - 1e-12,
                                    "punch made the curve non-monotone at density \(d)")
        last = out
    }
}

/// Fade raises paper black; glow lowers paper white; both leave the map
/// monotone and strictly below 1.
func testFadeAndGlowMoveTheEndpoints() {
    let g = log10(PaperResponse.targetBlack) / -2.0
    func out(_ density: Double, fade: Double, glow: Double) -> Double {
        let t = 0.55 * pow(10, -density)
        return PaperResponse.develop((t, t, t), dminLinear: (0.55, 0.55, 0.55),
                                     dmax: (2, 2, 2), gammaEffective: (g, g, g),
                                     printOffset: (0, 0, 0), p: 16, q: 204,
                                     satScale: 1.0, fade: fade, glow: glow).0
    }
    let fadeAmount = PaperResponse.fadeLift(100)
    XCTAssertGreaterThan(out(0, fade: fadeAmount, glow: 0), out(0, fade: 0, glow: 0),
                         "fade must lift the black end")
    let glowAmount = PaperResponse.glowDrop(100)
    XCTAssertLessThan(out(3, fade: 0, glow: glowAmount), out(3, fade: 0, glow: 0),
                      "glow must lower the white end")
    XCTAssertLessThan(out(3, fade: fadeAmount, glow: glowAmount), 1.0)
}

/// Toe chroma compression is hue-preserving by the same argument as the
/// highlight rolloff: one weight scales all inter-channel differences. In
/// deep shadow the ratios move toward 1; the channel ORDER never flips.
func testToeChromaCompressionDesaturatesShadowsWithoutHueFlip() {
    let g = log10(PaperResponse.targetBlack) / -2.0
    // A saturated deep-shadow pixel — a THIN negative, density just above
    // the base. PLAN BUG, corrected 2026-08-10: the original fixture used
    // densities near dmax (-2.6/-2.4/-2.2). Density is measured from the
    // base, so a *dense* negative is where the scene was bright; those land
    // at paper white, where the toe weight is zero by construction, and the
    // test passed with the toe doing literally nothing (spreads bit-equal).
    let t = (0.55 * pow(10, -0.40), 0.30 * pow(10, -0.25), 0.13 * pow(10, -0.10))
    let plain = PaperResponse.develop(t, dminLinear: (0.55, 0.30, 0.13),
                                      dmax: (2, 2, 2), gammaEffective: (g, g, g),
                                      printOffset: (0, 0, 0), p: 16, q: 204, satScale: 1.0)
    let squeezed = PaperResponse.develop(t, dminLinear: (0.55, 0.30, 0.13),
                                         dmax: (2, 2, 2), gammaEffective: (g, g, g),
                                         printOffset: (0, 0, 0), p: 16, q: 204,
                                         satScale: 1.0,
                                         toeChroma: PaperResponse.toeChromaWeight(100))
    func spread(_ c: (Double, Double, Double)) -> Double {
        max(c.0, max(c.1, c.2)) - min(c.0, min(c.1, c.2))
    }
    XCTAssertLessThan(spread(squeezed), spread(plain),
                      "toe chroma compression must reduce shadow chroma")
    XCTAssertEqual(plain.0 < plain.1, squeezed.0 < squeezed.1, "channel order flipped")
    XCTAssertEqual(plain.1 < plain.2, squeezed.1 < squeezed.2, "channel order flipped")
}

/// Zone trims: a shadow trim moves a deep-shadow pixel and leaves a
/// highlight pixel essentially alone; vice versa for a high trim. Weights
/// come from the PRE-trim paper-output norm (no circularity).
func testZoneTrimsAreZoneScoped() {
    let g = log10(PaperResponse.targetBlack) / -2.0
    func develop(_ density: Double, shadow: Double, high: Double) -> Double {
        let t = 0.55 * pow(10, -density)
        // Pre-folded trim: gammaEffective × density offset, as
        // FilmDensityConverter will fold it (Task 4).
        let fold = g * PaperResponse.zoneTrimDensity(shadow)
        let foldH = g * PaperResponse.zoneTrimDensity(high)
        return PaperResponse.develop((t, t, t), dminLinear: (0.55, 0.55, 0.55),
                                     dmax: (2, 2, 2), gammaEffective: (g, g, g),
                                     printOffset: (0, 0, 0), p: 16, q: 204,
                                     satScale: 1.0,
                                     shadowTrim: (fold, fold, fold),
                                     highTrim: (foldH, foldH, foldH)).0
    }
    // Deep shadow (density 0.35 ⇒ pn well under zoneShadowEnd):
    XCTAssertGreaterThan(develop(0.35, shadow: 100, high: 0), develop(0.35, shadow: 0, high: 0))
    // Bright highlight (density 2.0 ⇒ pn above zoneHighFull):
    XCTAssertEqual(develop(2.0, shadow: 100, high: 0), develop(2.0, shadow: 0, high: 0),
                   accuracy: 1e-6, "shadow trim leaked into the highlights")
    XCTAssertLessThan(develop(2.0, shadow: 0, high: -100), develop(2.0, shadow: 0, high: 0))
}

/// Balanced tint (renderVersion 2 semantics): green moves one way, red and
/// blue each move half the other way — the offsets sum to zero, so tint no
/// longer changes overall log-domain exposure. v1 (default) is unchanged.
func testBalancedTintPreservesLogExposure() {
    let v1 = PaperResponse.printOffsets(exposureEV: 0, warmth: 0, tint: 60)
    XCTAssertEqual(v1.0, 0); XCTAssertGreaterThan(v1.1, 0); XCTAssertEqual(v1.2, 0)
    let v2 = PaperResponse.printOffsets(exposureEV: 0, warmth: 0, tint: 60,
                                        balancedTint: true)
    XCTAssertEqual(v2.0 + v2.1 + v2.2, 0, accuracy: 1e-15)
    XCTAssertEqual(v2.1, v1.1, accuracy: 1e-15, "green leg must not change")
    XCTAssertEqual(v2.0, -v1.1 / 2, accuracy: 1e-15)
    XCTAssertEqual(v2.2, -v1.1 / 2, accuracy: 1e-15)
}
```

- [x] **Step 2: Run the new tests to verify they fail**

Run: `xcodebuild … test -only-testing:PhotoEditorTests/PaperResponseTests`
Expected: COMPILE FAILURE (no such parameters/functions) — that is this cycle's "red".

- [x] **Step 3: Implement in `PaperResponse.swift`**

Add to the constants block (each with a doc comment in the house voice — what it is and why the value):

```swift
    // MARK: Minilab constants — the lab rendering layers (Phase 2.5)

    /// Full-scale midtone punch. The S-curve is pn + a·pn(1−pn)(pn−targetMid);
    /// its worst-case slope is 1 − a·(1 − targetMid) ≈ 1 − 0.82a, so 1.0
    /// keeps the curve monotone with real margin (proven by test at 100).
    static let punchFullScale = 1.0
    /// Full-scale raised paper black ("Fade") — 6% linear, a clearly faded
    /// print at the extreme, imperceptible per slider tick.
    static let fadeFullScale = 0.06
    /// Full-scale lowered paper white ("Glow") — same bound, same reasoning.
    static let glowFullScale = 0.06
    /// Toe chroma compression ceiling — the mirror of highlightDesat: reaches
    /// print-like shadow neutrality without reading as a channel clamp.
    static let toeChromaFull = 0.9
    /// Norm band over which the toe compression fades out (fully engaged at
    /// toeStart, gone by toeEnd). Below the paper floor everything is black
    /// anyway; 0.10 keeps it out of the mids.
    static let toeStart = 0.02
    static let toeEnd = 0.10
    /// Zone weight edges over the pre-trim paper-output norm: shadows fade
    /// out across 0.15–0.45, highlights fade in across 0.55–0.85, mids take
    /// the remainder — complementary smoothsteps, always summing to ≤ 1.
    static let zoneShadowEnd = 0.15
    static let zoneShadowFade = 0.45
    static let zoneHighStart = 0.55
    static let zoneHighFull = 0.85
    /// Cast correction full scale: ±100 = ±0.5 EV of per-channel density —
    /// twice the filtration clamp: enough to remove a real base-estimation
    /// cast, still bounded against scan-rescue abuse (spec §Cast correction).
    static let castFullScaleEV = 0.5
    /// Zone trim full scale: ±0.25 EV, the filtration bound — a taste trim.
    static let zoneTrimFullScaleEV = 0.25

    static func punchAmount(_ slider: Double) -> Double {
        min(max(slider, 0), 100) / 100.0 * punchFullScale
    }
    static func fadeLift(_ slider: Double) -> Double {
        min(max(slider, 0), 100) / 100.0 * fadeFullScale
    }
    static func glowDrop(_ slider: Double) -> Double {
        min(max(slider, 0), 100) / 100.0 * glowFullScale
    }
    static func toeChromaWeight(_ slider: Double) -> Double {
        min(max(slider, 0), 100) / 100.0 * toeChromaFull
    }
    /// Slider (−100…100) → density offset. 1 EV = log10(2) density.
    static func castDensity(_ slider: Double) -> Double {
        min(max(slider, -100), 100) / 100.0 * castFullScaleEV * log10(2.0)
    }
    static func zoneTrimDensity(_ slider: Double) -> Double {
        min(max(slider, -100), 100) / 100.0 * zoneTrimFullScaleEV * log10(2.0)
    }
```

Extend `printOffsets` (keep the existing doc comment, append the v2 story):

```swift
    static func printOffsets(exposureEV: Double, warmth: Double, tint: Double,
                             balancedTint: Bool = false)
        -> (Double, Double, Double) {
        let base = exposureEV * log10(2.0)
        let full = 0.25 * log10(2.0)
        let t = tint / 100.0 * full
        if balancedTint {
            // renderVersion 2: tint moves green against BOTH complements, half
            // each, so the three offsets sum to zero — the "moves exposure
            // between complementary channels" promise, now true on both axes.
            return (base + warmth / 100.0 * full - t / 2,
                    base + t,
                    base - warmth / 100.0 * full - t / 2)
        }
        return (base + warmth / 100.0 * full,
                base + t,
                base - warmth / 100.0 * full)
    }
```

Extend `develop` — the full new body (replaces the current one; the first half is unchanged):

```swift
    static func develop(_ t: (Double, Double, Double),
                        dminLinear: (Double, Double, Double),
                        dmax: (Double, Double, Double),
                        gammaEffective: (Double, Double, Double),
                        printOffset: (Double, Double, Double),
                        p: Double, q: Double,
                        satScale: Double,
                        shadowTrim: (Double, Double, Double) = (0, 0, 0),
                        midTrim: (Double, Double, Double) = (0, 0, 0),
                        highTrim: (Double, Double, Double) = (0, 0, 0),
                        punch: Double = 0, fade: Double = 0, glow: Double = 0,
                        toeChroma: Double = 0) -> (Double, Double, Double) {
        func straightLine(_ t: Double, _ dmin: Double, _ dmax: Double, _ g: Double,
                          _ offset: Double) -> Double {
            let density = log10(max(dmin, 1e-4) / max(t, transmittanceFloor))
            return pow(10.0, g * (density - dmax) + offset)
        }
        var s = (straightLine(t.0, dminLinear.0, dmax.0, gammaEffective.0, printOffset.0),
                 straightLine(t.1, dminLinear.1, dmax.1, gammaEffective.1, printOffset.1),
                 straightLine(t.2, dminLinear.2, dmax.2, gammaEffective.2, printOffset.2))
        // Zone trims: weights from the PRE-trim paper-output norm — evaluated
        // once on the untrimmed value, then applied as folded log offsets
        // (trim args arrive as gammaEffective × zoneTrimDensity, CPU-folded).
        if shadowTrim != (0, 0, 0) || midTrim != (0, 0, 0) || highTrim != (0, 0, 0) {
            let n0 = max(s.0, max(s.1, s.2))
            let pn0 = paper(n0, p: p, q: q)
            let wS = 1 - smoothstep(zoneShadowEnd, zoneShadowFade, pn0)
            let wH = smoothstep(zoneHighStart, zoneHighFull, pn0)
            let wM = max(1 - wS - wH, 0)
            func trimmed(_ v: Double, _ tS: Double, _ tM: Double, _ tH: Double) -> Double {
                v * pow(10.0, wS * tS + wM * tM + wH * tH)
            }
            s = (trimmed(s.0, shadowTrim.0, midTrim.0, highTrim.0),
                 trimmed(s.1, shadowTrim.1, midTrim.1, highTrim.1),
                 trimmed(s.2, shadowTrim.2, midTrim.2, highTrim.2))
        }
        let n = max(s.0, max(s.1, s.2))
        var ratio = n > 0 ? (s.0 / n, s.1 / n, s.2 / n) : (1.0, 1.0, 1.0)
        ratio = (max(1 + (ratio.0 - 1) * satScale, 0),
                 max(1 + (ratio.1 - 1) * satScale, 0),
                 max(1 + (ratio.2 - 1) * satScale, 0))
        var pn = paper(n, p: p, q: q)
        // Punch: a monotone cubic S about the mid target — zero at black,
        // targetMid, and white, so it adds midtone contrast without moving
        // the endpoints the fade/glow remap below owns.
        pn = pn + punch * pn * (1 - pn) * (pn - targetMid)
        // Fade/glow: the endpoint remap — raised paper black, lowered paper
        // white. Affine, slope 1 − fade − glow > 0, still strictly < 1.
        pn = fade + pn * (1 - fade - glow)
        let w = smoothstep(shoulderStart, 1.0, pn) * highlightDesat
        let wToe = (1 - smoothstep(toeStart, toeEnd, pn)) * toeChroma
        let wAll = min(w + wToe, 1.0)
        return (pn * (ratio.0 + (1 - ratio.0) * wAll),
                pn * (ratio.1 + (1 - ratio.1) * wAll),
                pn * (ratio.2 + (1 - ratio.2) * wAll))
    }
```

Note: `w` and `wToe` have disjoint supports (pn ≥ 0.75·(1−fade−glow) vs pn ≤ 0.10 + fade), so `min(w + wToe, 1)` never mixes the two regimes; at defaults both are 0 and the return line reduces bit-exactly to the old one (`wAll == w`, and `w`'s formula is unchanged).

- [x] **Step 4: Run PaperResponseTests + the goldens**

Run: `xcodebuild … test -only-testing:PhotoEditorTests/PaperResponseTests -only-testing:PhotoEditorTests/PaperResponseGoldenTests`
Expected: ALL PASS — including both goldens (the identity-at-default proof) and every pre-existing PaperResponse test.

- [x] **Step 5: Commit**

```bash
git add Sources/Film/PaperResponse.swift Tests/PaperResponseTests.swift
git commit -m "feat(film): lab-layer curve math — punch/fade/glow, toe chroma, zone trims, balanced tint (defaulted neutral)"
```

---

### Task 3: Tone profiles + toning fields, kernel-wired and conformance-covered

Persist `renderVersion`, `toneProfile`, `punch`, `fade`, `glow`, `toeChroma`; mirror the Task 2 math in the Metal kernel; marshal in `FilmDensityConverter`; cover every new field in the conformance suite. **Design decision locked here:** `PrintSettings()`'s toning defaults stay NEUTRAL (`toneProfile: .linear`, punch/fade/glow/toeChroma 0) so the solver's and conformance suite's `PrintSettings()` reference is unchanged; "Lab Standard is the default for new conversions" is applied at the gesture level (`enableFilmNegative`, Task 6) — the spec's init-`.labStandard` intent lands there, where every new conversion actually passes through.

**Files:**
- Modify: `Sources/Film/PrintSettings.swift`, `Sources/Pipeline/Kernels/Film.ci.metal`, `Sources/Film/FilmDensityConverter.swift`
- Test: `Tests/PrintSettingsTests.swift`, `Tests/FilmDensityConverterTests.swift`, `Tests/FilmControlConformanceTests.swift`

**Interfaces:**
- Produces:
  - `enum FilmToneProfile: String, Codable, Equatable, CaseIterable { case linear, labSoft, labStandard, labHard }` with `var punch/fade/glow/toeChroma: Double` (slider units) and `var enablesAutoColorBalance: Bool` (false only for `.linear`)
  - `PrintSettings.renderVersion: Int` (init **2**, decode **1**), `toneProfile: FilmToneProfile` (init/decode `.linear`), `punch/fade/glow/toeChroma: Double` (init/decode 0)
  - `PrintSettings.applyToneProfile(_ profile: FilmToneProfile)` (mutating: sets `toneProfile` + the four sliders to the profile's values)
  - Kernel `film_density_print` gains trailing args: `float3 trimS, float3 trimM, float3 trimH, float punch, float fade, float glow, float toeChroma` (Task 4 wires the trims; this task passes zeros)

- [x] **Step 1: Write failing decode/profile tests**

Append to `Tests/PrintSettingsTests.swift`:

```swift
/// The freeze asymmetry, same trick as conversionModel: fresh settings are
/// renderVersion 2; anything decoded from JSON that predates the field is 1.
func testRenderVersionInitializesTwoDecodesOne() throws {
    XCTAssertEqual(PrintSettings().renderVersion, 2)
    let old = try JSONDecoder().decode(PrintSettings.self,
                                       from: #"{"exposure": 1}"#.data(using: .utf8)!)
    XCTAssertEqual(old.renderVersion, 1)
    XCTAssertEqual(old.toneProfile, .linear)
    XCTAssertEqual(old.punch, 0); XCTAssertEqual(old.fade, 0)
    XCTAssertEqual(old.glow, 0); XCTAssertEqual(old.toeChroma, 0)
}

func testApplyToneProfileWritesTheProfileParameters() {
    var p = PrintSettings()
    p.applyToneProfile(.labStandard)
    XCTAssertEqual(p.toneProfile, .labStandard)
    XCTAssertEqual(p.punch, FilmToneProfile.labStandard.punch)
    XCTAssertEqual(p.fade, FilmToneProfile.labStandard.fade)
    XCTAssertEqual(p.glow, FilmToneProfile.labStandard.glow)
    XCTAssertEqual(p.toeChroma, FilmToneProfile.labStandard.toeChroma)
    p.applyToneProfile(.linear)
    XCTAssertEqual(p.punch, 0, "linear must be exactly today's render")
    XCTAssertFalse(FilmToneProfile.linear.enablesAutoColorBalance)
    XCTAssertTrue(FilmToneProfile.labStandard.enablesAutoColorBalance)
}
```

- [x] **Step 2: Run to verify compile failure** (`-only-testing:PhotoEditorTests/PrintSettingsTests`).

- [x] **Step 3: Implement `FilmToneProfile` + fields in `PrintSettings.swift`**

Above `PrintSettings`:

```swift
/// A named rendering family for the print stage — the first choice after
/// conversion, separating "accurate" from "pleasing" (spec §Tone profiles).
/// `.linear` is exactly the Phase 2 render; the Lab profiles add the minilab
/// layers (midtone punch, raised black, softened white, shadow chroma
/// compression) at increasing strength. Values are slider units; selecting a
/// profile WRITES them into ordinary visible sliders (resolved values, like
/// a film stock), so the profile is a starting point, not hidden state.
/// Provisional values — tuned against the corpora in the acceptance pass.
enum FilmToneProfile: String, Codable, Equatable, CaseIterable {
    case linear, labSoft, labStandard, labHard

    var punch: Double {
        switch self {
        case .linear: 0; case .labSoft: 30; case .labStandard: 50; case .labHard: 70
        }
    }
    var fade: Double {
        switch self {
        case .linear: 0; case .labSoft: 35; case .labStandard: 22; case .labHard: 12
        }
    }
    var glow: Double {
        switch self {
        case .linear: 0; case .labSoft: 20; case .labStandard: 12; case .labHard: 8
        }
    }
    var toeChroma: Double {
        switch self { case .linear: 0; default: 30 }
    }
    /// Lab profiles balance midtone colour automatically (Task 6/7);
    /// linear stays a pure measurement.
    var enablesAutoColorBalance: Bool { self != .linear }

    var displayName: String {
        switch self {
        case .linear: "Linear"; case .labSoft: "Lab Soft"
        case .labStandard: "Lab Standard"; case .labHard: "Lab Hard"
        }
    }
}
```

In `PrintSettings`, after `tint`:

```swift
    /// Which semantics render this photo. Initialized 2 (the Minilab fixes:
    /// pre-curve legacy EV, balanced tint, mid-pivot grade); decoded 1 so
    /// every photo converted before this field existed keeps its exact
    /// rendering — the conversionModel freeze trick, one level down.
    var renderVersion: Int = 2

    /// The rendering family these toning sliders were seeded from. Provenance
    /// plus the Auto solve's parameter source — the sliders below stay the
    /// truth the renderer reads.
    var toneProfile: FilmToneProfile = .linear

    /// Midtone punch, 0…100 → PaperResponse.punchAmount. The minilab's
    /// midtone contrast, applied to the norm only (hue-preserving).
    var punch: Double = 0

    /// Raised paper black, 0…100 → PaperResponse.fadeLift.
    var fade: Double = 0

    /// Lowered paper white, 0…100 → PaperResponse.glowDrop.
    var glow: Double = 0

    /// Shadow chroma compression, 0…100 → PaperResponse.toeChromaWeight —
    /// the toe's mirror of the highlight rolloff.
    var toeChroma: Double = 0

    mutating func applyToneProfile(_ profile: FilmToneProfile) {
        toneProfile = profile
        punch = profile.punch
        fade = profile.fade
        glow = profile.glow
        toeChroma = profile.toeChroma
    }
```

And in `init(from:)`, after the `tint` line:

```swift
        renderVersion = c.lenient(.renderVersion, 1)
        toneProfile = c.lenient(.toneProfile, .linear)
        punch = c.lenient(.punch, 0)
        fade = c.lenient(.fade, 0)
        glow = c.lenient(.glow, 0)
        toeChroma = c.lenient(.toeChroma, 0)
```

- [x] **Step 4: Run PrintSettingsTests** — expected PASS.

- [x] **Step 5: Mirror in the kernel and marshal**

`Film.ci.metal` — extend the signature and body (mirror of Task 2, same order of operations; keep the doc comments in step with `PaperResponse`):

```metal
extern "C" float4 film_density_print(coreimage::sample_t s,
                                     float3 dmin, float3 dmax, float3 gam,
                                     float3 printOffset, float p, float q,
                                     float shoulderStart, float highlightDesat,
                                     float satScale,
                                     float3 trimS, float3 trimM, float3 trimH,
                                     float punch, float fade, float glow,
                                     float toeChroma, float targetMid,
                                     float toeStart, float toeEnd,
                                     float3 zoneEdges, float zoneHighFull) {
    float3 t = max(s.rgb, float3(1e-5f));
    float3 D = log10(max(dmin, float3(1e-4f)) / t);
    float3 sp = pow(float3(10.0f), gam * (D - dmax) + printOffset);

    // Zone trims: weights from the PRE-trim paper-output norm (mirrors
    // PaperResponse.develop — evaluated once, untrimmed, no circularity).
    if (any(trimS != 0.0f) || any(trimM != 0.0f) || any(trimH != 0.0f)) {
        float n0 = max(sp.x, max(sp.y, sp.z));
        float pn0 = paper_curve(n0, p, q);
        float wS = 1.0f - smoothstep(zoneEdges.x, zoneEdges.y, pn0);
        float wH = smoothstep(zoneEdges.z, zoneHighFull, pn0);
        float wM = max(1.0f - wS - wH, 0.0f);
        sp *= pow(float3(10.0f), wS * trimS + wM * trimM + wH * trimH);
    }

    float n = max(sp.x, max(sp.y, sp.z));
    float3 ratio = n > 0.0f ? sp / n : float3(1.0f);
    ratio = max(1.0f + (ratio - 1.0f) * satScale, float3(0.0f));
    float pn = paper_curve(n, p, q);
    // Punch: monotone cubic S about the mid target (see PaperResponse).
    pn = pn + punch * pn * (1.0f - pn) * (pn - targetMid);
    // Fade/glow: endpoint remap — raised black, lowered white.
    pn = fade + pn * (1.0f - fade - glow);
    float w = smoothstep(shoulderStart, 1.0f, pn) * highlightDesat;
    float wToe = (1.0f - smoothstep(toeStart, toeEnd, pn)) * toeChroma;
    float3 outc = pn * mix(ratio, float3(1.0f), min(w + wToe, 1.0f));
    return float4(outc, s.a);
}
```

(`zoneEdges` = `(zoneShadowEnd, zoneShadowFade, zoneHighStart)`; `targetMid`/`toeStart`/`toeEnd` passed rather than duplicated as literals so the Swift constants stay the single source.)

`FilmDensityConverter.convert` — replace the `kernel.apply` arguments array (Task 4 replaces the three `CIVector(x: 0, y: 0, z: 0)` trim placeholders with real folds):

```swift
        var result = kernel.apply(
            extent: image.extent,
            arguments: [
                image,
                CIVector(x: dminLinear.0, y: dminLinear.1, z: dminLinear.2),
                CIVector(x: p.dmax.red, y: p.dmax.green, z: p.dmax.blue),
                CIVector(x: p.gamma.red * grade, y: p.gamma.green * grade,
                         z: p.gamma.blue * grade),
                CIVector(x: printOffset.0, y: printOffset.1, z: printOffset.2),
                Float(PaperResponse.kneeP(shoulder: p.shoulder)),
                Float(PaperResponse.kneeQ(toe: p.toe)),
                Float(PaperResponse.shoulderStart),
                Float(PaperResponse.highlightDesat),
                Float(1.0 + p.saturation / 100.0),
                CIVector(x: 0, y: 0, z: 0),   // trimS — Task 4
                CIVector(x: 0, y: 0, z: 0),   // trimM — Task 4
                CIVector(x: 0, y: 0, z: 0),   // trimH — Task 4
                Float(PaperResponse.punchAmount(p.punch)),
                Float(PaperResponse.fadeLift(p.fade)),
                Float(PaperResponse.glowDrop(p.glow)),
                Float(PaperResponse.toeChromaWeight(p.toeChroma)),
                Float(PaperResponse.targetMid),
                Float(PaperResponse.toeStart),
                Float(PaperResponse.toeEnd),
                CIVector(x: PaperResponse.zoneShadowEnd,
                         y: PaperResponse.zoneShadowFade,
                         z: PaperResponse.zoneHighStart),
                Float(PaperResponse.zoneHighFull),
            ]
        ) ?? image
```

- [x] **Step 6: Extend the kernel-agreement test to non-neutral toning**

In `Tests/FilmDensityConverterTests.swift`, add a third leg to `testKernelAgreesWithTheSwiftModel` and thread the new params through `assertKernelAgreesWithSwiftModel`'s expected-value computation:

```swift
        var lab = densitySettings()
        lab.print.applyToneProfile(.labStandard)
        assertKernelAgreesWithSwiftModel(lab)
```

and in the helper, compute `expected` with:

```swift
            expected.append(PaperResponse.develop(
                t, dminLinear: dminLin, dmax: dmax, gammaEffective: gammaEffective,
                printOffset: printOffset, p: p, q: q, satScale: satScale,
                punch: PaperResponse.punchAmount(settings.print.punch),
                fade: PaperResponse.fadeLift(settings.print.fade),
                glow: PaperResponse.glowDrop(settings.print.glow),
                toeChroma: PaperResponse.toeChromaWeight(settings.print.toeChroma)))
```

- [x] **Step 7: Conformance rows**

In `Tests/FilmControlConformanceTests.swift` — the completeness test now fails without these. Append to `cases` (reference is the `.linear`-solved `baseStack()`, so 0-floor sliders use two non-neutral legs):

```swift
        .init(name: "Punch", key: "print.punch",
              low: { $0.filmNegative.print.punch = 35 },
              high: { $0.filmNegative.print.punch = 100 },
              measure: FilmControlConformanceTests.interiorStdDevLuma, sign: +1),
        .init(name: "Fade", key: "print.fade",
              low: { $0.filmNegative.print.fade = 30 },
              high: { $0.filmNegative.print.fade = 100 },
              measure: { Conformance.percentileLuma($0, 0.02) }, sign: +1),
        .init(name: "Glow", key: "print.glow",
              low: { $0.filmNegative.print.glow = 30 },
              high: { $0.filmNegative.print.glow = 100 },
              measure: { Conformance.percentileLuma($0, 0.98) }, sign: -1),
        .init(name: "Toe Chroma", key: "print.toeChroma",
              low: { $0.filmNegative.print.toeChroma = 40 },
              high: { $0.filmNegative.print.toeChroma = 100 },
              measure: Conformance.meanSaturation, sign: -1),
```

And to `excluded`:

```swift
        "print.renderVersion": "freeze flag, not a control — PaperResponseGoldenTests owns it",
        "print.toneProfile": "profile selector — its four parameters each have a case above; selection behavior covered by EditorModelTests",
```

**Measure before declaring:** render the probe once with each `high` leg and print the four measures (temporary diagnostic, then delete it — house discipline per this file's block comment). If a measured sign contradicts the table above, the declared sign is wrong: fix the table to the measurement and record why in the case's comment. If a delta lands under its floor, first try moving the leg further from neutral (the `FilmControlCase` contract allows any in-range value); only then adjust the floor, with the measured number in the comment (Toe/Warmth precedents).

- [x] **Step 8: Run the three suites**

Run: `-only-testing:PhotoEditorTests/FilmDensityConverterTests -only-testing:PhotoEditorTests/FilmControlConformanceTests -only-testing:PhotoEditorTests/PaperResponseGoldenTests`
Expected: ALL PASS. The goldens pass because every new field defaults/decodes to its identity and the kernel additions are exact no-ops at those values.

- [x] **Step 9: Commit**

```bash
git add Sources/Film/PrintSettings.swift Sources/Film/FilmDensityConverter.swift Sources/Pipeline/Kernels/Film.ci.metal Tests/PrintSettingsTests.swift Tests/FilmDensityConverterTests.swift Tests/FilmControlConformanceTests.swift
git commit -m "feat(film): tone profiles (Linear/Lab) with punch, fade, glow, toe chroma — kernel-wired, conformance-covered"
```

---

### Task 4: Cast correction + zone trims + grade pivot (fields and folds)

The cast and grade-pivot corrections fold into `printOffset` on the CPU (they are per-channel constants); zone trims go to the kernel args added in Task 3.

**Files:**
- Modify: `Sources/Film/PrintSettings.swift`, `Sources/Film/FilmDensityConverter.swift`
- Test: `Tests/PrintSettingsTests.swift`, `Tests/FilmDensityConverterTests.swift`, `Tests/FilmControlConformanceTests.swift`

**Interfaces:**
- Produces:
  - `DensityTriple.zero` (`static let zero = DensityTriple(red: 0, green: 0, blue: 0)`)
  - `PrintSettings.castRed/castGreen/castBlue: Double` (−100…100, init/decode 0)
  - `PrintSettings.shadowTrim/midTrim/highTrim: DensityTriple` (slider units per channel, init/decode `.zero`)
  - `PrintSettings.gradePivot: DensityTriple?` (init/decode nil; Auto writes it in Task 6)
  - The CPU folds in `FilmDensityConverter` (exact formulas below) — Task 5/6 rely on them.

- [x] **Step 1: Write failing tests**

`Tests/PrintSettingsTests.swift`:

```swift
func testCastAndTrimFieldsDecodeToNeutral() throws {
    let old = try JSONDecoder().decode(PrintSettings.self,
                                       from: #"{"exposure": 1}"#.data(using: .utf8)!)
    XCTAssertEqual(old.castRed, 0); XCTAssertEqual(old.castGreen, 0)
    XCTAssertEqual(old.castBlue, 0)
    XCTAssertEqual(old.shadowTrim, .zero); XCTAssertEqual(old.midTrim, .zero)
    XCTAssertEqual(old.highTrim, .zero)
    XCTAssertNil(old.gradePivot)
}
```

`Tests/FilmDensityConverterTests.swift` — the fold correctness, against the pure model:

```swift
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
```

If `TestSupport` has no linear-value solid-image/readback helpers, add them beside `solidImage`/`readColor` following those implementations (a 1×1 `.RGBAf` bitmap in `extendedLinearSRGB`, and a `.RGBAf` readback in the same space) — do NOT reuse the sRGB readers for linear values.

- [x] **Step 2: Run to verify failure** (compile failure on the new fields).

- [x] **Step 3: Implement**

`PrintSettings.swift` — after `toeChroma`:

```swift
    /// Cast correction, −100…100 per channel; ±100 = ±0.5 EV of density
    /// (PaperResponse.castDensity). The ANALYSIS layer: written by the
    /// neutral picker and auto colour balance, hand-trimmable, independent of
    /// the ±0.25 EV house filtration above (spec §Cast correction).
    var castRed: Double = 0
    var castGreen: Double = 0
    var castBlue: Double = 0

    /// Zone trims, −100…100 per channel per zone; ±100 = ±0.25 EV, weighted
    /// by tone zone (PaperResponse.zoneTrimDensity + the zone smoothsteps).
    /// The deliberate shadow/mid/highlight colour-character controls — these
    /// rotate colour by design, unlike the hue-preserving tone path.
    var shadowTrim: DensityTriple = .zero
    var midTrim: DensityTriple = .zero
    var highTrim: DensityTriple = .zero

    /// The density each channel's grade pivots around (renderVersion 2):
    /// Auto writes its solved median so changing Contrast holds the mids
    /// instead of darkening everything below paper white. nil (never solved)
    /// preserves the v1 white-point pivot.
    var gradePivot: DensityTriple?
```

Decode lines: `castRed = c.lenient(.castRed, 0)` (×3), `shadowTrim = c.lenient(.shadowTrim, .zero)` (×3), `gradePivot = c.lenient(.gradePivot, nil)`. Add `static let zero` to `DensityTriple`.

`FilmDensityConverter.convert` — replace the offset/gamma section with the full fold (this is the load-bearing block; Task 5 already accounted for below is gated off `renderVersion`):

```swift
        let p = settings.print
        let grade = PaperResponse.gradeScale(p.contrast)
        let gammaEff = (p.gamma.red * grade, p.gamma.green * grade, p.gamma.blue * grade)
        let v2 = p.renderVersion >= 2
        // renderVersion 2 folds the legacy EV lift into the print exposure —
        // pre-curve, restoring the never-clips contract (Task 5). v1 keeps
        // the historical post-curve multiply below.
        var printOffset = PaperResponse.printOffsets(
            exposureEV: p.exposure + (v2 ? settings.exposure : 0),
            warmth: p.warmth, tint: p.tint, balancedTint: v2)
        // Cast correction: a density-domain offset per channel, folded
        // through the effective gamma (γ·(D + c − Dmax) = γ·(D − Dmax) + γ·c).
        printOffset.0 += gammaEff.0 * PaperResponse.castDensity(p.castRed)
        printOffset.1 += gammaEff.1 * PaperResponse.castDensity(p.castGreen)
        printOffset.2 += gammaEff.2 * PaperResponse.castDensity(p.castBlue)
        // Grade pivot (renderVersion 2, Auto-solved only): hold the solved
        // median invariant under grade — offset' = γ·(1 − k)·(P − Dmax),
        // with γ the UN-graded gamma and k the grade scale.
        if v2, let pivot = p.gradePivot {
            printOffset.0 += p.gamma.red * (1 - grade) * (pivot.red - p.dmax.red)
            printOffset.1 += p.gamma.green * (1 - grade) * (pivot.green - p.dmax.green)
            printOffset.2 += p.gamma.blue * (1 - grade) * (pivot.blue - p.dmax.blue)
        }
```

and replace the three trim placeholders in the arguments array:

```swift
                CIVector(x: gammaEff.0 * PaperResponse.zoneTrimDensity(p.shadowTrim.red),
                         y: gammaEff.1 * PaperResponse.zoneTrimDensity(p.shadowTrim.green),
                         z: gammaEff.2 * PaperResponse.zoneTrimDensity(p.shadowTrim.blue)),
                CIVector(x: gammaEff.0 * PaperResponse.zoneTrimDensity(p.midTrim.red),
                         y: gammaEff.1 * PaperResponse.zoneTrimDensity(p.midTrim.green),
                         z: gammaEff.2 * PaperResponse.zoneTrimDensity(p.midTrim.blue)),
                CIVector(x: gammaEff.0 * PaperResponse.zoneTrimDensity(p.highTrim.red),
                         y: gammaEff.1 * PaperResponse.zoneTrimDensity(p.highTrim.green),
                         z: gammaEff.2 * PaperResponse.zoneTrimDensity(p.highTrim.blue)),
```

Also extend the kernel-agreement helper: fold cast/pivot/trims exactly as above when computing `expected`, and add a fourth leg exercising `castRed = 40, shadowTrim.red = 60, contrast = 3` — the agreement test is what proves the CPU fold and the kernel's zone math describe one model.

- [x] **Step 4: Conformance rows for the seven new fields**

```swift
        .init(name: "Cast Red", key: "print.castRed",
              low: { $0.filmNegative.print.castRed = -80 },
              high: { $0.filmNegative.print.castRed = 80 },
              measure: Conformance.warmth, sign: +1),
        .init(name: "Cast Green", key: "print.castGreen",
              low: { $0.filmNegative.print.castGreen = -80 },
              high: { $0.filmNegative.print.castGreen = 80 },
              measure: Conformance.greenMagenta, sign: +1),
        .init(name: "Cast Blue", key: "print.castBlue",
              low: { $0.filmNegative.print.castBlue = -80 },
              high: { $0.filmNegative.print.castBlue = 80 },
              measure: Conformance.warmth, sign: -1),
        // Zone trims: per-zone colour moves whose whole-frame direction
        // depends on the probe's tonal distribution — change-only (sign 0),
        // the Paper Gamma Red precedent. Red leg per field.
        .init(name: "Shadow Trim Red", key: "print.shadowTrim",
              low: { $0.filmNegative.print.shadowTrim.red = -100 },
              high: { $0.filmNegative.print.shadowTrim.red = 100 },
              measure: Conformance.warmth, sign: 0),
        .init(name: "Mid Trim Red", key: "print.midTrim",
              low: { $0.filmNegative.print.midTrim.red = -100 },
              high: { $0.filmNegative.print.midTrim.red = 100 },
              measure: Conformance.warmth, sign: 0),
        .init(name: "High Trim Red", key: "print.highTrim",
              low: { $0.filmNegative.print.highTrim.red = -100 },
              high: { $0.filmNegative.print.highTrim.red = 100 },
              measure: Conformance.warmth, sign: 0),
```

and:

```swift
        "print.gradePivot": "Auto-solved compensation anchor, not a control — grade-invariance test in FilmDensityConverterTests owns it",
```

Same measure-first discipline as Task 3 Step 7: print the actual deltas once, adjust legs/floors from measurement, delete the diagnostic.

- [x] **Step 5: Run the suites** (`FilmDensityConverterTests`, `FilmControlConformanceTests`, `PaperResponseGoldenTests`, `PrintSettingsTests`). Expected: ALL PASS.

- [x] **Step 6: Commit**

```bash
git add Sources/Film/PrintSettings.swift Sources/Film/FilmDensityConverter.swift Sources/Pipeline/Kernels/Film.ci.metal Tests/PrintSettingsTests.swift Tests/FilmDensityConverterTests.swift Tests/FilmControlConformanceTests.swift
git commit -m "feat(film): cast correction, zone trims, grade pivot — CPU folds + conformance"
```

---

### Task 5: renderVersion 2 semantics, proven

Task 3/4 installed the v2 branches (`balancedTint: v2`, legacy-EV fold, pivot compensation). This task proves each fix does what the spec claims — and re-measures any conformance case the new reference rendering disturbed (the suite's `baseStack()` is fresh, hence renderVersion 2 with tint −8 now balanced: expect Print Warmth/Tint measured deltas to shift).

**Files:**
- Modify: `Sources/Film/FilmDensityConverter.swift` (only the legacy-EV skip below)
- Test: `Tests/FilmDensityConverterTests.swift`, `Tests/FilmControlConformanceTests.swift`

- [x] **Step 1: Gate the post-curve legacy EV to v1**

In `FilmDensityConverter.convert`, change the legacy-EV block:

```swift
        // renderVersion 1 only: the historical post-curve EV multiply. A
        // frozen misfeature — it can push paper white past 1.0 — kept
        // verbatim because v1 photos' appearance depends on it. v2 folds the
        // same EV into the print exposure above, pre-curve.
        if settings.exposure != 0 && p.renderVersion < 2 {
            let exposure = CIFilter.exposureAdjust()
            exposure.inputImage = result
            exposure.ev = Float(settings.exposure)
            result = exposure.outputImage ?? result
        }
```

- [x] **Step 2: Write the three semantic proofs**

`Tests/FilmDensityConverterTests.swift`:

```swift
/// renderVersion 2 restores the never-clips contract with a nonzero legacy
/// EV: the same +2 EV that pushes a v1 render past 1.0 stays under 1.0 on
/// v2, because it now runs through the paper curve.
func testV2FoldsLegacyExposureBeforeThePaperCurve() throws {
    var v2 = densitySettings()
    v2.exposure = 2
    // PLAN BUG, corrected 2026-08-10 (same class as Task 2's toe fixture):
    // the original probe was near-base "renders near white" — on a NEGATIVE
    // the base renders near BLACK, where a post-curve multiply has nothing to
    // clip, so neither assertion could ever trip. The implemented test uses a
    // DENSE patch (density 1.7, the print's near-white) built in linear space.
    let scan = TestSupport.solidImage(red: v2.baseColor.red * 0.9,
                                      green: v2.baseColor.green * 0.9,
                                      blue: v2.baseColor.blue * 0.9) // WRONG — see note above
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
                         "the frozen v1 misfeature must stay frozen — near-white × 2EV clips")
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
```

(The balanced-tint proof already exists at the model level from Task 2; the kernel-agreement fourth leg covers it end-to-end.)

- [x] **Step 3: Run FilmDensityConverterTests** — expected: the two new tests PASS, all old ones PASS, goldens PASS (the v1 ramp golden carries nonzero legacy EV + tint −8, which is exactly what this task must not disturb).

- [x] **Step 4: Re-verify conformance and re-measure if needed**

Run `FilmControlConformanceTests`. If Print Warmth/Tint (or any case) now fails a floor or flips: re-run with a temporary sweep diagnostic, adjust the leg (preferred) or floor to the measured values, document in the case comment citing this task — the exact Phase C procedure recorded in that file's block comment. Delete the diagnostic.

- [x] **Step 5: Commit**

```bash
git add Sources/Film/FilmDensityConverter.swift Tests/FilmDensityConverterTests.swift Tests/FilmControlConformanceTests.swift
git commit -m "fix(film): renderVersion 2 semantics — pre-curve legacy EV, balanced tint, mid-pivot grade (v1 frozen, proven)"
```

---

### Task 6: AutoInvert — measure/solve split, profile-aware, pivot-writing

Split measurement from solving (RollAnalysis needs the measurements in Task 9), make the solve profile-aware, and write `gradePivot`.

**Files:**
- Modify: `Sources/Film/AutoInvert.swift`, `Sources/Views/EditorModel.swift` (call sites), `Tests/FilmControlConformanceTests.swift` + `Tests/RealScanTests.swift` (call sites)
- Test: `Tests/AutoInvertTests.swift`

**Interfaces:**
- Produces (exact signatures Tasks 7/9/10 consume):

```swift
struct FrameMeasurement {
    /// Ascending-sorted linear transmittances of the gated population.
    var sortedRed: [Double]
    var sortedGreen: [Double]
    var sortedBlue: [Double]
    var sampledBase: FilmColor?      // display-encoded, wins over statistics
    var degradedTerms: [String]      // gating fallbacks, carried into the solve
}

extension AutoInvert {
    static func measure(scan: CIImage, sampledBase: FilmColor?,
                        context: CIContext) -> FrameMeasurement?
    static func solve(from m: FrameMeasurement,
                      profile: FilmToneProfile) -> AutoInvertSolution?
    static func solve(scan: CIImage, sampledBase: FilmColor?,
                      profile: FilmToneProfile,
                      context: CIContext) -> AutoInvertSolution?   // wrapper
}
```

  - `AutoInvertSolution` gains `var medianDensity: DensityTriple` (→ `gradePivot`) and `var cast: DensityTriple` (SLIDER units despite the type — `DensityTriple` is the house "triple of Doubles, not a colour" carrier and keeps the struct's synthesized `Equatable`, which a labeled tuple would break; doc-comment this. `.zero` unless Task 7's auto colour balance runs).
  - The old `solve(scan:sampledBase:context:)` is REMOVED (three call sites: `EditorModel.autoConvertNegative`, `FilmControlConformanceTests.baseStack`, `RealScanTests.convert`) — `profile:` becomes explicit everywhere so no site solves under an accidental default.

- [x] **Step 1: Write failing tests**

`Tests/AutoInvertTests.swift` (append):

```swift
/// The measure/solve split is pure refactor: solving a measurement must give
/// the same numbers the one-shot wrapper gives, and (under .linear) the same
/// numbers the pre-split solver gave — anchored by the conformance suite's
/// reproducibility test and the unchanged corpus prints.
func testMeasureThenSolveEqualsTheWrapper() throws {
    let probe = FilmSim.negativeImage(dmin: FilmSim.c41Base,
                                      gammas: FilmSim.crossoverGammas, size: 128)
    let context = CIContext()
    let m = try XCTUnwrap(AutoInvert.measure(scan: probe, sampledBase: nil,
                                             context: context))
    let a = try XCTUnwrap(AutoInvert.solve(from: m, profile: .linear))
    let b = try XCTUnwrap(AutoInvert.solve(scan: probe, sampledBase: nil,
                                           profile: .linear, context: context))
    XCTAssertEqual(a, b)
}

/// Profile-aware placement: the Lab profiles change the rendering the median
/// lands under (punch/fade/glow), so the solved EV must differ from linear's
/// — if it didn't, the bisection would be ignoring the profile.
func testLabProfileSolvesADifferentExposureThanLinear() throws {
    let probe = FilmSim.negativeImage(dmin: FilmSim.c41Base,
                                      gammas: FilmSim.crossoverGammas, size: 128)
    let context = CIContext()
    let linear = try XCTUnwrap(AutoInvert.solve(scan: probe, sampledBase: nil,
                                                profile: .linear, context: context))
    let lab = try XCTUnwrap(AutoInvert.solve(scan: probe, sampledBase: nil,
                                             profile: .labStandard, context: context))
    XCTAssertNotEqual(linear.printExposure, lab.printExposure)
    XCTAssertEqual(linear.dmax, lab.dmax, "endpoint statistics are profile-independent")
    XCTAssertEqual(linear.gamma, lab.gamma, "gammas are profile-independent")
}

/// The solved median density is reported (it becomes gradePivot): rendering
/// the median transmittance under the solved stack must land its max channel
/// at targetMid — the bisection's own contract, now visible in the solution.
func testMedianDensityIsReportedAndLandsAtTargetMid() throws {
    let probe = FilmSim.negativeImage(dmin: FilmSim.c41Base,
                                      gammas: FilmSim.crossoverGammas, size: 128)
    let context = CIContext()
    let s = try XCTUnwrap(AutoInvert.solve(scan: probe, sampledBase: nil,
                                           profile: .linear, context: context))
    XCTAssertGreaterThan(s.medianDensity.red, 0)
    let dminLin = (PaperResponse.srgbDecode(s.baseColor.red),
                   PaperResponse.srgbDecode(s.baseColor.green),
                   PaperResponse.srgbDecode(s.baseColor.blue))
    let medianT = (dminLin.0 * pow(10, -s.medianDensity.red),
                   dminLin.1 * pow(10, -s.medianDensity.green),
                   dminLin.2 * pow(10, -s.medianDensity.blue))
    let defaults = PrintSettings()
    let offset = PaperResponse.printOffsets(exposureEV: s.printExposure,
                                            warmth: defaults.warmth,
                                            tint: defaults.tint, balancedTint: true)
    let out = PaperResponse.develop(
        medianT, dminLinear: dminLin,
        dmax: (s.dmax.red, s.dmax.green, s.dmax.blue),
        gammaEffective: (s.gamma.red, s.gamma.green, s.gamma.blue),
        printOffset: offset,
        p: PaperResponse.kneeP(shoulder: defaults.shoulder),
        q: PaperResponse.kneeQ(toe: defaults.toe), satScale: 1.0)
    XCTAssertEqual(max(out.0, max(out.1, out.2)), PaperResponse.targetMid,
                   accuracy: 0.01)
}
```

- [x] **Step 2: Run — expect compile failure.**

- [x] **Step 3: Refactor `AutoInvert.swift`**

Mechanical split of the existing `solve`:
- `measure(scan:sampledBase:context:)` = steps 0–gating: `linearPixels`, the gate-then-validate population choice, returns `FrameMeasurement(sortedRed: pixels.map(\.0).sorted(), …, sampledBase: sampledBase, degradedTerms: degraded)`. (Sort once here; the solve consumes sorted arrays.)
- `solve(from:profile:)` = steps 1–6 operating on the sorted arrays (the existing code re-sorts after the density transform — keep exactly that logic, it is order-preserving-in-reverse, and the existing `percentile` calls). Bisection changes: solve EV under the profile's rendering —

```swift
        var defaults = PrintSettings()
        defaults.applyToneProfile(profile)
        let p = PaperResponse.kneeP(shoulder: defaults.shoulder)
        let q = PaperResponse.kneeQ(toe: defaults.toe)
        // renderVersion 2 semantics: new solves render balanced-tint.
        …
            let offset = PaperResponse.printOffsets(exposureEV: mid,
                                                    warmth: defaults.warmth,
                                                    tint: defaults.tint,
                                                    balancedTint: true)
            let out = PaperResponse.develop(
                medianT, dminLinear: dminLinear,
                dmax: (dmaxV.0, dmaxV.1, dmaxV.2),
                gammaEffective: (gamma.red, gamma.green, gamma.blue),
                printOffset: offset, p: p, q: q, satScale: 1.0,
                punch: PaperResponse.punchAmount(defaults.punch),
                fade: PaperResponse.fadeLift(defaults.fade),
                glow: PaperResponse.glowDrop(defaults.glow),
                toeChroma: PaperResponse.toeChromaWeight(defaults.toeChroma))
```

  (satScale 1.0 stays exact for the max channel, as the existing comment explains.) Populate `medianDensity: DensityTriple(red: medianD.0, green: medianD.1, blue: medianD.2)` and `cast: .zero` in the returned solution. (`DensityTriple.zero` arrives in Task 4; if executing Task 6 against a tree where Task 4 somehow hasn't landed, that's an ordering violation — stop.)
- Wrapper `solve(scan:sampledBase:profile:context:)` = `measure` + `solve(from:)`.

- [x] **Step 4: Update the three call sites**

`EditorModel.autoConvertNegative` — solve under the CURRENT profile, write the new outputs, and (this is where the spec's "Lab Standard default for new conversions" lands) have `enableFilmNegative` seed the profile on first enable:

```swift
    func enableFilmNegative() {
        if editStack.filmNegative.conversionModel == .density {
            autoConvertNegative(seedProfile: .labStandard)
        } else {
            editStack.filmNegative.isEnabled = true
            sampleFilmBase()
        }
    }

    /// - Parameter seedProfile: when non-nil AND the conversion is being
    ///   enabled for the first time (isEnabled false), the profile applied
    ///   before solving — the "new conversions default to Lab Standard" rule.
    ///   The Auto button passes nil: re-solving respects the user's profile.
    func autoConvertNegative(seedProfile: FilmToneProfile? = nil) {
        guard let source else { return }
        let measured = GeometryTransform.apply(source, geometry: editStack.geometry)
        var film = editStack.filmNegative
        if let seedProfile, !film.isEnabled {
            film.print.applyToneProfile(seedProfile)
        }
        film.isEnabled = true
        let sampled = film.baseOrigin == .sampled ? film.baseColor : nil
        guard let solution = AutoInvert.solve(scan: measured, sampledBase: sampled,
                                              profile: film.print.toneProfile,
                                              context: renderer.context) else { return }
        film.baseColor = solution.baseColor
        film.baseOrigin = solution.baseOrigin
        film.isBaseSampled = solution.baseOrigin == .sampled
        film.print.dmax = solution.dmax
        film.print.gamma = solution.gamma
        film.print.exposure = solution.printExposure
        film.print.gradePivot = solution.medianDensity
        film.print.castRed = solution.cast.red
        film.print.castGreen = solution.cast.green
        film.print.castBlue = solution.cast.blue
        film.exposure = 0
        // (existing stock-family inference + single assignment unchanged)
```

`FilmControlConformanceTests.baseStack()`: `AutoInvert.solve(scan: probe, sampledBase: nil, profile: .linear, context: renderer.context)!` — the suite's reference deliberately stays the linear render. `RealScanTests.convert`: same explicit `.linear` for now (Task 12 parameterizes it).

- [x] **Step 5: Run** `AutoInvertTests`, `FilmControlConformanceTests`, `RealScanTests` (corpus machine) — expected PASS; conformance reference must be bit-identical to pre-task (its reproducibility test plus unchanged case measurements are the evidence).

- [x] **Step 6: Also update FilmPanel's Auto button** — it calls `model.autoConvertNegative()`; the new defaulted parameter keeps it compiling unchanged. Verify with a build.

- [x] **Step 7: Commit**

```bash
git add Sources/Film/AutoInvert.swift Sources/Views/EditorModel.swift Tests/AutoInvertTests.swift Tests/FilmControlConformanceTests.swift Tests/RealScanTests.swift
git commit -m "feat(film): AutoInvert measure/solve split — profile-aware placement, gradePivot, cast slots"
```

---

### Task 7: Cast solver — neutral picker math + auto colour balance

Pure closed-form cast math in a new `CastSolver`, wired into `AutoInvert` (Lab profiles balance automatically) with the gray-world honesty gate.

**Files:**
- Create: `Sources/Film/CastSolver.swift`
- Modify: `Sources/Film/AutoInvert.swift`
- Test: create `Tests/CastSolverTests.swift`

**Interfaces:**
- Produces:

```swift
/// Closed-form cast correction: given per-channel densities of something
/// that SHOULD be neutral, the per-channel density offsets that equalize the
/// three straight-line log outputs — then expressed in cast-slider units.
enum CastSolver {
    /// Density offsets o_c with Σ tone preserved: target τ = mean of
    /// L_c = gamma_c·(D_c − Dmax_c); o_c = (τ − L_c)/gamma_c.
    static func densityOffsets(neutralDensity: DensityTriple,
                               gamma: DensityTriple,
                               dmax: DensityTriple) -> DensityTriple

    /// The same, as ±100 cast-slider values (PaperResponse.castDensity⁻¹),
    /// clamped to the slider range; `clipped` reports truncation.
    static func castSliders(neutralDensity: DensityTriple,
                            gamma: DensityTriple,
                            dmax: DensityTriple)
        -> (red: Double, green: Double, blue: Double, clipped: Bool)

    /// Fixed warm/cool biases (slider units) documented as taste constants.
    static let warmBias = (red: 8.0, green: 0.0, blue: -8.0)
}
```

- Modifies `AutoInvert.solve(from:profile:)`: when `profile.enablesAutoColorBalance`, solve `cast` from the median densities BEFORE the EV bisection, fold the cast into the bisection's develop call (as `printOffset += gammaEffective · castDensity`, the Task 4 fold), and gate honesty: if the median transmittances' chroma spread (via the existing `chromaSpread(_:)` on the srgbEncoded medians) exceeds 0.18, append `"auto colour balance: midtones are strongly coloured — check with the neutral picker"` to `degradedTerms`.

- [x] **Step 1: Write failing tests**

`Tests/CastSolverTests.swift`:

```swift
import CoreImage
import XCTest
@testable import PhotoEditor

final class CastSolverTests: XCTestCase {
    /// The defining property: applying the solved offsets makes the three
    /// straight-line log outputs equal, and their mean is unchanged (the
    /// correction moves colour, not exposure).
    func testSolvedOffsetsEqualizeWithoutMovingTheMean() {
        let d = DensityTriple(red: 1.30, green: 1.05, blue: 0.85)
        let gamma = DensityTriple(red: 1.1, green: 1.2, blue: 1.35)
        let dmax = DensityTriple(red: 2.2, green: 2.1, blue: 1.9)
        let o = CastSolver.densityOffsets(neutralDensity: d, gamma: gamma, dmax: dmax)
        func L(_ dd: Double, _ oo: Double, _ g: Double, _ dm: Double) -> Double {
            g * (dd + oo - dm)
        }
        let l = (L(d.red, o.red, gamma.red, dmax.red),
                 L(d.green, o.green, gamma.green, dmax.green),
                 L(d.blue, o.blue, gamma.blue, dmax.blue))
        XCTAssertEqual(l.0, l.1, accuracy: 1e-12)
        XCTAssertEqual(l.1, l.2, accuracy: 1e-12)
        let before = (L(d.red, 0, gamma.red, dmax.red)
                      + L(d.green, 0, gamma.green, dmax.green)
                      + L(d.blue, 0, gamma.blue, dmax.blue)) / 3
        XCTAssertEqual(l.0, before, accuracy: 1e-12,
                       "the equalized level must be the pre-correction mean")
    }

    func testCastSlidersRoundTripAndClamp() {
        let d = DensityTriple(red: 1.30, green: 1.05, blue: 0.85)
        let gamma = DensityTriple.unit
        let dmax = DensityTriple(red: 2, green: 2, blue: 2)
        let s = CastSolver.castSliders(neutralDensity: d, gamma: gamma, dmax: dmax)
        XCTAssertFalse(s.clipped)
        XCTAssertEqual(PaperResponse.castDensity(s.red),
                       CastSolver.densityOffsets(neutralDensity: d, gamma: gamma,
                                                 dmax: dmax).red,
                       accuracy: 1e-12)
        // A cast far past the slider range must clamp and say so.
        let wild = DensityTriple(red: 2.5, green: 1.0, blue: 0.2)
        let clamped = CastSolver.castSliders(neutralDensity: wild, gamma: gamma,
                                             dmax: dmax)
        XCTAssertTrue(clamped.clipped)
        XCTAssertLessThanOrEqual(abs(clamped.red), 100)
    }

    /// End-to-end: inject a known cast into the simulated negative (scale
    /// each channel's transmittance — exactly what a wrong Dmin does), solve
    /// under labStandard, and the auto colour balance must neutralize the
    /// rendered midtone.
    func testAutoColorBalanceNeutralizesAnInjectedCast() throws {
        let context = CIContext()
        let clean = FilmSim.negativeImage(dmin: FilmSim.c41Base,
                                          gammas: FilmSim.crossoverGammas, size: 128)
        // Inject: green transmittance × 10^(−0.12) — a green-magenta cast of
        // 0.12 density, well inside the ±0.5 EV solver range.
        let castMatrix = CIFilter.colorMatrix()
        castMatrix.inputImage = clean
        castMatrix.gVector = CIVector(x: 0, y: CGFloat(pow(10.0, -0.12)), z: 0, w: 0)
        let injected = castMatrix.outputImage!
        func medianChroma(_ solution: AutoInvertSolution, scan: CIImage) throws -> Double {
            var stack = EditStack()
            stack.filmNegative.isEnabled = true
            stack.filmNegative.conversionModel = .density
            stack.filmNegative.baseColor = solution.baseColor
            stack.filmNegative.baseOrigin = solution.baseOrigin
            stack.filmNegative.print.dmax = solution.dmax
            stack.filmNegative.print.gamma = solution.gamma
            stack.filmNegative.print.exposure = solution.printExposure
            stack.filmNegative.print.gradePivot = solution.medianDensity
            stack.filmNegative.print.castRed = solution.cast.red
            stack.filmNegative.print.castGreen = solution.cast.green
            stack.filmNegative.print.castBlue = solution.cast.blue
            stack.filmNegative.print.applyToneProfile(.labStandard)
            let out = EditRenderer().render(source: scan, stack: stack)
            let px = try XCTUnwrap(AutoInvert.linearPixels(of: out, side: 64,
                                                           context: context))
            let med = (AutoInvert.percentile(px.map(\.0).sorted(), 0.5),
                       AutoInvert.percentile(px.map(\.1).sorted(), 0.5),
                       AutoInvert.percentile(px.map(\.2).sorted(), 0.5))
            let n = max(med.0, max(med.1, med.2))
            return n > 0 ? (n - min(med.0, min(med.1, med.2))) / n : 0
        }
        let balanced = try XCTUnwrap(AutoInvert.solve(scan: injected, sampledBase: nil,
                                                      profile: .labStandard,
                                                      context: context))
        XCTAssertNotEqual(balanced.cast.green, 0,
                          "labStandard must have solved a green cast correction")
        let chroma = try medianChroma(balanced, scan: injected)
        XCTAssertLessThan(chroma, 0.06,
                          "auto colour balance left the midtone visibly cast")
        let linear = try XCTUnwrap(AutoInvert.solve(scan: injected, sampledBase: nil,
                                                    profile: .linear, context: context))
        XCTAssertEqual(linear.cast.red, 0, "linear must not auto-balance")
    }
}
```

- [x] **Step 2: Run — expect compile failure.** (`AutoInvert.percentile` is currently internal-static — it is; `chromaSpread` stays private, the solver body uses it internally.)

- [x] **Step 3: Implement `CastSolver.swift`**

```swift
import Foundation

/// Closed-form cast correction (spec §Cast correction). Given the densities
/// of something that SHOULD render neutral — the eyedropper's patch, or the
/// per-channel medians for auto colour balance — solve the per-channel
/// density offsets that equalize the three straight-line log outputs at
/// their mean: τ = mean(L_c), L_c = γ_c·(D_c − Dmax_c), o_c = (τ − L_c)/γ_c.
/// Equalizing AT THE MEAN moves colour without moving exposure.
enum CastSolver {
    static func densityOffsets(neutralDensity d: DensityTriple,
                               gamma: DensityTriple,
                               dmax: DensityTriple) -> DensityTriple {
        let l = (gamma.red * (d.red - dmax.red),
                 gamma.green * (d.green - dmax.green),
                 gamma.blue * (d.blue - dmax.blue))
        let tau = (l.0 + l.1 + l.2) / 3
        func safe(_ g: Double) -> Double { abs(g) > 1e-6 ? g : 1 }
        return DensityTriple(red: (tau - l.0) / safe(gamma.red),
                             green: (tau - l.1) / safe(gamma.green),
                             blue: (tau - l.2) / safe(gamma.blue))
    }

    static func castSliders(neutralDensity: DensityTriple,
                            gamma: DensityTriple,
                            dmax: DensityTriple)
        -> (red: Double, green: Double, blue: Double, clipped: Bool) {
        let o = densityOffsets(neutralDensity: neutralDensity, gamma: gamma, dmax: dmax)
        let unit = PaperResponse.castFullScaleEV * log10(2.0) / 100.0
        let raw = (o.red / unit, o.green / unit, o.blue / unit)
        func clamp(_ v: Double) -> Double { min(max(v, -100), 100) }
        let clipped = raw.0 != clamp(raw.0) || raw.1 != clamp(raw.1) || raw.2 != clamp(raw.2)
        return (clamp(raw.0), clamp(raw.1), clamp(raw.2), clipped)
    }

    /// Warm/cool auto-balance biases in slider units — a gentle, documented
    /// push either side of neutral (±0.04 EV split red/blue), the NLP
    /// auto-warm/auto-cool idea sized to this engine's slider scale.
    static let warmBias = (red: 8.0, green: 0.0, blue: -8.0)
}
```

- [x] **Step 4: Wire auto colour balance into `AutoInvert.solve(from:profile:)`**

After the gamma solve and median computation, before the bisection:

```swift
        var cast = DensityTriple.zero   // slider units — see AutoInvertSolution.cast
        if profile.enablesAutoColorBalance {
            let solved = CastSolver.castSliders(
                neutralDensity: DensityTriple(red: medianD.0, green: medianD.1,
                                              blue: medianD.2),
                gamma: gamma, dmax: DensityTriple(red: dmaxV.0, green: dmaxV.1,
                                                  blue: dmaxV.2))
            cast = DensityTriple(red: solved.red, green: solved.green, blue: solved.blue)
            if solved.clipped {
                degraded.append("auto colour balance hit the slider limit")
            }
            let medianColor = FilmColor(red: PaperResponse.srgbEncode(medianT.0),
                                        green: PaperResponse.srgbEncode(medianT.1),
                                        blue: PaperResponse.srgbEncode(medianT.2))
            if chromaSpread(medianColor) > 0.18 {
                degraded.append("auto colour balance: midtones are strongly coloured — check with the neutral picker")
            }
        }
```

and fold it into the bisection's develop call: `offset.0 += gamma.red * PaperResponse.castDensity(cast.red)` (×3, applied to the offset each iteration — hoist the three folded constants out of the loop). Return `cast` in the solution.

- [x] **Step 5: Run CastSolverTests + AutoInvertTests + FilmControlConformanceTests** — expected PASS (conformance solves `.linear`: cast stays zero, reference unchanged).

- [x] **Step 6: Commit**

```bash
git add Sources/Film/CastSolver.swift Sources/Film/AutoInvert.swift Tests/CastSolverTests.swift project.yml PhotoEditor.xcodeproj
git commit -m "feat(film): closed-form cast solver — auto colour balance under Lab profiles, honesty-gated"
```

---

### Task 8: Catalog v8 — rolls

**Files:**
- Create: `Sources/Models/Roll.swift`
- Modify: `Sources/Catalog/CatalogStore.swift`, `Sources/Models/CatalogEntry.swift`
- Test: `Tests/CatalogStoreTests.swift` (append)

**Interfaces:**
- Produces:

```swift
/// A roll's solved conversion: the roll-level constants every frame shares.
/// Stored on the roll (JSON column) so frames added later adopt it.
struct RollConversion: Codable, Equatable {
    var baseColor: FilmColor          // display-encoded, like every base
    var baseOrigin: FilmBaseOrigin
    var gamma: DensityTriple
    var dmax: DensityTriple
    var castRed: Double
    var castGreen: Double
    var castBlue: Double
    var toneProfile: FilmToneProfile
}

/// A physical roll of film: the unit conversion constants belong to.
/// "A roll is a physical fact, a collection is an editorial choice" — the
/// roadmap's boundary; collections are Phase 4 and stay out of this type.
struct Roll: Codable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "roll"
    let id: UUID
    var identifier: String            // "2026-07 Portra roll 3"
    var stock: String?
    var camera: String?
    var lens: String?
    var exposureIndex: Int?
    var pushPull: Int?
    var developer: String?
    var devNotes: String?
    var lab: String?
    var scanDate: Date?
    let dateCreated: Date
    var conversion: RollConversion?
}
```

  - `CatalogEntry.rollID: UUID?`, `CatalogEntry.frameNumber: Int?` (lenient decode, defaulted init params at the end of the initializer so existing call sites compile unchanged)
  - `CatalogStore`: `allRolls() throws -> [Roll]`, `saveRoll(_:) throws`, `deleteRoll(id: UUID) throws`, `entries(inRoll: UUID) throws -> [CatalogEntry]` (ordered by `frameNumber`, then `dateImported`)

- [x] **Step 1: Write failing tests**

Append to `Tests/CatalogStoreTests.swift` (follow that file's existing in-memory-store fixture style):

```swift
func testRollRoundTripAndAssignment() throws {
    let store = try CatalogStore()
    var roll = Roll(id: UUID(), identifier: "test roll", stock: "Portra 400",
                    camera: nil, lens: nil, exposureIndex: nil, pushPull: nil,
                    developer: nil, devNotes: nil, lab: nil, scanDate: nil,
                    dateCreated: Date(), conversion: nil)
    try store.saveRoll(roll)
    XCTAssertEqual(try store.allRolls().map(\.id), [roll.id])

    var entry = CatalogEntry(id: UUID(), fileURL: URL(fileURLWithPath: "/tmp/a.tif"),
                             dateImported: Date(), editStack: EditStack(),
                             thumbnailPath: nil)
    entry.rollID = roll.id
    entry.frameNumber = 7
    try store.save(entry)
    let inRoll = try store.entries(inRoll: roll.id)
    XCTAssertEqual(inRoll.map(\.id), [entry.id])
    XCTAssertEqual(inRoll[0].frameNumber, 7)

    roll.conversion = RollConversion(
        baseColor: FilmColor(red: 0.9, green: 0.6, blue: 0.3),
        baseOrigin: .estimated, gamma: .unit,
        dmax: DensityTriple(red: 2, green: 2, blue: 2),
        castRed: 3, castGreen: 0, castBlue: -2, toneProfile: .labStandard)
    try store.saveRoll(roll)
    XCTAssertEqual(try store.allRolls()[0].conversion?.castRed, 3)
}

/// A pre-v8 row (no rollID key in its JSON) still decodes.
func testEntriesWithoutRollFieldsDecode() throws {
    let json = #"{"id": "00000000-0000-0000-0000-000000000001", "fileURL": "file:///tmp/a.tif", "dateImported": 0, "editStack": {}}"#
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    let entry = try decoder.decode(CatalogEntry.self, from: json.data(using: .utf8)!)
    XCTAssertNil(entry.rollID)
    XCTAssertNil(entry.frameNumber)
}
```

- [x] **Step 2: Run to verify failure**, then implement: `Roll.swift` as above; in `CatalogStore.migrator` append after `v7_stockPrintCharacter`:

```swift
        // Phase 2.5 (the Minilab): the roll table the Phase 3 roadmap
        // sketched — created here because roll-level conversion needs it now.
        // Phase 3 fills the metadata columns (body, developer, lab, …).
        migrator.registerMigration("v8_rolls") { db in
            try db.create(table: Roll.databaseTableName) { t in
                t.primaryKey("id", .blob)
                t.column("identifier", .text).notNull()
                t.column("stock", .text)
                t.column("camera", .text)
                t.column("lens", .text)
                t.column("exposureIndex", .integer)
                t.column("pushPull", .integer)
                t.column("developer", .text)
                t.column("devNotes", .text)
                t.column("lab", .text)
                t.column("scanDate", .datetime)
                t.column("dateCreated", .datetime).notNull()
                t.column("conversion", .text) // JSON RollConversion
            }
            try db.alter(table: CatalogEntry.databaseTableName) { t in
                t.add(column: "rollID", .blob)
                t.add(column: "frameNumber", .integer)
            }
            try db.create(index: "idx_catalogEntry_rollID",
                          on: CatalogEntry.databaseTableName, columns: ["rollID"])
        }
```

plus the four store methods (mirror the film-stock CRUD section's style) and the `CatalogEntry` fields + `rollID = c.lenient(.rollID, nil)` / `frameNumber = c.lenient(.frameNumber, nil)` in its decoder.

- [x] **Step 3: Run** `CatalogStoreTests` — PASS. Then `xcodegen generate` was needed for `Roll.swift` — confirm the build includes it.

- [x] **Step 4: Commit**

```bash
git add Sources/Models/Roll.swift Sources/Catalog/CatalogStore.swift Sources/Models/CatalogEntry.swift Tests/CatalogStoreTests.swift project.yml PhotoEditor.xcodeproj
git commit -m "feat(catalog): v8 rolls — roll table, rollID/frameNumber, roll conversion record"
```

---

### Task 9: RollAnalysis — roll-level constants, per-frame exposure

The consistency discipline: gammas and base are roll constants from pooled statistics; only print EV solves per frame.

**Files:**
- Create: `Sources/Film/RollAnalysis.swift`
- Modify: `Sources/Film/AutoInvert.swift` (extract the shared EV bisection)
- Test: create `Tests/RollAnalysisTests.swift`

**Interfaces:**
- Produces:

```swift
struct RollSolution: Equatable {
    var conversion: RollConversion
    var frameExposures: [Double]       // parallel to the input measurements
    var framePivots: [DensityTriple]   // per-frame gradePivot (median densities)
    var degradedTerms: [String]
}

enum RollAnalysis {
    /// Solves roll-level constants from ALL frames' measurements, then one
    /// exposure per frame. Deterministic, closed-form + bisection, like Auto.
    static func solve(measurements: [FrameMeasurement],
                      profile: FilmToneProfile) -> RollSolution?
}
```

- Refactors `AutoInvert`: extract the bisection into
  `static func solveExposure(medianT: (Double, Double, Double), dminLinear: (Double, Double, Double), dmax: DensityTriple, gamma: DensityTriple, cast: DensityTriple, profile: FilmToneProfile) -> Double`
  (`cast` in slider units, matching `AutoInvertSolution.cast`) — `AutoInvert.solve(from:profile:)` and `RollAnalysis` both call it (one bisection, two callers; the Task 6/7 fold/develop code moves inside unchanged).

- [ ] **Step 1: Write failing tests**

`Tests/RollAnalysisTests.swift`:

```swift
import CoreImage
import XCTest
@testable import PhotoEditor

final class RollAnalysisTests: XCTestCase {
    private let context = CIContext()

    /// Three frames of one simulated roll: identical film (base + gammas),
    /// different content — a full-scene frame, a shadow-heavy crop, a
    /// highlight-heavy crop — plus an exposure shift. The situation that
    /// makes per-frame Auto inconsistent by construction.
    private func rollFrames() -> [CIImage] {
        let full = FilmSim.negativeImage(dmin: FilmSim.c41Base,
                                         gammas: FilmSim.crossoverGammas, size: 128)
        let dark = full.cropped(to: CGRect(x: 12, y: 12, width: 50, height: 104))
        let bright = full.cropped(to: CGRect(x: 62, y: 12, width: 54, height: 104))
        let dim = CIFilter.colorMatrix()
        dim.inputImage = full
        let k = CGFloat(pow(10.0, -0.2)) // −0.2 density: a thinner exposure
        dim.rVector = CIVector(x: k, y: 0, z: 0, w: 0)
        dim.gVector = CIVector(x: 0, y: k, z: 0, w: 0)
        dim.bVector = CIVector(x: 0, y: 0, z: k, w: 0)
        return [full, dark, bright, dim.outputImage!]
    }

    func testRollConstantsAreSharedAndPerFrameSolvesAreNot() throws {
        let frames = rollFrames()
        let ms = try frames.map {
            try XCTUnwrap(AutoInvert.measure(scan: $0, sampledBase: nil,
                                             context: context))
        }
        // Per-frame: the gammas genuinely differ across these frames — the
        // inconsistency this whole task exists to remove.
        let perFrame = try ms.map { try XCTUnwrap(AutoInvert.solve(from: $0, profile: .linear)) }
        let gammaSpread = perFrame.map(\.gamma.red).max()! - perFrame.map(\.gamma.red).min()!
        XCTAssertGreaterThan(gammaSpread, 0.01,
                             "the fixture no longer provokes per-frame drift — strengthen it")

        let roll = try XCTUnwrap(RollAnalysis.solve(measurements: ms, profile: .linear))
        XCTAssertEqual(roll.frameExposures.count, frames.count)
        XCTAssertEqual(roll.framePivots.count, frames.count)
        // One gamma/dmax/base for the roll; exposures differ per frame.
        XCTAssertGreaterThan(
            roll.frameExposures.max()! - roll.frameExposures.min()!, 0.05,
            "the dimmed frame must solve a different exposure")
    }

    /// The metric that justifies the feature: the rebate (border) of every
    /// frame is IDENTICAL film base, so after conversion its chromaticity
    /// should agree across frames. Roll-solved frames must agree at least as
    /// well as per-frame-solved ones (in practice far better).
    func testRollSolveShrinksCrossFrameChromaVariance() throws {
        let frames = rollFrames()
        let ms = try frames.map {
            try XCTUnwrap(AutoInvert.measure(scan: $0, sampledBase: nil,
                                             context: context))
        }
        let perFrame = try ms.map { try XCTUnwrap(AutoInvert.solve(from: $0, profile: .linear)) }
        let roll = try XCTUnwrap(RollAnalysis.solve(measurements: ms, profile: .linear))

        func borderChroma(_ image: CIImage, settings: FilmNegativeSettings) throws -> Double {
            let out = FilmDensityConverter.convert(image, settings: settings)
            // The frame's lower-left corner is rebate in every fixture frame.
            let corner = out.cropped(to: CGRect(x: out.extent.minX, y: out.extent.minY,
                                                width: 8, height: 8))
            let px = try XCTUnwrap(AutoInvert.linearPixels(of: corner, side: 8,
                                                           context: context))
            let mean = px.reduce((0.0, 0.0, 0.0)) { ($0.0 + $1.0, $0.1 + $1.1, $0.2 + $1.2) }
            let c = (mean.0 / Double(px.count), mean.1 / Double(px.count),
                     mean.2 / Double(px.count))
            let n = max(c.0, max(c.1, c.2))
            return n > 0 ? (n - min(c.0, min(c.1, c.2))) / n : 0
        }
        func settings(base: FilmColor, origin: FilmBaseOrigin, gamma: DensityTriple,
                      dmax: DensityTriple, ev: Double, pivot: DensityTriple) -> FilmNegativeSettings {
            var f = FilmNegativeSettings()
            f.isEnabled = true; f.conversionModel = .density
            f.baseColor = base; f.baseOrigin = origin
            f.print.gamma = gamma; f.print.dmax = dmax
            f.print.exposure = ev; f.print.gradePivot = pivot
            return f
        }
        func variance(_ v: [Double]) -> Double {
            let m = v.reduce(0, +) / Double(v.count)
            return v.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(v.count)
        }
        let perFrameChroma = try zip(frames, perFrame).map { frame, s in
            try borderChroma(frame, settings: settings(
                base: s.baseColor, origin: s.baseOrigin, gamma: s.gamma,
                dmax: s.dmax, ev: s.printExposure, pivot: s.medianDensity))
        }
        let c = roll.conversion
        let rollChroma = try zip(frames, zip(roll.frameExposures, roll.framePivots)).map {
            frame, solved in
            try borderChroma(frame, settings: settings(
                base: c.baseColor, origin: c.baseOrigin, gamma: c.gamma,
                dmax: c.dmax, ev: solved.0, pivot: solved.1))
        }
        XCTAssertLessThanOrEqual(variance(rollChroma), variance(perFrameChroma) * 1.05,
                                 "roll analysis must not be less consistent than per-frame")
        print("ROLLCONSISTENCY synthetic: perFrame=\(variance(perFrameChroma)) roll=\(variance(rollChroma))")
    }

    /// A sampled rebate base anywhere on the roll wins for the whole roll.
    func testSampledBaseAnywhereWinsForTheRoll() throws {
        let frames = rollFrames()
        let sampled = FilmColor(red: 0.94, green: 0.72, blue: 0.50)
        var ms = try frames.map {
            try XCTUnwrap(AutoInvert.measure(scan: $0, sampledBase: nil,
                                             context: context))
        }
        ms[2].sampledBase = sampled
        let roll = try XCTUnwrap(RollAnalysis.solve(measurements: ms, profile: .linear))
        XCTAssertEqual(roll.conversion.baseOrigin, .sampled)
        XCTAssertEqual(roll.conversion.baseColor, sampled)
    }
}
```

- [ ] **Step 2: Run — expect compile failure.**

- [ ] **Step 3: Implement**

Extract `AutoInvert.solveExposure` (move the Task 6/7 bisection verbatim; both callers pass their own inputs). Then `RollAnalysis.swift`:

```swift
import Foundation

/// Roll-level conversion (spec §Roll model & roll analysis): per-channel
/// base and gamma are properties of the roll — solved once from statistics
/// pooled across every frame — and only print exposure varies per frame.
/// The C F Systems / NLP-v3 discipline, applied to AutoInvert's own math.
enum RollAnalysis {
    static func solve(measurements: [FrameMeasurement],
                      profile: FilmToneProfile) -> RollSolution? {
        guard !measurements.isEmpty,
              measurements.allSatisfy({ !$0.sortedRed.isEmpty }) else { return nil }
        var degraded = measurements.flatMap(\.degradedTerms)

        // 1. Roll base: any sampled rebate wins (median across sampled frames
        // if several); otherwise the thinnest-film envelope — the per-channel
        // MINIMUM over each frame's own 98th-percentile estimate, because the
        // thinnest film seen anywhere on the roll is closest to true base.
        let sampled = measurements.compactMap(\.sampledBase)
        let dminLinear: (Double, Double, Double)
        let origin: FilmBaseOrigin
        let baseColor: FilmColor
        if !sampled.isEmpty {
            func median(_ v: [Double]) -> Double {
                let s = v.sorted(); return s[s.count / 2]
            }
            baseColor = FilmColor(red: median(sampled.map(\.red)),
                                  green: median(sampled.map(\.green)),
                                  blue: median(sampled.map(\.blue)))
            dminLinear = (PaperResponse.srgbDecode(baseColor.red),
                          PaperResponse.srgbDecode(baseColor.green),
                          PaperResponse.srgbDecode(baseColor.blue))
            origin = .sampled
        } else {
            let perFrame = measurements.map { m in
                (AutoInvert.percentile(m.sortedRed, PaperResponse.dminPercentile),
                 AutoInvert.percentile(m.sortedGreen, PaperResponse.dminPercentile),
                 AutoInvert.percentile(m.sortedBlue, PaperResponse.dminPercentile))
            }
            dminLinear = (perFrame.map(\.0).min()!,
                          perFrame.map(\.1).min()!,
                          perFrame.map(\.2).min()!)
            baseColor = FilmColor(red: PaperResponse.srgbEncode(dminLinear.0),
                                  green: PaperResponse.srgbEncode(dminLinear.1),
                                  blue: PaperResponse.srgbEncode(dminLinear.2))
            origin = .estimated
        }

        // 2. Densities per frame against the ROLL base; pooled per channel.
        func density(_ t: Double, _ dmin: Double) -> Double {
            log10(max(dmin, 1e-4) / max(t, PaperResponse.transmittanceFloor))
        }
        var frameDensities: [([Double], [Double], [Double])] = []
        for m in measurements {
            var r = m.sortedRed.map { density($0, dminLinear.0) }
            var g = m.sortedGreen.map { density($0, dminLinear.1) }
            var b = m.sortedBlue.map { density($0, dminLinear.2) }
            r.sort(); g.sort(); b.sort()
            frameDensities.append((r, g, b))
        }
        let pooled = (frameDensities.flatMap(\.0).sorted(),
                      frameDensities.flatMap(\.1).sorted(),
                      frameDensities.flatMap(\.2).sorted())

        // 3–5. Roll endpoints and gammas — AutoInvert's own math on the pool.
        let dmaxV = DensityTriple(
            red: AutoInvert.percentile(pooled.0, PaperResponse.dmaxPercentile),
            green: AutoInvert.percentile(pooled.1, PaperResponse.dmaxPercentile),
            blue: AutoInvert.percentile(pooled.2, PaperResponse.dmaxPercentile))
        let dlow = (AutoInvert.percentile(pooled.0, PaperResponse.dLowPercentile),
                    AutoInvert.percentile(pooled.1, PaperResponse.dLowPercentile),
                    AutoInvert.percentile(pooled.2, PaperResponse.dLowPercentile))
        func solveGamma(_ dlow: Double, _ dmax: Double, _ channel: String) -> Double {
            let range = dlow - dmax
            guard abs(range) > 0.05 else {
                degraded.append("roll gamma (\(channel)): no measurable density range")
                return 1.0
            }
            return log10(PaperResponse.targetBlack) / range
        }
        let gamma = DensityTriple(red: solveGamma(dlow.0, dmaxV.red, "red"),
                                  green: solveGamma(dlow.1, dmaxV.green, "green"),
                                  blue: solveGamma(dlow.2, dmaxV.blue, "blue"))

        // Roll cast from the POOLED medians (roll-level: per-frame auto
        // balance would reintroduce exactly the drift this type removes).
        var cast = DensityTriple.zero   // slider units
        if profile.enablesAutoColorBalance {
            let pooledMedian = DensityTriple(
                red: AutoInvert.percentile(pooled.0, 0.5),
                green: AutoInvert.percentile(pooled.1, 0.5),
                blue: AutoInvert.percentile(pooled.2, 0.5))
            let solved = CastSolver.castSliders(neutralDensity: pooledMedian,
                                                gamma: gamma, dmax: dmaxV)
            cast = DensityTriple(red: solved.red, green: solved.green, blue: solved.blue)
            if solved.clipped { degraded.append("roll colour balance hit the slider limit") }
        }

        // 6. Per frame: exposure only, from that frame's own medians.
        var exposures: [Double] = []
        var pivots: [DensityTriple] = []
        for d in frameDensities {
            let medianD = (AutoInvert.percentile(d.0, 0.5),
                           AutoInvert.percentile(d.1, 0.5),
                           AutoInvert.percentile(d.2, 0.5))
            let medianT = (dminLinear.0 * pow(10, -medianD.0),
                           dminLinear.1 * pow(10, -medianD.1),
                           dminLinear.2 * pow(10, -medianD.2))
            exposures.append(AutoInvert.solveExposure(
                medianT: medianT, dminLinear: dminLinear, dmax: dmaxV,
                gamma: gamma, cast: cast, profile: profile))
            pivots.append(DensityTriple(red: medianD.0, green: medianD.1, blue: medianD.2))
        }

        return RollSolution(
            conversion: RollConversion(baseColor: baseColor, baseOrigin: origin,
                                       gamma: gamma, dmax: dmaxV,
                                       castRed: cast.red, castGreen: cast.green,
                                       castBlue: cast.blue, toneProfile: profile),
            // (cast is slider units carried in a DensityTriple — see
            //  AutoInvertSolution.cast's doc comment)
            frameExposures: exposures, framePivots: pivots,
            degradedTerms: degraded)
    }
}
```

- [ ] **Step 4: Run** `RollAnalysisTests` + `AutoInvertTests` (the extraction must not change `AutoInvert.solve` results — its tests prove it). Expected PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Film/RollAnalysis.swift Sources/Film/AutoInvert.swift Tests/RollAnalysisTests.swift project.yml PhotoEditor.xcodeproj
git commit -m "feat(film): RollAnalysis — roll-level base/gamma/cast from pooled statistics, per-frame exposure only"
```

---

### Task 10: RollModel + roll workflow (create, assign, convert, roll-aware Auto)

**Files:**
- Create: `Sources/Views/RollModel.swift`
- Modify: `Sources/App/AppModel.swift`, `Sources/Views/EditorModel.swift`, `Sources/Views/LibrarySidebar.swift`, `Sources/App/EditorCommands.swift`
- Test: create `Tests/RollModelTests.swift`

**Interfaces:**
- Produces:

```swift
@Observable
final class RollModel {
    private unowned let app: AppModel
    private(set) var rolls: [Roll] = []
    private(set) var isConverting = false

    init(app: AppModel)
    func reload()                                     // rolls = catalog.allRolls()
    func roll(for entry: CatalogEntry) -> Roll?
    @discardableResult
    func createRoll(identifier: String, stock: String?,
                    from entries: [CatalogEntry]) -> Roll?
    func add(_ entries: [CatalogEntry], to roll: Roll)
    func convertRoll(_ roll: Roll, profile: FilmToneProfile = .labStandard) async

    /// Pure core of convertRoll, separated for testability: the stacks to
    /// write, one per entry, in entry order. Frames whose baseOrigin is
    /// .sampled keep their own base; everyone shares the roll constants.
    static func conversionStacks(entries: [CatalogEntry],
                                 solution: RollSolution) -> [(CatalogEntry, EditStack)]
}
```

  - `AppModel` gains `private(set) lazy var rollModel = RollModel(app: self)` and the batch-writer RollModel and future sync share:

```swift
    /// Saves prepared (entry, stack) pairs: persists, updates `entries`,
    /// refreshes thumbnails, reopens the editor if it shows one of them.
    /// The roll-wide/sync-across-selection shared mechanism (spec §Roll
    /// model; Phase 4 reuses this).
    @discardableResult
    func updateStacks(_ updates: [(CatalogEntry, EditStack)]) -> Int
```

  - `EditorModel` gains `var rollConversion: RollConversion?` (set by `AppModel.open` when the entry's roll has a solved conversion) — `autoConvertNegative` uses it: roll constants + frame-only EV.

- [ ] **Step 1: Write failing tests**

`Tests/RollModelTests.swift`:

```swift
import CoreImage
import XCTest
@testable import PhotoEditor

final class RollModelTests: XCTestCase {
    private func entry(_ name: String, stack: EditStack = EditStack()) -> CatalogEntry {
        CatalogEntry(id: UUID(), fileURL: URL(fileURLWithPath: "/tmp/\(name).tif"),
                     dateImported: Date(), editStack: stack, thumbnailPath: nil)
    }

    func testConversionStacksShareConstantsAndKeepSampledBases() throws {
        var sampledStack = EditStack()
        sampledStack.filmNegative.baseColor = FilmColor(red: 0.9, green: 0.7, blue: 0.5)
        sampledStack.filmNegative.baseOrigin = .sampled
        sampledStack.filmNegative.isBaseSampled = true
        let entries = [entry("a"), entry("b", stack: sampledStack), entry("c")]
        let conversion = RollConversion(
            baseColor: FilmColor(red: 0.95, green: 0.75, blue: 0.55),
            baseOrigin: .estimated,
            gamma: DensityTriple(red: 1.1, green: 1.2, blue: 1.3),
            dmax: DensityTriple(red: 2.1, green: 2.0, blue: 1.9),
            castRed: 4, castGreen: 0, castBlue: -3, toneProfile: .labStandard)
        let solution = RollSolution(conversion: conversion,
                                    frameExposures: [0.5, 0.7, 0.9],
                                    framePivots: [DensityTriple.unit, .unit, .unit],
                                    degradedTerms: [])
        let stacks = RollModel.conversionStacks(entries: entries, solution: solution)
        XCTAssertEqual(stacks.count, 3)
        for (i, (_, stack)) in stacks.enumerated() {
            let f = stack.filmNegative
            XCTAssertTrue(f.isEnabled)
            XCTAssertEqual(f.conversionModel, .density)
            XCTAssertEqual(f.print.gamma, conversion.gamma)
            XCTAssertEqual(f.print.dmax, conversion.dmax)
            XCTAssertEqual(f.print.castRed, conversion.castRed)
            XCTAssertEqual(f.print.toneProfile, .labStandard)
            XCTAssertEqual(f.print.punch, FilmToneProfile.labStandard.punch)
            XCTAssertEqual(f.print.exposure, solution.frameExposures[i])
            XCTAssertEqual(f.exposure, 0, "legacy EV must be zeroed, like Auto")
        }
        XCTAssertEqual(stacks[0].1.filmNegative.baseColor, conversion.baseColor)
        XCTAssertEqual(stacks[1].1.filmNegative.baseColor,
                       sampledStack.filmNegative.baseColor,
                       "a frame's own sampled base survives roll conversion")
        XCTAssertEqual(stacks[1].1.filmNegative.baseOrigin, .sampled)
    }

    func testCreateAndAssignRollNumbersFramesInOrder() throws {
        let store = try CatalogStore()
        let a = entry("a"), b = entry("b")
        try store.save(a); try store.save(b)
        var roll = Roll(id: UUID(), identifier: "r1", stock: nil, camera: nil,
                        lens: nil, exposureIndex: nil, pushPull: nil, developer: nil,
                        devNotes: nil, lab: nil, scanDate: nil,
                        dateCreated: Date(), conversion: nil)
        try store.saveRoll(roll)
        var ua = a; ua.rollID = roll.id; ua.frameNumber = 1
        var ub = b; ub.rollID = roll.id; ub.frameNumber = 2
        try store.save(ua); try store.save(ub)
        XCTAssertEqual(try store.entries(inRoll: roll.id).map(\.frameNumber), [1, 2])
        _ = roll // silences the unused-var warning if the compiler raises one
    }
}
```

(The second test pins the store contract `RollModel.createRoll` builds on; `createRoll`/`add`/`convertRoll` themselves are thin AppModel plumbing exercised by the corpus tests and by hand — the pure core is what gets the unit coverage.)

- [ ] **Step 2: Run — expect compile failure.**

- [ ] **Step 3: Implement**

`RollModel.swift` — `conversionStacks`:

```swift
    static func conversionStacks(entries: [CatalogEntry],
                                 solution: RollSolution) -> [(CatalogEntry, EditStack)] {
        zip(entries, zip(solution.frameExposures, solution.framePivots)).map {
            entry, solved in
            var stack = entry.editStack
            var film = stack.filmNegative
            film.isEnabled = true
            film.conversionModel = .density
            if film.baseOrigin != .sampled {
                film.baseColor = solution.conversion.baseColor
                film.baseOrigin = solution.conversion.baseOrigin
                film.isBaseSampled = false
            }
            film.print.applyToneProfile(solution.conversion.toneProfile)
            film.print.gamma = solution.conversion.gamma
            film.print.dmax = solution.conversion.dmax
            film.print.castRed = solution.conversion.castRed
            film.print.castGreen = solution.conversion.castGreen
            film.print.castBlue = solution.conversion.castBlue
            film.print.exposure = solved.0
            film.print.gradePivot = solved.1
            film.exposure = 0
            stack.filmNegative = film
            return (entry, stack)
        }
    }
```

`convertRoll` (async): entries = `catalog.entries(inRoll:)`; per entry decode `ImageDecoder.loadPreviewImage(from:maxDimension: 1600, processVersion: 2)`, `GeometryTransform.apply(scan, geometry: entry.editStack.geometry)`, `AutoInvert.measure(scan:sampledBase: film.baseOrigin == .sampled ? film.baseColor : nil, context:)` (skip-and-report frames that fail to decode); `RollAnalysis.solve`; per frame `catalog.saveSnapshot(EditSnapshot(...name: "Before Roll Conversion"...))` — preserve, never destroy; `app.updateStacks(Self.conversionStacks(...))`; store `roll.conversion = solution.conversion` via `saveRoll`; `reload()`. Wrap the decode/measure loop in `isConverting` state. `createRoll`: saveRoll + number frames by `dateImported` order via `updateStacks`-style entry saves (rollID/frameNumber are entry columns, not stack — save entries directly through `catalog.save` + `app` list refresh).

`AppModel.updateStacks` — extract the loop body of the existing `apply(_:to:options:)` (save, entries[index] =, refreshThumbnail, editor reopen) so both call one implementation.

`EditorModel.autoConvertNegative` — before the solve:

```swift
        if let rc = rollConversion, forceProfile == nil {
            // A rolled frame re-Autos against its roll's constants: measure
            // this frame, solve exposure only. Constants stay the roll's —
            // that IS the consistency contract. (Switching profiles via
            // forceProfile deliberately leaves the roll and does a full
            // per-frame solve; Convert Roll re-establishes the roll.)
            guard let m = AutoInvert.measure(scan: measured, sampledBase: sampled,
                                             context: renderer.context) else { return }
            let base = (film.baseOrigin == .sampled) ? film.baseColor : rc.baseColor
            let dminLin = (PaperResponse.srgbDecode(base.red),
                           PaperResponse.srgbDecode(base.green),
                           PaperResponse.srgbDecode(base.blue))
            func density(_ t: Double, _ dm: Double) -> Double {
                log10(max(dm, 1e-4) / max(t, PaperResponse.transmittanceFloor))
            }
            let medianD = DensityTriple(
                red: density(AutoInvert.percentile(m.sortedRed, 0.5), dminLin.0),
                green: density(AutoInvert.percentile(m.sortedGreen, 0.5), dminLin.1),
                blue: density(AutoInvert.percentile(m.sortedBlue, 0.5), dminLin.2))
            let medianT = (dminLin.0 * pow(10, -medianD.red),
                           dminLin.1 * pow(10, -medianD.green),
                           dminLin.2 * pow(10, -medianD.blue))
            if film.baseOrigin != .sampled {
                film.baseColor = rc.baseColor
                film.baseOrigin = rc.baseOrigin
                film.isBaseSampled = false
            }
            film.print.gamma = rc.gamma
            film.print.dmax = rc.dmax
            film.print.castRed = rc.castRed
            film.print.castGreen = rc.castGreen
            film.print.castBlue = rc.castBlue
            film.print.applyToneProfile(rc.toneProfile)
            film.print.exposure = AutoInvert.solveExposure(
                medianT: medianT, dminLinear: dminLin, dmax: rc.dmax,
                gamma: rc.gamma,
                cast: DensityTriple(red: rc.castRed, green: rc.castGreen,
                                    blue: rc.castBlue),
                profile: rc.toneProfile)
            film.print.gradePivot = medianD
            film.exposure = 0
            editStack.filmNegative = film
            return
        }
```

`AppModel.open` sets `editor.rollConversion = rollModel.roll(for: entry)?.conversion`.

UI: `LibrarySidebar` context menu after "Paste Settings" — `Menu("Roll")` with "New Roll from Selection…" (sheet: two `InstrumentField`s — identifier, stock — and a `PlateButton("Create")`; drawn chrome, not a stock alert), "Add to Roll" submenu over `app.rollModel.rolls`, and "Convert Roll" (visible when every target shares one `rollID`). `FilmstripRow`: when `entry.rollID` resolves, append the roll identifier to the existing edge-print legend (the decoration becomes data — keep `Theme.filmEdge`, same type size). `EditorCommands`: Develop menu → "Convert Roll" invoking the same action for the open frame's roll, disabled when `rollID == nil`.

- [ ] **Step 4: Run** `RollModelTests` + `CatalogStoreTests`, then build the app (`xcodebuild … build`) to prove the UI wiring compiles. Expected PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Views/RollModel.swift Sources/App/AppModel.swift Sources/Views/EditorModel.swift Sources/Views/LibrarySidebar.swift Sources/App/EditorCommands.swift Tests/RollModelTests.swift project.yml PhotoEditor.xcodeproj
git commit -m "feat(film): roll workflow — create/assign/convert roll, roll-aware Auto, shared batch writer"
```

---

### Task 11: FilmPanel — profile strip, toning sliders, cast group, zone trims, neutral picker

All drawn in the existing language; every control double-click-resets via `AdjustmentSlider`'s existing behavior.

**Files:**
- Modify: `Sources/Views/SliderPanel/FilmPanel.swift`, `Sources/Views/EditorModel.swift`, `Sources/Views/CanvasArea.swift`
- Test: `Tests/EditorModelTests.swift`, `Tests/CanvasToolTests.swift` (append)

**Interfaces:**
- Produces on `EditorModel`:
  - `CanvasPicker` gains `case neutralCast` (+ routing in `handleCanvasClick`: `pickNeutralCast(atUnitPoint:)`, then `canvasPicker = nil`)
  - `func applyToneProfile(_ profile: FilmToneProfile)` — writes the profile fields and re-solves under it when enabled (single `editStack` assignment via `autoConvertNegative(forceProfile:)`; when not enabled, writes the fields only)
  - `func autoConvertNegative(seedProfile: FilmToneProfile? = nil, forceProfile: FilmToneProfile? = nil)` (forceProfile applies regardless of enabled state — the profile-switch path)
  - `func pickNeutralCast(atUnitPoint point: CGPoint)` — samples the SCAN (not the rendered positive) linearly in a 2%-side rect around the point, computes densities against the current linearized base, adds the current cast (the solve is a delta on top of what is dialed in), `CastSolver.castSliders`, writes `castRed/Green/Blue += delta` clamped, single assignment
  - `func autoColorBalance(bias: (red: Double, green: Double, blue: Double))` — fresh `AutoInvert.measure` of the geometry-cropped scan, medians → `CastSolver` + bias, writes the three cast sliders (menu: Neutral `(0,0,0)`, Warm `CastSolver.warmBias`, Cool negated)
- `CanvasArea.pickerPrompt` gains: `case .neutralCast: "Click something that should be neutral — grey card, pavement, a white shirt."`

- [ ] **Step 1: Write failing model tests**

`Tests/EditorModelTests.swift` (follow that file's existing fixture pattern for building an `EditorModel` with a test image):

```swift
func testApplyToneProfileReSolvesInOneUndoStep() throws {
    // model: an EditorModel opened on the FilmSim probe via this file's
    // existing fixture helper; enable + Auto first.
    model.enableFilmNegative()
    let before = model.editStack
    XCTAssertEqual(model.editStack.filmNegative.print.toneProfile, .labStandard,
                   "first enable seeds Lab Standard (the spec's default)")
    model.applyToneProfile(.linear)
    XCTAssertEqual(model.editStack.filmNegative.print.toneProfile, .linear)
    XCTAssertEqual(model.editStack.filmNegative.print.punch, 0)
    XCTAssertNotEqual(model.editStack.filmNegative.print.exposure,
                      before.filmNegative.print.exposure,
                      "switching profiles re-solves the placement")
    model.undo()
    XCTAssertEqual(model.editStack, before, "profile switch is one undo step")
}

func testNeutralCastPickerRoutesAndWrites() throws {
    model.enableFilmNegative()
    let before = model.editStack.filmNegative.print
    model.canvasPicker = .neutralCast
    model.handleCanvasClick(atUnitPoint: CGPoint(x: 0.5, y: 0.5))
    XCTAssertNil(model.canvasPicker, "picker is one-shot")
    let after = model.editStack.filmNegative.print
    XCTAssertTrue(after.castRed != before.castRed || after.castGreen != before.castGreen
                  || after.castBlue != before.castBlue,
                  "clicking a non-neutral patch must move the cast sliders")
}
```

(If `EditorModelTests` has no undo-count helper, follow `EditorUndoTests`' pattern for the one-step assertion instead — whichever file already asserts single-step gestures.)

- [ ] **Step 2: Run — expect failure.** Implement the `EditorModel` pieces per the Interfaces block, then the panel:

In `FilmPanel.printControls`, top: a `TabStrip` over profiles —

```swift
            TabStrip(
                options: [
                    (FilmToneProfile.linear, "LIN"),
                    (.labSoft, "SOFT"),
                    (.labStandard, "LAB"),
                    (.labHard, "HARD"),
                ],
                selection: Binding(
                    get: { film.print.toneProfile },
                    set: { model.applyToneProfile($0) }
                )
            )
```

then, with the existing print sliders: `AdjustmentSlider(title: "Punch", value: …print.punch, range: 0...100, format: "%.0f", neutral: 0)`, `"Fade"` and `"Glow"` likewise. A `COLOUR BALANCE` group (`sectionLabel` style): `PlateButton(title: model.canvasPicker == .neutralCast ? "Click…" : "Neutral…")` toggling the picker; a drawn `Menu`("Auto") with Neutral/Warm/Cool calling `autoColorBalance`; three `AdjustmentSlider`s Cast R/G/B, range −100…100, neutral 0. Inside the existing per-channel trims disclosure: `"Toe Chroma"` (0…100) and the nine zone-trim sliders in three labelled groups (Shadows/Mids/Highs, R/G/B each, −100…100). Honesty caption under the cast group when the last Auto reported the gray-world degraded term — read from a new `model.lastSolveDegradedTerms: [String]` the solve writes (non-persisted UI state).

- [ ] **Step 3: Run the two test classes + build.** Expected PASS.

- [ ] **Step 4: Commit**

```bash
git add Sources/Views/SliderPanel/FilmPanel.swift Sources/Views/EditorModel.swift Sources/Views/CanvasArea.swift Tests/EditorModelTests.swift Tests/CanvasToolTests.swift
git commit -m "feat(film): panel — tone profile strip, punch/fade/glow, colour balance group, zone trims, neutral picker"
```

---

### Task 12: Validation harnesses — A/B corpus renders, negadoctor references, roll-consistency metric

Everything gated (`XCTSkip`) off this machine's corpora and tools; asserts sanity, produces evidence for the human pass.

**Files:**
- Modify: `Tests/RealScanTests.swift`
- Create: `Tests/NegadoctorReferenceTests.swift`, `Tests/RollConsistencyTests.swift`

- [ ] **Step 1: A/B profile renders + acceptance sheet**

In `RealScanTests`: give `convert` a `profile: FilmToneProfile` parameter (label suffix `-linear` / `-lab`), passing it to `AutoInvert.solve` and writing the solved cast/pivot/profile fields into the stack exactly as `autoConvertNegative` does. Corpus tests render each frame under BOTH profiles (medium format: cropped only, plus one blind linear per frame kept as the Fix-2 before/after evidence). Artifacts move to `artifacts/minilab/`. Add `testWriteAcceptanceSheet` (runs last alphabetically — name it `testZZAcceptanceSheet` so the JPEGs exist): builds `artifacts/minilab/acceptance-sheet.html`, a table of rows `<name> | linear | lab` with `<img>` tags referencing the JPEGs, plus each frame's printed solve numbers. Plain string-built HTML, no dependencies.

- [ ] **Step 2: negadoctor references**

`Tests/NegadoctorReferenceTests.swift`: locate `darktable-cli` among `/opt/homebrew/bin/darktable-cli`, `/usr/local/bin/darktable-cli`, `/Applications/darktable.app/Contents/MacOS/darktable-cli` — `XCTSkip` if absent ("brew install --cask darktable"). For the first 5 CR2s that have an XMP sidecar (try `<name>.cr2.xmp` then `<name>.xmp` beside the file; skip the test if none): run

```swift
    let p = Process()
    p.executableURL = URL(fileURLWithPath: cli)
    p.arguments = [cr2.path, xmp.path, out.path, "--width", "1600",
                   "--core", "--library", ":memory:", "--configdir",
                   NSTemporaryDirectory() + "dt-config"]
    try p.run(); p.waitUntilExit()
```

Assert exit 0 → non-empty `artifacts/minilab/ref-<name>.jpg`, and add a `ref` column to the acceptance sheet when present. (These runs take ~10–30 s per frame — keep the count at 5.)

- [ ] **Step 3: Roll-consistency metric on the real corpus**

`Tests/RollConsistencyTests.swift`: manifest at `~/Desktop/negatives/rolls.json` —

```json
{"rolls": [{"name": "roll-1", "files": ["IMG_4308.CR2", "IMG_4310.CR2", "IMG_4311.CR2"]}]}
```

`XCTSkip` when absent, PRINTING that template so the user can create it. For each manifest roll (≥ 2 files): decode each frame (1600 px, PV2), apply `RealScanTests.mediumFormatDemoCropRect` via Geometry before measuring (make that constant `internal` rather than duplicating it), `AutoInvert.measure` each; solve per-frame (`AutoInvert.solve(from:profile: .labStandard)`) AND as a roll (`RollAnalysis.solve`). Render both ways through `EditRenderer`; metric = variance across frames of the rendered median chromaticity `(max−min)/max` of the median linear pixel (the `CastSolverTests.medianChroma` computation — lift it into a shared test helper in `PrintEngineSupport.swift`). Assert `rollVariance ≤ perFrameVariance * 1.05` and print both plus the per-frame vs roll gamma values (`ROLLCONSISTENCY corpus: …`) for the acceptance log.

- [ ] **Step 4: Run all three on this machine** (corpus present). Expected: PASS with artifacts written; on any other machine: SKIP cleanly.

- [ ] **Step 5: Commit**

```bash
git add Tests/RealScanTests.swift Tests/NegadoctorReferenceTests.swift Tests/RollConsistencyTests.swift Tests/PrintEngineSupport.swift project.yml PhotoEditor.xcodeproj
git commit -m "test(film): minilab validation — A/B profile corpus renders, negadoctor references, roll-consistency metric"
```

---

### Task 13: Full verification + acceptance handoff

- [ ] **Step 1: Full suite once**

Run: `xcodebuild -project PhotoEditor.xcodeproj -scheme PhotoEditor -destination 'platform=macOS' -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO test`
Expected: everything green (gated suites skip or pass per machine). Fix anything that isn't before proceeding — no green claim without this output in hand.

- [ ] **Step 2: Regenerate acceptance artifacts** (the corpus suites just did). Open `artifacts/minilab/acceptance-sheet.html` and confirm it renders linear/lab/ref columns.

- [ ] **Step 3: CHANGELOG**

Add under `Unreleased` in `CHANGELOG.md`: the Minilab engine — tone profiles (Linear preserves the Phase 2 render; Lab Standard is the new-conversion default), cast correction (picker/auto/manual) and zone trims, renderVersion 2 fixes (pre-curve EV, balanced tint, mid-pivot grade, toe chroma), rolls with roll-level conversion. Note the freeze guarantees explicitly.

- [ ] **Step 4: Commit, then hand to the user**

```bash
git add CHANGELOG.md
git commit -m "docs: changelog for the Minilab engine"
```

The final gate is human: the user judges the acceptance sheet (Lab Standard vs Linear vs negadoctor references, both corpora) and the roll-consistency numbers. Expect profile-constant tuning (`FilmToneProfile`'s switch values — one screen of code) from that pass; constants live outside the renderVersion 1 path, so tuning them cannot disturb the goldens, but re-run `FilmControlConformanceTests` after any change since `baseStack()` re-solves. **Do not claim the engine "feels like a lab scan" — show the sheet and let the user say it.**

---

## Execution notes

- Tasks are strictly ordered 1→13; 1–7 are engine-internal (no schema), 8–10 are the roll layer, 11 the panel, 12–13 validation. Nothing user-visible changes behavior for existing photos at any point — that is what Task 1 enforces continuously.
- The spec's look-layer slot (stage 6, Frontier/Noritsu emulation later) is deliberately NOT built: it is the position after the paper stage in `develop()`/the kernel where a future 3×3 or LUT can be inserted without touching stages 1–5. Nothing to implement now beyond keeping that seam clean — do not fold new math past the rolloff return line.
- If any task's measured conformance sign contradicts this plan's declared sign, trust the measurement, fix the table, and record the sweep in the case comment (house precedent: Print Contrast, Phase C warmth).
- The Develop Grammar sub-project (`docs/superpowers/specs/2026-08-05-develop-grammar-design.md`) starts only after this plan ships and the user accepts the corpus sheet.

