import SwiftUI

/// The right-hand adjustment panel: a live histogram on top, then grouped
/// adjustment controls, and finally the tone-curve editor. Every control binds
/// directly into the model's ``EditStack``, so changing one drives a live,
/// non-destructive re-render.
struct SliderPanel: View {
    @Bindable var model: EditorModel
    @Bindable var app: AppModel

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

                section("Crop & Rotate") {
                    GeometryPanel(model: model)
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
                    AdjustmentSlider(title: "Whites",
                                     value: $model.editStack.whites,
                                     range: -100...100, format: "%.0f", neutral: 0)
                    AdjustmentSlider(title: "Blacks",
                                     value: $model.editStack.blacks,
                                     range: -100...100, format: "%.0f", neutral: 0)
                }

                section("Presence") {
                    AdjustmentSlider(title: "Texture",
                                     value: $model.editStack.texture,
                                     range: -100...100, format: "%.0f", neutral: 0)
                    AdjustmentSlider(title: "Clarity",
                                     value: $model.editStack.clarity,
                                     range: -100...100, format: "%.0f", neutral: 0)
                    AdjustmentSlider(title: "Dehaze",
                                     value: $model.editStack.dehaze,
                                     range: -100...100, format: "%.0f", neutral: 0)
                }

                section("Color") {
                    AdjustmentSlider(title: "Vibrance",
                                     value: $model.editStack.vibrance,
                                     range: -100...100, format: "%.0f", neutral: 0)
                    AdjustmentSlider(title: "Saturation",
                                     value: $model.editStack.saturation,
                                     range: -100...100, format: "%.0f", neutral: 0)
                }

                section("Color Mixer") {
                    ColorMixerPanel(model: model)
                }

                section("Color Grading") {
                    ColorGradingPanel(model: model)
                }

                section("Detail") {
                    AdjustmentSlider(title: "Sharpening",
                                     value: $model.editStack.sharpenAmount,
                                     range: 0...100, format: "%.0f", neutral: 0)
                    AdjustmentSlider(title: "Sharpen Radius",
                                     value: $model.editStack.sharpenRadius,
                                     range: 0.5...5, format: "%.1f px", neutral: 1.5)
                    AdjustmentSlider(title: "Luminance NR",
                                     value: $model.editStack.luminanceNoiseReduction,
                                     range: 0...100, format: "%.0f", neutral: 0)
                    AdjustmentSlider(title: "Color NR",
                                     value: $model.editStack.colorNoiseReduction,
                                     range: 0...100, format: "%.0f", neutral: 0)
                }

                section("Effects") {
                    AdjustmentSlider(title: "Vignette",
                                     value: $model.editStack.vignetteAmount,
                                     range: -100...100, format: "%.0f", neutral: 0)
                    AdjustmentSlider(title: "Vignette Midpoint",
                                     value: $model.editStack.vignetteMidpoint,
                                     range: 0...100, format: "%.0f", neutral: 50)
                    AdjustmentSlider(title: "Grain",
                                     value: $model.editStack.grainAmount,
                                     range: 0...100, format: "%.0f", neutral: 0)
                    AdjustmentSlider(title: "Grain Size",
                                     value: $model.editStack.grainSize,
                                     range: 0...100, format: "%.0f", neutral: 25)
                }

                section("Tone Curve") {
                    ToneCurveEditor(points: $model.editStack.toneCurvePoints)
                        .frame(height: 190)
                    Text("Drag a point vertically to reshape. Double-click to reset.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                section("Presets") {
                    PresetPanel(app: app, model: model)
                }

                section("Info") {
                    MetadataPanel(metadata: model.metadata, fileName: model.fileName)
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

// AdjustmentSlider lives in AdjustmentSlider.swift.
