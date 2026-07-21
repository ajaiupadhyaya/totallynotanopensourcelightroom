import SwiftUI

/// The Local Adjustments section: the mask list, and the selected mask's
/// corrections.
///
/// Selecting a mask shows its handles on the canvas — drag the pins to place
/// a linear gradient, or the center/radius handles to shape a radial.
struct LocalAdjustmentPanel: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.controlSpacing) {
            HStack(spacing: 6) {
                PlateButton(title: "+ Brush") { model.addLocalAdjustment(.brush) }
                PlateButton(title: "+ Linear") { model.addLocalAdjustment(.linear) }
                PlateButton(title: "+ Radial") { model.addLocalAdjustment(.radial) }
                Spacer()
            }

            if model.editStack.localAdjustments.isEmpty {
                Text("Paint a correction directly, burn a sky with a linear "
                     + "gradient, or dodge a face with a radial mask.")
                    .font(Theme.readableFont)
                    .foregroundStyle(Theme.secondaryText)
            } else {
                maskList

                if let index = model.selectedMaskIndex {
                    maskControls(at: index)
                }
            }
        }
    }

    private var maskList: some View {
        VStack(spacing: 2) {
            ForEach(model.editStack.localAdjustments) { adjustment in
                let isSelected = adjustment.id == model.selectedMaskID
                HStack(spacing: 8) {
                    // The mask's shape, drawn: a slanted line or an ellipse.
                    Group {
                        switch adjustment.shape {
                        case .linear:
                            Path { path in
                                path.move(to: CGPoint(x: 1, y: 11))
                                path.addLine(to: CGPoint(x: 11, y: 1))
                            }
                            .stroke(style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                        case .radial:
                            Ellipse()
                                .stroke(style: StrokeStyle(lineWidth: 1.2, dash: [2, 2]))
                                .padding(1)
                        case .brush:
                            Image(systemName: "paintbrush.pointed")
                                .font(.system(size: 10, weight: .medium))
                        }
                    }
                    .foregroundStyle(isSelected ? Theme.accent : Theme.secondaryText)
                    .frame(width: 12, height: 12)

                    Text(adjustment.displayName)
                        .font(Theme.controlFont)
                        .foregroundStyle(Theme.text.opacity(adjustment.isEnabled ? 0.9 : 0.4))

                    Spacer()

                    LampToggle(label: "", isOn: binding(for: adjustment.id, \.isEnabled))

                    GlyphButton(kind: .cross, label: "Delete mask") {
                        model.removeLocalAdjustment(id: adjustment.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background {
                    Rectangle()
                        .fill(isSelected ? Theme.control : .clear)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    model.selectedMaskID = isSelected ? nil : adjustment.id
                }
            }
        }
    }

    @ViewBuilder
    private func maskControls(at index: Int) -> some View {
        let adjustment = model.editStack.localAdjustments[index]

        Rectangle().fill(Theme.separator).frame(height: Theme.hairline)

        AdjustmentSlider(title: "Exposure",
                         value: maskBinding(index, \.exposure),
                         range: -3...3, format: "%.2f EV", neutral: 0)
        AdjustmentSlider(title: "Contrast",
                         value: maskBinding(index, \.contrast),
                         range: -100...100, format: "%.0f", neutral: 0)
        AdjustmentSlider(title: "Highlights",
                         value: maskBinding(index, \.highlights),
                         range: -100...100, format: "%.0f", neutral: 0)
        AdjustmentSlider(title: "Shadows",
                         value: maskBinding(index, \.shadows),
                         range: -100...100, format: "%.0f", neutral: 0)
        AdjustmentSlider(title: "Saturation",
                         value: maskBinding(index, \.saturation),
                         range: -100...100, format: "%.0f", neutral: 0)
        AdjustmentSlider(title: "Warmth",
                         value: maskBinding(index, \.warmth),
                         range: -100...100, format: "%.0f", neutral: 0)

        if adjustment.shape == .radial {
            AdjustmentSlider(title: "Feather",
                             value: maskBinding(index, \.feather),
                             range: 0...1, format: "%.2f", neutral: 0.5)
        }

        if adjustment.shape == .brush {
            AdjustmentSlider(title: "Brush Size",
                             value: maskBinding(index, \.brushSize),
                             range: 0.005...0.2, format: "%.3f", neutral: 0.04)
            AdjustmentSlider(title: "Brush Feather",
                             value: maskBinding(index, \.brushFeather),
                             range: 0...1, format: "%.2f", neutral: 0.65)
            AdjustmentSlider(title: "Brush Flow",
                             value: maskBinding(index, \.brushFlow),
                             range: 0.05...1, format: "%.2f", neutral: 0.8)

            HStack {
                Text("\(adjustment.brushStrokes.count) STROKES")
                    .engraved()
                Spacer()
                PlateButton(title: "Undo Stroke",
                            isEnabled: !adjustment.brushStrokes.isEmpty) {
                    model.removeLastBrushStroke()
                }
            }
        }

        LampToggle(label: "Invert — apply outside the shape",
                   isOn: maskBinding(index, \.isInverted))

        Text(adjustment.shape == .brush
             ? "Drag on the photograph to paint this mask."
             : "Drag the handles on the photograph to place this mask.")
            .font(Theme.readableFont)
            .foregroundStyle(Theme.secondaryText)
    }

    // MARK: Bindings

    private func maskBinding<T>(
        _ index: Int, _ keyPath: WritableKeyPath<LocalAdjustment, T>
    ) -> Binding<T> {
        Binding(
            get: {
                guard model.editStack.localAdjustments.indices.contains(index) else {
                    return LocalAdjustment()[keyPath: keyPath]
                }
                return model.editStack.localAdjustments[index][keyPath: keyPath]
            },
            set: { newValue in
                guard model.editStack.localAdjustments.indices.contains(index) else { return }
                model.editStack.localAdjustments[index][keyPath: keyPath] = newValue
            }
        )
    }

    private func binding<T>(
        for id: UUID, _ keyPath: WritableKeyPath<LocalAdjustment, T>
    ) -> Binding<T> {
        Binding(
            get: {
                guard let index = model.editStack.localAdjustments.firstIndex(where: { $0.id == id })
                else { return LocalAdjustment()[keyPath: keyPath] }
                return model.editStack.localAdjustments[index][keyPath: keyPath]
            },
            set: { newValue in
                guard let index = model.editStack.localAdjustments.firstIndex(where: { $0.id == id })
                else { return }
                model.editStack.localAdjustments[index][keyPath: keyPath] = newValue
            }
        )
    }
}
