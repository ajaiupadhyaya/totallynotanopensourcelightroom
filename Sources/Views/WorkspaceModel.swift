import Foundation
import Observation

/// The parts of the editing session that belong to the window rather than to
/// a photograph: which tool the pointer is holding and which inspector
/// workspace is open. Held as a reference so the tool rail, the options bar
/// and the keyboard monitor all read and write one truth.
@Observable
final class WorkspaceModel {
    var activeTool: EditorTool = .hand
    var inspectorMode: InspectorMode = .adjust

    /// Opening a different frame starts in the neutral tool. Otherwise the
    /// rail would keep claiming "Crop" while the new photograph is not
    /// actually in crop mode.
    func resetForNewPhoto() {
        activeTool = .hand
    }

    /// Selects `tool` and puts the editor into the matching state.
    ///
    /// Leaving a tool tidies up after it: an in-progress crop is committed,
    /// canvas pickers are dismissed, and selections that only make sense for
    /// the previous tool are cleared.
    func activate(_ tool: EditorTool, in model: EditorModel) {
        // A momentary look, not a mode — nothing else is disturbed.
        guard tool != .compare else {
            model.isShowingBefore.toggle()
            return
        }

        activeTool = tool

        if model.isCropping { model.finishCrop() }
        if tool != .heal, tool != .clone {
            model.canvasPicker = nil
            model.selectedSpotID = nil
        }
        if tool != .brush, tool != .gradient { model.selectedMaskID = nil }

        switch tool {
        case .hand:
            break
        case .crop:
            model.enterCropMode()
            inspectorMode = .adjust
        case .heal:
            model.retouchMode = .heal
            model.canvasPicker = .retouchPlace
            inspectorMode = .adjust
        case .clone:
            model.retouchMode = .clone
            model.canvasPicker = .retouchPlace
            inspectorMode = .adjust
        case .brush:
            if let brush = model.editStack.localAdjustments.last(where: { $0.shape == .brush }) {
                model.selectedMaskID = brush.id
            } else {
                model.addLocalAdjustment(.brush)
            }
            inspectorMode = .masks
        case .gradient:
            if let gradient = model.editStack.localAdjustments.last(where: {
                $0.shape == .linear || $0.shape == .radial
            }) {
                model.selectedMaskID = gradient.id
            } else {
                model.addLocalAdjustment(.linear)
            }
            inspectorMode = .masks
        case .eyedropper:
            model.canvasPicker = .whiteBalance
            inspectorMode = .adjust
        case .compare:
            break
        }
    }
}
