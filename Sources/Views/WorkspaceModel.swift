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

    /// The lights-out ladder: two dim stages over all chrome, canvas
    /// untouched. Window state, never persisted.
    enum LightsOut: Int, CaseIterable {
        case off, dim, dark

        /// Achromatic veil strengths — taste constants, verified in-app.
        /// Dark stops short of 1: the chrome recedes, it does not vanish.
        var veilOpacity: Double {
            switch self {
            case .off: 0
            case .dim: 0.55
            case .dark: 0.88
            }
        }
    }

    var lightsOut: LightsOut = .off

    func cycleLightsOut() {
        lightsOut = LightsOut(rawValue: lightsOut.rawValue + 1) ?? .off
    }

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
        if tool != .brush, tool != .gradient {
            model.selectedMaskID = nil
            model.selectedComponentID = nil
        }

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
            if model.selectedMaskID != nil {
                if let existing = selectedComponent(in: model, shape: .brush) {
                    model.selectedComponentID = existing
                } else {
                    model.addMaskComponent(.brush)
                }
            } else {
                model.addLocalAdjustment(.brush)
            }
            inspectorMode = .masks
        case .gradient:
            if model.selectedMaskID != nil {
                if let existing = selectedComponent(in: model, shapes: [.linear, .radial]) {
                    model.selectedComponentID = existing
                } else {
                    model.addMaskComponent(.linear)
                }
            } else {
                model.addLocalAdjustment(.linear)
            }
            inspectorMode = .masks
        case .eyedropper:
            // Arming the picker on a sensor-domain RAW would put the canvas in
            // a mode whose click does nothing (see
            // ``EditorModel/pickWhiteBalance(atUnitPoint:)``). Show the White
            // Balance panel instead, where the disabled affordance says why.
            if !model.isSensorDomainWB { model.canvasPicker = .whiteBalance }
            inspectorMode = .adjust
        case .targetedAdjustment:
            inspectorMode = .adjust
        case .compare:
            break
        }
    }

    private func selectedComponent(
        in model: EditorModel, shape: MaskComponent.Shape
    ) -> UUID? {
        selectedComponent(in: model, shapes: [shape])
    }

    private func selectedComponent(
        in model: EditorModel, shapes: Set<MaskComponent.Shape>
    ) -> UUID? {
        guard let index = model.selectedMaskIndex else { return nil }
        return model.editStack.localAdjustments[index]
            .components.last { shapes.contains($0.shape) }?.id
    }
}
