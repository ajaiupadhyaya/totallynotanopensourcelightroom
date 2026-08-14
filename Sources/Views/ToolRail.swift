import SwiftUI

/// The direct-manipulation tools that sit between the roll and the canvas.
/// This is intentionally a narrow, stable rail: tools do not move when the
/// inspector changes mode, so muscle memory can form.
struct ToolRail: View {
    @Bindable var model: EditorModel
    @Bindable var workspace: WorkspaceModel

    var body: some View {
        VStack(spacing: 3) {
            railGroup(EditorTool.allCases.filter { !$0.isViewingAid })

            Rule(color: Theme.separator)
                .padding(.horizontal, 12)
                .padding(.vertical, Theme.space2)

            railGroup(EditorTool.allCases.filter(\.isViewingAid))

            Spacer(minLength: 0)
        }
        .padding(.vertical, Theme.space2)
        .frame(width: Theme.toolRailWidth)
        .background(Theme.canvas)
        .accessibilityLabel("Tools")
    }

    private func railGroup(_ tools: [EditorTool]) -> some View {
        ForEach(tools) { tool in
            ToolButton(
                symbol: tool.symbolName,
                label: tool.label,
                shortcut: tool.shortcutHint ?? "",
                isSelected: isLit(tool)
            ) {
                workspace.activate(tool, in: model)
            }
        }
    }

    /// Compare is a momentary look rather than a mode, so it never becomes the
    /// active tool. It still has to *look* engaged while it is showing the
    /// original, or the rail would claim nothing is happening while the canvas
    /// plainly disagrees.
    private func isLit(_ tool: EditorTool) -> Bool {
        tool == .compare ? model.isShowingBefore : tool == workspace.activeTool
    }
}

/// Context-sensitive options for the selected canvas tool. This replaces
/// modal sheets for the frequent parts of crop, retouch, and brush work.
struct ToolOptionsBar: View {
    @Bindable var model: EditorModel
    @Bindable var workspace: WorkspaceModel

    /// The bar exists only when the tool in hand actually has options.
    ///
    /// The Hand tool has none, and a full-width bar carrying one sentence of
    /// advice is worse than no bar: it takes a strip off the photograph to say
    /// something a person reads once and never again. Collapsing gives the
    /// space back to the image, which is what the window is for.
    private var hasOptions: Bool {
        workspace.activeTool != .hand
    }

    var body: some View {
        if hasOptions {
            HStack(spacing: Theme.space4) {
                HStack(spacing: 7) {
                    Image(systemName: workspace.activeTool.symbolName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.accent)
                    Text(workspace.activeTool.label.uppercased())
                        .sectionLabel(Theme.text)
                }
                .frame(width: 104, alignment: .leading)

                Rule(axis: .vertical, color: Theme.separator).frame(height: 18)

                options

                Spacer(minLength: Theme.space2)
            }
            .padding(.horizontal, Theme.panelInset)
            .frame(height: Theme.contextBarHeight)
            .background(Theme.background)
            .overlay(alignment: .bottom) { Rule() }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var options: some View {
        switch workspace.activeTool {
        case .hand:
            EmptyView()
        case .crop:
            HStack(spacing: 8) {
                Text("RATIO").sectionLabel()
                ForEach(cropRatios, id: \.label) { item in
                    PlateButton(title: item.label) { model.setCropAspectRatio(item.ratio) }
                }
                Rectangle().fill(Theme.separator).frame(width: Theme.hairline, height: 18)
                PlateButton(title: "Cancel") {
                    model.cancelCrop()
                    workspace.activeTool = .hand
                }
                PlateButton(title: "Apply") {
                    model.finishCrop()
                    workspace.activeTool = .hand
                }
            }
        case .heal, .clone:
            HStack(spacing: 14) {
                contextNote(model.canvasPicker == .retouchPlace
                            ? "Click a defect on the photograph"
                            : "Select a repair or add another spot")
                PlateButton(title: "Add Spot") { model.canvasPicker = .retouchPlace }
                if let index = model.selectedSpotIndex {
                    AdjustmentSlider(title: "Size", value: spotBinding(index, \.radius),
                                     range: 0.004...0.15, format: "%.3f",
                                     neutral: 0.025, style: .compact)
                    AdjustmentSlider(title: "Feather", value: spotBinding(index, \.feather),
                                     range: 0...1, format: "%.2f",
                                     neutral: 0.5, style: .compact)
                }
            }
        case .brush:
            if let index = model.selectedMaskIndex,
               let componentIndex = model.selectedComponentIndex,
               model.editStack.localAdjustments[index]
                   .components[componentIndex].shape == .brush {
                HStack(spacing: 18) {
                    AdjustmentSlider(title: "Size", value: maskBinding(index, \.brushSize),
                                     range: 0.005...0.2, format: "%.3f",
                                     neutral: 0.04, style: .compact)
                    AdjustmentSlider(title: "Feather", value: maskBinding(index, \.brushFeather),
                                     range: 0...1, format: "%.2f",
                                     neutral: 0.65, style: .compact)
                    AdjustmentSlider(title: "Flow", value: maskBinding(index, \.brushFlow),
                                     range: 0.05...1, format: "%.2f",
                                     neutral: 0.8, style: .compact)
                    PlateButton(title: "Undo Stroke",
                                isEnabled: !model.editStack.localAdjustments[index]
                                    .components[componentIndex].brushStrokes.isEmpty) {
                        model.removeLastBrushStroke()
                    }
                    PlateButton(title: model.isShowingMaskOverlay ? "Hide Mask" : "Show Mask") {
                        model.isShowingMaskOverlay.toggle()
                    }
                }
            } else {
                contextNote("Create or select a brush mask")
            }
        case .gradient:
            HStack(spacing: 8) {
                contextNote("Drag the on-canvas handles to shape the mask")
                PlateButton(title: "+ Linear") { model.addLocalAdjustment(.linear) }
                PlateButton(title: "+ Radial") { model.addLocalAdjustment(.radial) }
                PlateButton(title: model.isShowingMaskOverlay ? "Hide Mask" : "Show Mask") {
                    model.isShowingMaskOverlay.toggle()
                }
            }
        case .eyedropper:
            contextNote(model.isSensorDomainWB
                        ? "Not available on a RAW photo — see White Balance"
                        : "Click something that should be neutral gray")
        case .targetedAdjustment:
            HStack(spacing: 14) {
                TabStrip(
                    options: EditorModel.TATTarget.allCases.map { ($0, $0.label) },
                    selection: Binding(get: { model.tatTarget },
                                       set: { model.tatTarget = $0 }),
                    spacing: Theme.space3
                )
                contextNote(model.editStack.color.treatment == .blackAndWhite
                            && model.tatTarget != .curve
                            ? "Drag the photograph up or down — edits the B&W mix"
                            : "Drag the photograph up or down")
            }
        case .compare:
            HStack(spacing: 10) {
                contextNote(model.isShowingBefore ? "Showing the original interpretation"
                                                  : "Showing the developed interpretation")
                PlateButton(title: model.isShowingBefore ? "Show After" : "Show Before") {
                    model.isShowingBefore.toggle()
                }
            }
        }
    }

    private var cropRatios: [(label: String, ratio: Double?)] {
        [("Orig", nil), ("1:1", 1), ("4:5", 4.0 / 5), ("3:2", 3.0 / 2), ("16:9", 16.0 / 9)]
    }

    private func contextNote(_ text: String) -> some View {
        Text(text)
            .font(Theme.body)
            .foregroundStyle(Theme.secondaryText)
            .lineLimit(1)
    }

    private func spotBinding(
        _ index: Int, _ keyPath: WritableKeyPath<RetouchSpot, Double>
    ) -> Binding<Double> {
        Binding(
            get: { model.editStack.retouch[index][keyPath: keyPath] },
            set: { model.editStack.retouch[index][keyPath: keyPath] = $0 }
        )
    }

    /// Index of the component ``maskBinding`` should address: the explicitly
    /// selected one when it still exists in this mask, otherwise the first —
    /// mirroring ``LocalAdjustmentPanel``'s ``component(_:)`` fallback. `nil`
    /// only when the mask genuinely has no components left.
    private func resolvedComponentIndex(_ index: Int) -> Int? {
        let components = model.editStack.localAdjustments[index].components
        if let componentIndex = model.selectedComponentIndex,
           components.indices.contains(componentIndex) {
            return componentIndex
        }
        return components.indices.first
    }

    /// Addresses a property of the selected mask's selected component.
    private func maskBinding(
        _ index: Int, _ keyPath: WritableKeyPath<MaskComponent, Double>
    ) -> Binding<Double> {
        Binding(
            get: {
                guard let componentIndex = resolvedComponentIndex(index) else {
                    return MaskComponent()[keyPath: keyPath]
                }
                return model.editStack.localAdjustments[index]
                    .components[componentIndex][keyPath: keyPath]
            },
            set: {
                guard let componentIndex = resolvedComponentIndex(index) else { return }
                model.editStack.localAdjustments[index]
                    .components[componentIndex][keyPath: keyPath] = $0
            }
        )
    }
}
