import SwiftUI

/// The Retouch section: place heal/clone spots, list them, and shape the
/// selected one.
///
/// The flow mirrors the darkroom's spotting brush: choose heal or clone, add
/// a spot by clicking the defect on the photo, then drag the on-canvas
/// circles — solid is the repair, dashed is where the pixels come from.
struct RetouchPanel: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.controlSpacing) {
            HStack(spacing: 12) {
                TabStrip(
                    options: [(RetouchSpot.Mode.heal, "Heal"), (.clone, "Clone")],
                    selection: $model.retouchMode
                )
                Spacer()
                PlateButton(title: model.canvasPicker == .retouchPlace
                            ? "Click the photo…" : "Add Spot") {
                    model.canvasPicker = model.canvasPicker == .retouchPlace
                        ? nil : .retouchPlace
                }
            }

            if model.editStack.retouch.isEmpty {
                Text("Heal matches the patch to its surroundings — dust and "
                     + "scratches on a scan. Clone copies exactly — repeating "
                     + "texture like brick or fabric.")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
            } else {
                spotList

                if let index = model.selectedSpotIndex {
                    spotControls(at: index)
                }
            }
        }
    }

    private var spotList: some View {
        VStack(spacing: 2) {
            ForEach(Array(model.editStack.retouch.enumerated()), id: \.element.id) { index, spot in
                let isSelected = spot.id == model.selectedSpotID
                HStack(spacing: 8) {
                    Text(String(format: "%02d", index + 1))
                        .font(Theme.indexFont)
                        .foregroundStyle(isSelected ? Theme.accent : Theme.tertiaryText)

                    Text(spot.mode == .heal ? "HEAL" : "CLONE")
                        .font(Theme.plateFont)
                        .kerning(Theme.plateTracking)
                        .foregroundStyle(Theme.text.opacity(spot.isEnabled ? 0.9 : 0.4))

                    Spacer()

                    LampToggle(label: "", isOn: binding(for: spot.id, \.isEnabled))

                    GlyphButton(kind: .cross, label: "Delete spot") {
                        model.removeRetouchSpot(id: spot.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(isSelected ? Theme.control : .clear)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    model.selectedSpotID = isSelected ? nil : spot.id
                }
            }
        }
    }

    @ViewBuilder
    private func spotControls(at index: Int) -> some View {
        Rectangle().fill(Theme.separator).frame(height: Theme.hairline)

        TabStrip(
            options: [(RetouchSpot.Mode.heal, "Heal"), (.clone, "Clone")],
            selection: spotBinding(index, \.mode)
        )

        AdjustmentSlider(title: "Size",
                         value: spotBinding(index, \.radius),
                         range: 0.004...0.15, format: "%.3f", neutral: 0.025)
        AdjustmentSlider(title: "Feather",
                         value: spotBinding(index, \.feather),
                         range: 0...1, format: "%.2f", neutral: 0.5)

        Text("Drag the solid circle to move the repair; drag the dashed "
             + "circle to choose where its pixels come from.")
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Theme.secondaryText)
    }

    // MARK: Bindings

    private func spotBinding<T>(
        _ index: Int, _ keyPath: WritableKeyPath<RetouchSpot, T>
    ) -> Binding<T> {
        Binding(
            get: {
                guard model.editStack.retouch.indices.contains(index) else {
                    return RetouchSpot()[keyPath: keyPath]
                }
                return model.editStack.retouch[index][keyPath: keyPath]
            },
            set: { newValue in
                guard model.editStack.retouch.indices.contains(index) else { return }
                model.editStack.retouch[index][keyPath: keyPath] = newValue
            }
        )
    }

    private func binding<T>(
        for id: UUID, _ keyPath: WritableKeyPath<RetouchSpot, T>
    ) -> Binding<T> {
        Binding(
            get: {
                guard let index = model.editStack.retouch.firstIndex(where: { $0.id == id })
                else { return RetouchSpot()[keyPath: keyPath] }
                return model.editStack.retouch[index][keyPath: keyPath]
            },
            set: { newValue in
                guard let index = model.editStack.retouch.firstIndex(where: { $0.id == id })
                else { return }
                model.editStack.retouch[index][keyPath: keyPath] = newValue
            }
        )
    }
}
