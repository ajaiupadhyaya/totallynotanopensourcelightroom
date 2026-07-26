# Process Version 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the miscalibrated tone/color core with build-time-compiled Metal CIKernels operating in declared color spaces, route RAW edits into the sensor domain, fix effects, and prove calibration with measured tests — without changing the appearance of any existing edit.

**Architecture:** The working space stays Core Image's default (extended linear sRGB — scene-linear, unclamped, wide gamut via extended range; changing it would silently alter the frozen legacy path and the film-conversion math). The two-space discipline lives *inside our kernels*: each kernel gamma-encodes to sRGB display space for display-referred math and decodes back, using sign-preserving transfer functions so EDR values survive. `EditStack.processVersion` selects between the frozen legacy chain (verbatim today's code) and the new PV2 chain.

**Tech Stack:** Swift 5 / SwiftUI, Core Image + Metal CIKernels (`-fcikernel`), XcodeGen, XCTest, GRDB (untouched).

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-25-process-version-2-design.md`. Read it before starting.
- After adding/removing ANY source file or editing `project.yml`, run `xcodegen generate` before building.
- Test command (from repo root):
  `xcodebuild -project PhotoEditor.xcodeproj -scheme PhotoEditor -destination 'platform=macOS' test 2>&1 | tail -25`
  Scope a run with `-only-testing:PhotoEditorTests/<ClassName>`. First build after clean is slow; that's normal.
- **The legacy path is frozen.** After Task 3, never edit `LegacyToneRenderer.swift` — its bugs are part of what existing edits look like.
- Kernel shape constants (knee widths, weight-band edges, authority coefficients) are deliberate magic numbers pinned by calibration tests; parity ratcheting later may tune them, but only alongside the test that pins them.
- All photos in this app are opaque; kernels pass `s.a` through and operate on RGB only.
- Commit after every green test cycle. Author is already configured (`ajaiupadhyaya@users.noreply.github.com`). End commit messages with the `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` trailer.
- The Metal helpers `srgb_encode`/`srgb_decode` are duplicated per `.ci.metal` file **on purpose**: classic CIKernel metallibs cannot link functions across files. Do not "clean this up."

---

### Task 1: Metal CIKernel build infrastructure

**Files:**
- Modify: `project.yml` (settings block, ~line 16)
- Create: `Sources/Pipeline/Kernels/Probe.ci.metal`
- Create: `Sources/Pipeline/Kernels/KernelLibrary.swift`
- Test: `Tests/KernelInfrastructureTests.swift`

**Interfaces:**
- Produces: `KernelLibrary.color(_ name: String) -> CIColorKernel`, `KernelLibrary.general(_ name: String) -> CIKernel` — every later kernel task loads through these. Kernel function `pv2_probe_identity` (test-only, stays in the lib).

- [ ] **Step 1: Add the CIKernel compile/link flags to `project.yml`**

In the top-level `settings.base` block (alongside `SWIFT_VERSION`), add:

```yaml
    MTL_COMPILER_FLAGS: "-fcikernel"
    MTLLINKER_FLAGS: "-cikernel"
```

This compiles every `.metal` file in the app target as a Core Image kernel into `default.metallib`. Safe here because the project has zero other Metal shader files (verified — `MetalCanvasView` uses MTKView without custom shaders).

- [ ] **Step 2: Write the probe kernel**

`Sources/Pipeline/Kernels/Probe.ci.metal`:

```metal
// Build-infrastructure probe. Proves (a) .ci.metal files compile into
// default.metallib with -fcikernel, (b) kernels load at runtime, and
// (c) extended-range values pass through a kernel unclamped — the property
// the whole PV2 design depends on.
#include <metal_stdlib>
using namespace metal;
#include <CoreImage/CoreImage.h>

extern "C" float4 pv2_probe_identity(coreimage::sample_t s) {
    return s;
}
```

- [ ] **Step 3: Write the kernel loader**

`Sources/Pipeline/Kernels/KernelLibrary.swift`:

```swift
import CoreImage

/// Loads PV2's Metal CIKernels from the app bundle's `default.metallib`.
///
/// Kernels are compiled at build time (`-fcikernel` in project.yml); there is
/// no runtime-source fallback — that API is gone. A missing metallib or
/// function name is a build break, not a recoverable condition, so this traps.
enum KernelLibrary {
    private final class BundleToken {}

    private static let data: Data = {
        guard let url = Bundle(for: BundleToken.self)
            .url(forResource: "default", withExtension: "metallib"),
              let data = try? Data(contentsOf: url) else {
            fatalError("default.metallib missing — check MTL_COMPILER_FLAGS/-fcikernel in project.yml")
        }
        return data
    }()

    static func color(_ name: String) -> CIColorKernel {
        do { return try CIColorKernel(functionName: name, fromMetalLibraryData: data) }
        catch { fatalError("CIColorKernel \(name): \(error)") }
    }

    static func general(_ name: String) -> CIKernel {
        do { return try CIKernel(functionName: name, fromMetalLibraryData: data) }
        catch { fatalError("CIKernel \(name): \(error)") }
    }
}
```

- [ ] **Step 4: Write the failing tests**

`Tests/KernelInfrastructureTests.swift`:

```swift
import CoreImage
import CoreImage.CIFilterBuiltins
import XCTest
@testable import PhotoEditor

final class KernelInfrastructureTests: XCTestCase {
    func testProbeKernelLoadsAndIsIdentity() throws {
        let kernel = KernelLibrary.color("pv2_probe_identity")
        let source = TestSupport.solidImage(red: 0.25, green: 0.5, blue: 0.75, size: 16)
        let out = try XCTUnwrap(kernel.apply(extent: source.extent, arguments: [source]))
        let color = TestSupport.readColor(out)
        XCTAssertEqual(color.red, 0.25, accuracy: 0.01)
        XCTAssertEqual(color.green, 0.5, accuracy: 0.01)
        XCTAssertEqual(color.blue, 0.75, accuracy: 0.01)
    }

    /// The load-bearing assumption of the whole design: values above 1.0
    /// survive a kernel pass unclamped in the default working format.
    func testExtendedRangeSurvivesAKernelPass() throws {
        let kernel = KernelLibrary.color("pv2_probe_identity")
        // Push a 1.0 patch to 2.0 with a color matrix (bias is unclamped).
        let base = TestSupport.solidImage(red: 1, green: 1, blue: 1, size: 16)
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = base
        matrix.biasVector = CIVector(x: 1, y: 1, z: 1, w: 0)
        let edr = try XCTUnwrap(matrix.outputImage)
        let out = try XCTUnwrap(kernel.apply(extent: base.extent, arguments: [edr]))

        var px = [Float](repeating: 0, count: 4)
        let ctx = CIContext()
        ctx.render(out, toBitmap: &px, rowBytes: 4 * MemoryLayout<Float>.stride,
                   bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                   format: .RGBAf, colorSpace: nil)
        XCTAssertGreaterThan(px[0], 1.5, "EDR value was clamped inside the kernel path")
    }
}
```

Note: `TestSupport.readColor` already exists (used by `AdjustmentTests`); check its exact signature in `Tests/TestSupport.swift` and adjust the tuple access if it returns a struct.

- [ ] **Step 5: Regenerate, run, verify failure mode**

```bash
xcodegen generate
xcodebuild -project PhotoEditor.xcodeproj -scheme PhotoEditor -destination 'platform=macOS' test -only-testing:PhotoEditorTests/KernelInfrastructureTests 2>&1 | tail -25
```

Expected first run: PASS if the flags took, or a `default.metallib missing` trap / `functionName not found` if the build rules didn't apply. If the metallib is missing, check that `Probe.ci.metal` is in the app target (XcodeGen picks up `Sources/**` automatically) and that both flags appear in Build Settings.

- [ ] **Step 6: Commit**

```bash
git add project.yml Sources/Pipeline/Kernels Tests/KernelInfrastructureTests.swift
git commit -m "Add build-time Metal CIKernel infrastructure with EDR probe"
```

---

### Task 2: Process versioning on EditStack

**Files:**
- Modify: `Sources/Models/EditStack.swift` (property block ~line 17; lenient init ~line 150)
- Modify: `Sources/App/AppModel.swift:120` (neutral-stack check)
- Test: `Tests/ProcessVersionTests.swift`

**Interfaces:**
- Produces: `EditStack.processVersion: Int` (1 = legacy, 2 = PV2; struct default **2**, decode fallback **1**), `EditStack.isNeutralEdit: Bool`, and new PV2 fields consumed by later tasks: `vignetteRoundness: Double = 0` (−100…100), `vignetteFeather: Double = 50` (0…100), `vignetteHighlights: Double = 0` (0…100), `rawBoost: Double = 100` (0…100), `rawWBInitialized: Bool = false`.

- [ ] **Step 1: Write the failing tests**

`Tests/ProcessVersionTests.swift`:

```swift
import Foundation
import XCTest
@testable import PhotoEditor

final class ProcessVersionTests: XCTestCase {
    /// A stack saved by an older build has no processVersion key — it MUST
    /// decode as version 1, or every existing edit changes appearance.
    func testStackWithoutVersionKeyDecodesAsVersion1() throws {
        let legacyJSON = #"{"exposure": 0.5, "contrast": 25}"#.data(using: .utf8)!
        let stack = try JSONDecoder().decode(EditStack.self, from: legacyJSON)
        XCTAssertEqual(stack.processVersion, 1)
        XCTAssertEqual(stack.exposure, 0.5)
    }

    func testFreshStackIsVersion2() {
        XCTAssertEqual(EditStack().processVersion, 2)
    }

    func testVersionRoundTripsThroughCoding() throws {
        var stack = EditStack()
        stack.processVersion = 1
        let data = try JSONEncoder().encode(stack)
        let decoded = try JSONDecoder().decode(EditStack.self, from: data)
        XCTAssertEqual(decoded.processVersion, 1)
    }

    /// A decoded PV1 stack with no edits is still "neutral" for the purposes
    /// of import/thumbnail shortcuts, even though it != EditStack().
    func testNeutralEditIgnoresProcessVersion() throws {
        let legacyJSON = "{}".data(using: .utf8)!
        let stack = try JSONDecoder().decode(EditStack.self, from: legacyJSON)
        XCTAssertNotEqual(stack, EditStack())      // versions differ
        XCTAssertTrue(stack.isNeutralEdit)          // but no edits
        var edited = EditStack()
        edited.exposure = 1
        XCTAssertFalse(edited.isNeutralEdit)
    }

    func testNewFieldsDecodeLeniently() throws {
        let stack = try JSONDecoder().decode(EditStack.self, from: "{}".data(using: .utf8)!)
        XCTAssertEqual(stack.vignetteRoundness, 0)
        XCTAssertEqual(stack.vignetteFeather, 50)
        XCTAssertEqual(stack.vignetteHighlights, 0)
        XCTAssertEqual(stack.rawBoost, 100)
        XCTAssertFalse(stack.rawWBInitialized)
    }
}
```

- [ ] **Step 2: Run to verify failure** (`-only-testing:PhotoEditorTests/ProcessVersionTests`; expected: compile error, `processVersion` undefined)

- [ ] **Step 3: Implement**

In `EditStack.swift`, at the top of the struct (before `// MARK: Light`):

```swift
    // MARK: Process version

    /// Which rendering engine interprets this stack. 1 = the original chain,
    /// frozen verbatim in ``LegacyToneRenderer`` so old edits never change
    /// appearance; 2 = the calibrated PV2 chain. New stacks start at 2;
    /// decoding falls back to 1 because any stack persisted before this field
    /// existed was authored against the old math.
    var processVersion: Int = 2
```

In the Effects section (after `grainSize`):

```swift
    /// Vignette shape, `-100...100`. Negative pushes the superellipse toward
    /// rectangular; positive rounds it toward a circle.
    var vignetteRoundness: Double = 0

    /// Vignette falloff width, `0...100`.
    var vignetteFeather: Double = 50

    /// Vignette highlight priority, `0...100`. Lets bright areas punch
    /// through a darkening vignette.
    var vignetteHighlights: Double = 0
```

New section after `// MARK: Film`:

```swift
    // MARK: RAW

    /// Baseline RAW rendering boost, `0...100`, mapped to
    /// `CIRAWFilter.boostAmount`. 100 is Apple's default look; 0 is the flat
    /// linear rendering. This is the spec's "visible, adjustable baseline
    /// tone lift" — the lift exists either way; this makes it a slider
    /// instead of an invisible bake. Ignored for non-RAW sources.
    var rawBoost: Double = 100

    /// Whether as-shot white balance has been read from the RAW file into
    /// ``whiteBalanceTemp``/``whiteBalanceTint`` (done once on first load).
    var rawWBInitialized: Bool = false
```

In `init(from:)` add (mind the section grouping):

```swift
        processVersion = c.lenient(.processVersion, 1)
        vignetteRoundness = c.lenient(.vignetteRoundness, 0)
        vignetteFeather = c.lenient(.vignetteFeather, 50)
        vignetteHighlights = c.lenient(.vignetteHighlights, 0)
        rawBoost = c.lenient(.rawBoost, 100)
        rawWBInitialized = c.lenient(.rawWBInitialized, false)
```

Below the struct, add:

```swift
extension EditStack {
    /// True when the stack contains no edits, regardless of which process
    /// version it targets. Use this — not `== EditStack()` — for "has the
    /// user done anything" checks; a neutral PV1 stack differs from
    /// `EditStack()` only in `processVersion`, and a neutral stack renders
    /// identically under both engines.
    var isNeutralEdit: Bool {
        var normalized = self
        normalized.processVersion = EditStack().processVersion
        normalized.rawWBInitialized = false
        return normalized == EditStack()
    }
}
```

- [ ] **Step 4: Fix the neutral-stack comparison at `AppModel.swift:120`**

Change `if entry.editStack == EditStack(),` to `if entry.editStack.isNeutralEdit,`. Then grep for any other occurrence:

```bash
grep -rn "== EditStack()" Sources/
```

Fix any comparison that means "has no edits" the same way. (`EditorModel.swift:115` and `:482` construct fresh stacks rather than compare — leave those.)

- [ ] **Step 5: Run tests, then the full suite** (both must pass — the full suite proves no existing behavior changed)

- [ ] **Step 6: Commit** — `feat: add processVersion and PV2 fields to EditStack`

---

### Task 3: Freeze the legacy renderer, dispatch by version

**Files:**
- Create: `Sources/Pipeline/LegacyToneRenderer.swift`
- Modify: `Sources/Pipeline/EditRenderer.swift` (whole tone section, lines 51–408)
- Modify: `Tests/AdjustmentTests.swift` (pin to legacy)
- Test: `Tests/ProcessVersionTests.swift` (add dispatch tests)

**Interfaces:**
- Consumes: `EditStack.processVersion` (Task 2).
- Produces: `final class LegacyToneRenderer { func render(source: CIImage, stack: EditStack, mlEnvironment: MLMaskEnvironment?, context: CIContext) -> CIImage }`; `EditRenderer.render(source:stack:mlEnvironment:)` unchanged in signature but dispatching on version. PV2 chain initially = legacy stage implementations (each later task swaps one stage), so behavior is identical until kernels land.

- [ ] **Step 1: Create `LegacyToneRenderer.swift`**

Move — verbatim, cut-and-paste, no edits beyond what's listed — the body of `render(source:stack:mlEnvironment:)` and ALL private `apply*` methods, `unsharpMask`, `applyDehaze`, `reduceColorNoise`, `applyVignette`, `applyGrain` from `EditRenderer.swift` into:

```swift
import CoreImage
import CoreImage.CIFilterBuiltins

/// The original (process version 1) develop chain, frozen.
///
/// Every stack persisted before PV2 was authored against this math — including
/// its bugs (linear-space contrast pivot, dead positive highlights, pinned
/// whites/blacks). Those bugs are part of what those edits *look like*, so
/// this file must never be edited. See the PV2 spec.
final class LegacyToneRenderer {
    private let cubeCache = ColorCubeCache()
    private let developedCache = DevelopedSourceCache()

    func render(source: CIImage, stack: EditStack,
                mlEnvironment: MLMaskEnvironment?, context: CIContext) -> CIImage {
        // ← the exact body of today's EditRenderer.render, lines 52–80
    }

    // ← today's applyWhiteBalance … applyGrain, verbatim, with
    //   `stack:` signatures unchanged. Where a method used `self.context`,
    //   thread the `context` parameter through instead (applyColorLUT takes
    //   no context; DevelopedSourceCache and RetouchRenderer already take one).
}
```

The only mechanical changes allowed: `struct → methods on this class`, threading `context` as a parameter, and using this class's own two caches.

- [ ] **Step 2: Rewrite `EditRenderer.render` as a dispatcher**

`EditRenderer` keeps: `context`, `makeCGImage`, `renderCGImage`, `histogram`, `displaySpace`. Its tone methods remain **for now** (PV2 chain starts as a copy of the legacy chain; later tasks replace stages one by one). Add:

```swift
    private let legacy = LegacyToneRenderer()

    func render(source: CIImage, stack: EditStack, mlEnvironment: MLMaskEnvironment? = nil) -> CIImage {
        guard stack.processVersion >= 2 else {
            return legacy.render(source: source, stack: stack,
                                 mlEnvironment: mlEnvironment, context: context)
        }
        // PV2 chain — stage bodies are replaced task by task.
        var image = source
        image = developedCache.developed(from: image, film: stack.filmNegative,
                                         geometry: stack.geometry, defringe: stack.defringe,
                                         retouch: stack.retouch, context: context)
        image = applyWhiteBalance(image, stack: stack)
        image = applyExposure(image, stack: stack)
        image = applyHighlightsAndShadows(image, stack: stack)
        image = applyContrast(image, stack: stack)
        image = applyWhitesAndBlacks(image, stack: stack)
        image = applyPresence(image, stack: stack)
        image = applyColor(image, stack: stack)
        image = applyColorLUT(image, stack: stack)
        image = applyCreativeLUT(image, stack: stack)
        image = applyToneCurve(image, stack: stack)
        let maskSource = image
        image = LocalAdjustmentRenderer.apply(stack.localAdjustments, to: image,
                                              maskSource: maskSource,
                                              mlEnvironment: mlEnvironment, context: context)
        image = applyDetail(image, stack: stack)
        image = applyEffects(image, stack: stack)
        return image
    }
```

Note the PV2 tone order is highlights/shadows → contrast → whites/blacks (recover first, shape midtones, place clip points last). Legacy order inside `LegacyToneRenderer` is untouched.

- [ ] **Step 3: Pin the direction tests to the correct engine**

In `Tests/AdjustmentTests.swift`, the helper at line ~22 builds `EditStack()` — now PV2. These direction assertions must keep guarding the **frozen legacy** path (that's the pin that keeps the freeze frozen). At the top of `brightness(_:_:)` and the other stack-building helpers add `stack.processVersion = 1`. `testWhitesAndBlacksActOnOppositeEnds` (line ~55) now documents *legacy* behavior — add a comment saying so. PV2 gets its own placement tests in Tasks 5–8.

- [ ] **Step 4: Add dispatch tests to `ProcessVersionTests`**

```swift
    func testVersion1RendersThroughLegacyChainUnchanged() {
        // The known legacy bug: positive highlights is a no-op. If PV1 ever
        // stops reproducing it, the freeze broke.
        let renderer = EditRenderer()
        var stack = EditStack()
        stack.processVersion = 1
        stack.highlights = 100
        let source = TestSupport.solidImage(red: 0.6, green: 0.6, blue: 0.6, size: 32)
        let out = renderer.render(source: source, stack: stack)
        let color = TestSupport.readColor(out)
        XCTAssertEqual(color.red, 0.6, accuracy: 0.01,
                       "PV1 must keep the legacy no-op highlights bug")
    }

    func testNeutralStacksRenderIdenticallyUnderBothVersions() {
        let renderer = EditRenderer()
        let source = TestSupport.solidImage(red: 0.4, green: 0.5, blue: 0.6, size: 32)
        var v1 = EditStack(); v1.processVersion = 1
        let a = TestSupport.readColor(renderer.render(source: source, stack: v1))
        let b = TestSupport.readColor(renderer.render(source: source, stack: EditStack()))
        XCTAssertEqual(a.red, b.red, accuracy: 0.005)
        XCTAssertEqual(a.green, b.green, accuracy: 0.005)
        XCTAssertEqual(a.blue, b.blue, accuracy: 0.005)
    }
```

- [ ] **Step 5: Run the FULL suite** — everything must pass; this task is pure reshuffle.

- [ ] **Step 6: Commit** — `refactor: freeze PV1 chain in LegacyToneRenderer, dispatch on processVersion`

---

### Task 4: Calibration test support + display-space point curve

**Files:**
- Create: `Tests/CalibrationSupport.swift`
- Create: `Sources/Pipeline/DisplaySpace.swift`
- Modify: `Sources/Pipeline/EditRenderer.swift` (`applyToneCurve`, PV2 copy only)
- Test: `Tests/CalibrationTests.swift`

**Interfaces:**
- Produces: `Calibration.displaySweep(inputs: [Double], mutate: (inout EditStack) -> Void) -> [Double]` (display-in → display-out through the PV2 renderer) and `Calibration.displayValue(of: CIImage, x: Int, y: Int) -> Double` — every calibration test in Tasks 5–10 uses these. `CIImage.inDisplaySpace(_ transform: (CIImage) -> CIImage) -> CIImage` for wrapping built-ins.

- [ ] **Step 1: Write `Tests/CalibrationSupport.swift`**

```swift
import CoreGraphics
import CoreImage
import XCTest
@testable import PhotoEditor

/// Measures what the pipeline does to known display-referred sRGB values.
/// This is the harness that would have caught every PV1 calibration bug:
/// direction tests say "brighter"; these say "brighter by how much, where."
enum Calibration {
    static let context = CIContext()
    static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    /// A patch whose sRGB *display* value is `v` in all channels.
    static func patch(_ v: Double, size: CGFloat = 16) -> CIImage {
        TestSupport.solidImage(red: v, green: v, blue: v, size: size)
    }

    /// Reads back the sRGB display value of the red channel at (x, y).
    static func displayValue(of image: CIImage, x: Int = 0, y: Int = 0) -> Double {
        var px = [UInt8](repeating: 0, count: 4)
        context.render(image, toBitmap: &px, rowBytes: 4,
                       bounds: CGRect(x: x, y: y, width: 1, height: 1),
                       format: .RGBA8, colorSpace: srgb)
        return Double(px[0]) / 255.0
    }

    /// Feeds each display value through the PV2 renderer with `mutate`
    /// applied to a fresh (PV2) stack; returns display-out values.
    static func displaySweep(inputs: [Double],
                             mutate: (inout EditStack) -> Void) -> [Double] {
        let renderer = EditRenderer()
        var stack = EditStack()
        mutate(&stack)
        return inputs.map { v in
            displayValue(of: renderer.render(source: patch(v), stack: stack), x: 2, y: 2)
        }
    }

    /// A 128-wide horizontal display-space ramp from 0 to 1, `height` tall.
    static func ramp(height: Int = 16) -> CIImage {
        let w = 128
        var bytes = [UInt8](repeating: 255, count: w * height * 4)
        for y in 0..<height {
            for x in 0..<w {
                let v = UInt8((Double(x) / Double(w - 1) * 255).rounded())
                let i = (y * w + x) * 4
                bytes[i] = v; bytes[i + 1] = v; bytes[i + 2] = v
            }
        }
        return CIImage(bitmapData: Data(bytes), bytesPerRow: w * 4,
                       size: CGSize(width: w, height: height),
                       format: .RGBA8, colorSpace: srgb)
    }
}
```

- [ ] **Step 2: Write the failing point-curve test in `Tests/CalibrationTests.swift`**

```swift
import CoreGraphics
import XCTest
@testable import PhotoEditor

final class CalibrationTests: XCTestCase {
    /// Dragging the curve's midpoint up must lift DISPLAY midtones most.
    /// PV1 applied CIToneCurve in the linear working space, which put the
    /// peak of the lift near display 0.74 instead of 0.50.
    func testPointCurveMidtoneLiftPeaksAtDisplayMidtone() {
        let inputs = stride(from: 0.1, through: 0.9, by: 0.1).map { $0 }
        let outputs = Calibration.displaySweep(inputs: inputs) {
            $0.toneCurvePoints = [CGPoint(x: 0, y: 0), CGPoint(x: 0.25, y: 0.25),
                                  CGPoint(x: 0.5, y: 0.6), CGPoint(x: 0.75, y: 0.75),
                                  CGPoint(x: 1, y: 1)]
        }
        let deltas = zip(outputs, inputs).map { $0 - $1 }
        let peakInput = inputs[deltas.firstIndex(of: deltas.max()!)!]
        XCTAssertEqual(peakInput, 0.5, accuracy: 0.11,
                       "midtone lift peaked at display \(peakInput), deltas \(deltas)")
        XCTAssertEqual(outputs[4], 0.6, accuracy: 0.03,
                       "display 0.5 through a 0.5→0.6 curve point must land near 0.6")
    }
}
```

- [ ] **Step 3: Run to verify it fails** (peak lands near 0.7–0.8 today).

- [ ] **Step 4: Implement `Sources/Pipeline/DisplaySpace.swift`**

```swift
import CoreImage

extension CIImage {
    /// Runs `transform` on the sRGB-gamma-encoded version of the image and
    /// converts the result back to the linear working space.
    ///
    /// Core Image's built-in curve filters interpolate whatever values they
    /// are handed — which, in the working space, are linear. A curve the user
    /// drew against a display-referred UI must interpolate display values, so
    /// display-referred built-ins get sandwiched in these two conversions.
    /// (PV2's own Metal kernels do this encode/decode internally instead.)
    func inDisplaySpace(_ transform: (CIImage) -> CIImage) -> CIImage {
        let encoded = applyingFilter("CILinearToSRGBToneCurve")
        return transform(encoded).applyingFilter("CISRGBToneCurveToLinear")
    }
}
```

- [ ] **Step 5: Fix the PV2 `applyToneCurve`**

In `EditRenderer.swift` (PV2 copy — NOT `LegacyToneRenderer`), wrap both curve applications:

```swift
    private func applyToneCurve(_ image: CIImage, stack: EditStack) -> CIImage {
        var result = image
        if hasParametricToneCurve(stack) {
            result = applyParametricToneCurve(result, stack: stack)   // replaced in Task 7
        }
        guard stack.toneCurvePoints.count == 5 else { return result }
        return result.inDisplaySpace { encoded in
            let curve = CIFilter.toneCurve()
            curve.inputImage = encoded
            curve.point0 = stack.toneCurvePoints[0]
            curve.point1 = stack.toneCurvePoints[1]
            curve.point2 = stack.toneCurvePoints[2]
            curve.point3 = stack.toneCurvePoints[3]
            curve.point4 = stack.toneCurvePoints[4]
            return curve.outputImage ?? encoded
        }
    }
```

- [ ] **Step 6: Run CalibrationTests + full suite, commit** — `fix(pv2): interpolate the point tone curve in display space`

---

### Task 5: Tone.ci.metal — contrast

**Files:**
- Create: `Sources/Pipeline/Kernels/Tone.ci.metal`
- Create: `Sources/Pipeline/ToneStages.swift`
- Modify: `Sources/Pipeline/EditRenderer.swift` (PV2 `applyContrast`)
- Test: `Tests/CalibrationTests.swift`

**Interfaces:**
- Produces: kernel `pv2_contrast(sample_t, float amount)`; `ToneStages.contrast(_ image: CIImage, amount: Double) -> CIImage` (amount −100…100). Tasks 6–7 add functions to the same `.ci.metal` file and same `ToneStages` enum.

- [ ] **Step 1: Write the failing tests** (add to `CalibrationTests`):

```swift
    func testContrastPivotsAtDisplayMiddleGrey() {
        let out = Calibration.displaySweep(inputs: [0.5]) { $0.contrast = 60 }
        XCTAssertEqual(out[0], 0.5, accuracy: 0.02,
                       "contrast must pivot at display 0.5, not linear 0.5 (display 0.74)")
    }

    func testContrastNeverCrushesMidRampToBlackOrWhite() {
        let inputs = [0.1, 0.2, 0.3, 0.4, 0.6, 0.7, 0.8, 0.9]
        let out = Calibration.displaySweep(inputs: inputs) { $0.contrast = 100 }
        for (i, v) in out.enumerated() {
            XCTAssertGreaterThan(v, 0.004, "display \(inputs[i]) crushed to black at +100")
            XCTAssertLessThan(v, 0.996, "display \(inputs[i]) blown to white at +100")
        }
        // PV1 sent display 0.10–0.40 to exactly 0.0 at +50. Never again:
        let legacyVictims = Calibration.displaySweep(inputs: [0.1, 0.25, 0.4]) { $0.contrast = 50 }
        XCTAssertGreaterThan(legacyVictims[0], 0.01)
        XCTAssertGreaterThan(legacyVictims[1], 0.08)
        XCTAssertGreaterThan(legacyVictims[2], 0.2)
    }

    func testContrastIsMonotonicAndDirectional() {
        let inputs = stride(from: 0.05, through: 0.95, by: 0.05).map { $0 }
        let plus = Calibration.displaySweep(inputs: inputs) { $0.contrast = 70 }
        let minus = Calibration.displaySweep(inputs: inputs) { $0.contrast = -70 }
        for i in 1..<plus.count {
            XCTAssertGreaterThanOrEqual(plus[i] + 0.002, plus[i - 1], "not monotonic at +70")
            XCTAssertGreaterThanOrEqual(minus[i] + 0.002, minus[i - 1], "not monotonic at −70")
        }
        XCTAssertLessThan(plus[2], inputs[2])       // + steepens: shadows darker
        XCTAssertGreaterThan(plus[16], inputs[16])  //              highlights brighter
        XCTAssertGreaterThan(minus[2], inputs[2])   // − flattens: shadows lifted
    }
```

- [ ] **Step 2: Run to verify failure** (pivot lands ~0.29 today via the legacy-copied stage).

- [ ] **Step 3: Write the kernel** — `Sources/Pipeline/Kernels/Tone.ci.metal`:

```metal
// PV2 tone kernels. All display-referred: each kernel encodes the linear
// working-space sample to sRGB gamma, does its math where the histogram and
// the user's eye live, and decodes back. Sign-preserving transfer functions
// keep extended-range values alive; values above 1.0 pass around the curve
// as a residual so EDR headroom is not flattened.
#include <metal_stdlib>
using namespace metal;
#include <CoreImage/CoreImage.h>

// Duplicated per .ci.metal file on purpose — classic CIKernel metallibs
// cannot link functions across translation units.
static float srgb_enc1(float c) {
    float a = fabs(c);
    float e = (a <= 0.0031308f) ? a * 12.92f : 1.055f * pow(a, 1.0f / 2.4f) - 0.055f;
    return copysign(e, c);
}
static float srgb_dec1(float c) {
    float a = fabs(c);
    float l = (a <= 0.04045f) ? a / 12.92f : pow((a + 0.055f) / 1.055f, 2.4f);
    return copysign(l, c);
}
static float3 srgb_encode(float3 c) { return float3(srgb_enc1(c.x), srgb_enc1(c.y), srgb_enc1(c.z)); }
static float3 srgb_decode(float3 c) { return float3(srgb_dec1(c.x), srgb_dec1(c.y), srgb_dec1(c.z)); }

// Contrast about display middle grey. amount in −1…1.
// Positive blends toward the Hermite S-curve x²(3−2x): pinned at 0 and 1,
// fixed point exactly at 0.5, slope 1.5 there at full strength — steepens
// without ever clipping. Negative blends toward that curve's exact inverse
// (0.5 − sin(asin(1−2y)/3)), which flattens symmetrically.
static float contrast_curve(float x, float amount) {
    float xc = clamp(x, 0.0f, 1.0f);
    float residual = x - xc;                       // EDR / negative headroom
    float shaped;
    if (amount >= 0.0f) {
        float s = xc * xc * (3.0f - 2.0f * xc);
        shaped = mix(xc, s, amount);
    } else {
        float inv = 0.5f - sin(asin(1.0f - 2.0f * xc) / 3.0f);
        shaped = mix(xc, inv, -amount);
    }
    return shaped + residual;
}

extern "C" float4 pv2_contrast(coreimage::sample_t s, float amount) {
    float3 d = srgb_encode(s.rgb);
    d = float3(contrast_curve(d.x, amount),
               contrast_curve(d.y, amount),
               contrast_curve(d.z, amount));
    return float4(srgb_decode(d), s.a);
}
```

- [ ] **Step 4: Write the stage** — `Sources/Pipeline/ToneStages.swift`:

```swift
import CoreImage

/// Swift faces of the Tone.ci.metal kernels. Amounts arrive on the sliders'
/// −100…100 scale and are normalized here, so the kernels speak −1…1.
enum ToneStages {
    private static let contrastKernel = KernelLibrary.color("pv2_contrast")

    static func contrast(_ image: CIImage, amount: Double) -> CIImage {
        guard amount != 0 else { return image }
        return contrastKernel.apply(extent: image.extent,
                                    arguments: [image, Float(amount / 100)]) ?? image
    }
}
```

- [ ] **Step 5: Swap the PV2 stage.** In `EditRenderer.swift` replace the PV2 `applyContrast` body:

```swift
    private func applyContrast(_ image: CIImage, stack: EditStack) -> CIImage {
        ToneStages.contrast(image, amount: stack.contrast)
    }
```

(Confirm `LegacyToneRenderer` still has its own `applyContrast` — it must.)

- [ ] **Step 6: `xcodegen generate`, run CalibrationTests + full suite, commit** — `feat(pv2): contrast pivots at display middle grey via Metal kernel`

---

### Task 6: Tone.ci.metal — whites and blacks

**Files:**
- Modify: `Sources/Pipeline/Kernels/Tone.ci.metal`, `Sources/Pipeline/ToneStages.swift`
- Modify: `Sources/Pipeline/EditRenderer.swift` (PV2 `applyWhitesAndBlacks`)
- Test: `Tests/CalibrationTests.swift`

**Interfaces:**
- Produces: kernel `pv2_whites_blacks(sample_t, float whites, float blacks)`; `ToneStages.whitesAndBlacks(_ image: CIImage, whites: Double, blacks: Double) -> CIImage`.

- [ ] **Step 1: Failing tests:**

```swift
    func testWhitesMoveTheWhiteClippingPoint() {
        // PV1's pinned curve mapped display 1.0 → 1.0 at ANY whites value and
        // could never clip. Whites +100 must drive the top of the range to white.
        let top = Calibration.displaySweep(inputs: [0.85, 1.0]) { $0.whites = 100 }
        XCTAssertGreaterThan(top[0], 0.97, "near-white must reach white at whites +100")
        XCTAssertGreaterThanOrEqual(top[1], 0.995)
        // …while barely moving a quarter-tone (that's contrast's job).
        let quarter = Calibration.displaySweep(inputs: [0.25]) { $0.whites = 100 }
        XCTAssertEqual(quarter[0], 0.25 / 0.7, accuracy: 0.06)
        // Negative whites pulls the top down without touching shadows.
        let pulled = Calibration.displaySweep(inputs: [0.15, 1.0]) { $0.whites = -100 }
        XCTAssertLessThan(pulled[1], 0.75)
        XCTAssertEqual(pulled[0], 0.15, accuracy: 0.03)
    }

    func testBlacksMoveTheBlackClippingPoint() {
        let bottom = Calibration.displaySweep(inputs: [0.0, 0.15]) { $0.blacks = -100 }
        XCTAssertLessThan(bottom[1], 0.03, "near-black must crush at blacks −100")
        let high = Calibration.displaySweep(inputs: [0.85]) { $0.blacks = -100 }
        XCTAssertEqual(high[0], (0.85 - 0.3) / 0.7, accuracy: 0.06)
        // Positive blacks lifts the floor (the faded look).
        let lifted = Calibration.displaySweep(inputs: [0.0]) { $0.blacks = 100 }
        XCTAssertGreaterThan(lifted[0], 0.1)
    }

    func testWhitesAndBlacksComposeMonotonically() {
        let inputs = stride(from: 0.0, through: 1.0, by: 0.1).map { $0 }
        let out = Calibration.displaySweep(inputs: inputs) { $0.whites = 60; $0.blacks = -60 }
        for i in 1..<out.count {
            XCTAssertGreaterThanOrEqual(out[i] + 0.002, out[i - 1])
        }
    }
```

- [ ] **Step 2: Run to verify failure.**

- [ ] **Step 3: Add to `Tone.ci.metal`:**

```metal
// Soft shoulder: exact identity below 1−k, C1 quadratic knee that reaches
// exactly 1.0 (zero slope) at t = 1+k. This is what lets whites/blacks
// genuinely clip without posterizing at the knee.
static float soft_shoulder(float t, float k) {
    if (t <= 1.0f - k) return t;
    if (t >= 1.0f + k) return 1.0f;
    float u = (t - (1.0f - k)) / (2.0f * k);
    return (1.0f - k) + 2.0f * k * (u - 0.5f * u * u);
}

// Whites/blacks move the clipping points (authority: 0.30 of the range at
// ±100, knee width 0.05), with the negative directions as tone-weighted
// compressions so the opposite end of the range stays put.
static float whites_blacks(float x, float w, float b) {
    float y = x;
    if (w > 0.0f)      y = soft_shoulder(y / (1.0f - 0.30f * w), 0.05f);
    else if (w < 0.0f) y = y + 0.35f * w * y * y;                      // top-weighted pull-down
    if (b < 0.0f)      y = 1.0f - soft_shoulder((1.0f - y) / (1.0f + 0.30f * b), 0.05f);
    else if (b > 0.0f) y = y + 0.25f * b * (1.0f - y) * (1.0f - y);    // bottom-weighted lift
    return y;
}

extern "C" float4 pv2_whites_blacks(coreimage::sample_t s, float whites, float blacks) {
    float3 d = srgb_encode(s.rgb);
    d = float3(whites_blacks(d.x, whites, blacks),
               whites_blacks(d.y, whites, blacks),
               whites_blacks(d.z, whites, blacks));
    return float4(srgb_decode(d), s.a);
}
```

- [ ] **Step 4: Add the stage and swap it in:**

```swift
    private static let whitesBlacksKernel = KernelLibrary.color("pv2_whites_blacks")

    static func whitesAndBlacks(_ image: CIImage, whites: Double, blacks: Double) -> CIImage {
        guard whites != 0 || blacks != 0 else { return image }
        return whitesBlacksKernel.apply(extent: image.extent,
                                        arguments: [image, Float(whites / 100), Float(blacks / 100)]) ?? image
    }
```

PV2 `applyWhitesAndBlacks` body becomes `ToneStages.whitesAndBlacks(image, whites: stack.whites, blacks: stack.blacks)`.

- [ ] **Step 5: Run + full suite + commit** — `feat(pv2): whites/blacks move real clipping points with a soft knee`

---

### Task 7: Tone.ci.metal — parametric tone curve

**Files:**
- Modify: `Sources/Pipeline/Kernels/Tone.ci.metal`, `Sources/Pipeline/ToneStages.swift`
- Modify: `Sources/Pipeline/EditRenderer.swift` (PV2 `applyParametricToneCurve`)
- Test: `Tests/CalibrationTests.swift`

**Interfaces:**
- Produces: kernel `pv2_parametric(sample_t, float highlights, float lights, float darks, float shadows)`; `ToneStages.parametricCurve(_ image: CIImage, highlights: Double, lights: Double, darks: Double, shadows: Double) -> CIImage`.

- [ ] **Step 1: Failing tests:**

```swift
    func testParametricRegionsPeakInTheirOwnQuartiles() {
        let inputs = [0.05, 0.3, 0.7, 0.95]
        for (index, mutate) in [
            { (s: inout EditStack) in s.toneCurveShadows = 100 },
            { (s: inout EditStack) in s.toneCurveDarks = 100 },
            { (s: inout EditStack) in s.toneCurveLights = 100 },
            { (s: inout EditStack) in s.toneCurveHighlights = 100 },
        ].enumerated() {
            let out = Calibration.displaySweep(inputs: inputs, mutate: mutate)
            let deltas = zip(out, inputs).map { $0 - $1 }
            let peak = deltas.firstIndex(of: deltas.max()!)!
            XCTAssertEqual(peak, index,
                           "region \(index) peaked at input \(inputs[peak]); deltas \(deltas)")
        }
    }

    func testParametricIsAppliedInDisplaySpace() {
        // Darks +100 must move display 0.3 far more than display 0.7.
        let out = Calibration.displaySweep(inputs: [0.3, 0.7]) { $0.toneCurveDarks = 100 }
        XCTAssertGreaterThan(out[0] - 0.3, (out[1] - 0.7) * 2)
    }
```

- [ ] **Step 2: Run to verify failure** (legacy-copied parametric works at linear positions).

- [ ] **Step 3: Add to `Tone.ci.metal`:**

```metal
// Parametric tone curve. The four regions are the cubic Bernstein basis
// functions — smooth, non-negative, summing to 1, peaking at 0, 1/3, 2/3, 1
// in display space. 0.25 sets total authority at ±100.
static float parametric_curve(float x, float hl, float lt, float dk, float sh) {
    float xc = clamp(x, 0.0f, 1.0f);
    float residual = x - xc;
    float omx = 1.0f - xc;
    float wsh = omx * omx * omx;
    float wdk = 3.0f * xc * omx * omx;
    float wlt = 3.0f * xc * xc * omx;
    float whl = xc * xc * xc;
    float y = xc + 0.25f * (sh * wsh + dk * wdk + lt * wlt + hl * whl);
    return clamp(y, 0.0f, 1.0f) + residual;
}

extern "C" float4 pv2_parametric(coreimage::sample_t s,
                                 float highlights, float lights, float darks, float shadows) {
    float3 d = srgb_encode(s.rgb);
    d = float3(parametric_curve(d.x, highlights, lights, darks, shadows),
               parametric_curve(d.y, highlights, lights, darks, shadows),
               parametric_curve(d.z, highlights, lights, darks, shadows));
    return float4(srgb_decode(d), s.a);
}
```

- [ ] **Step 4: Stage + swap.** In `ToneStages`:

```swift
    private static let parametricKernel = KernelLibrary.color("pv2_parametric")

    static func parametricCurve(_ image: CIImage, highlights: Double, lights: Double,
                                darks: Double, shadows: Double) -> CIImage {
        guard highlights != 0 || lights != 0 || darks != 0 || shadows != 0 else { return image }
        return parametricKernel.apply(
            extent: image.extent,
            arguments: [image, Float(highlights / 100), Float(lights / 100),
                        Float(darks / 100), Float(shadows / 100)]) ?? image
    }
```

PV2 `applyParametricToneCurve` becomes a call to it; delete the PV2 copy of the old five-point implementation and the `lift` helper (legacy keeps its own).

- [ ] **Step 5: Run + full suite + commit** — `feat(pv2): parametric tone curve with Bernstein region weights`

---

### Task 8: LocalTone — highlights and shadows without halos

**Files:**
- Create: `Sources/Pipeline/Kernels/LocalTone.ci.metal`
- Create: `Sources/Pipeline/LocalToneStage.swift`
- Modify: `Sources/Pipeline/EditRenderer.swift` (PV2 `applyHighlightsAndShadows`)
- Test: `Tests/CalibrationTests.swift`

**Interfaces:**
- Produces: kernel `pv2_local_tone(sample_t s, sample_t base, float highlights, float shadows)`; `LocalToneStage.apply(_ image: CIImage, highlights: Double, shadows: Double) -> CIImage`.

- [ ] **Step 1: Failing tests:**

```swift
    func testHighlightsWorksInBothDirections() {
        // The PV1 bug: +highlights was a hard no-op. Both signs must move a
        // bright patch, monotonically.
        let bright = 0.8
        let up = Calibration.displaySweep(inputs: [bright]) { $0.highlights = 80 }
        let down = Calibration.displaySweep(inputs: [bright]) { $0.highlights = -80 }
        let downFull = Calibration.displaySweep(inputs: [bright]) { $0.highlights = -100 }
        XCTAssertGreaterThan(up[0], bright + 0.02)
        XCTAssertLessThan(down[0], bright - 0.05)
        XCTAssertLessThan(downFull[0], down[0], "recovery must deepen with amount")
        // …and leave a shadow patch essentially alone.
        let dark = Calibration.displaySweep(inputs: [0.15]) { $0.highlights = -100 }
        XCTAssertEqual(dark[0], 0.15, accuracy: 0.02)
    }

    func testShadowsWorksInBothDirectionsAndIsLocalToShadows() {
        let lifted = Calibration.displaySweep(inputs: [0.2]) { $0.shadows = 80 }
        let deepened = Calibration.displaySweep(inputs: [0.2]) { $0.shadows = -80 }
        XCTAssertGreaterThan(lifted[0], 0.25)
        XCTAssertLessThan(deepened[0], 0.15)
        let bright = Calibration.displaySweep(inputs: [0.85]) { $0.shadows = 80 }
        XCTAssertEqual(bright[0], 0.85, accuracy: 0.03)
    }

    /// The halo test. Shadow recovery on a hard dark/bright edge must not
    /// overshoot on either side of the boundary — the guided-filter base
    /// keeps the step a step, so the gain map cannot leak across it.
    func testShadowLiftDoesNotHaloAcrossAHardEdge() {
        let renderer = EditRenderer()
        var stack = EditStack()
        stack.shadows = 100
        let edge = CalibrationEdge.image(dark: 0.16, bright: 0.82, size: 128)
        let out = renderer.render(source: edge, stack: stack)
        // Bright side, near and far from the edge: lift must not darken it,
        // and near-edge must match far-edge (no dark band).
        let brightNear = Calibration.displayValue(of: out, x: 68, y: 64)
        let brightFar = Calibration.displayValue(of: out, x: 120, y: 64)
        XCTAssertGreaterThanOrEqual(brightNear, 0.80)
        XCTAssertEqual(brightNear, brightFar, accuracy: 0.03, "halo band on the bright side")
        // Dark side near the edge must be lifted the same as far from it.
        let darkNear = Calibration.displayValue(of: out, x: 60, y: 64)
        let darkFar = Calibration.displayValue(of: out, x: 8, y: 64)
        XCTAssertEqual(darkNear, darkFar, accuracy: 0.04, "uneven lift = halo on the dark side")
    }
```

Add the edge builder to `CalibrationSupport.swift`:

```swift
enum CalibrationEdge {
    /// A vertical hard edge: left half `dark`, right half `bright` (display values).
    static func image(dark: Double, bright: Double, size: Int) -> CIImage {
        var bytes = [UInt8](repeating: 255, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let v = UInt8(((x < size / 2 ? dark : bright) * 255).rounded())
                let i = (y * size + x) * 4
                bytes[i] = v; bytes[i + 1] = v; bytes[i + 2] = v
            }
        }
        return CIImage(bitmapData: Data(bytes), bytesPerRow: size * 4,
                       size: CGSize(width: size, height: size),
                       format: .RGBA8, colorSpace: Calibration.srgb)
    }
}
```

- [ ] **Step 2: Run to verify failure** (`testHighlightsWorksInBothDirections` fails on the legacy-copied stage).

- [ ] **Step 3: Write `LocalTone.ci.metal`:**

```metal
// Highlights/shadows via base–detail decomposition. The base arrives from
// CIGuidedFilter (edge-preserving, so the tonal gain cannot bleed across
// edges — that bleed is what a halo is). The kernel retones the BASE only
// and adds the untouched detail back on top.
#include <metal_stdlib>
using namespace metal;
#include <CoreImage/CoreImage.h>

static float srgb_enc1(float c) {
    float a = fabs(c);
    float e = (a <= 0.0031308f) ? a * 12.92f : 1.055f * pow(a, 1.0f / 2.4f) - 0.055f;
    return copysign(e, c);
}
static float srgb_dec1(float c) {
    float a = fabs(c);
    float l = (a <= 0.04045f) ? a / 12.92f : pow((a + 0.055f) / 1.055f, 2.4f);
    return copysign(l, c);
}
static float3 srgb_encode(float3 c) { return float3(srgb_enc1(c.x), srgb_enc1(c.y), srgb_enc1(c.z)); }
static float3 srgb_decode(float3 c) { return float3(srgb_dec1(c.x), srgb_dec1(c.y), srgb_dec1(c.z)); }

extern "C" float4 pv2_local_tone(coreimage::sample_t s, coreimage::sample_t base,
                                 float highlights, float shadows) {
    float3 img = srgb_encode(s.rgb);
    float3 b = srgb_encode(base.rgb);
    float3 detail = img - b;

    float L = dot(b, float3(0.2126f, 0.7152f, 0.0722f));
    float hw = smoothstep(0.35f, 0.85f, L);          // highlight region weight
    float sw = 1.0f - smoothstep(0.15f, 0.65f, L);   // shadow region weight
    // 0.45 total authority; (1−L)/L factors keep each control from crossing
    // into the opposite end of the range.
    float newL = L
        + shadows * 0.45f * sw * (1.0f - L)
        + highlights * 0.45f * hw * L;
    newL = clamp(newL, 0.0f, 1.0f);
    float gain = (L > 1e-4f) ? newL / L : 1.0f;

    float3 outRGB = clamp(b * gain + detail, -0.1f, 4.0f);
    return float4(srgb_decode(outRGB), s.a);
}
```

- [ ] **Step 4: Write `Sources/Pipeline/LocalToneStage.swift`:**

```swift
import CoreImage

/// Highlights/shadows: guided-filter base + kernel recombine.
enum LocalToneStage {
    private static let kernel = KernelLibrary.color("pv2_local_tone")

    static func apply(_ image: CIImage, highlights: Double, shadows: Double) -> CIImage {
        guard highlights != 0 || shadows != 0 else { return image }
        guard !image.extent.isInfinite, image.extent.width > 0 else { return image }

        // Radius ~1% of the long edge: big enough to be "local tone", small
        // enough that CIGuidedFilter stays cheap. Clamped so tiny previews
        // and huge exports both behave.
        let longEdge = Double(max(image.extent.width, image.extent.height))
        let radius = min(60.0, max(8.0, longEdge * 0.01))

        guard let guided = CIFilter(name: "CIGuidedFilter") else { return image }
        let clamped = image.clampedToExtent()
        guided.setValue(clamped, forKey: kCIInputImageKey)
        guided.setValue(clamped, forKey: "inputGuideImage")
        guided.setValue(radius, forKey: "inputRadius")
        guided.setValue(0.01, forKey: "inputEpsilon")
        guard let base = guided.outputImage?.cropped(to: image.extent) else { return image }

        return kernel.apply(extent: image.extent,
                            arguments: [image, base,
                                        Float(highlights / 100), Float(shadows / 100)]) ?? image
    }
}
```

- [ ] **Step 5: Swap the PV2 stage.** `applyHighlightsAndShadows` (PV2 copy) becomes `LocalToneStage.apply(image, highlights: stack.highlights, shadows: stack.shadows)`.

- [ ] **Step 6: `xcodegen generate`, run CalibrationTests + full suite.** If the guided filter's export-size cost shows up later in `PerformanceTests`, the spec's fallback is to compute the base at a capped resolution and upsample with `CIEdgePreserveUpsampleFilter` — do NOT preemptively add that.

- [ ] **Step 7: Commit** — `feat(pv2): halo-free highlights/shadows via guided-filter base/detail split`

---

### Task 9: White balance — Bradford adaptation, mired-uniform

**Files:**
- Modify: `Sources/Pipeline/ColorScience.swift` (add matrix section)
- Create: `Sources/Pipeline/WhiteBalanceStage.swift`
- Modify: `Sources/Pipeline/EditRenderer.swift` (PV2 `applyWhiteBalance`)
- Test: `Tests/WhiteBalanceTests.swift`

**Interfaces:**
- Produces: `ColorScience.whiteBalanceMatrix(temperature: Double, tint: Double) -> [Double]` (9 values, row-major, linear-sRGB → linear-sRGB, adapting the given neutral to D65); `WhiteBalanceStage.apply(_ image: CIImage, temperature: Double, tint: Double) -> CIImage`. Task 11 reuses the same (temperature, tint) semantics for the RAW sensor-domain route.

- [ ] **Step 1: Failing tests** — `Tests/WhiteBalanceTests.swift`:

```swift
import CoreImage
import XCTest
@testable import PhotoEditor

final class WhiteBalanceTests: XCTestCase {
    private func greyAfterWB(temp: Double, tint: Double) -> (r: Double, g: Double, b: Double) {
        let renderer = EditRenderer()
        var stack = EditStack()
        stack.whiteBalanceTemp = temp
        stack.whiteBalanceTint = tint
        let out = renderer.render(source: Calibration.patch(0.5), stack: stack)
        let c = TestSupport.readColor(out)
        return (c.red, c.green, c.blue)
    }

    func testNeutralSettingIsExactIdentity() {
        let c = greyAfterWB(temp: 6500, tint: 0)
        XCTAssertEqual(c.r, 0.5, accuracy: 0.005)
        XCTAssertEqual(c.g, 0.5, accuracy: 0.005)
        XCTAssertEqual(c.b, 0.5, accuracy: 0.005)
    }

    func testDirectionMatchesLegacySemantics() {
        // Higher temperature warms (red up, blue down) — same convention as
        // PV1's "map the chosen neutral to D65".
        let warm = greyAfterWB(temp: 8000, tint: 0)
        XCTAssertGreaterThan(warm.r, warm.b + 0.02)
        let cool = greyAfterWB(temp: 4500, tint: 0)
        XCTAssertGreaterThan(cool.b, cool.r + 0.02)
        // Positive tint pushes magenta (green down relative to r/b mean).
        let magenta = greyAfterWB(temp: 6500, tint: 60)
        XCTAssertLessThan(magenta.g, (magenta.r + magenta.b) / 2 - 0.01)
    }

    /// The mired test: equal mired steps must produce equal chromatic effect.
    /// 4000→4444 K and 8000→10000 K are both 25 mired. In PV1 (uniform in
    /// Kelvin) the same slider distance was ~15× stronger at the cold end.
    func testEqualMiredStepsHaveEqualEffect() {
        func warmth(_ temp: Double) -> Double {
            let c = greyAfterWB(temp: temp, tint: 0)
            return c.r - c.b
        }
        let stepLow = warmth(4444) - warmth(4000)     // 25 mired at the cold end
        let stepHigh = warmth(10000) - warmth(8000)   // 25 mired at the warm end
        XCTAssertEqual(stepLow, stepHigh, accuracy: max(abs(stepLow), abs(stepHigh)) * 0.35 + 0.005,
                       "25 mired must cost the same at both ends: \(stepLow) vs \(stepHigh)")
    }

    func testMatrixMapsItsOwnNeutralToGrey() {
        // A grey patch cast with the chromaticity of 4500 K, corrected with
        // temp=4500, must come back near-neutral. This is the eyedropper
        // contract: sample a should-be-neutral color, set WB to it, get grey.
        let m = ColorScience.whiteBalanceMatrix(temperature: 4500, tint: 0)
        // Apply the matrix's inverse-direction check cheaply: correcting the
        // D65 grey by 4500K then by the inverse-of-4500K matrix round-trips.
        let mInv = ColorScience.whiteBalanceMatrix(temperature: 6500, tint: 0)
        XCTAssertEqual(mInv, [1, 0, 0, 0, 1, 0, 0, 0, 1].map(Double.init))
        let r = m[0] * 0.5 + m[1] * 0.5 + m[2] * 0.5
        let g = m[3] * 0.5 + m[4] * 0.5 + m[5] * 0.5
        let b = m[6] * 0.5 + m[7] * 0.5 + m[8] * 0.5
        // Correcting a 4500K-lit grey: matrix must boost blue relative to red.
        XCTAssertGreaterThan(r, b, "adapting FROM a warm neutral TO D65 raises red of a D65 grey")
        _ = g
    }
}
```

- [ ] **Step 2: Run to verify failure** (compile error: `whiteBalanceMatrix` undefined).

- [ ] **Step 3: Implement in `ColorScience.swift`** (new `// MARK: White balance matrix` section):

```swift
    // MARK: White balance matrix

    /// Linear-sRGB → linear-sRGB Bradford adaptation that maps the neutral
    /// described by (temperature, tint) to D65.
    ///
    /// Semantics match PV1's `CITemperatureAndTint` usage: the sliders name
    /// the image's *current* neutral, and the correction carries it to D65 —
    /// so raising temperature warms the image. Internally the locus is
    /// parameterized in **mired** (1e6/K), which is what makes equal slider
    /// travel produce equal perceptual change at both ends; the UI stays in
    /// Kelvin. Tint is a signed offset perpendicular-ish to the locus in
    /// CIE 1960 uv (positive = magenta), scaled so ±100 covers a strong but
    /// recoverable cast.
    ///
    /// - Returns: 9 row-major values; identity when the input is D65 exactly.
    static func whiteBalanceMatrix(temperature: Double, tint: Double) -> [Double] {
        if temperature == 6500 && tint == 0 {
            return [1, 0, 0, 0, 1, 0, 0, 0, 1]
        }

        // CCT → CIE xy on the Planckian/daylight locus (Kim et al. cubic
        // spline approximation), computed from mired for numeric symmetry.
        func locusXY(kelvin: Double) -> (x: Double, y: Double) {
            let t = min(max(kelvin, 1667), 25000)
            let invT = 1000.0 / t   // kiloKelvin⁻¹, i.e. mired / 1000
            let x: Double
            if t < 4000 {
                x = -0.2661239 * pow(invT, 3) - 0.2343589 * pow(invT, 2)
                    + 0.8776956 * invT + 0.179910
            } else {
                x = -3.0258469 * pow(invT, 3) + 2.1070379 * pow(invT, 2)
                    + 0.2226347 * invT + 0.240390
            }
            let y: Double
            if t < 2222 {
                y = -1.1063814 * pow(x, 3) - 1.34811020 * pow(x, 2)
                    + 2.18555832 * x - 0.20219683
            } else if t < 4000 {
                y = -0.9549476 * pow(x, 3) - 1.37418593 * pow(x, 2)
                    + 2.09137015 * x - 0.16748867
            } else {
                y = 3.0817580 * pow(x, 3) - 5.87338670 * pow(x, 2)
                    + 3.75112997 * x - 0.37001483
            }
            return (x, y)
        }

        // Apply tint as a v-offset in CIE 1960 uv (green up, magenta down).
        func whitePointXYZ(kelvin: Double, tint: Double) -> (X: Double, Y: Double, Z: Double) {
            let (x, y) = locusXY(kelvin: kelvin)
            let d = -2 * x + 12 * y + 3
            var u = 4 * x / d
            var v = 6 * y / d
            v -= tint * 3e-4
            u = max(u, 1e-4); v = max(v, 1e-4)
            let d2 = 2 * u - 8 * v + 4
            let nx = 3 * u / d2
            let ny = 2 * v / d2
            return (nx / ny, 1.0, (1 - nx - ny) / ny)
        }

        // Bradford cone-response matrix and its inverse.
        let bradford = [0.8951, 0.2664, -0.1614,
                        -0.7502, 1.7135, 0.0367,
                        0.0389, -0.0685, 1.0296]
        let bradfordInv = [0.9869929, -0.1470543, 0.1599627,
                           0.4323053, 0.5183603, 0.0492912,
                           -0.0085287, 0.0400428, 0.9684867]
        // sRGB (D65) ↔ XYZ.
        let srgbToXYZ = [0.4124564, 0.3575761, 0.1804375,
                         0.2126729, 0.7151522, 0.0721750,
                         0.0193339, 0.1191920, 0.9503041]
        let xyzToSRGB = [3.2404542, -1.5371385, -0.4985314,
                         -0.9692660, 1.8760108, 0.0415560,
                         0.0556434, -0.2040259, 1.0572252]

        func mul(_ a: [Double], _ b: [Double]) -> [Double] {
            var out = [Double](repeating: 0, count: 9)
            for r in 0..<3 { for c in 0..<3 {
                out[r * 3 + c] = a[r * 3] * b[c] + a[r * 3 + 1] * b[3 + c] + a[r * 3 + 2] * b[6 + c]
            } }
            return out
        }
        func apply(_ m: [Double], _ v: (Double, Double, Double)) -> (Double, Double, Double) {
            (m[0] * v.0 + m[1] * v.1 + m[2] * v.2,
             m[3] * v.0 + m[4] * v.1 + m[5] * v.2,
             m[6] * v.0 + m[7] * v.1 + m[8] * v.2)
        }

        let src = whitePointXYZ(kelvin: temperature, tint: tint)
        let d65 = (X: 0.95047, Y: 1.0, Z: 1.08883)
        let srcCone = apply(bradford, (src.X, src.Y, src.Z))
        let dstCone = apply(bradford, (d65.X, d65.Y, d65.Z))
        let scale = [dstCone.0 / srcCone.0, 0, 0,
                     0, dstCone.1 / srcCone.1, 0,
                     0, 0, dstCone.2 / srcCone.2]

        let adapt = mul(bradfordInv, mul(scale, bradford))
        return mul(xyzToSRGB, mul(adapt, srgbToXYZ))
    }
```

- [ ] **Step 4: Write `Sources/Pipeline/WhiteBalanceStage.swift`:**

```swift
import CoreImage
import CoreImage.CIFilterBuiltins

/// White balance for rendered (non-RAW) sources: a Bradford adaptation
/// matrix applied to linear working-space values via CIColorMatrix. RAW
/// sources never reach this stage — their WB happens in the sensor domain
/// (see RawSourcePreparation).
enum WhiteBalanceStage {
    static func apply(_ image: CIImage, temperature: Double, tint: Double) -> CIImage {
        guard temperature != 6500 || tint != 0 else { return image }
        let m = ColorScience.whiteBalanceMatrix(temperature: temperature, tint: tint)
        let filter = CIFilter.colorMatrix()
        filter.inputImage = image
        filter.rVector = CIVector(x: m[0], y: m[1], z: m[2], w: 0)
        filter.gVector = CIVector(x: m[3], y: m[4], z: m[5], w: 0)
        filter.bVector = CIVector(x: m[6], y: m[7], z: m[8], w: 0)
        filter.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        return filter.outputImage ?? image
    }
}
```

- [ ] **Step 5: Swap the PV2 stage** (`applyWhiteBalance` body → `WhiteBalanceStage.apply(image, temperature: stack.whiteBalanceTemp, tint: stack.whiteBalanceTint)`), run WhiteBalanceTests + full suite. The existing WB eyedropper (`ColorScience.temperatureAndTint(ofRed:green:blue:)`) keeps working unchanged — its estimates now drive a correction that actually neutralizes what it measured; if `ColorMixerTests` or `ColorSuiteTests` pinned old WB renders, re-pin those cases with `processVersion = 1`.

- [ ] **Step 6: Commit** — `feat(pv2): mired-uniform Bradford white balance`

---

### Task 10: Color.ci.metal — luminance-preserving vibrance and saturation

**Files:**
- Create: `Sources/Pipeline/Kernels/Color.ci.metal`
- Create: `Sources/Pipeline/ColorStages.swift`
- Modify: `Sources/Pipeline/EditRenderer.swift` (PV2 `applyColor`)
- Test: `Tests/CalibrationTests.swift`

**Interfaces:**
- Produces: kernel `pv2_vibrance_saturation(sample_t, float vibrance, float saturation)`; `ColorStages.vibranceAndSaturation(_ image: CIImage, vibrance: Double, saturation: Double) -> CIImage`.

- [ ] **Step 1: Failing tests:**

```swift
    private func rgbAfter(_ r: Double, _ g: Double, _ b: Double,
                          _ mutate: (inout EditStack) -> Void) -> (r: Double, g: Double, b: Double) {
        let renderer = EditRenderer()
        var stack = EditStack()
        mutate(&stack)
        let src = TestSupport.solidImage(red: r, green: g, blue: b, size: 16)
        let c = TestSupport.readColor(renderer.render(source: src, stack: stack))
        return (c.red, c.green, c.blue)
    }

    private func displayLuma(_ c: (r: Double, g: Double, b: Double)) -> Double {
        0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
    }

    func testSaturationPreservesDisplayLuminance() {
        // PV1 dropped a bright red's display luma from 0.43 to 0.21 at +50.
        for color in [(0.9, 0.3, 0.3), (0.2, 0.35, 0.7), (0.35, 0.1, 0.1)] {
            let before = displayLuma((color.0, color.1, color.2))
            let after = displayLuma(rgbAfter(color.0, color.1, color.2) { $0.saturation = 50 })
            XCTAssertEqual(after, before, accuracy: 0.015,
                           "saturation +50 moved display luma of \(color): \(before) → \(after)")
        }
    }

    func testSaturationRollsOffAtTheGamutEdgeInsteadOfClipping() {
        // PV1 sent (0.9, 0.3, 0.3) to (1.0, 0.0, 0.0) at +50 — two channels
        // slammed into the walls. The rolloff must keep all channels interior.
        let c = rgbAfter(0.9, 0.3, 0.3) { $0.saturation = 60 }
        XCTAssertGreaterThan(c.g, 0.02)
        XCTAssertGreaterThan(c.b, 0.02)
        XCTAssertLessThan(c.r, 0.999)
        XCTAssertGreaterThan(c.r - c.g, 0.6 - 0.0001, "it must still saturate meaningfully")
    }

    func testSaturationMinus100IsGreyscale() {
        let c = rgbAfter(0.7, 0.4, 0.2) { $0.saturation = -100 }
        XCTAssertEqual(c.r, c.g, accuracy: 0.01)
        XCTAssertEqual(c.g, c.b, accuracy: 0.01)
    }

    func testVibranceProtectsSkinAndFavorsMutedColors() {
        // Muted blue moves more than an equally-muted skin tone.
        let skinBefore = (r: 0.75, g: 0.62, b: 0.55)
        let blueBefore = (r: 0.55, g: 0.62, b: 0.75)
        func chroma(_ c: (r: Double, g: Double, b: Double)) -> Double {
            max(c.r, c.g, c.b) - min(c.r, c.g, c.b)
        }
        let skinAfter = rgbAfter(skinBefore.r, skinBefore.g, skinBefore.b) { $0.vibrance = 100 }
        let blueAfter = rgbAfter(blueBefore.r, blueBefore.g, blueBefore.b) { $0.vibrance = 100 }
        let skinGain = chroma(skinAfter) - chroma(skinBefore)
        let blueGain = chroma(blueAfter) - chroma(blueBefore)
        XCTAssertGreaterThan(blueGain, skinGain * 1.5 + 0.005,
                             "vibrance must move muted non-skin colors more than skin")
        // And an already-saturated color barely moves.
        let vivid = rgbAfter(0.95, 0.1, 0.1) { $0.vibrance = 100 }
        XCTAssertEqual(chroma(vivid), 0.85, accuracy: 0.08)
    }
```

- [ ] **Step 2: Run to verify failure.**

- [ ] **Step 3: Write `Color.ci.metal`:**

```metal
// Vibrance and saturation, display-referred and luminance-preserving.
// Chroma is scaled about the display-space luma axis, so luma is invariant
// BY CONSTRUCTION; an exponential rolloff toward the maximum feasible scale
// replaces PV1's channel clipping.
#include <metal_stdlib>
using namespace metal;
#include <CoreImage/CoreImage.h>

static float srgb_enc1(float c) {
    float a = fabs(c);
    float e = (a <= 0.0031308f) ? a * 12.92f : 1.055f * pow(a, 1.0f / 2.4f) - 0.055f;
    return copysign(e, c);
}
static float srgb_dec1(float c) {
    float a = fabs(c);
    float l = (a <= 0.04045f) ? a / 12.92f : pow((a + 0.055f) / 1.055f, 2.4f);
    return copysign(l, c);
}
static float3 srgb_encode(float3 c) { return float3(srgb_enc1(c.x), srgb_enc1(c.y), srgb_enc1(c.z)); }
static float3 srgb_decode(float3 c) { return float3(srgb_dec1(c.x), srgb_dec1(c.y), srgb_dec1(c.z)); }

// 0…1 weight for the skin hue band (~15°–50°), tapered at both edges.
static float skin_weight(float3 c) {
    float mx = max(c.x, max(c.y, c.z));
    float mn = min(c.x, min(c.y, c.z));
    float delta = mx - mn;
    if (delta < 1e-4f) return 0.0f;
    float h;
    if (mx == c.x)      h = (c.y - c.z) / delta;
    else if (mx == c.y) h = (c.z - c.x) / delta + 2.0f;
    else                h = (c.x - c.y) / delta + 4.0f;
    h *= 60.0f;
    if (h < 0.0f) h += 360.0f;
    return smoothstep(8.0f, 18.0f, h) * (1.0f - smoothstep(42.0f, 58.0f, h));
}

extern "C" float4 pv2_vibrance_saturation(coreimage::sample_t s,
                                          float vibrance, float saturation) {
    float3 d = clamp(srgb_encode(s.rgb), 0.0f, 1.0f);
    float L = dot(d, float3(0.2126f, 0.7152f, 0.0722f));
    float3 chroma = d - L;

    float satAmount = max(d.x, max(d.y, d.z)) - min(d.x, min(d.y, d.z));
    float f = 1.0f + saturation;                       // −1…1 → 0…2
    if (vibrance != 0.0f) {
        float muted = clamp(1.0f - satAmount * 1.6f, 0.0f, 1.0f);
        float skin = skin_weight(d);
        f *= 1.0f + vibrance * muted * (1.0f - 0.75f * skin);
    }
    f = max(f, 0.0f);

    if (f > 1.0f) {
        // Largest scale that keeps every channel inside [0, 1].
        float kmax = 1e6f;
        if (chroma.x > 1e-5f) kmax = min(kmax, (1.0f - L) / chroma.x);
        if (chroma.x < -1e-5f) kmax = min(kmax, -L / chroma.x);
        if (chroma.y > 1e-5f) kmax = min(kmax, (1.0f - L) / chroma.y);
        if (chroma.y < -1e-5f) kmax = min(kmax, -L / chroma.y);
        if (chroma.z > 1e-5f) kmax = min(kmax, (1.0f - L) / chroma.z);
        if (chroma.z < -1e-5f) kmax = min(kmax, -L / chroma.z);
        if (kmax < 1e6f) {
            float km = max(kmax, 1.0001f);
            // Asymptotic approach: f=1 → 1, f→∞ → km, monotonic, C1.
            f = 1.0f + (km - 1.0f) * (1.0f - exp(-(f - 1.0f) / (km - 1.0f)));
        }
    }

    float3 outc = L + chroma * f;
    return float4(srgb_decode(clamp(outc, 0.0f, 1.0f)), s.a);
}
```

- [ ] **Step 4: Write `Sources/Pipeline/ColorStages.swift` and swap:**

```swift
import CoreImage

enum ColorStages {
    private static let kernel = KernelLibrary.color("pv2_vibrance_saturation")

    static func vibranceAndSaturation(_ image: CIImage,
                                      vibrance: Double, saturation: Double) -> CIImage {
        guard vibrance != 0 || saturation != 0 else { return image }
        return kernel.apply(extent: image.extent,
                            arguments: [image, Float(vibrance / 100),
                                        Float(saturation / 100)]) ?? image
    }
}
```

PV2 `applyColor` body → `ColorStages.vibranceAndSaturation(image, vibrance: stack.vibrance, saturation: stack.saturation)`.

- [ ] **Step 5: `xcodegen generate`, run + full suite + commit** — `feat(pv2): luminance-preserving vibrance/saturation with gamut rolloff`

---

### Task 11: RAW — SourceImage and the sensor domain

**Files:**
- Create: `Sources/Pipeline/SourceImage.swift`
- Modify: `Sources/Pipeline/ImageDecoder.swift`
- Modify: `Sources/Pipeline/EditRenderer.swift` (dispatch + raw route)
- Modify: `Sources/Views/EditorModel.swift` (`loadSource` ~line 785, `activeRenderSource` ~797, `renderEditedImage` ~815)
- Modify: `Sources/Pipeline/ExportService.swift:164`
- Test: `Tests/RawSourceTests.swift`

**Interfaces:**
- Consumes: `EditStack.rawBoost`, `.rawWBInitialized` (Task 2); `WhiteBalanceStage` semantics (Task 9).
- Produces:

```swift
enum SourceImage {
    case raw(CIRAWFilter)
    case rendered(CIImage)
    var image: CIImage { get }          // decode at current filter state / the image
    var extent: CGRect { get }
}
// ImageDecoder:
static func loadSource(from url: URL, maxDimension: CGFloat?) -> SourceImage?
// EditRenderer:
func render(source: SourceImage, stack: EditStack, mlEnvironment: MLMaskEnvironment?) -> CIImage
// (the existing CIImage overload remains and wraps .rendered)
struct RawDevelopSettings: Equatable {          // pure, unit-testable mapping
    let temperature: Double, tint: Double, exposure: Double, boost: Double
    init(stack: EditStack)
    func configure(_ filter: CIRAWFilter)
}
```

- [ ] **Step 1: Failing tests** — `Tests/RawSourceTests.swift`:

```swift
import CoreImage
import XCTest
@testable import PhotoEditor

final class RawSourceTests: XCTestCase {
    func testRawDevelopSettingsMapsTheStack() {
        var stack = EditStack()
        stack.whiteBalanceTemp = 5200
        stack.whiteBalanceTint = 12
        stack.exposure = 0.7
        stack.rawBoost = 40
        let s = RawDevelopSettings(stack: stack)
        XCTAssertEqual(s.temperature, 5200)
        XCTAssertEqual(s.tint, 12)
        XCTAssertEqual(s.exposure, 0.7)
        XCTAssertEqual(s.boost, 0.4)
    }

    func testRenderedSourcesStillRouteThroughTheFullChain() {
        let renderer = EditRenderer()
        var stack = EditStack()
        stack.exposure = 1
        let src = SourceImage.rendered(Calibration.patch(0.25))
        let out = Calibration.displayValue(of: renderer.render(source: src, stack: stack,
                                                               mlEnvironment: nil), x: 2, y: 2)
        XCTAssertGreaterThan(out, 0.3)
    }

    func testNonRawFileLoadsAsRendered() throws {
        let url = try TestSupport.makeTempPNG()
        let source = try XCTUnwrap(ImageDecoder.loadSource(from: url, maxDimension: nil))
        if case .rendered = source {} else { XCTFail("PNG must load as .rendered") }
    }

    /// Integration against a real RAW, gated on a fixture the repo does not
    /// ship (drop any camera RAW at Tests/Fixtures/RAW/sample.dng or
    /// sample.arw to activate). Everything above runs without it.
    func testRawFixtureDecodesInSensorDomain() throws {
        guard let url = RawFixture.url() else {
            throw XCTSkip("no RAW fixture present — see Tests/Fixtures/RAW/README.md")
        }
        let source = try XCTUnwrap(ImageDecoder.loadSource(from: url, maxDimension: 1600))
        guard case .raw(let filter) = source else { return XCTFail("RAW must load as .raw") }
        XCTAssertFalse(filter.isGamutMappingEnabled)
        XCTAssertGreaterThan(filter.extendedDynamicRangeAmount, 0)
        // As-shot neutral is readable — the eyedropper/default-WB contract.
        XCTAssertGreaterThan(filter.neutralTemperature, 1000)
        // Preview decode is actually preview-sized.
        let img = source.image
        XCTAssertLessThanOrEqual(max(img.extent.width, img.extent.height), 1700)
    }
}

enum RawFixture {
    static func url() -> URL? {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("Fixtures/RAW")
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        return items.first { ImageDecoder.isRAW($0) }
    }
}
```

Also create `Tests/Fixtures/RAW/README.md`: "Drop any camera RAW file (DNG/ARW/CR3/NEF…) here to activate the gated RAW integration tests. Nothing in this directory is committed except this README." and add `Tests/Fixtures/RAW/*` (except the README) to `.gitignore`.

- [ ] **Step 2: Run to verify failure.**

- [ ] **Step 3: Implement `SourceImage.swift`:**

```swift
import CoreImage

/// Where the pixels came from — and therefore which domain edits can reach.
///
/// A `.raw` source keeps its `CIRAWFilter` alive so white balance, exposure,
/// and the baseline boost apply to *sensor data* before demosaic rendering,
/// the way a raw editor is supposed to work. A `.rendered` source (JPEG,
/// HEIC, TIFF, PNG) is already display-referred; its scene-domain edits run
/// on linearized pixels instead.
enum SourceImage {
    case raw(CIRAWFilter)
    case rendered(CIImage)

    /// The image at the filter's current settings (raw) or the image itself.
    var image: CIImage {
        switch self {
        case .raw(let filter): return filter.outputImage ?? CIImage.empty()
        case .rendered(let image): return image
        }
    }

    var extent: CGRect { image.extent }
}

/// The stack fields that live in the RAW sensor domain, as a pure value —
/// separable from CIRAWFilter so the mapping is unit-testable without a
/// camera file.
struct RawDevelopSettings: Equatable {
    let temperature: Double
    let tint: Double
    let exposure: Double
    let boost: Double

    init(stack: EditStack) {
        temperature = stack.whiteBalanceTemp
        tint = stack.whiteBalanceTint
        exposure = stack.exposure
        boost = stack.rawBoost / 100
    }

    func configure(_ filter: CIRAWFilter) {
        filter.neutralTemperature = Float(temperature)
        filter.neutralTint = Float(tint)
        filter.exposure = Float(exposure)
        filter.boostAmount = Float(boost)
    }
}
```

- [ ] **Step 4: Rework `ImageDecoder`:**

```swift
    /// Loads a file as a `SourceImage`. RAW files keep their `CIRAWFilter`
    /// (configured for PV2: gamut mapping off so out-of-gamut color survives,
    /// EDR headroom on so highlights above 1.0 survive, decoded at
    /// `maxDimension` via `scaleFactor` rather than decode-then-downsample).
    /// Everything else decodes through ImageIO as before.
    static func loadSource(from url: URL, maxDimension: CGFloat?) -> SourceImage? {
        if isRAW(url), let filter = CIRAWFilter(imageURL: url) {
            filter.isGamutMappingEnabled = false
            filter.extendedDynamicRangeAmount = 1.0
            if let maxDimension {
                let native = max(filter.nativeSize.width, filter.nativeSize.height)
                if native > maxDimension && native > 0 {
                    filter.scaleFactor = Float(maxDimension / native)
                }
            }
            return .raw(filter)
        }
        guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            return nil
        }
        if let maxDimension {
            return .rendered(downsampled(image, maxDimension: maxDimension))
        }
        return .rendered(image)
    }
```

Keep `loadFullImage`/`loadPreviewImage` as thin wrappers (`loadSource(...)?.image`) so thumbnails and other callers are untouched.

- [ ] **Step 5: Renderer routing.** In `EditRenderer`:

```swift
    func render(source: SourceImage, stack: EditStack,
                mlEnvironment: MLMaskEnvironment? = nil) -> CIImage {
        guard stack.processVersion >= 2 else {
            return legacy.render(source: source.image, stack: stack,
                                 mlEnvironment: mlEnvironment, context: context)
        }
        var image: CIImage
        var sensorDomainHandled = false
        switch source {
        case .raw(let filter) where !stack.filmNegative.isEnabled:
            // WB, exposure, and boost act on sensor data. A film-negative
            // scan that happens to be RAW opts out: inversion must precede
            // white balance, so it takes the rendered route below.
            RawDevelopSettings(stack: stack).configure(filter)
            image = filter.outputImage ?? CIImage.empty()
            sensorDomainHandled = true
        case .raw(let filter):
            image = filter.outputImage ?? CIImage.empty()
        case .rendered(let base):
            image = base
        }

        image = developedCache.developed(from: image, film: stack.filmNegative,
                                         geometry: stack.geometry, defringe: stack.defringe,
                                         retouch: stack.retouch, context: context)
        if !sensorDomainHandled {
            image = applyWhiteBalance(image, stack: stack)
            image = applyExposure(image, stack: stack)
        }
        // …rest of the PV2 chain exactly as before.
```

Keep the compatibility overload:

```swift
    func render(source: CIImage, stack: EditStack, mlEnvironment: MLMaskEnvironment? = nil) -> CIImage {
        render(source: .rendered(source), stack: stack, mlEnvironment: mlEnvironment)
    }
```

Check `stack.filmNegative.isEnabled` is the real property name (`grep -n "isEnabled\|enabled" Sources/Film/FilmNegativeSettings.swift`) and adjust.

Note: mutating the shared `CIRAWFilter` per render means a WB/exposure/boost drag re-runs the RAW develop (Core Image caches the demosaic internally; this is the interactive path CIRAWFilter is designed for). `DevelopedSourceCache` keys on the *output image's* object identity, which changes exactly when RAW params change — correct behavior, no change needed there.

- [ ] **Step 6: Integrate `EditorModel` and `ExportService`.**

In `EditorModel`: store `private var sourceImage: SourceImage?` alongside the existing `source: CIImage?`. `loadSource()` (line ~785) becomes:

```swift
    private func loadSource() {
        guard let loaded = ImageDecoder.loadSource(from: entry.fileURL, maxDimension: 1600) else {
            isMissingFile = true
            sourceImage = nil; source = nil; fullSource = nil
            return
        }
        sourceImage = loaded
        source = loaded.image
        fullSource = nil
        adoptAsShotWhiteBalanceIfNeeded(from: loaded)
    }

    /// First open of a RAW under PV2: the stack's WB defaults become the
    /// file's as-shot neutral instead of an assumed 6500 K.
    private func adoptAsShotWhiteBalanceIfNeeded(from loaded: SourceImage) {
        guard case .raw(let filter) = loaded,
              editStack.processVersion >= 2, !editStack.rawWBInitialized else { return }
        editStack.whiteBalanceTemp = Double(filter.neutralTemperature)
        editStack.whiteBalanceTint = Double(filter.neutralTint)
        editStack.rawWBInitialized = true
    }
```

`activeRenderSource()` (~797): the full-res branch becomes `fullSourceImage = ImageDecoder.loadSource(from: entry.fileURL, maxDimension: nil)` (store as `SourceImage?`, keep `fullSource = fullSourceImage?.image` for extent uses), and `renderEditedImage` passes the active `SourceImage` into `renderer.render(source:stack:mlEnvironment:)`. In `ExportService.swift:164`, `loadFullImage` → `loadSource(from: sourceURL, maxDimension: nil)` and pass it straight to the renderer.

- [ ] **Step 7: Run RawSourceTests + full suite** (the gated test skips without a fixture; everything else must pass). If you have any RAW file handy, drop it in `Tests/Fixtures/RAW/` and run once un-gated.

- [ ] **Step 8: Commit** — `feat(pv2): RAW edits in the sensor domain via SourceImage`

---

### Task 12: Effects — vignette with roundness, feather, highlight priority

**Files:**
- Create: `Sources/Pipeline/Kernels/Effects.ci.metal`
- Create: `Sources/Pipeline/EffectsStages.swift`
- Modify: `Sources/Pipeline/EditRenderer.swift` (PV2 `applyEffects`/`applyVignette`)
- Test: `Tests/EffectsCalibrationTests.swift`

**Interfaces:**
- Consumes: `EditStack.vignetteRoundness/.vignetteFeather/.vignetteHighlights` (Task 2).
- Produces: general kernel `pv2_vignette(sampler, float cx, float cy, float hw, float hh, float amount, float midpoint, float feather, float shapeN, float highlightPriority, destination)`; `EffectsStages.vignette(_ image: CIImage, stack: EditStack) -> CIImage`. Task 13 adds `pv2_grain` to the same file/enum.

- [ ] **Step 1: Failing tests** — `Tests/EffectsCalibrationTests.swift`:

```swift
import CoreGraphics
import XCTest
@testable import PhotoEditor

final class EffectsCalibrationTests: XCTestCase {
    private func rendered(_ mutate: (inout EditStack) -> Void,
                          patch: Double = 0.6, size: Int = 128) -> CIImage {
        let renderer = EditRenderer()
        var stack = EditStack()
        mutate(&stack)
        return renderer.render(source: Calibration.patch(patch, size: CGFloat(size)),
                               stack: stack)
    }

    func testVignetteDarkensCornersNotCenter() {
        let out = rendered { $0.vignetteAmount = -80 }
        let center = Calibration.displayValue(of: out, x: 64, y: 64)
        let corner = Calibration.displayValue(of: out, x: 4, y: 4)
        XCTAssertEqual(center, 0.6, accuracy: 0.03)
        XCTAssertLessThan(corner, center - 0.1)
    }

    func testMidpointMovesTheFalloffInward() {
        let far = rendered { $0.vignetteAmount = -80; $0.vignetteMidpoint = 80 }
        let near = rendered { $0.vignetteAmount = -80; $0.vignetteMidpoint = 10 }
        // With a low midpoint the darkening reaches a point midway out;
        // with a high midpoint that same point is untouched.
        let mid = (x: 96, y: 96)
        XCTAssertLessThan(Calibration.displayValue(of: near, x: mid.x, y: mid.y),
                          Calibration.displayValue(of: far, x: mid.x, y: mid.y) - 0.04)
    }

    func testFeatherWidensTheTransition() {
        let hard = rendered { $0.vignetteAmount = -100; $0.vignetteFeather = 5 }
        let soft = rendered { $0.vignetteAmount = -100; $0.vignetteFeather = 95 }
        func band(_ img: CIImage) -> Double {
            // Difference across a fixed radial span — smaller span delta = softer.
            abs(Calibration.displayValue(of: img, x: 24, y: 24)
                - Calibration.displayValue(of: img, x: 40, y: 40))
        }
        XCTAssertGreaterThan(band(hard), band(soft) + 0.02)
    }

    func testHighlightPriorityProtectsBrightCorners() {
        let plain = rendered({ $0.vignetteAmount = -90 }, patch: 0.92)
        let prioritized = rendered({ $0.vignetteAmount = -90; $0.vignetteHighlights = 100 },
                                   patch: 0.92)
        XCTAssertGreaterThan(Calibration.displayValue(of: prioritized, x: 4, y: 4),
                             Calibration.displayValue(of: plain, x: 4, y: 4) + 0.04)
    }

    func testVignetteMeasuresTheCroppedFrame() {
        // Crop to the right half; the vignette center must be the CROP's
        // center, so the crop's own left edge darkens like an edge, not like
        // the middle of the original frame.
        let renderer = EditRenderer()
        var stack = EditStack()
        stack.vignetteAmount = -90
        stack.geometry.cropRect = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        let out = renderer.render(source: Calibration.patch(0.6, size: 128), stack: stack)
        let w = Int(out.extent.width), h = Int(out.extent.height)
        let leftEdge = Calibration.displayValue(of: out, x: Int(out.extent.minX) + 2,
                                                y: Int(out.extent.minY) + h / 2)
        let center = Calibration.displayValue(of: out, x: Int(out.extent.minX) + w / 2,
                                              y: Int(out.extent.minY) + h / 2)
        XCTAssertLessThan(leftEdge, center - 0.05)
    }
}
```

Check `Geometry.cropRect`'s actual name/coordinate convention first (`grep -n "cropRect\|unitFrame" Sources/Models/Geometry.swift`) and adjust the crop line.

- [ ] **Step 2: Run to verify failure** (highlight-priority and feather tests fail against the legacy-copied `CIVignetteEffect` stage).

- [ ] **Step 3: Write `Effects.ci.metal`** (vignette part):

```metal
// PV2 effects. Vignette: a superellipse distance field over the cropped
// frame, gain applied in LINEAR light so a protected highlight keeps its
// energy. Grain (Task 13) lives here too.
#include <metal_stdlib>
using namespace metal;
#include <CoreImage/CoreImage.h>

static float srgb_enc1(float c) {
    float a = fabs(c);
    float e = (a <= 0.0031308f) ? a * 12.92f : 1.055f * pow(a, 1.0f / 2.4f) - 0.055f;
    return copysign(e, c);
}
static float srgb_dec1(float c) {
    float a = fabs(c);
    float l = (a <= 0.04045f) ? a / 12.92f : pow((a + 0.055f) / 1.055f, 2.4f);
    return copysign(l, c);
}
static float3 srgb_encode(float3 c) { return float3(srgb_enc1(c.x), srgb_enc1(c.y), srgb_enc1(c.z)); }
static float3 srgb_decode(float3 c) { return float3(srgb_dec1(c.x), srgb_dec1(c.y), srgb_dec1(c.z)); }

extern "C" float4 pv2_vignette(coreimage::sampler src,
                               float cx, float cy, float hw, float hh,
                               float amount, float midpoint, float feather,
                               float shapeN, float highlightPriority,
                               coreimage::destination dest) {
    float2 dc = dest.coord();
    float4 s = sample(src, src.transform(dc));

    float2 p = float2(fabs(dc.x - cx) / max(hw, 1.0f),
                      fabs(dc.y - cy) / max(hh, 1.0f));       // 1.0 at frame edges
    float d = pow(pow(p.x, shapeN) + pow(p.y, shapeN), 1.0f / shapeN);

    float inner = midpoint * 1.3f;                            // 0…1 slider → start radius
    float width = max(0.05f, feather * 1.2f);
    float fall = smoothstep(inner, inner + width, d);

    float g = max(1.0f + amount * fall, 0.0f);                // amount −1…1, linear gain
    if (amount < 0.0f && highlightPriority > 0.0f) {
        // Linear-light luma; >0.5 linear is already a bright highlight.
        float L = dot(max(s.rgb, 0.0f), float3(0.2126f, 0.7152f, 0.0722f));
        float protect = highlightPriority * smoothstep(0.35f, 1.0f, L);
        g = mix(g, 1.0f, protect);
    }
    return float4(s.rgb * g, s.a);
}
```

- [ ] **Step 4: Write `Sources/Pipeline/EffectsStages.swift`** (vignette part):

```swift
import CoreImage

enum EffectsStages {
    private static let vignetteKernel = KernelLibrary.general("pv2_vignette")

    static func vignette(_ image: CIImage, stack: EditStack) -> CIImage {
        guard stack.vignetteAmount != 0 else { return image }
        let extent = image.extent
        guard !extent.isInfinite, extent.width > 0 else { return image }

        var hw = extent.width / 2
        var hh = extent.height / 2
        // Positive roundness pulls the field toward a circle by equalizing
        // the two radii; negative squares the superellipse exponent instead.
        let roundness = stack.vignetteRoundness / 100
        if roundness > 0 {
            let m = min(hw, hh)
            hw += (m - hw) * roundness
            hh += (m - hh) * roundness
        }
        let shapeN = roundness < 0 ? 2 + 4 * (-roundness) : 2.0

        return vignetteKernel.apply(
            extent: extent,
            roiCallback: { _, rect in rect },
            arguments: [image,
                        Float(extent.midX), Float(extent.midY),
                        Float(hw), Float(hh),
                        Float(stack.vignetteAmount / 100),
                        Float(stack.vignetteMidpoint / 100),
                        Float(stack.vignetteFeather / 100),
                        Float(shapeN),
                        Float(stack.vignetteHighlights / 100)]) ?? image
    }
}
```

- [ ] **Step 5: Swap the PV2 stage.** PV2 `applyEffects` calls `EffectsStages.vignette(result, stack: stack)` instead of `applyVignette`; delete the PV2 copies of `applyVignette` (grain swaps in Task 13; keep the old grain call until then). Update the effects change-summary/reset sites so the new sliders participate: `Sources/Views/SliderPanel/SliderPanel.swift:319-327` (isEdited + reset must include roundness/feather/highlights) and the stage-summary block at `Sources/Views/EditorModel.swift` (~line 774, the `vignetteAmount` comparison group).

- [ ] **Step 6: `xcodegen generate`, run + full suite + commit** — `feat(pv2): superellipse vignette with roundness, feather, highlight priority`

---

### Task 13: Effects — deterministic, frame-relative grain

**Files:**
- Modify: `Sources/Pipeline/Kernels/Effects.ci.metal`, `Sources/Pipeline/EffectsStages.swift`
- Modify: `Sources/Pipeline/EditRenderer.swift` (PV2 grain call)
- Test: `Tests/EffectsCalibrationTests.swift`

**Interfaces:**
- Produces: general kernel `pv2_grain(sampler, float cellSize, float amount, float originX, float originY, destination)`; `EffectsStages.grain(_ image: CIImage, amount: Double, size: Double) -> CIImage`.

- [ ] **Step 1: Failing tests:**

```swift
    func testGrainIsDeterministic() {
        let a = rendered { $0.grainAmount = 60 }
        let b = rendered { $0.grainAmount = 60 }
        for point in [(10, 10), (50, 80), (100, 30)] {
            XCTAssertEqual(Calibration.displayValue(of: a, x: point.0, y: point.1),
                           Calibration.displayValue(of: b, x: point.0, y: point.1),
                           accuracy: 0.004, "grain must be identical across renders")
        }
    }

    func testGrainActuallyAppears() {
        let out = rendered { $0.grainAmount = 80 }
        var values: Set<Int> = []
        for x in stride(from: 4, to: 124, by: 4) {
            values.insert(Int(Calibration.displayValue(of: out, x: x, y: 64) * 255))
        }
        XCTAssertGreaterThan(values.count, 4, "an 80-strength grain must vary the patch")
    }

    /// The preview/export contract: the same photo rendered at two sizes
    /// carries the SAME grain field. Rendering the noise in normalized frame
    /// coordinates makes the 256px render a downsample of the 512px one.
    func testGrainIsResolutionIndependent() {
        let renderer = EditRenderer()
        var stack = EditStack()
        stack.grainAmount = 70
        stack.grainSize = 50
        let small = renderer.render(source: Calibration.patch(0.5, size: 256), stack: stack)
        // Downsample the large render to the small one's size before
        // comparing — point-sampling both would compare misaligned pixel
        // centers of a continuous noise field and flake.
        let large = renderer.render(source: Calibration.patch(0.5, size: 512), stack: stack)
            .transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5))
        var matched = 0, total = 0
        for y in stride(from: 8, to: 248, by: 12) {
            for x in stride(from: 8, to: 248, by: 12) {
                let s = Calibration.displayValue(of: small, x: x, y: y)
                let l = Calibration.displayValue(of: large, x: x, y: y)
                total += 1
                if abs(s - l) < 0.05 { matched += 1 }
            }
        }
        XCTAssertGreaterThan(Double(matched) / Double(total), 0.7,
                             "grain field must match across render sizes (\(matched)/\(total))")
    }

    func testGrainZeroIsIdentity() {
        let out = rendered { $0.grainAmount = 0 }
        XCTAssertEqual(Calibration.displayValue(of: out, x: 64, y: 64), 0.6, accuracy: 0.01)
    }
```

- [ ] **Step 2: Run to verify failure** (`testGrainIsResolutionIndependent` fails against legacy-copied `CIRandomGenerator` grain — its noise is per-output-pixel).

- [ ] **Step 3: Add to `Effects.ci.metal`:**

```metal
// Deterministic value noise. Seedless by design: the same develop settings
// must produce the same grain on every render, preview or export — the
// lattice is anchored to the frame (normalized coordinates), not the pixel
// grid, so resolution only changes how densely the same field is sampled.
static float hash21(float2 p) {
    p = fract(p * float2(123.34f, 456.21f));
    p += dot(p, p + 45.32f);
    return fract(p.x * p.y);
}
static float value_noise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0f - 2.0f * f);
    float a = hash21(i);
    float b = hash21(i + float2(1.0f, 0.0f));
    float c = hash21(i + float2(0.0f, 1.0f));
    float d = hash21(i + float2(1.0f, 1.0f));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

extern "C" float4 pv2_grain(coreimage::sampler src,
                            float cellSize, float amount,
                            float originX, float originY,
                            coreimage::destination dest) {
    float2 dc = dest.coord();
    float4 s = sample(src, src.transform(dc));

    float2 cell = (dc - float2(originX, originY)) / max(cellSize, 0.5f);
    float g = value_noise(cell) - 0.5f;                      // −0.5…0.5

    float3 d = srgb_encode(clamp(s.rgb, 0.0f, 1.0f));
    float L = dot(d, float3(0.2126f, 0.7152f, 0.0722f));
    float w = 4.0f * L * (1.0f - L);                         // midtone-weighted, like emulsion
    d = clamp(d + g * amount * 0.35f * w, 0.0f, 1.0f);
    return float4(srgb_decode(d), s.a);
}
```

- [ ] **Step 4: Stage + swap.** In `EffectsStages`:

```swift
    private static let grainKernel = KernelLibrary.general("pv2_grain")

    static func grain(_ image: CIImage, amount: Double, size: Double) -> CIImage {
        guard amount > 0 else { return image }
        let extent = image.extent
        guard !extent.isInfinite, extent.width > 0 else { return image }
        // Cell size as a fraction of the frame's long edge: size 0 → fine
        // (~1/1000th of the frame), 100 → coarse (~1/125th).
        let longEdge = Double(max(extent.width, extent.height))
        let cell = longEdge * (0.001 + size / 100 * 0.007)
        return grainKernel.apply(
            extent: extent,
            roiCallback: { _, rect in rect },
            arguments: [image, Float(cell), Float(amount / 100),
                        Float(extent.minX), Float(extent.minY)]) ?? image
    }
```

PV2 `applyEffects` grain branch → `EffectsStages.grain(result, amount: stack.grainAmount, size: stack.grainSize)`; delete the PV2 copy of `applyGrain`.

- [ ] **Step 5: Run + full suite + commit** — `feat(pv2): deterministic frame-relative grain`

---

### Task 14: Parity harness against Lightroom CC

**Files:**
- Create: `Tests/ParitySupport.swift` (Lab + ΔE2000 + fixture loading)
- Create: `Tests/ParityTests.swift`
- Create: `scripts/make-parity-presets.swift`
- Create: `docs/PARITY.md`
- Create: `Tests/Fixtures/Parity/README.md`

**Interfaces:**
- Consumes: the full PV2 chain.
- Produces: `DeltaE.ciede2000(lab1: (Double, Double, Double), lab2: (Double, Double, Double)) -> Double`, `ParitySupport.labPixels(of: CIImage, side: Int) -> [(Double, Double, Double)]`, `ParityCase` manifest type. Nothing downstream consumes these — this is the measuring instrument.

- [ ] **Step 1: Write `Tests/ParitySupport.swift`:**

```swift
import CoreGraphics
import CoreImage
import Foundation
import XCTest
@testable import PhotoEditor

/// CIELAB conversion and CIEDE2000, for measuring renders against
/// Lightroom's. Formulae follow Sharma, Wu & Dalal (2005).
enum DeltaE {
    static func srgbToLab(r: Double, g: Double, b: Double) -> (L: Double, a: Double, b: Double) {
        func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let rl = lin(r), gl = lin(g), bl = lin(b)
        let x = (0.4124564 * rl + 0.3575761 * gl + 0.1804375 * bl) / 0.95047
        let y = 0.2126729 * rl + 0.7151522 * gl + 0.0721750 * bl
        let z = (0.0193339 * rl + 0.1191920 * gl + 0.9503041 * bl) / 1.08883
        func f(_ t: Double) -> Double { t > 0.008856 ? pow(t, 1.0 / 3.0) : 7.787 * t + 16.0 / 116.0 }
        return (116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
    }

    static func ciede2000(_ p: (L: Double, a: Double, b: Double),
                          _ q: (L: Double, a: Double, b: Double)) -> Double {
        let c1 = sqrt(p.a * p.a + p.b * p.b), c2 = sqrt(q.a * q.a + q.b * q.b)
        let cBar = (c1 + c2) / 2
        let g = 0.5 * (1 - sqrt(pow(cBar, 7) / (pow(cBar, 7) + pow(25.0, 7))))
        let a1p = p.a * (1 + g), a2p = q.a * (1 + g)
        let c1p = sqrt(a1p * a1p + p.b * p.b), c2p = sqrt(a2p * a2p + q.b * q.b)
        func hp(_ a: Double, _ b: Double) -> Double {
            if a == 0 && b == 0 { return 0 }
            var h = atan2(b, a) * 180 / .pi
            if h < 0 { h += 360 }
            return h
        }
        let h1p = hp(a1p, p.b), h2p = hp(a2p, q.b)
        let dLp = q.L - p.L
        let dCp = c2p - c1p
        var dhp: Double
        if c1p * c2p == 0 { dhp = 0 }
        else if abs(h2p - h1p) <= 180 { dhp = h2p - h1p }
        else if h2p - h1p > 180 { dhp = h2p - h1p - 360 }
        else { dhp = h2p - h1p + 360 }
        let dHp = 2 * sqrt(c1p * c2p) * sin(dhp / 2 * .pi / 180)
        let lBar = (p.L + q.L) / 2, cBarP = (c1p + c2p) / 2
        var hBar: Double
        if c1p * c2p == 0 { hBar = h1p + h2p }
        else if abs(h1p - h2p) <= 180 { hBar = (h1p + h2p) / 2 }
        else if h1p + h2p < 360 { hBar = (h1p + h2p + 360) / 2 }
        else { hBar = (h1p + h2p - 360) / 2 }
        let t = 1 - 0.17 * cos((hBar - 30) * .pi / 180) + 0.24 * cos(2 * hBar * .pi / 180)
            + 0.32 * cos((3 * hBar + 6) * .pi / 180) - 0.20 * cos((4 * hBar - 63) * .pi / 180)
        let dTheta = 30 * exp(-pow((hBar - 275) / 25, 2))
        let rc = 2 * sqrt(pow(cBarP, 7) / (pow(cBarP, 7) + pow(25.0, 7)))
        let sl = 1 + 0.015 * pow(lBar - 50, 2) / sqrt(20 + pow(lBar - 50, 2))
        let sc = 1 + 0.045 * cBarP
        let sh = 1 + 0.015 * cBarP * t
        let rt = -sin(2 * dTheta * .pi / 180) * rc
        return sqrt(pow(dLp / sl, 2) + pow(dCp / sc, 2) + pow(dHp / sh, 2)
                    + rt * (dCp / sc) * (dHp / sh))
    }
}

enum ParitySupport {
    static let fixturesDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("Fixtures/Parity")

    /// Renders an image to `side`×`side` sRGB and returns Lab per pixel.
    static func labPixels(of image: CIImage, side: Int = 128) -> [(Double, Double, Double)] {
        let ctx = Calibration.context
        let scale = CGFloat(side) / max(image.extent.width, image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let w = Int(scaled.extent.width.rounded()), h = Int(scaled.extent.height.rounded())
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        ctx.render(scaled, toBitmap: &bytes, rowBytes: w * 4,
                   bounds: CGRect(x: scaled.extent.minX, y: scaled.extent.minY,
                                  width: CGFloat(w), height: CGFloat(h)),
                   format: .RGBA8, colorSpace: Calibration.srgb)
        var out: [(Double, Double, Double)] = []
        out.reserveCapacity(w * h)
        for i in stride(from: 0, to: bytes.count, by: 4) {
            out.append(DeltaE.srgbToLab(r: Double(bytes[i]) / 255,
                                        g: Double(bytes[i + 1]) / 255,
                                        b: Double(bytes[i + 2]) / 255))
        }
        return out
    }
}

/// One measured comparison: a control at a value, our render of the neutral
/// export vs Lightroom's own export of the same recipe.
struct ParityCase: Decodable {
    let fixture: String              // e.g. "contrast_p50.tif"
    let field: String                // EditStack field name
    let value: Double
    let meanTolerance: Double?       // nil = report-only (no strict mapping)
    let maxTolerance: Double?

    func apply(to stack: inout EditStack) {
        switch field {
        case "contrast": stack.contrast = value
        case "exposure": stack.exposure = value
        case "highlights": stack.highlights = value
        case "shadows": stack.shadows = value
        case "whites": stack.whites = value
        case "blacks": stack.blacks = value
        case "vibrance": stack.vibrance = value
        case "saturation": stack.saturation = value
        case "whiteBalanceTemp": stack.whiteBalanceTemp = value
        case "whiteBalanceTint": stack.whiteBalanceTint = value
        default: XCTFail("unknown parity field \(field)")
        }
    }
}
```

- [ ] **Step 2: Write `scripts/make-parity-presets.swift`** (run with `swift scripts/make-parity-presets.swift`):

```swift
#!/usr/bin/env swift
// Emits the Lightroom XMP preset set + manifest for the parity harness.
// Output: scripts/parity-presets/*.xmp and Tests/Fixtures/Parity/manifest.json
import Foundation

struct Preset {
    let name: String          // also the fixture filename stem
    let crsKey: String
    let crsValue: String
    let field: String         // EditStack field
    let value: Double
    let meanTol: Double?      // nil = report-only
    let maxTol: Double?
}

// Sliders whose −100…100 semantics map 1:1 map with strict tolerances;
// WB on a rendered file uses Lightroom's incremental units, which have no
// exact mapping to Kelvin — those are report-only.
let presets: [Preset] = [
    .init(name: "exposure_p1", crsKey: "crs:Exposure2012", crsValue: "+1.00", field: "exposure", value: 1, meanTol: 6, maxTol: 14),
    .init(name: "exposure_m1", crsKey: "crs:Exposure2012", crsValue: "-1.00", field: "exposure", value: -1, meanTol: 6, maxTol: 14),
    .init(name: "contrast_p50", crsKey: "crs:Contrast2012", crsValue: "+50", field: "contrast", value: 50, meanTol: 6, maxTol: 14),
    .init(name: "contrast_m50", crsKey: "crs:Contrast2012", crsValue: "-50", field: "contrast", value: -50, meanTol: 6, maxTol: 14),
    .init(name: "contrast_p100", crsKey: "crs:Contrast2012", crsValue: "+100", field: "contrast", value: 100, meanTol: 8, maxTol: 18),
    .init(name: "highlights_m100", crsKey: "crs:Highlights2012", crsValue: "-100", field: "highlights", value: -100, meanTol: 8, maxTol: 18),
    .init(name: "highlights_p100", crsKey: "crs:Highlights2012", crsValue: "+100", field: "highlights", value: 100, meanTol: 8, maxTol: 18),
    .init(name: "shadows_p100", crsKey: "crs:Shadows2012", crsValue: "+100", field: "shadows", value: 100, meanTol: 8, maxTol: 18),
    .init(name: "shadows_m100", crsKey: "crs:Shadows2012", crsValue: "-100", field: "shadows", value: -100, meanTol: 8, maxTol: 18),
    .init(name: "whites_p100", crsKey: "crs:Whites2012", crsValue: "+100", field: "whites", value: 100, meanTol: 8, maxTol: 18),
    .init(name: "blacks_m100", crsKey: "crs:Blacks2012", crsValue: "-100", field: "blacks", value: -100, meanTol: 8, maxTol: 18),
    .init(name: "vibrance_p60", crsKey: "crs:Vibrance", crsValue: "+60", field: "vibrance", value: 60, meanTol: 7, maxTol: 16),
    .init(name: "saturation_p50", crsKey: "crs:Saturation", crsValue: "+50", field: "saturation", value: 50, meanTol: 7, maxTol: 16),
    .init(name: "saturation_m50", crsKey: "crs:Saturation", crsValue: "-50", field: "saturation", value: -50, meanTol: 7, maxTol: 16),
    .init(name: "temp_p40", crsKey: "crs:IncrementalTemperature", crsValue: "+40", field: "whiteBalanceTemp", value: 8000, meanTol: nil, maxTol: nil),
    .init(name: "temp_m40", crsKey: "crs:IncrementalTemperature", crsValue: "-40", field: "whiteBalanceTemp", value: 5000, meanTol: nil, maxTol: nil),
    .init(name: "tint_p50", crsKey: "crs:IncrementalTint", crsValue: "+50", field: "whiteBalanceTint", value: 50, meanTol: nil, maxTol: nil),
]

func xmp(_ p: Preset) -> String {
    """
    <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="PV2 parity generator">
     <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
      <rdf:Description rdf:about=""
        xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
        crs:PresetType="Normal"
        crs:Cluster="PV2 Parity"
        crs:UUID="\(UUID().uuidString)"
        crs:SupportsAmount="False"
        crs:SupportsColor="True"
        crs:SupportsMonochrome="True"
        crs:ProcessVersion="15.4"
        \(p.crsKey)="\(p.crsValue)"
        crs:HasSettings="True">
       <crs:Name><rdf:Alt><rdf:li xml:lang="x-default">PV2 \(p.name)</rdf:li></rdf:Alt></crs:Name>
       <crs:Group><rdf:Alt><rdf:li xml:lang="x-default">PV2 Parity</rdf:li></rdf:Alt></crs:Group>
      </rdf:Description>
     </rdf:RDF>
    </x:xmpmeta>
    """
}

let fm = FileManager.default
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let outDir = root.appendingPathComponent("parity-presets")
try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)
for p in presets {
    try! xmp(p).write(to: outDir.appendingPathComponent("PV2_\(p.name).xmp"),
                      atomically: true, encoding: .utf8)
}
struct ManifestEntry: Encodable {
    let fixture: String, field: String, value: Double
    let meanTolerance: Double?, maxTolerance: Double?
}
let manifest = presets.map {
    ManifestEntry(fixture: "\($0.name).tif", field: $0.field, value: $0.value,
                  meanTolerance: $0.meanTol, maxTolerance: $0.maxTol)
}
let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
let manifestDir = root.deletingLastPathComponent()
    .appendingPathComponent("Tests/Fixtures/Parity")
try? fm.createDirectory(at: manifestDir, withIntermediateDirectories: true)
try! enc.encode(manifest).write(to: manifestDir.appendingPathComponent("manifest.json"))
print("Wrote \(presets.count) presets to \(outDir.path) and manifest.json")
```

- [ ] **Step 3: Write `Tests/ParityTests.swift`:**

```swift
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
```

- [ ] **Step 4: Write `docs/PARITY.md`** — the one-time manual procedure:

```markdown
# Measuring PV2 against Lightroom CC

One-time setup per reference photo (15 minutes):

1. `swift scripts/make-parity-presets.swift` — writes `scripts/parity-presets/`
   (17 XMP presets) and `Tests/Fixtures/Parity/manifest.json`.
2. In Lightroom CC: add a reference photo (any well-exposed photo with real
   shadows, midtones, highlights, and some saturated color).
3. Presets panel → ⋯ → Import Presets → select the `scripts/parity-presets`
   folder. They arrive under the "PV2 Parity" group.
4. Export the photo untouched as 16-bit TIFF, sRGB, 1024 px long edge →
   `Tests/Fixtures/Parity/neutral.tif`. **Every slider at zero.**
5. For each preset: apply it (one preset at a time, on top of the untouched
   photo — easiest with a virtual copy per preset), export with the same
   settings, named after the preset: `contrast_p50.tif`, `exposure_p1.tif`, …
   (the manifest lists the exact names).
6. Run the suite. `ParityTests` un-gates automatically and prints a ΔE2000
   report per control; WB cases are report-only (Lightroom's incremental WB
   units have no exact Kelvin mapping).

Fixtures are personal photos and stay untracked (`Tests/Fixtures/Parity/*`
is gitignored except the manifest and README).
```

Create `Tests/Fixtures/Parity/README.md` pointing at `docs/PARITY.md`, and gitignore `Tests/Fixtures/Parity/*.tif`.

- [ ] **Step 5: Run** — `swift scripts/make-parity-presets.swift` must emit 17 presets + manifest; the test suite must pass with `ParityTests` skipping. Verify one emitted XMP imports into Lightroom CC if the user is available; otherwise flag it in the handoff notes.

- [ ] **Step 6: Commit** — `feat(pv2): Lightroom parity harness (ΔE2000, gated on exported fixtures)`

---

### Task 15: UI — process badge, upgrade action, new sliders; changelog

**Files:**
- Modify: `Sources/Views/SliderPanel/SliderPanel.swift` (~line 203 effects rows; panel top)
- Modify: `Sources/Views/EditorModel.swift` (upgrade action; ~line 774 stage summary)
- Modify: `CHANGELOG.md`
- Test: `Tests/ProcessVersionTests.swift`

**Interfaces:**
- Consumes: everything above.
- Produces: `EditorModel.upgradeToProcessVersion2()`.

- [ ] **Step 1: Failing test:**

```swift
    func testUpgradeToProcessVersion2SnapshotsFirst() throws {
        // Build an EditorModel the way EditorModelTests does — reuse its
        // fixture helper (see Tests/EditorModelTests.swift for the exact
        // setup; it creates a temp catalog + entry).
        let model = try TestSupport.makeEditorModel()   // add this helper if absent, mirroring EditorModelTests' setup
        model.editStack.processVersion = 1
        model.editStack.contrast = 30
        let snapshotsBefore = model.snapshots.count
        model.upgradeToProcessVersion2()
        XCTAssertEqual(model.editStack.processVersion, 2)
        XCTAssertEqual(model.editStack.contrast, 30, "slider values are kept — only the engine changes")
        XCTAssertEqual(model.snapshots.count, snapshotsBefore + 1, "must snapshot before upgrading")
        // Idempotent.
        model.upgradeToProcessVersion2()
        XCTAssertEqual(model.snapshots.count, snapshotsBefore + 1)
    }
```

Before writing it, read `Tests/EditorModelTests.swift` for the established way to construct an `EditorModel` with a temp catalog, and check the actual name of the published snapshots property (`grep -n "snapshots" Sources/Views/EditorModel.swift`). Mirror that; if no shared helper exists, extract one into `TestSupport`.

- [ ] **Step 2: Run to verify failure.**

- [ ] **Step 3: Implement `upgradeToProcessVersion2` in `EditorModel`** (near `applySnapshot`, ~line 525):

```swift
    /// Re-interprets this photo's slider values through the PV2 engine.
    /// Appearance will change — that is the point — so the PV1 look is
    /// snapshotted first and one click away forever.
    func upgradeToProcessVersion2() {
        guard editStack.processVersion < 2 else { return }
        _ = saveSnapshot(named: "Before Process Version 2")
        editStack.processVersion = 2
    }
```

Verify that assigning `editStack` triggers re-render + persist the same way slider bindings do (check how `editStack` is observed — `grep -n "editStack" Sources/Views/EditorModel.swift | head -20`); if mutation alone doesn't schedule a render, do what `applySnapshot` does after assignment.

- [ ] **Step 4: Add the badge + new sliders in `SliderPanel.swift`.** At the top of the panel content (above the first `PanelGroupHeading`):

```swift
                if model.editStack.processVersion < 2 {
                    PanelSection("Process") {
                        HStack {
                            Text("This photo uses the original develop engine.")
                                .foregroundStyle(Theme.secondaryText)
                            Spacer()
                            Button("Update to Version 2") {
                                model.upgradeToProcessVersion2()
                            }
                        }
                    }
                }
```

(Match the panel's actual container/typography idiom — read the surrounding 30 lines and use the same components; `Theme.secondaryText` is a guess to be corrected against `Sources/Views/Theme.swift`.)

After the `Grain Size` row (~line 212):

```swift
                    AdjustmentSlider(title: "Vignette Roundness",
                                     value: $model.editStack.vignetteRoundness,
                                     range: -100...100, format: "%.0f", neutral: 0)
                    AdjustmentSlider(title: "Vignette Feather",
                                     value: $model.editStack.vignetteFeather,
                                     range: 0...100, format: "%.0f", neutral: 50)
                    AdjustmentSlider(title: "Vignette Highlights",
                                     value: $model.editStack.vignetteHighlights,
                                     range: 0...100, format: "%.0f", neutral: 0)
```

Confirm Task 12's isEdited/reset updates (SliderPanel ~319–327) include the three new fields; add the RAW boost slider in the Light section, gated on the source being RAW:

```swift
                    if ImageDecoder.isRAW(model.entry.fileURL) {
                        AdjustmentSlider(title: "Raw Boost",
                                         value: $model.editStack.rawBoost,
                                         range: 0...100, format: "%.0f", neutral: 100)
                    }
```

(`model.entry` visibility: if `entry` is private, add a small `var isRAWSource: Bool` on `EditorModel`.)

- [ ] **Step 5: Build and launch the app** (`xcodebuild -project PhotoEditor.xcodeproj -scheme PhotoEditor -destination 'platform=macOS' build`, then open the product): import a JPEG, verify sliders behave (contrast around middle grey, whites can clip, vignette sub-controls respond), verify a photo edited pre-upgrade shows the Process badge and the update button works. Screenshot for the record.

- [ ] **Step 6: Update `CHANGELOG.md`** — new `## 2.2.0` section summarizing: PV2 engine (what was broken, measured; what changed), process versioning ("existing edits keep their appearance; update per photo from the develop panel"), RAW sensor-domain editing + as-shot WB + Raw Boost, vignette sub-controls, deterministic grain, parity harness. Follow the existing changelog's voice (plain, factual, no marketing).

- [ ] **Step 7: Run the FULL suite one final time; commit** — `feat(pv2): process badge, upgrade action, vignette/raw controls; 2.2.0 changelog`

---

## Post-plan notes for the executor

- **Out of scope, deliberately** (user decision, recorded in the spec): clarity/texture/dehaze/sharpening/NR are untouched and still have PV1 behavior in BOTH process versions (they were never version-split). Do not "fix" them in passing.
- **Performance**: `PerformanceTests.swift` exists; if PV2 regresses it, the two knobs are the guided-filter capped-resolution fallback (Task 8 note) and kernel pass fusion (Core Image fuses adjacent color kernels automatically — verify with `CI_PRINT_TREE=1` before optimizing anything).
- **Parity fixtures** need the user (Lightroom clicks). Everything else is autonomous. When fixtures land, expect initial ΔE misses; tune the pinned kernel constants (contrast slope, whites/blacks authority 0.30, local-tone authority 0.45) alongside their calibration tests, one constant per commit.



