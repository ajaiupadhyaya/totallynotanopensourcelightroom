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
                Button {
                    model.addLocalAdjustment(.linear)
                } label: {
                    Label("Linear", systemImage: "line.diagonal")
                }
                Button {
                    model.addLocalAdjustment(.radial)
                } label: {
                    Label("Radial", systemImage: "circle.dashed")
                }
                Spacer()
            }
            .controlSize(.small)
            .font(Theme.controlFont)

            if model.editStack.localAdjustments.isEmpty {
                Text("A linear gradient burns a sky the way a tilted card "
                     + "under the enlarger did; a radial dodges a face.")
                    .font(.caption)
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
                    Image(systemName: adjustment.shape == .linear
                          ? "line.diagonal" : "circle.dashed")
                        .font(.system(size: 10))
                        .foregroundStyle(isSelected ? Theme.accent : Theme.secondaryText)
                        .frame(width: 14)

                    Text(adjustment.displayName)
                        .font(Theme.controlFont)

                    Spacer()

                    Toggle("", isOn: binding(for: adjustment.id, \.isEnabled))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()

                    Button {
                        model.removeLocalAdjustment(id: adjustment.id)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 9))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.secondaryText)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background {
                    RoundedRectangle(cornerRadius: 5)
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

        Divider().overlay(Theme.separator)

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

        Toggle("Invert (apply outside the shape)",
               isOn: maskBinding(index, \.isInverted))
            .font(Theme.controlFont)
            .toggleStyle(.checkbox)

        Text("Drag the handles on the photo to place the mask.")
            .font(.caption)
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
