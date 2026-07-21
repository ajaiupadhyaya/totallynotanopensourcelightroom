import SwiftUI

/// The direct-manipulation tools that sit between the roll and the canvas.
/// This is intentionally a narrow, stable rail: tools do not move when the
/// inspector changes mode, so muscle memory can form.
struct ToolRail: View {
    @Bindable var model: EditorModel
    @Bindable var workspace: WorkspaceModel

    var body: some View {
        VStack(spacing: 2) {
            ForEach(EditorTool.allCases) { tool in
                ToolRailButton(tool: tool, isSelected: tool == workspace.activeTool) {
                    workspace.activate(tool, in: model)
                }
            }
            Spacer()

            Text("TOOLS")
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .kerning(1.5)
                .foregroundStyle(Theme.tertiaryText)
                .rotationEffect(.degrees(-90))
                .fixedSize()
                .padding(.bottom, 24)
        }
        .padding(.top, 7)
        .frame(width: Theme.toolRailWidth)
        .background(Color(white: 0.065))
    }
}

private struct ToolRailButton: View {
    let tool: EditorTool
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: tool.symbolName)
                .font(.system(size: 15, weight: .regular))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(isSelected ? Theme.text
                                             : (isHovering ? Theme.text : Theme.secondaryText))
                .frame(width: Theme.toolRailWidth, height: 40)
                .background(isSelected ? Theme.control : .clear)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(isSelected ? Theme.accent : .clear)
                        .frame(width: 2)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(tool.shortcutHint.map { "\(tool.label)  ·  \($0)" } ?? tool.label)
        .accessibilityLabel(tool.label)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// Context-sensitive options for the selected canvas tool. This replaces
/// modal sheets for the frequent parts of crop, retouch, and brush work.
struct ToolOptionsBar: View {
    @Bindable var model: EditorModel
    @Bindable var workspace: WorkspaceModel

    var body: some View {
        HStack(spacing: 16) {
            Text(workspace.activeTool.label.uppercased())
                .font(Theme.engravedLabel)
                .kerning(Theme.engravedTracking)
                .foregroundStyle(Theme.text)
                .frame(width: 86, alignment: .leading)

            Rectangle().fill(Theme.strongSeparator).frame(width: Theme.hairline, height: 18)

            options

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 14)
        .frame(height: Theme.contextBarHeight)
        .background(Theme.background)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.separator).frame(height: Theme.hairline)
        }
    }

    @ViewBuilder
    private var options: some View {
        switch workspace.activeTool {
        case .hand:
            contextNote("Double-click the photograph to toggle Fit and 100%")
        case .crop:
            HStack(spacing: 8) {
                Text("RATIO").engraved()
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
               model.editStack.localAdjustments[index].shape == .brush {
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
                                    .brushStrokes.isEmpty) {
                        model.removeLastBrushStroke()
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
            }
        case .eyedropper:
            contextNote("Click something that should be neutral gray")
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
            .font(Theme.readableFont)
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

    private func maskBinding(
        _ index: Int, _ keyPath: WritableKeyPath<LocalAdjustment, Double>
    ) -> Binding<Double> {
        Binding(
            get: { model.editStack.localAdjustments[index][keyPath: keyPath] },
            set: { model.editStack.localAdjustments[index][keyPath: keyPath] = $0 }
        )
    }
}

private struct MiniContextFader: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String

    var body: some View {
        HStack(spacing: 7) {
            Text(label).engraved()
            GeometryReader { proxy in
                let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
                ZStack(alignment: .leading) {
                    Rectangle().fill(Theme.separator).frame(height: 1)
                    Rectangle().fill(Theme.secondaryText)
                        .frame(width: proxy.size.width * CGFloat(fraction), height: 2)
                    Rectangle().fill(Theme.text).frame(width: 1, height: 11)
                        .offset(x: proxy.size.width * CGFloat(fraction))
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { event in
                    let t = min(max(event.location.x / proxy.size.width, 0), 1)
                    value = range.lowerBound + Double(t) * (range.upperBound - range.lowerBound)
                })
            }
            .frame(width: 92, height: 14)
            Text(String(format: format, value))
                .font(Theme.valueFont)
                .foregroundStyle(Theme.text)
                .frame(width: 44, alignment: .trailing)
        }
    }
}
