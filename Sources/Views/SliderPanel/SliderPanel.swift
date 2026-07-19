import SwiftUI

/// The right-hand adjustment panel: a live histogram on top, then grouped
/// adjustment controls, and finally the tone-curve editor. Every control binds
/// directly into the model's ``EditStack``, so changing one drives a live,
/// non-destructive re-render.
struct SliderPanel: View {
    @Bindable var model: EditorModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HistogramView(histogram: model.histogram)

                Text(model.fileName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)

                section("Film") {
                    FilmPanel(model: model)
                }

                section("White Balance") {
                    AdjustmentSlider(title: "Temperature",
                                     value: $model.editStack.whiteBalanceTemp,
                                     range: 2000...10000, format: "%.0f K", neutral: 6500)
                    AdjustmentSlider(title: "Tint",
                                     value: $model.editStack.whiteBalanceTint,
                                     range: -100...100, format: "%.0f", neutral: 0)
                }

                section("Light") {
                    AdjustmentSlider(title: "Exposure",
                                     value: $model.editStack.exposure,
                                     range: -3...3, format: "%.2f EV", neutral: 0)
                    AdjustmentSlider(title: "Contrast",
                                     value: $model.editStack.contrast,
                                     range: -100...100, format: "%.0f", neutral: 0)
                    AdjustmentSlider(title: "Highlights",
                                     value: $model.editStack.highlights,
                                     range: -100...100, format: "%.0f", neutral: 0)
                    AdjustmentSlider(title: "Shadows",
                                     value: $model.editStack.shadows,
                                     range: -100...100, format: "%.0f", neutral: 0)
                }

                section("Color") {
                    AdjustmentSlider(title: "Saturation",
                                     value: $model.editStack.saturation,
                                     range: -100...100, format: "%.0f", neutral: 0)
                }

                section("Tone Curve") {
                    ToneCurveEditor(points: $model.editStack.toneCurvePoints)
                        .frame(height: 190)
                    Text("Drag a point vertically to reshape. Double-click to reset.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("Reset All Adjustments") {
                    model.editStack = EditStack()
                }
                .disabled(model.editStack == EditStack())
                .padding(.top, 4)
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .kerning(0.5)
            content()
        }
    }
}

/// A labeled slider that shows its current value, dims to secondary when at its
/// neutral point, and resets to neutral on a double-click.
struct AdjustmentSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String
    var neutral: Double = 0

    private var isNeutral: Bool { value == neutral }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                    .font(.subheadline)
                Spacer()
                Text(String(format: format, value))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(isNeutral ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
            }
            Slider(value: $value, in: range)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { value = neutral }
    }
}
