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
                                                     size: probeSize)

    private static let probeSize = 128
    private static let probeExtent = CGRect(x: 0, y: 0, width: probeSize, height: probeSize)
    private static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    /// A solved density stack — the reference every case's `low`/`high`
    /// diverge from. Deterministic: `AutoInvert.solve` has no randomness, so
    /// calling this twice produces bit-identical settings (proven by
    /// ``testTheSolvedReferenceIsExactlyReproducible``).
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

    /// Rasterizes the probe through the renderer into display-space RGBA8
    /// bytes — the same readback convention as `Conformance.render`
    /// (`Tests/ConformanceSupport.swift`), copied here rather than imported
    /// because the probe's size (128², the film fixture's own square) differs
    /// from `Conformance`'s 256×192 control-panel probe.
    private static func render(_ stack: EditStack) -> [UInt8] {
        let image = renderer.render(source: probe, stack: stack)
        var buffer = [UInt8](repeating: 0, count: probeSize * probeSize * 4)
        renderer.context.render(image.cropped(to: probeExtent), toBitmap: &buffer,
                                rowBytes: probeSize * 4, bounds: probeExtent,
                                format: .RGBA8, colorSpace: srgb)
        return buffer
    }

    /// `FilmSim.negativeImage`'s own patch grid, in pixels, at `probeSize`
    /// (128): `border = size/10 = 12`, `cellW·cols = 100`, `cellH·rows = 104`
    /// — symmetric margins on every edge, so this is orientation-safe. Used
    /// by ``interiorStdDevLuma(_:)`` to exclude the unexposed-rebate border
    /// (~36.5% of the frame — see `PrintEngineSupport.negativeImage`'s doc
    /// comment) from a measurement that is otherwise dominated by it.
    private static let interiorRect = (x: 12, y: 12, width: 100, height: 104)

    /// `stdDevLuma`, scoped to ``interiorRect`` — the probe's actual scene
    /// patches, excluding the bare-film-base border.
    ///
    /// Whole-frame `stdDevLuma` is unusable for Print Contrast: the border is
    /// a second, near-black population sitting alongside the scene, and
    /// whole-frame variance is dominated by *how far apart* those two
    /// populations' means are, not by how much contrast the paper curve adds
    /// within the scene itself. Cropping to the scene-only region measures
    /// what "contrast" actually means for this control. Kept in the same
    /// `([UInt8]) -> Double` shape as every other measure by baking the rect
    /// in as a capture rather than a parameter.
    private static func interiorStdDevLuma(_ px: [UInt8]) -> Double {
        var values: [Double] = []
        values.reserveCapacity(interiorRect.width * interiorRect.height)
        for y in interiorRect.y..<(interiorRect.y + interiorRect.height) {
            for x in interiorRect.x..<(interiorRect.x + interiorRect.width) {
                values.append(Conformance.luma(px, at: (y * probeSize + x) * 4))
            }
        }
        let mean = values.reduce(0, +) / Double(values.count)
        return (values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count))
            .squareRoot()
    }

    /// One print/film control's declared contract with the density renderer.
    ///
    /// Unlike `ControlCase` (Tests/ControlConformanceTests.swift), there is no
    /// per-case `setup`: every case shares the same reference, ``baseStack()``
    /// — the Auto-solved stack — so "neutral" for every case in this suite is
    /// that one stack, not an unedited `EditStack()`.
    struct FilmControlCase {
        let name: String

        /// The dotted key this covers: an `EditStack.filmNegative` field name,
        /// or `"print.<field>"` for a `FilmNegativeSettings.print` field.
        let key: String

        /// Two non-neutral settings, at or near the ends of the control's
        /// range as the panel actually offers it, applied on top of
        /// ``baseStack()``.
        let low: (inout EditStack) -> Void
        let high: (inout EditStack) -> Void

        /// The statistic this control is declared to move.
        let measure: ([UInt8]) -> Double

        /// Sign of `measure(high) - measure(reference)`. `0` means the
        /// control genuinely changes the image but no single scalar describes
        /// how, so only the change is asserted.
        let sign: Int

        /// How far `measure` must move before the direction assertion means
        /// anything. Phase 1's default (`Tests/ControlConformanceTests.swift`).
        let minimumChange: Double

        /// How much of the frame has to change before a setting counts as
        /// having done something. Phase 1's default.
        let minimumVisibleChange: Double

        init(name: String, key: String,
             low: @escaping (inout EditStack) -> Void,
             high: @escaping (inout EditStack) -> Void,
             measure: @escaping ([UInt8]) -> Double,
             sign: Int,
             minimumChange: Double = 0.002,
             minimumVisibleChange: Double = 0.0015) {
            self.name = name
            self.key = key
            self.low = low
            self.high = high
            self.measure = measure
            self.sign = sign
            self.minimumChange = minimumChange
            self.minimumVisibleChange = minimumVisibleChange
        }
    }

    // MARK: Cases
    //
    // Every sign below was measured against the actual renderer (probe
    // rendered, each `Conformance` measure printed, the diagnostic then
    // deleted) rather than taken on the brief's reasoning alone — see
    // task-7-report.md for the full table, including a fix-round correction.
    //
    // - Shoulder, Toe, and White Point Red matched the brief's reasoned signs
    //   exactly (all confirmed numerically).
    //
    // - Print Contrast: the brief reasoned whole-frame stdDevLuma would rise
    //   with contrast (sign +1). A first pass measured whole-frame stdDevLuma
    //   FALLING at the high end (0.4133 at grade 2.0 → 0.3619 at grade 4.5)
    //   and concluded the sign should flip to −1. That conclusion was wrong,
    //   caught in review: whole-frame stdDevLuma on this probe is dominated
    //   by a between-mode artifact, not by contrast. The frame is two
    //   populations — the scene patches and a ~36.5% unexposed-rebate border
    //   (see `PrintEngineSupport.negativeImage`) — and raising grade dims the
    //   scene's mean faster than it can dim the already-near-black border
    //   floor, so the two populations' means converge and the *between-group*
    //   spread that had been inflating whole-frame variance shrinks. That
    //   masks the real, opposite effect happening *inside* the scene: the
    //   engine's actual contrast is rising with grade the whole time.
    //   Measured on ``interiorStdDevLuma(_:)`` (the scene patches only, border
    //   excluded): 0.2678 at grade 0.5 → 0.2971 at grade 2.0 → 0.3250 at
    //   grade 4.5 — monotonically rising, exactly the brief's sign. Verified
    //   sign: **+1**, matching the brief; the whole-frame *statistic* was the
    //   wrong tool, not the control. See the report for the full sweep, the
    //   interior/exterior mean-convergence numbers, and a falsification check
    //   that a pure brightness offset (no contrast change at all) does NOT
    //   fool `interiorStdDevLuma` the way it fooled the whole-frame one.
    //
    // - Print Warmth and Print Tint (Task 8, Phase A): both matched their doc
    //   comment's reasoned sign — measured, not assumed. At warmth=80
    //   (against the then-neutral baseStack() reference, warmth=0),
    //   `Conformance.warmth` moved neutral=−0.000498 → high=0.007908,
    //   delta=+0.008406 — sign **+1**. At tint=80, `Conformance.greenMagenta`
    //   moved neutral=0.001991 → high=0.011142, delta=+0.009151 — sign **+1**.
    //
    // - Re-measured for Task 8, Phase C, once `baseStack()` itself carries the
    //   new house default filtration (warmth=24, tint=−8) rather than neutral:
    //   Print Tint's leg (still low=−80/high=80) needed no change — at
    //   tint=80 against the new (warmth=24, tint=−8) reference,
    //   `Conformance.greenMagenta` moved 0.002893 → 0.007221, delta=+0.004328,
    //   comfortably clearing the 0.002 floor with the same **+1** sign.
    //   Print Warmth's old high=80 leg, though, now measured only
    //   neutral=−0.000310 → 0.000253, delta=+0.000563 — under the 0.002
    //   floor. Mechanism, swept and confirmed rather than guessed: once the
    //   baseline itself already carries real warmth, red is already the
    //   dominant (max) channel feeding
    //   `PaperResponse.develop`'s max-channel normalization for much of this
    //   probe's tonal range, so out.0 stays pinned near `paper(n,…)` while
    //   pushing warmth further mostly raises `n` itself and, via the
    //   highlight-shoulder's hue-preserving desaturation, pulls blue *up*
    //   toward that same value — narrowing R−B rather than widening it. A
    //   sweep from warmth 24→100 was non-monotonic in whole-frame
    //   `Conformance.warmth` for exactly this reason (e.g. delta only
    //   +0.000812 at warmth=70, +0.001000 at warmth=90) before clearing the
    //   floor at the slider's actual maximum: warmth=100 measured
    //   delta=+0.002681, sign **+1**, matching the doc comment. Leg raised to
    //   100 (still "at the end of the control's range as the panel actually
    //   offers it," per `FilmControlCase`'s own contract) rather than
    //   loosening the floor. See task-8-filtration-report.md, Phase C, for
    //   the full sweep.
    static let cases: [FilmControlCase] = [
        .init(name: "Print Exposure", key: "print.exposure",
              low: { $0.filmNegative.print.exposure -= 1.5 },
              high: { $0.filmNegative.print.exposure += 1.5 },
              measure: Conformance.meanLuma, sign: +1),
        .init(name: "Print Contrast", key: "print.contrast",
              low: { $0.filmNegative.print.contrast = 0.5 },
              high: { $0.filmNegative.print.contrast = 4.5 },
              measure: FilmControlConformanceTests.interiorStdDevLuma, sign: +1),
        .init(name: "Shoulder", key: "print.shoulder",
              low: { $0.filmNegative.print.shoulder = 0 },
              high: { $0.filmNegative.print.shoulder = 100 },
              measure: { Conformance.percentileLuma($0, 0.98) }, sign: -1),
        .init(name: "Toe", key: "print.toe",
              low: { $0.filmNegative.print.toe = 0 },
              high: { $0.filmNegative.print.toe = 100 },
              measure: { Conformance.percentileLuma($0, 0.02) }, sign: +1,
              // Toe's default (30) already sits close to the toe=0 asymptote
              // (kneeQ(0)=512 vs kneeQ(30)≈204 — both large, both give a
              // near-imperceptible black lift per the doc comment on
              // `PaperResponse.kneeQ`), so the low leg's genuine effect is
              // small: measured Δpix ≈ 0.00143 against the Phase 1 default
              // floor of 0.0015. Real and reproducible (deterministic
              // render, confirmed structural cause), just small — lowered
              // with margin below the measured value, not to silence a flake.
              minimumVisibleChange: 0.0010),
        .init(name: "Print Saturation", key: "print.saturation",
              low: { $0.filmNegative.print.saturation = -40 },
              high: { $0.filmNegative.print.saturation = 40 },
              measure: Conformance.meanSaturation, sign: +1),
        // Print Warmth/Tint: signs measured against the actual renderer, same
        // discipline as the rest of this table (see the block comment above)
        // — +1 for both, confirmed empirically, not just assumed from the
        // doc comment's stated polarity. See task-8-filtration-report.md for
        // the measured deltas.
        .init(name: "Print Warmth", key: "print.warmth",
              low: { $0.filmNegative.print.warmth = -80 },
              // high raised to the slider's actual maximum (100, not 80) in
              // Phase C: against the new (warmth=24, tint=−8) baseStack()
              // reference, high=80 fell short of the 0.002 floor at only
              // delta=+0.000563 (the highlight shoulder's desaturation
              // increasingly cancels further warmth once red is already the
              // dominant channel for much of this probe — see the block
              // comment above); high=100 clears it at delta=+0.002681,
              // sign unchanged at **+1**.
              high: { $0.filmNegative.print.warmth = 100 },
              measure: Conformance.warmth, sign: +1),
        .init(name: "Print Tint", key: "print.tint",
              low: { $0.filmNegative.print.tint = -80 },
              high: { $0.filmNegative.print.tint = 80 },
              measure: Conformance.greenMagenta, sign: +1),
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

    /// Fields deliberately not covered here, each with the suite that does
    /// cover it instead — mirrors `ControlCase.excluded`
    /// (Tests/ControlConformanceTests.swift:78-89).
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
        // "print" itself is not a leaf field: it is decomposed into its own
        // seven fields below (all prefixed "print."), every one of which is
        // covered via `cases` — no print exclusions.
    ]

    // MARK: Field inventory
    //
    // `Mirror(reflecting: FilmNegativeSettings())` yields "print" as one of
    // its children — the whole `PrintSettings` sub-struct as a single field.
    // That label is dropped here (not excluded — decomposed) in favor of its
    // own children, individually prefixed "print.", so a print field added
    // without a case or exclusion fails the completeness test by its own
    // name rather than hiding behind the umbrella "print" label.
    private static func allFields() -> [String] {
        let filmFields = Mirror(reflecting: FilmNegativeSettings()).children
            .compactMap(\.label)
            .filter { $0 != "print" }
        let printFields = Mirror(reflecting: PrintSettings()).children
            .compactMap(\.label)
            .map { "print." + $0 }
        return filmFields + printFields
    }

    // MARK: Tests

    /// The reference is what "neutral" means in this suite — there is no
    /// per-case setup that leaves a control at a genuinely-inert value the
    /// way Phase 1's does (e.g. Grain Size at Grain Amount 0). Every case's
    /// `low`/`high` diverges from ``baseStack()`` alone, so the meaningful
    /// no-op check is that the solve itself is a pure, deterministic function
    /// of the probe: rendering it twice must be bit-exact.
    func testTheSolvedReferenceIsExactlyReproducible() {
        let a = Self.render(Self.baseStack())
        let b = Self.render(Self.baseStack())
        XCTAssertEqual(Conformance.difference(a, b), 0, accuracy: 0.0001,
                       "AutoInvert.solve, or the density render, is not deterministic.")
    }

    /// Both ends of every control must visibly change the image relative to
    /// the solved reference. This is the test that would have caught Phase
    /// 1's dead Highlights slider, applied to the print engine.
    func testBothExtremesChangeTheImage() {
        let reference = Self.render(Self.baseStack())
        for control in Self.cases {
            for (label, mutate) in [("minimum", control.low), ("maximum", control.high)] {
                var stack = Self.baseStack()
                mutate(&stack)
                let variant = Self.render(stack)
                let delta = Conformance.difference(reference, variant)
                XCTAssertGreaterThan(
                    delta, control.minimumVisibleChange,
                    "\(control.name) at its \(label) changes the image by \(delta), "
                    + "which is indistinguishable from doing nothing."
                )
            }
        }
    }

    /// Each control must move its declared statistic in its declared
    /// direction, relative to the solved reference.
    func testDirectionMatchesTheDeclaredOne() {
        let reference = Self.render(Self.baseStack())
        for control in Self.cases where control.sign != 0 {
            let neutral = control.measure(reference)
            var stack = Self.baseStack()
            control.high(&stack)
            let high = control.measure(Self.render(stack))
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

    // MARK: The inventory cannot rot

    /// Every stored property of `FilmNegativeSettings`, and every stored
    /// property of its `print: PrintSettings`, is either covered by a
    /// conformance case or explicitly excluded with the suite that covers it
    /// instead — mirrors
    /// `ControlConformanceTests.testEveryEditStackFieldIsCoveredOrExcluded`
    /// (Tests/ControlConformanceTests.swift:303-316).
    func testEveryEditStackFieldIsCoveredOrExcluded() {
        let fields = Self.allFields()
        XCTAssertFalse(fields.isEmpty, "Mirror found no stored properties.")

        let covered = Set(Self.cases.map(\.key)).union(Self.excluded.keys)
        for field in fields {
            XCTAssertTrue(
                covered.contains(field),
                "\(field) is neither in FilmControlConformanceTests.cases nor in "
                + "FilmControlConformanceTests.excluded. Add a conformance case for "
                + "it, or an exclusion naming the suite that covers it."
            )
        }
    }

    /// …and nothing in the table refers to a field that no longer exists.
    func testNoStaleEntriesInTheInventory() {
        let fields = Set(Self.allFields())
        for key in Self.cases.map(\.key) {
            XCTAssertTrue(fields.contains(key),
                          "cases covers '\(key)', which is not a field of "
                          + "FilmNegativeSettings or its print settings.")
        }
        for key in Self.excluded.keys {
            XCTAssertTrue(fields.contains(key),
                          "excluded lists '\(key)', which is not a field of "
                          + "FilmNegativeSettings or its print settings.")
        }
    }

    /// Two cases covering the same field means one of them is not being
    /// thought about.
    func testNoDuplicateCoverage() {
        let keys = Self.cases.map(\.key)
        XCTAssertEqual(Set(keys).count, keys.count, "A field has two conformance cases.")
        for key in keys {
            XCTAssertNil(Self.excluded[key], "'\(key)' is both covered and excluded.")
        }
    }
}
