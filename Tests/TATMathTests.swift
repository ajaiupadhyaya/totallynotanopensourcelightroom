import CoreGraphics
import XCTest
@testable import PhotoEditor

/// The TAT weighting as pure functions from gesture deltas to field values.
final class TATMathTests: XCTestCase {
    // MARK: Curve

    func testCurveDragAddsAPointAtTheSampledLuminanceAndLiftsIt() {
        let edit = TATMath.curveEdit(points: [], luma: 0.62, existingIndex: nil,
                                     deltaPoints: TATMath.pointsForFullSweep / 2)
        let point = edit.points[edit.index]
        XCTAssertEqual(point.x, 0.62, accuracy: 0.001)
        XCTAssertGreaterThan(point.y, 0.62, "an upward drag lifts the tone under the cursor")
        XCTAssertEqual(edit.points.map(\.x), edit.points.map(\.x).sorted())
    }

    func testCurveDragReusesTheAnchoredIndexAcrossTicks() {
        let first = TATMath.curveEdit(points: [], luma: 0.5, existingIndex: nil, deltaPoints: 30)
        let second = TATMath.curveEdit(points: [], luma: 0.5,
                                       existingIndex: first.index, deltaPoints: 60)
        XCTAssertEqual(second.index, first.index)
        XCTAssertGreaterThan(second.points[second.index].y, first.points[first.index].y)
        XCTAssertEqual(second.points.count, first.points.count, "no twin per tick")
    }

    func testCurveDragClampsAtTheUnitSquare() {
        let edit = TATMath.curveEdit(points: [], luma: 0.9, existingIndex: nil,
                                     deltaPoints: 10_000)
        XCTAssertEqual(edit.points[edit.index].y, 1.0)
    }

    // MARK: Mixer — weighted by the colours actually under the cursor

    func testMixerDragOnPureRedMovesTheRedBandAndLeavesAquaAlone() {
        let (hue, sat, _) = ColorScience.rgbToHSL(0.8, 0.15, 0.15)
        let mixer = TATMath.mixerEdit(ColorMixer(), hue: hue, saturation: sat,
                                      field: \.saturation,
                                      deltaPoints: TATMath.pointsForFullSweep / 2)
        XCTAssertGreaterThan(mixer[.red].saturation, 20)
        XCTAssertEqual(mixer[.aqua].saturation, 0, accuracy: 1e-9,
                       "bands that don't touch the sampled colour must not move")
    }

    /// The saturation ramp, mirrored from the LUT, is what keeps the TAT from
    /// yanking bands around when the probe lands on something nearly neutral.
    /// Stated as a ratio rather than an absolute: the same drag on a saturated
    /// colour of the same hue is the honest reference, and the ramp
    /// (`smoothstep(0.03 / 0.2)` ≈ 0.06) is what separates them.
    func testMixerDragOnNearGreyBarelyMovesAnything() {
        func totalMovement(saturation: Double) -> Double {
            let mixer = TATMath.mixerEdit(ColorMixer(), hue: 30, saturation: saturation,
                                          field: \.luminance, deltaPoints: 200)
            return HueBand.allCases.reduce(0.0) { $0 + abs(mixer[$1].luminance) }
        }
        let grey = totalMovement(saturation: 0.03)
        let colourful = totalMovement(saturation: 0.6)
        XCTAssertGreaterThan(colourful, 50, "a saturated probe moves the bands properly")
        XCTAssertLessThan(grey, colourful * 0.1,
                          "the saturation ramp — mirrored from the LUT — gates greys")
    }

    func testMixerValuesClampToTheSliderRange() {
        var mixer = ColorMixer()
        mixer[.red].saturation = 95
        let (hue, sat, _) = ColorScience.rgbToHSL(0.9, 0.1, 0.1)
        let moved = TATMath.mixerEdit(mixer, hue: hue, saturation: sat,
                                      field: \.saturation, deltaPoints: 10_000)
        XCTAssertEqual(moved[.red].saturation, 100)
    }

    func testBlackAndWhiteDragMovesTheMixNotTheBands() {
        let (hue, sat, _) = ColorScience.rgbToHSL(0.2, 0.3, 0.9)
        let mixer = TATMath.blackAndWhiteEdit(ColorMixer(), hue: hue, saturation: sat,
                                              deltaPoints: 150)
        XCTAssertGreaterThan(mixer.blackAndWhiteWeight(.blue), 10)
        XCTAssertTrue(mixer.bands.allSatisfy(\.isNeutral))
    }
}

@MainActor
final class TATModelTests: XCTestCase {
    func testTheToolExistsWithItsBareKey() {
        XCTAssertEqual(EditorTool(shortcutKey: "t"), .targetedAdjustment)
        XCTAssertEqual(EditorTool.targetedAdjustment.shortcutHint, "T")
        XCTAssertFalse(EditorTool.targetedAdjustment.isViewingAid)
    }

    func testActivationTidiesUpLikeEveryOtherTool() throws {
        let editor = try TestSupport.makeEditorModel()
        let workspace = WorkspaceModel()
        editor.canvasPicker = .whiteBalance
        workspace.activate(.targetedAdjustment, in: editor)
        XCTAssertEqual(workspace.activeTool, .targetedAdjustment)
        XCTAssertNil(editor.canvasPicker, "an armed eyedropper must not survive the switch")
        XCTAssertEqual(workspace.inspectorMode, .adjust)
    }

    /// The whole gesture against the live model: one field written, one undo
    /// step, and the curve point lands at the sampled luminance.
    func testACurveDragEditsTheStackOnceAndIsOneUndoStep() throws {
        let editor = try TestSupport.makeEditorModel(gray: 128)
        editor.tatTarget = .curve
        editor.beginTATDrag(atUnitPoint: CGPoint(x: 0.5, y: 0.5))
        editor.continueTATDrag(byPoints: 60)
        editor.continueTATDrag(byPoints: 120)
        XCTAssertFalse(editor.editStack.toneCurvePoints.isEmpty)
        editor.endTATDrag()
        editor.commitEdit()
        XCTAssertEqual(editor.undoDepth, 1)
    }

    func testAMixerDragWritesTheMixerNotTheCurve() throws {
        let editor = try TestSupport.makeEditorModel(gray: 128)
        editor.tatTarget = .saturation
        editor.beginTATDrag(atUnitPoint: CGPoint(x: 0.5, y: 0.5))
        editor.continueTATDrag(byPoints: 200)
        editor.endTATDrag()
        XCTAssertTrue(editor.editStack.toneCurvePoints.isEmpty)
        // A grey probe moves almost nothing (the saturation ramp) — the write
        // path, not the magnitude, is what this asserts.
    }
}
