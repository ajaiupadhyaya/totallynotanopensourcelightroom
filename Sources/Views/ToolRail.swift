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
                    MiniContextFader(label: "SIZE",
                                     value: spotBinding(index, \.radius),
                                     range: 0.004...0.15, format: "%.3f")
                    MiniContextFader(label: "FEATHER",
                                     value: spotBinding(index, \.feather),
                                     range: 0...1, format: "%.2f")
                }
            }
        case .brush:
            if let index = model.selectedMaskIndex,
               let componentIndex = model.selectedComponentIndex,
               model.editStack.localAdjustments[index]
                   .components[componentIndex].shape == .brush {
                HStack(spacing: 18) {
                    MiniContextFader(label: "SIZE",
                                     value: maskBinding(index, \.brushSize),
                                     range: 0.005...0.2, format: "%.3f")
                    MiniContextFader(label: "FEATHER",
                                     value: maskBinding(index, \.brushFeather),
                                     range: 0...1, format: "%.2f")
                    MiniContextFader(label: "FLOW",
                                     value: maskBinding(index, \.brushFlow),
                                     range: 0.05...1, format: "%.2f")
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

private struct MiniContextFader: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(label).sectionLabel()

            GeometryReader { proxy in
                let fraction = CGFloat(
                    (value - range.lowerBound) / (range.upperBound - range.lowerBound)
                )
                let x = proxy.size.width * min(max(fraction, 0), 1)
                let midY = proxy.size.height / 2

                ZStack(alignment: .topLeading) {
                    // Same groove-and-thumb language as the panel faders, at
                    // the size the bar allows. A control that behaves the same
                    // should look the same.
                    Capsule()
                        .fill(Theme.canvas.opacity(0.75))
                        .frame(width: proxy.size.width, height: 3)
                        .offset(y: midY - 1.5)
                    Capsule()
                        .fill(Theme.secondaryText.opacity(0.85))
                        .frame(width: x, height: 3)
                        .offset(y: midY - 1.5)
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Theme.text)
                        .frame(width: 5, height: 12)
                        .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                        .scaleEffect(x: isHovering ? 1.2 : 1)
                        .offset(x: x - 2.5, y: midY - 6)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { event in
                    let t = min(max(event.location.x / proxy.size.width, 0), 1)
                    value = range.lowerBound + Double(t) * (range.upperBound - range.lowerBound)
                })
            }
            .frame(width: 92, height: 18)
            .onHover { isHovering = $0 }
            .animation(Theme.quick, value: isHovering)

            Text(String(format: format, value))
                .font(Theme.valueFont)
                .monospacedDigit()
                .foregroundStyle(Theme.text)
                .frame(width: 46, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(String(format: format, value))
    }
}
