import SwiftUI

struct PointColorPanel: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.controlSpacing) {
            HStack {
                PlateButton(title: "+ Target") {
                    model.editStack.color.pointColors.append(PointColorTarget())
                }
                Spacer()
            }

            if model.editStack.color.pointColors.isEmpty {
                Text("Sample colours on the photograph, then shift their hue, saturation, and luminance within a chosen range.")
                    .font(Theme.readableFont)
                    .foregroundStyle(Theme.secondaryText)
            } else {
                ForEach(Array(model.editStack.color.pointColors.enumerated()), id: \.element.id) { index, _ in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Rectangle()
                                .fill(Color(red: target(index).red,
                                            green: target(index).green,
                                            blue: target(index).blue))
                                .frame(width: 18, height: 12)
                            Text("TARGET \(index + 1)").engraved()
                            Spacer()
                            PlateButton(title: model.canvasPicker == .pointColorSample
                                        && model.pointColorSampleIndex == index
                                        ? "Click…" : "Sample") {
                                if model.canvasPicker == .pointColorSample
                                    && model.pointColorSampleIndex == index {
                                    model.canvasPicker = nil
                                    model.pointColorSampleIndex = nil
                                } else {
                                    model.pointColorSampleIndex = index
                                    model.canvasPicker = .pointColorSample
                                }
                            }
                            GlyphButton(kind: .cross, label: "Remove target") {
                                model.editStack.color.pointColors.remove(at: index)
                            }
                        }
                        AdjustmentSlider(title: "Hue", value: binding(index, \.hue),
                                         range: -100...100, format: "%.0f", neutral: 0)
                        AdjustmentSlider(title: "Saturation", value: binding(index, \.saturation),
                                         range: -100...100, format: "%.0f", neutral: 0)
                        AdjustmentSlider(title: "Luminance", value: binding(index, \.luminance),
                                         range: -100...100, format: "%.0f", neutral: 0)
                        AdjustmentSlider(title: "Range", value: binding(index, \.range),
                                         range: 0.01...0.5, format: "%.2f", neutral: 0.15)
                    }
                    Rectangle().fill(Theme.separator).frame(height: Theme.hairline)
                }
            }
        }
    }

    private func target(_ index: Int) -> PointColorTarget {
        model.editStack.color.pointColors[index]
    }

    private func binding(
        _ index: Int, _ keyPath: WritableKeyPath<PointColorTarget, Double>
    ) -> Binding<Double> {
        Binding(
            get: { model.editStack.color.pointColors[index][keyPath: keyPath] },
            set: { model.editStack.color.pointColors[index][keyPath: keyPath] = $0 }
        )
    }
}
