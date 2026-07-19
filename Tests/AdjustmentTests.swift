import CoreImage
import XCTest
@testable import PhotoEditor

/// Verifies the tone, presence, detail, and effects adjustments added for
/// Lightroom parity.
///
/// Each test asserts the *direction and locality* of an effect rather than
/// exact pixel values — that's what actually distinguishes a correct filter
/// chain from a plausible-looking one.
final class AdjustmentTests: XCTestCase {
    private let renderer = EditRenderer()

    /// A flat patch at a given level, big enough for large-radius filters.
    private func patch(_ level: Double, size: CGFloat = 128) -> CIImage {
        TestSupport.solidImage(red: level, green: level, blue: level, size: size)
    }

    /// Renders a stack over a patch and returns its average brightness.
    private func brightness(_ level: Double, _ mutate: (inout EditStack) -> Void) -> Double {
        var stack = EditStack()
        mutate(&stack)
        let result = renderer.render(source: patch(level), stack: stack)
        return TestSupport.readColor(result).red
    }

    // MARK: Whites & blacks

    func testWhitesLiftBrightTonesWithoutTouchingBlack() {
        let brightBefore = brightness(0.75) { _ in }
        let brightAfter = brightness(0.75) { $0.whites = 80 }
        XCTAssertGreaterThan(brightAfter, brightBefore)

        // Pure black is pinned, so the curve can't shift it.
        let blackAfter = brightness(0.0) { $0.whites = 80 }
        XCTAssertEqual(blackAfter, 0, accuracy: 0.02)
    }

    func testBlacksLiftDarkTonesWithoutTouchingWhite() {
        let darkBefore = brightness(0.25) { _ in }
        let darkAfter = brightness(0.25) { $0.blacks = 80 }
        XCTAssertGreaterThan(darkAfter, darkBefore)

        let whiteAfter = brightness(1.0) { $0.blacks = 80 }
        XCTAssertEqual(whiteAfter, 1.0, accuracy: 0.02)
    }

    func testNegativeBlacksDeepenShadows() {
        let before = brightness(0.25) { _ in }
        let after = brightness(0.25) { $0.blacks = -80 }
        XCTAssertLessThan(after, before)
    }

    func testWhitesAndBlacksActOnOppositeEnds() {
        // Whites should barely move a quarter-tone; blacks should barely move a
        // three-quarter tone. If either did, they'd be duplicating contrast.
        let quarterWithWhites = brightness(0.25) { $0.whites = 100 }
        let quarterPlain = brightness(0.25) { _ in }
        XCTAssertEqual(quarterWithWhites, quarterPlain, accuracy: 0.06)

        let threeQuarterWithBlacks = brightness(0.75) { $0.blacks = 100 }
        let threeQuarterPlain = brightness(0.75) { _ in }
        XCTAssertEqual(threeQuarterWithBlacks, threeQuarterPlain, accuracy: 0.06)
    }

    // MARK: Presence

    func testClarityAndTextureLeaveAFlatPatchAlone() {
        // Both are local-contrast filters, so with no local detail to work on
        // they must be no-ops. This catches an unsharp mask wired up as a
        // global brightness/contrast change by mistake.
        let plain = brightness(0.5) { _ in }
        XCTAssertEqual(brightness(0.5) { $0.clarity = 100 }, plain, accuracy: 0.02)
        XCTAssertEqual(brightness(0.5) { $0.texture = 100 }, plain, accuracy: 0.02)
    }

    func testClarityIncreasesLocalContrastAtAnEdge() {
        let edge = edgeImage()
        var stack = EditStack()
        stack.clarity = 100

        let before = edgeContrast(renderer.render(source: edge, stack: EditStack()))
        let after = edgeContrast(renderer.render(source: edge, stack: stack))
        XCTAssertGreaterThan(after, before,
                             "Clarity should widen the tonal gap across an edge.")
    }

    func testDehazeAddsContrastAndSaturation() {
        // Documented as an approximation, but its direction must still be right.
        let source = TestSupport.solidImage(red: 0.6, green: 0.5, blue: 0.45)
        var stack = EditStack()
        stack.dehaze = 100

        let before = TestSupport.readColor(renderer.render(source: source, stack: EditStack()))
        let after = TestSupport.readColor(renderer.render(source: source, stack: stack))

        let spreadBefore = before.red - before.blue
        let spreadAfter = after.red - after.blue
        XCTAssertGreaterThan(spreadAfter, spreadBefore,
                             "Dehaze should restore the saturation haze washes out.")
    }

    func testVibranceRaisesSaturationOfAMutedColor() {
        let muted = TestSupport.solidImage(red: 0.55, green: 0.5, blue: 0.5)
        var stack = EditStack()
        stack.vibrance = 100

        let before = TestSupport.readColor(renderer.render(source: muted, stack: EditStack()))
        let after = TestSupport.readColor(renderer.render(source: muted, stack: stack))
        XCTAssertGreaterThan(after.red - after.blue, before.red - before.blue)
    }

    // MARK: Detail

    func testSharpeningLeavesAFlatPatchAlone() {
        let plain = brightness(0.5) { _ in }
        XCTAssertEqual(brightness(0.5) { $0.sharpenAmount = 100 }, plain, accuracy: 0.02)
    }

    func testSharpeningStrengthensAnEdge() {
        let edge = edgeImage()
        var stack = EditStack()
        stack.sharpenAmount = 100
        stack.sharpenRadius = 2.0

        let before = edgeContrast(renderer.render(source: edge, stack: EditStack()))
        let after = edgeContrast(renderer.render(source: edge, stack: stack))
        XCTAssertGreaterThan(after, before)
    }

    func testNoiseReductionPreservesOverallBrightness() {
        // Blurring shouldn't shift exposure; if it does, the blend is wrong.
        let plain = brightness(0.5) { _ in }
        XCTAssertEqual(brightness(0.5) { $0.luminanceNoiseReduction = 100 },
                       plain, accuracy: 0.03)
        XCTAssertEqual(brightness(0.5) { $0.colorNoiseReduction = 100 },
                       plain, accuracy: 0.03)
    }

    func testColorNoiseReductionKeepsLuminanceStructure() {
        // Chroma NR must not soften a luminance edge — that's the whole reason
        // it composites in color blend mode instead of just blurring.
        let edge = edgeImage()
        var stack = EditStack()
        stack.colorNoiseReduction = 100

        let before = edgeContrast(renderer.render(source: edge, stack: EditStack()))
        let after = edgeContrast(renderer.render(source: edge, stack: stack))
        XCTAssertEqual(after, before, accuracy: 0.1,
                       "Chroma noise reduction should leave luminance detail intact.")
    }

    // MARK: Effects

    func testNegativeVignetteDarkensTheCornersNotTheCenter() {
        let source = patch(0.7, size: 200)
        var stack = EditStack()
        stack.vignetteAmount = -100
        stack.vignetteMidpoint = 20

        let result = renderer.render(source: source, stack: stack)
        let corner = TestSupport.readColor(
            result.cropped(to: CGRect(x: 0, y: 0, width: 20, height: 20))
        )
        let center = TestSupport.readColor(
            result.cropped(to: CGRect(x: 90, y: 90, width: 20, height: 20))
        )
        XCTAssertLessThan(corner.red, center.red,
                          "A negative vignette should darken corners relative to the center.")
    }

    func testGrainAddsVariationToAFlatPatch() {
        let source = patch(0.5, size: 128)
        var stack = EditStack()
        stack.grainAmount = 100

        let result = renderer.render(source: source, stack: stack)
        XCTAssertGreaterThan(spread(of: result), spread(of: source),
                             "Grain should introduce pixel-to-pixel variation.")
    }

    func testZeroGrainIsAnExactNoOp() {
        let source = patch(0.5, size: 64)
        var stack = EditStack()
        stack.grainAmount = 0
        stack.grainSize = 80 // size alone must not apply grain

        let result = TestSupport.readColor(renderer.render(source: source, stack: stack))
        XCTAssertEqual(result.red, 0.5, accuracy: 0.01)
    }

    // MARK: Neutrality

    func testAFreshStackRendersTheOriginalUnchanged() {
        // Every default must be its neutral value, or importing a photo would
        // silently alter it.
        let source = TestSupport.solidImage(red: 0.4, green: 0.55, blue: 0.7, size: 64)
        let result = TestSupport.readColor(renderer.render(source: source, stack: EditStack()))

        XCTAssertEqual(result.red, 0.4, accuracy: 0.01)
        XCTAssertEqual(result.green, 0.55, accuracy: 0.01)
        XCTAssertEqual(result.blue, 0.7, accuracy: 0.01)
    }

    func testAllNewFieldsSurviveACatalogRoundTrip() throws {
        let store = try TestSupport.inMemoryCatalog()
        var entry = TestSupport.makeEntry(fileURL: URL(fileURLWithPath: "/tmp/a.jpg"))
        entry.editStack.whites = 30
        entry.editStack.blacks = -20
        entry.editStack.texture = 15
        entry.editStack.clarity = 25
        entry.editStack.dehaze = 10
        entry.editStack.vibrance = 40
        entry.editStack.sharpenAmount = 55
        entry.editStack.sharpenRadius = 2.5
        entry.editStack.luminanceNoiseReduction = 12
        entry.editStack.colorNoiseReduction = 8
        entry.editStack.vignetteAmount = -35
        entry.editStack.vignetteMidpoint = 60
        entry.editStack.grainAmount = 45
        entry.editStack.grainSize = 70
        try store.save(entry)

        let fetched = try XCTUnwrap(store.entry(id: entry.id))
        XCTAssertEqual(fetched.editStack, entry.editStack)
    }

    func testLegacyEditStackJSONGetsNeutralDefaultsForNewFields() throws {
        let legacy = """
        {"exposure":0.5,"contrast":10,"highlights":0,"shadows":0,
         "whiteBalanceTemp":6500,"whiteBalanceTint":0,"saturation":0,
         "toneCurvePoints":[]}
        """.data(using: .utf8)!

        let stack = try JSONDecoder().decode(EditStack.self, from: legacy)
        XCTAssertEqual(stack.exposure, 0.5, accuracy: 1e-9)
        XCTAssertEqual(stack.whites, 0)
        XCTAssertEqual(stack.grainSize, 25, "Non-zero neutrals must use their default.")
        XCTAssertEqual(stack.sharpenRadius, 1.5)
        XCTAssertEqual(stack.vignetteMidpoint, 50)
        XCTAssertTrue(stack.geometry.isIdentity)
    }

    // MARK: Helpers

    /// A vertical dark/bright edge — the test subject for anything that claims
    /// to act on local detail.
    private func edgeImage() -> CIImage {
        let dark = TestSupport.solidImage(red: 0.3, green: 0.3, blue: 0.3,
                                          in: CGRect(x: 0, y: 0, width: 64, height: 128))
        let bright = TestSupport.solidImage(red: 0.7, green: 0.7, blue: 0.7,
                                            in: CGRect(x: 64, y: 0, width: 64, height: 128))
        return bright.composited(over: dark)
            .cropped(to: CGRect(x: 0, y: 0, width: 128, height: 128))
    }

    /// The tonal gap measured just either side of the edge at x = 64.
    private func edgeContrast(_ image: CIImage) -> Double {
        let left = TestSupport.readColor(
            image.cropped(to: CGRect(x: 54, y: 32, width: 8, height: 64))
        )
        let right = TestSupport.readColor(
            image.cropped(to: CGRect(x: 66, y: 32, width: 8, height: 64))
        )
        return right.red - left.red
    }

    /// Difference between the brightest and darkest small tile — a cheap proxy
    /// for pixel-to-pixel variation.
    private func spread(of image: CIImage) -> Double {
        var minimum = 1.0
        var maximum = 0.0
        for x in stride(from: 0, to: 120, by: 12) {
            for y in stride(from: 0, to: 120, by: 12) {
                let value = TestSupport.readColor(
                    image.cropped(to: CGRect(x: x, y: y, width: 2, height: 2))
                ).red
                minimum = min(minimum, value)
                maximum = max(maximum, value)
            }
        }
        return maximum - minimum
    }
}
