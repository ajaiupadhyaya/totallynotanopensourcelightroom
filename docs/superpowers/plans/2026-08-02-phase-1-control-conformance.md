# Phase 1: Control Conformance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove that every control in the app is wired to the render pipeline and moves the image in the direction it advertises — and fix whatever turns out not to be.

**Architecture:** A data-driven XCTest suite over a declared table of control cases. Each case names an `EditStack` field, the values to set, the statistic that field is claimed to move, and the expected sign. A completeness test reflects over `EditStack`'s stored properties so a new control cannot be added without either a conformance case or an explicit, named exclusion.

**Tech Stack:** Swift 5, XCTest, Core Image, XcodeGen. Builds on the existing `Calibration` harness in `Tests/CalibrationSupport.swift`.

## Global Constraints

- macOS deployment target 14.0; Swift 5 language mode.
- Tests run via `xcodebuild -project PhotoEditor.xcodeproj -scheme PhotoEditor -destination 'platform=macOS' test`.
- Baseline before this phase: 342 tests, 0 failures, 4 skipped. No task may reduce the passing count.
- `project.yml` is the source of truth for the Xcode project. New test files under `Tests/` are picked up by the existing glob — no `project.yml` edit and no `xcodegen generate` is needed for adding a test file.
- Comment density and doc-comment style follow the surrounding code: every type and non-obvious decision carries a `///` comment explaining *why*, not *what*.
- Commit messages end with `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`.

---

### Task 1: The probe image and its measurements

A conformance test is only as good as what it renders. A flat grey patch cannot tell you whether Texture works, because there is no texture in it to move; the existing `Calibration.patch` is deliberately flat because it answers a different question ("what does this value become"). This task builds the other kind of fixture: one image containing something for every control to act on.

**Files:**
- Create: `Tests/ConformanceSupport.swift`

**Interfaces:**
- Consumes: `EditRenderer.render(source:stack:)`, `TestSupport.sRGBSpace`.
- Produces: `enum Conformance` with `probe: CIImage`, `render(_:) -> [UInt8]`, `difference(_:_:) -> Double`, `meanLuma(_:)`, `stdDevLuma(_:)`, `meanSaturation(_:)`, `percentileLuma(_:_:)`, `localContrast(_:)`, `chromaVariance(_:)`, `warmth(_:)`, `greenMagenta(_:)`, `cornerLuma(_:)`, all `([UInt8]) -> Double` except where noted.

- [ ] **Step 1: Write the probe and measurements**

```swift
import CoreGraphics
import CoreImage
import Foundation
import XCTest
@testable import PhotoEditor

/// The fixture and measurements behind ``ControlConformanceTests``.
///
/// The probe deliberately is not a flat patch. A flat patch cannot answer
/// "does Texture do anything" — there is no texture in it to move — and a
/// control that silently does nothing would pass. Each quadrant here exists
/// so that some group of controls has signal to act on.
enum Conformance {
    static let context = CIContext()
    static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    /// 128 px is enough for percentile statistics to be stable and small
    /// enough that ~40 renders stay under a second.
    static let size = 128

    static let extent = CGRect(x: 0, y: 0, width: size, height: size)

    // MARK: The probe

    /// Four quadrants:
    ///
    /// - top-left: a full black-to-white luminance ramp, for the tone controls
    /// - top-right: six saturated hues at two luminances, for colour
    /// - bottom-left: a 2 px checker plus chroma noise, for texture, clarity,
    ///   sharpening, grain and both noise reductions
    /// - bottom-right: a flat, slightly blue low-contrast wash, for dehaze
    static let probe: CIImage = {
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let i = (y * size + x) * 4
                let (r, g, b) = probePixel(x: x, y: y)
                pixels[i] = r
                pixels[i + 1] = g
                pixels[i + 2] = b
                pixels[i + 3] = 255
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let cgImage = CGImage(
            width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: size * 4, space: srgb,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent
        )!
        return CIImage(cgImage: cgImage)
    }()

    private static func byte(_ d: Double) -> UInt8 {
        UInt8(max(0, min(255, (d * 255).rounded())))
    }

    private static func probePixel(x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
        let half = size / 2
        let left = x < half
        let top = y < half
        let u = Double(x % half) / Double(half - 1)
        let v = Double(y % half) / Double(half - 1)

        if top, left {
            return (byte(u), byte(u), byte(u))
        }
        if top {
            let hue = (floor(u * 6) / 6).truncatingRemainder(dividingBy: 1)
            let (r, g, b) = hsl(hue: hue, saturation: 0.85, lightness: v < 0.5 ? 0.35 : 0.65)
            return (byte(r), byte(g), byte(b))
        }
        if left {
            // High-frequency checker for sharpening and luminance NR, a
            // mid-frequency ripple for clarity, and a deterministic chroma
            // jitter so colour noise reduction has colour noise to remove.
            let checker = ((x / 2) + (y / 2)) % 2 == 0 ? 0.10 : -0.10
            let l = 0.5 + checker + 0.15 * sin(u * .pi * 4)
            let jitter = chromaJitter(x: x, y: y)
            return (byte(l + jitter), byte(l), byte(l - jitter))
        }
        let l = 0.55 + 0.12 * u
        return (byte(l), byte(l), byte(min(1.0, l + 0.06)))
    }

    /// A deterministic ±0.06 red/blue jitter. Deterministic because a test
    /// fixture that changes between runs turns a real regression into a
    /// coin flip.
    private static func chromaJitter(x: Int, y: Int) -> Double {
        let h = (x &* 73_856_093) ^ (y &* 19_349_663)
        return (Double(abs(h) % 1000) / 1000.0 - 0.5) * 0.12
    }

    private static func hsl(hue: Double, saturation: Double,
                            lightness: Double) -> (Double, Double, Double) {
        let c = (1 - abs(2 * lightness - 1)) * saturation
        let hp = hue * 6
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        let (r1, g1, b1): (Double, Double, Double)
        switch hp {
        case ..<1: (r1, g1, b1) = (c, x, 0)
        case ..<2: (r1, g1, b1) = (x, c, 0)
        case ..<3: (r1, g1, b1) = (0, c, x)
        case ..<4: (r1, g1, b1) = (0, x, c)
        case ..<5: (r1, g1, b1) = (x, 0, c)
        default:   (r1, g1, b1) = (c, 0, x)
        }
        let m = lightness - c / 2
        return (r1 + m, g1 + m, b1 + m)
    }

    // MARK: Rendering

    /// Renders the probe through the PV2 renderer with `mutate` applied,
    /// returning display-space RGBA8 bytes.
    static func render(_ mutate: (inout EditStack) -> Void) -> [UInt8] {
        var stack = EditStack()
        mutate(&stack)
        return bitmap(EditRenderer().render(source: probe, stack: stack))
    }

    static func bitmap(_ image: CIImage) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: size * size * 4)
        context.render(image.cropped(to: extent), toBitmap: &buffer,
                       rowBytes: size * 4, bounds: extent,
                       format: .RGBA8, colorSpace: srgb)
        return buffer
    }

    // MARK: Measurements
    //
    // All of these read display-space bytes, because that is what a person
    // looking at the canvas sees — the same reason the histogram is measured
    // in display space rather than the linear working space.

    /// Mean absolute per-channel difference, `0...1`.
    static func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        var total = 0.0
        for i in stride(from: 0, to: a.count, by: 4) {
            for c in 0..<3 { total += abs(Double(a[i + c]) - Double(b[i + c])) }
        }
        return total / (Double(a.count / 4 * 3) * 255.0)
    }

    static func luma(_ px: [UInt8], at i: Int) -> Double {
        (0.2126 * Double(px[i]) + 0.7152 * Double(px[i + 1])
            + 0.0722 * Double(px[i + 2])) / 255.0
    }

    static func lumaValues(_ px: [UInt8]) -> [Double] {
        stride(from: 0, to: px.count, by: 4).map { luma(px, at: $0) }
    }

    static func meanLuma(_ px: [UInt8]) -> Double {
        let v = lumaValues(px)
        return v.reduce(0, +) / Double(v.count)
    }

    static func stdDevLuma(_ px: [UInt8]) -> Double {
        let v = lumaValues(px)
        let mean = v.reduce(0, +) / Double(v.count)
        return (v.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(v.count)).squareRoot()
    }

    static func percentileLuma(_ px: [UInt8], _ p: Double) -> Double {
        let sorted = lumaValues(px).sorted()
        let index = Int((Double(sorted.count - 1) * p).rounded())
        return sorted[index]
    }

    /// HSV-style saturation, averaged.
    static func meanSaturation(_ px: [UInt8]) -> Double {
        var total = 0.0
        var count = 0
        for i in stride(from: 0, to: px.count, by: 4) {
            let r = Double(px[i]), g = Double(px[i + 1]), b = Double(px[i + 2])
            let hi = max(r, g, b)
            total += hi <= 0 ? 0 : (hi - min(r, g, b)) / hi
            count += 1
        }
        return total / Double(count)
    }

    /// Mean absolute luma difference between horizontally adjacent pixels —
    /// the high-frequency energy that sharpening adds and noise reduction
    /// removes.
    static func localContrast(_ px: [UInt8]) -> Double {
        var total = 0.0
        var count = 0
        for y in 0..<size {
            for x in 0..<(size - 1) {
                let i = (y * size + x) * 4
                total += abs(luma(px, at: i) - luma(px, at: i + 4))
                count += 1
            }
        }
        return total / Double(count)
    }

    /// Variance of the red-minus-blue difference — chroma noise, which is
    /// what colour noise reduction is supposed to reduce.
    static func chromaVariance(_ px: [UInt8]) -> Double {
        var values: [Double] = []
        for i in stride(from: 0, to: px.count, by: 4) {
            values.append((Double(px[i]) - Double(px[i + 2])) / 255.0)
        }
        let mean = values.reduce(0, +) / Double(values.count)
        return values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
    }

    /// Mean red minus mean blue. Positive is warmer.
    static func warmth(_ px: [UInt8]) -> Double {
        var r = 0.0, b = 0.0
        for i in stride(from: 0, to: px.count, by: 4) {
            r += Double(px[i]); b += Double(px[i + 2])
        }
        return (r - b) / (Double(px.count / 4) * 255.0)
    }

    /// Mean green minus the mean of red and blue. Positive is greener,
    /// negative is more magenta.
    static func greenMagenta(_ px: [UInt8]) -> Double {
        var g = 0.0, rb = 0.0
        for i in stride(from: 0, to: px.count, by: 4) {
            g += Double(px[i + 1])
            rb += (Double(px[i]) + Double(px[i + 2])) / 2
        }
        return (g - rb) / (Double(px.count / 4) * 255.0)
    }

    /// Mean luma of the four 16 px corners — what a vignette acts on.
    static func cornerLuma(_ px: [UInt8]) -> Double {
        var total = 0.0
        var count = 0
        let band = 16
        for y in 0..<size where y < band || y >= size - band {
            for x in 0..<size where x < band || x >= size - band {
                total += luma(px, at: (y * size + x) * 4)
                count += 1
            }
        }
        return total / Double(count)
    }
}
```

- [ ] **Step 2: Write a test that the probe is what it claims to be**

A fixture nobody checks is a fixture that can quietly degrade. Add to the same file's companion test in Task 2; for now verify by building.

Run: `xcodebuild -project PhotoEditor.xcodeproj -scheme PhotoEditor -destination 'platform=macOS' build-for-testing 2>&1 | tail -5`

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Tests/ConformanceSupport.swift
git commit -m "test: probe image and measurements for control conformance

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: The control inventory and the neutral no-op test

**Files:**
- Create: `Tests/ControlConformanceTests.swift`

**Interfaces:**
- Consumes: `Conformance` from Task 1.
- Produces: `struct ControlCase` with fields `name: String`, `key: String`, `setup: (inout EditStack) -> Void`, `low: (inout EditStack) -> Void`, `high: (inout EditStack) -> Void`, `measure: ([UInt8]) -> Double`, `sign: Int`, `minimumChange: Double`; and `ControlCase.all: [ControlCase]`, `ControlCase.excluded: [String: String]`.

- [ ] **Step 1: Write the inventory and the neutral test**

```swift
import CoreGraphics
import XCTest
@testable import PhotoEditor

/// One control's declared contract with the renderer.
///
/// The point of declaring this as data rather than writing a test per control
/// is that the *list* becomes checkable. A control added to ``EditStack``
/// without a row here fails ``testEveryEditStackFieldIsCoveredOrExcluded``,
/// so the matrix cannot rot the way a hand-written suite does.
struct ControlCase {
    let name: String

    /// The `EditStack` stored-property name this covers.
    let key: String

    /// Applied to *every* variant including neutral. This is for controls
    /// that legitimately do nothing on their own: Grain Size does nothing at
    /// Grain Amount 0, and a test that did not enable the amount first would
    /// report a working control as dead.
    let setup: (inout EditStack) -> Void

    let low: (inout EditStack) -> Void
    let high: (inout EditStack) -> Void

    /// The statistic this control is declared to move.
    let measure: ([UInt8]) -> Double

    /// Sign of `measure(high) - measure(neutral)`. `0` means the control
    /// genuinely changes the image but no single scalar describes how, so
    /// only the change is asserted.
    let sign: Int

    /// How far `measure` must move before the direction assertion means
    /// anything. Defaults to a value comfortably above render noise.
    let minimumChange: Double

    init(name: String, key: String,
         setup: @escaping (inout EditStack) -> Void = { _ in },
         low: @escaping (inout EditStack) -> Void,
         high: @escaping (inout EditStack) -> Void,
         measure: @escaping ([UInt8]) -> Double,
         sign: Int,
         minimumChange: Double = 0.002) {
        self.name = name
        self.key = key
        self.setup = setup
        self.low = low
        self.high = high
        self.measure = measure
        self.sign = sign
        self.minimumChange = minimumChange
    }
}

extension ControlCase {
    /// Fields deliberately not covered here, each with the suite that does
    /// cover it. An entry in this dictionary is a claim that someone checked;
    /// it is not a way to make the completeness test quiet.
    static let excluded: [String: String] = [
        "processVersion": "ProcessVersionTests — selects an engine, not an adjustment",
        "rawBoost": "RawSourceTests — no effect on a non-RAW source, which the probe is",
        "rawWBInitialized": "ProcessVersionTests — bookkeeping flag, never rendered",
        "toneCurvePoints": "CalibrationTests — point curve, covered with placement accuracy",
        "color": "ColorSuiteTests, ColorMixerTests — a whole subsystem with its own suite",
        "localAdjustments": "LocalAdjustmentTests, MaskComponentTests",
        "retouch": "RetouchTests",
        "defringe": "OpticsTests",
        "geometry": "GeometryTests — changes extent, so the byte-for-byte harness here does not apply",
        "filmNegative": "FilmNegativeTests, EndToEndFilmTests",
    ]

    static let all: [ControlCase] = [
        // MARK: Light
        ControlCase(name: "Exposure", key: "exposure",
                    low: { $0.exposure = -2 }, high: { $0.exposure = 2 },
                    measure: Conformance.meanLuma, sign: +1),
        ControlCase(name: "Contrast", key: "contrast",
                    low: { $0.contrast = -80 }, high: { $0.contrast = 80 },
                    measure: Conformance.stdDevLuma, sign: +1),
        ControlCase(name: "Highlights", key: "highlights",
                    low: { $0.highlights = -100 }, high: { $0.highlights = 100 },
                    measure: { Conformance.percentileLuma($0, 0.90) }, sign: +1),
        ControlCase(name: "Shadows", key: "shadows",
                    low: { $0.shadows = -100 }, high: { $0.shadows = 100 },
                    measure: { Conformance.percentileLuma($0, 0.10) }, sign: +1),
        ControlCase(name: "Whites", key: "whites",
                    low: { $0.whites = -100 }, high: { $0.whites = 100 },
                    measure: { Conformance.percentileLuma($0, 0.98) }, sign: +1),
        ControlCase(name: "Blacks", key: "blacks",
                    low: { $0.blacks = -100 }, high: { $0.blacks = 100 },
                    measure: { Conformance.percentileLuma($0, 0.02) }, sign: +1),

        // MARK: White balance
        //
        // Neutral is 6500 K, not 0, so `low`/`high` bracket the default
        // rather than sitting either side of zero.
        ControlCase(name: "Temperature", key: "whiteBalanceTemp",
                    low: { $0.whiteBalanceTemp = 3000 },
                    high: { $0.whiteBalanceTemp = 12000 },
                    measure: Conformance.warmth, sign: +1),
        ControlCase(name: "Tint", key: "whiteBalanceTint",
                    low: { $0.whiteBalanceTint = -100 },
                    high: { $0.whiteBalanceTint = 100 },
                    // Lightroom's convention: positive Tint is magenta, which
                    // is green going down.
                    measure: Conformance.greenMagenta, sign: -1),

        // MARK: Presence
        ControlCase(name: "Texture", key: "texture",
                    low: { $0.texture = -100 }, high: { $0.texture = 100 },
                    measure: Conformance.localContrast, sign: +1),
        ControlCase(name: "Clarity", key: "clarity",
                    low: { $0.clarity = -100 }, high: { $0.clarity = 100 },
                    measure: Conformance.localContrast, sign: +1),
        ControlCase(name: "Dehaze", key: "dehaze",
                    low: { $0.dehaze = -100 }, high: { $0.dehaze = 100 },
                    measure: Conformance.stdDevLuma, sign: +1),
        ControlCase(name: "Vibrance", key: "vibrance",
                    low: { $0.vibrance = -100 }, high: { $0.vibrance = 100 },
                    measure: Conformance.meanSaturation, sign: +1),
        ControlCase(name: "Saturation", key: "saturation",
                    low: { $0.saturation = -100 }, high: { $0.saturation = 100 },
                    measure: Conformance.meanSaturation, sign: +1),

        // MARK: Detail
        ControlCase(name: "Sharpen Amount", key: "sharpenAmount",
                    low: { $0.sharpenAmount = 0 }, high: { $0.sharpenAmount = 100 },
                    measure: Conformance.localContrast, sign: +1),
        ControlCase(name: "Sharpen Radius", key: "sharpenRadius",
                    setup: { $0.sharpenAmount = 100 },
                    low: { $0.sharpenRadius = 0.5 }, high: { $0.sharpenRadius = 3 },
                    measure: Conformance.localContrast, sign: 0),
        ControlCase(name: "Luminance Noise Reduction", key: "luminanceNoiseReduction",
                    low: { $0.luminanceNoiseReduction = 0 },
                    high: { $0.luminanceNoiseReduction = 100 },
                    measure: Conformance.localContrast, sign: -1),
        ControlCase(name: "Colour Noise Reduction", key: "colorNoiseReduction",
                    low: { $0.colorNoiseReduction = 0 },
                    high: { $0.colorNoiseReduction = 100 },
                    measure: Conformance.chromaVariance, sign: -1),

        // MARK: Effects
        ControlCase(name: "Vignette Amount", key: "vignetteAmount",
                    low: { $0.vignetteAmount = -100 }, high: { $0.vignetteAmount = 100 },
                    measure: Conformance.cornerLuma, sign: +1),
        ControlCase(name: "Vignette Midpoint", key: "vignetteMidpoint",
                    setup: { $0.vignetteAmount = -100 },
                    low: { $0.vignetteMidpoint = 10 }, high: { $0.vignetteMidpoint = 90 },
                    // A midpoint further out starts the darkening later, so
                    // the corners keep more of their brightness.
                    measure: Conformance.cornerLuma, sign: +1),
        ControlCase(name: "Vignette Roundness", key: "vignetteRoundness",
                    setup: { $0.vignetteAmount = -100 },
                    low: { $0.vignetteRoundness = -100 },
                    high: { $0.vignetteRoundness = 100 },
                    measure: Conformance.cornerLuma, sign: 0),
        ControlCase(name: "Vignette Feather", key: "vignetteFeather",
                    setup: { $0.vignetteAmount = -100 },
                    low: { $0.vignetteFeather = 0 }, high: { $0.vignetteFeather = 100 },
                    measure: Conformance.cornerLuma, sign: 0),
        ControlCase(name: "Vignette Highlights", key: "vignetteHighlights",
                    setup: { $0.vignetteAmount = -100 },
                    low: { $0.vignetteHighlights = 0 },
                    high: { $0.vignetteHighlights = 100 },
                    measure: Conformance.cornerLuma, sign: +1),
        ControlCase(name: "Grain Amount", key: "grainAmount",
                    low: { $0.grainAmount = 0 }, high: { $0.grainAmount = 100 },
                    measure: Conformance.localContrast, sign: +1),
        ControlCase(name: "Grain Size", key: "grainSize",
                    setup: { $0.grainAmount = 100 },
                    low: { $0.grainSize = 5 }, high: { $0.grainSize = 100 },
                    measure: Conformance.localContrast, sign: 0),

        // MARK: Parametric tone curve
        ControlCase(name: "Curve Highlights", key: "toneCurveHighlights",
                    low: { $0.toneCurveHighlights = -100 },
                    high: { $0.toneCurveHighlights = 100 },
                    measure: { Conformance.percentileLuma($0, 0.90) }, sign: +1),
        ControlCase(name: "Curve Lights", key: "toneCurveLights",
                    low: { $0.toneCurveLights = -100 },
                    high: { $0.toneCurveLights = 100 },
                    measure: { Conformance.percentileLuma($0, 0.65) }, sign: +1),
        ControlCase(name: "Curve Darks", key: "toneCurveDarks",
                    low: { $0.toneCurveDarks = -100 },
                    high: { $0.toneCurveDarks = 100 },
                    measure: { Conformance.percentileLuma($0, 0.35) }, sign: +1),
        ControlCase(name: "Curve Shadows", key: "toneCurveShadows",
                    low: { $0.toneCurveShadows = -100 },
                    high: { $0.toneCurveShadows = 100 },
                    measure: { Conformance.percentileLuma($0, 0.10) }, sign: +1),
    ]
}

final class ControlConformanceTests: XCTestCase {
    /// A control at its neutral value must be bit-for-bit invisible.
    ///
    /// This is the "quietly always-on" check. A stage that runs unconditionally
    /// — a filter applied before testing whether its parameter is zero, a
    /// clamp that rounds every value — costs quality on every photo in the
    /// catalog and is invisible in a direction test, because both extremes
    /// still move.
    func testNeutralIsExactlyANoOp() {
        let untouched = Conformance.render { _ in }
        for control in ControlCase.all where !isSetupNonNeutral(control) {
            let neutral = Conformance.render(control.setup)
            XCTAssertEqual(Conformance.difference(untouched, neutral), 0, accuracy: 0.0001,
                           "\(control.name) at its neutral value changes the image.")
        }
    }

    /// True when a case's `setup` deliberately turns something on, in which
    /// case its "neutral" is not the default stack and this check does not
    /// apply to it.
    private func isSetupNonNeutral(_ control: ControlCase) -> Bool {
        var stack = EditStack()
        control.setup(&stack)
        return stack != EditStack()
    }
}
```

- [ ] **Step 2: Run it**

Run: `xcodebuild -project PhotoEditor.xcodeproj -scheme PhotoEditor -destination 'platform=macOS' test -only-testing:PhotoEditorTests/ControlConformanceTests 2>&1 | grep -E "error:|failed|passed|Executed"`

Expected: it runs. Failures here are **findings**, not plan errors — record each one and carry it to Task 6.

- [ ] **Step 3: Commit**

```bash
git add Tests/ControlConformanceTests.swift
git commit -m "test: control inventory and neutral no-op conformance

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Both extremes must move the image

This is the test that would have caught PV1's Highlights no-op.

**Files:**
- Modify: `Tests/ControlConformanceTests.swift`

- [ ] **Step 1: Add the test**

```swift
    /// Both ends of every control must visibly change the image.
    ///
    /// PV1 shipped a Highlights slider whose positive half did nothing at all,
    /// because `CIHighlightShadowAdjust`'s highlight input is a no-op, and the
    /// whole suite stayed green for the life of the release. Every test
    /// asserted that the code did what it was written to do. None asserted
    /// that the picture changed.
    func testBothExtremesChangeTheImage() {
        for control in ControlCase.all {
            let neutral = Conformance.render(control.setup)
            for (label, mutate) in [("minimum", control.low), ("maximum", control.high)] {
                let variant = Conformance.render { stack in
                    control.setup(&stack)
                    mutate(&stack)
                }
                let delta = Conformance.difference(neutral, variant)
                XCTAssertGreaterThan(
                    delta, 0.0015,
                    "\(control.name) at its \(label) changes the image by \(delta), "
                    + "which is indistinguishable from doing nothing."
                )
            }
        }
    }
```

- [ ] **Step 2: Run it**

Run: `xcodebuild -project PhotoEditor.xcodeproj -scheme PhotoEditor -destination 'platform=macOS' test -only-testing:PhotoEditorTests/ControlConformanceTests/testBothExtremesChangeTheImage 2>&1 | grep -E "error:|XCTAssert|Executed"`

Expected: runs. Any failure names a control that does nothing — a finding for Task 6.

- [ ] **Step 3: Commit**

```bash
git add Tests/ControlConformanceTests.swift
git commit -m "test: every control extreme must change the image

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: The direction must be the advertised one

**Files:**
- Modify: `Tests/ControlConformanceTests.swift`

- [ ] **Step 1: Add the test**

```swift
    /// Each control must move its declared statistic in its declared
    /// direction. This is the inverted-binding check: a slider wired to the
    /// negative of what its label says passes every "does it change" test.
    func testDirectionMatchesTheDeclaredOne() {
        for control in ControlCase.all where control.sign != 0 {
            let neutral = control.measure(Conformance.render(control.setup))
            let high = control.measure(Conformance.render { stack in
                control.setup(&stack)
                control.high(&stack)
            })
            let delta = high - neutral
            XCTAssertGreaterThan(
                abs(delta), control.minimumChange,
                "\(control.name) moved its statistic by only \(delta) — too "
                + "little to call the direction either way."
            )
            XCTAssertEqual(
                delta > 0 ? 1 : -1, control.sign,
                "\(control.name) at maximum moved its statistic by \(delta); "
                + "the declared direction is \(control.sign > 0 ? "up" : "down")."
            )
        }
    }
```

- [ ] **Step 2: Run it**

Run: `xcodebuild -project PhotoEditor.xcodeproj -scheme PhotoEditor -destination 'platform=macOS' test -only-testing:PhotoEditorTests/ControlConformanceTests/testDirectionMatchesTheDeclaredOne 2>&1 | grep -E "error:|XCTAssert|Executed"`

Expected: runs. Failures are findings for Task 6 — and for each one, decide whether the *control* is backwards or the *declared direction* in the table is wrong, and say which in the commit.

- [ ] **Step 3: Commit**

```bash
git add Tests/ControlConformanceTests.swift
git commit -m "test: controls must move in their advertised direction

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: The inventory cannot rot

**Files:**
- Modify: `Tests/ControlConformanceTests.swift`

- [ ] **Step 1: Add the completeness tests**

```swift
    /// Every stored property of `EditStack` is either covered by a conformance
    /// case or explicitly excluded with the suite that covers it instead.
    ///
    /// Without this, the matrix is a snapshot of what someone remembered in
    /// August 2026. With it, adding a control to `EditStack` and forgetting to
    /// prove it works is a build-time failure.
    func testEveryEditStackFieldIsCoveredOrExcluded() {
        let fields = Mirror(reflecting: EditStack()).children.compactMap(\.label)
        XCTAssertFalse(fields.isEmpty, "Mirror found no stored properties on EditStack.")

        let covered = Set(ControlCase.all.map(\.key))
            .union(ControlCase.excluded.keys)
        for field in fields {
            XCTAssertTrue(
                covered.contains(field),
                "EditStack.\(field) is neither in ControlCase.all nor in "
                + "ControlCase.excluded. Add a conformance case for it, or an "
                + "exclusion naming the suite that covers it."
            )
        }
    }

    /// …and nothing in the table refers to a field that no longer exists.
    func testNoStaleEntriesInTheInventory() {
        let fields = Set(Mirror(reflecting: EditStack()).children.compactMap(\.label))
        for key in ControlCase.all.map(\.key) {
            XCTAssertTrue(fields.contains(key),
                          "ControlCase.all covers '\(key)', which is not a field of EditStack.")
        }
        for key in ControlCase.excluded.keys {
            XCTAssertTrue(fields.contains(key),
                          "ControlCase.excluded lists '\(key)', which is not a field of EditStack.")
        }
    }

    /// Two cases covering the same field means one of them is not being
    /// thought about.
    func testNoDuplicateCoverage() {
        let keys = ControlCase.all.map(\.key)
        XCTAssertEqual(Set(keys).count, keys.count, "A field has two conformance cases.")
        for key in keys {
            XCTAssertNil(ControlCase.excluded[key],
                         "'\(key)' is both covered and excluded.")
        }
    }
```

- [ ] **Step 2: Run and fix the inventory until it passes**

Run: `xcodebuild -project PhotoEditor.xcodeproj -scheme PhotoEditor -destination 'platform=macOS' test -only-testing:PhotoEditorTests/ControlConformanceTests 2>&1 | grep -E "error:|XCTAssert|Executed"`

Expected: any field named by a failure gets added to `ControlCase.all` (with a real case) or to `excluded` (with the real suite that covers it). Unlike Tasks 2–4, failures here are fixed *in this task* — they are gaps in the inventory, not in the app.

- [ ] **Step 3: Commit**

```bash
git add Tests/ControlConformanceTests.swift
git commit -m "test: conformance inventory must cover every EditStack field

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Fix what the suite found

**Files:**
- Modify: whichever pipeline files the findings point at, most likely under `Sources/Pipeline/`.

- [ ] **Step 1: Write down the findings**

Collect every failure from Tasks 2, 3 and 4 into a list: control, which test failed, and the measured number. If the list is empty, skip to Step 5 and record that in the commit — "no findings" is a real result and worth stating plainly.

- [ ] **Step 2: For each finding, decide which side is wrong**

Two possibilities, and they need different fixes:

- The **control** is broken — it does nothing, or moves backwards. Fix the pipeline.
- The **declaration** is wrong — the control does something reasonable that the table described badly (an unfortunate measurement choice, a statistic the control genuinely does not move). Fix the table, and put the reason in a comment.

Do not resolve a failure by loosening a threshold until it passes. That converts a finding into a lie.

- [ ] **Step 3: Fix the highest-severity finding, with a regression test naming it**

Each pipeline fix gets a named test in the suite that owns that area (`CalibrationTests` for tone, `EffectsCalibrationTests` for effects, `ColorSuiteTests` for colour) describing the specific bug in its doc comment, in the style of the existing PV1 regression tests.

- [ ] **Step 4: Run the full suite**

Run: `xcodebuild -project PhotoEditor.xcodeproj -scheme PhotoEditor -destination 'platform=macOS' test 2>&1 | grep -E "Executed [0-9]+ test|TEST (SUCCEEDED|FAILED)" | tail -3`

Expected: `** TEST SUCCEEDED **`, with a test count above the 342 baseline and zero failures.

Repeat Steps 3–4 per finding.

- [ ] **Step 5: Commit each fix separately**

```bash
git add -A
git commit -m "fix(<area>): <the specific defect the conformance suite found>

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Display toggles and housekeeping

The five view toggles in the View menu are the same class of risk as a slider: a flag bound to a menu item that nothing downstream reads. Three of them (`isShowingBefore`, `isFocusPeakingEnabled`, `isShowingMaskOverlay`) change `EditorModel.displayImage`. Two (`showsShadowClipping`, `showsHighlightClipping`) drive a text readout in `CanvasArea`, not the image — so they are verified through the histogram values that readout displays.

**Files:**
- Create: `Tests/DisplayToggleConformanceTests.swift`
- Delete: `Sources/Shaders/` (empty; the `.ci.metal` files live in `Sources/Pipeline/Kernels/`)

**Interfaces:**
- Consumes: `TestSupport.makeEditorModel(gray:editStack:)`, `EditorModel.displayImage`, `EditorModel.histogram`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import PhotoEditor

/// The View menu's toggles, checked the same way the sliders are: a toggle
/// bound to a property nothing reads looks identical, from the menu, to one
/// that works.
@MainActor
final class DisplayToggleConformanceTests: XCTestCase {
    /// Each image-affecting toggle must change what the canvas shows.
    func testImageTogglesChangeTheDisplayedImage() async throws {
        let model = try TestSupport.makeEditorModel(editStack: {
            var stack = EditStack()
            stack.exposure = 1.5
            return stack
        }())
        try await settle(model)
        let before = try XCTUnwrap(model.displayImage)

        model.isShowingBefore = true
        try await settle(model)
        let showingOriginal = try XCTUnwrap(model.displayImage)
        XCTAssertFalse(sameBytes(before, showingOriginal),
                       "Show Original displays the same image as Show Developed.")
        model.isShowingBefore = false
        try await settle(model)

        model.isFocusPeakingEnabled = true
        try await settle(model)
        XCTAssertFalse(sameBytes(before, try XCTUnwrap(model.displayImage)),
                       "Focus peaking does not change the canvas.")
        model.isFocusPeakingEnabled = false
        try await settle(model)
    }

    /// The clipping toggles drive a numeric readout rather than the image, so
    /// what has to be true is that the numbers behind it are real.
    func testClippingDiagnosticsReportRealClipping() async throws {
        var clipped = EditStack()
        clipped.exposure = 6
        let model = try TestSupport.makeEditorModel(gray: 250, editStack: clipped)
        try await settle(model)

        model.showsHighlightClipping = true
        XCTAssertTrue(model.histogram.isClippingHighlights,
                      "Six stops over a near-white frame must register as clipped.")
        XCTAssertGreaterThan(model.histogram.highlightClippedFraction, 0.5)
    }

    private func settle(_ model: EditorModel) async throws {
        try await Task.sleep(for: .milliseconds(400))
    }

    private func sameBytes(_ a: CGImage, _ b: CGImage) -> Bool {
        guard let x = a.dataProvider?.data as Data?,
              let y = b.dataProvider?.data as Data? else { return false }
        return x == y
    }
}
```

- [ ] **Step 2: Run it**

Run: `xcodebuild -project PhotoEditor.xcodeproj -scheme PhotoEditor -destination 'platform=macOS' test -only-testing:PhotoEditorTests/DisplayToggleConformanceTests 2>&1 | grep -E "error:|XCTAssert|Executed"`

Expected: runs. If `settle` proves flaky against the render scheduler's debounce, replace the sleep with polling on `model.displayImage` identity rather than lengthening the sleep — a timing-dependent test that passes by waiting longer is a test that will fail on someone else's machine.

- [ ] **Step 3: Remove the empty shader directory**

```bash
rmdir Sources/Shaders
```

- [ ] **Step 4: Run the full suite**

Run: `xcodebuild -project PhotoEditor.xcodeproj -scheme PhotoEditor -destination 'platform=macOS' test 2>&1 | grep -E "Executed [0-9]+ test|TEST (SUCCEEDED|FAILED)" | tail -3`

Expected: `** TEST SUCCEEDED **`, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "test: display toggle conformance; drop empty Sources/Shaders

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: Record the result

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Add an Unreleased section**

Write what the audit actually found — each defect, in the plain-language style the existing 2.2.0 entry uses ("Positive Highlights did nothing"). If it found nothing, say that: the suite is still worth having, and a changelog that invents findings to look busy is worse than one that reports a clean result.

- [ ] **Step 2: Run the full suite one more time**

Run: `xcodebuild -project PhotoEditor.xcodeproj -scheme PhotoEditor -destination 'platform=macOS' test 2>&1 | grep -E "Executed [0-9]+ test|TEST (SUCCEEDED|FAILED)" | tail -3`

Expected: `** TEST SUCCEEDED **`, 0 failures, count above 342.

- [ ] **Step 3: Commit**

```bash
git add CHANGELOG.md
git commit -m "docs: changelog for the control conformance audit

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Deferred from this phase

The spec's "un-gate the RAW fixture tests" item needs the user's own RAW files
in `Tests/Fixtures/RAW/`, which are gitignored and not present on this machine.
It moves to Phase 2, where the same files are needed to verify the density
converter against real sensor-domain input.

## Done when

- `ControlConformanceTests` covers every `EditStack` field or names the suite that does.
- Every control's neutral is a bit-exact no-op, both extremes change the image, and the direction is the advertised one.
- Every finding is either fixed with a named regression test, or the declaration is corrected with a stated reason.
- Full suite green, above 342 tests, zero failures.
