import SwiftUI

/// The develop panel: histogram on top, then every adjustment group as a
/// collapsible ``PanelSection``.
///
/// Each section knows whether it carries non-neutral edits (the dot in its
/// header) and can reset just itself — so state is visible even when folded,
/// and recovery is local rather than all-or-nothing.
struct SliderPanel: View {
    @Bindable var model: EditorModel
    @Bindable var app: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HistogramView(histogram: model.histogram)
                    .padding(.horizontal, Theme.panelInset)
                    .padding(.vertical, 12)

                PanelSection(
                    "Film",
                    isModified: model.editStack.filmNegative != FilmNegativeSettings(),
                    onReset: { model.editStack.filmNegative = FilmNegativeSettings() }
                ) {
                    FilmPanel(model: model)
                }

                PanelSection(
                    "Crop & Rotate",
                    isModified: !model.editStack.geometry.isIdentity,
                    onReset: { model.editStack.geometry = Geometry() }
                ) {
                    GeometryPanel(model: model)
                }

                PanelSection("Light", isModified: isLightModified, onReset: resetLight) {
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

                PanelSection(
                    "White Balance",
                    isModified: model.editStack.whiteBalanceTemp != 6500
                        || model.editStack.whiteBalanceTint != 0,
                    onReset: {
                        model.editStack.whiteBalanceTemp = 6500
                        model.editStack.whiteBalanceTint = 0
                    }
                ) {
                    WhiteBalancePanel(model: model)
                }

                PanelSection("Presence", isModified: isPresenceModified, onReset: resetPresence) {
                    AdjustmentSlider(title: "Texture",
                                     value: $model.editStack.texture,
                                     range: -100...100, format: "%.0f", neutral: 0)
                    AdjustmentSlider(title: "Clarity",
                                     value: $model.editStack.clarity,
                                     range: -100...100, format: "%.0f", neutral: 0)
                    AdjustmentSlider(title: "Dehaze",
                                     value: $model.editStack.dehaze,
                                     range: -100...100, format: "%.0f", neutral: 0)
                    AdjustmentSlider(title: "Vibrance",
                                     value: $model.editStack.vibrance,
                                     range: -100...100, format: "%.0f", neutral: 0)
                    AdjustmentSlider(title: "Saturation",
                                     value: $model.editStack.saturation,
                                     range: -100...100, format: "%.0f", neutral: 0)
                }

                PanelSection(
                    "Color Mixer",
                    isModified: model.editStack.color.treatment != .color
                        || !model.editStack.color.mixer.isNeutral,
                    onReset: {
                        model.editStack.color.treatment = .color
                        model.editStack.color.mixer = ColorMixer()
                    }
                ) {
                    ColorMixerPanel(model: model)
                }

                PanelSection(
                    "Color Grading",
                    isModified: !model.editStack.color.grading.isNeutral,
                    onReset: { model.editStack.color.grading = ColorGrading() }
                ) {
                    ColorGradingPanel(model: model)
                }

                PanelSection(
                    "Tone Curve",
                    isModified: !model.editStack.toneCurvePoints.isEmpty
                        || !model.editStack.color.channelCurves.isNeutral,
                    onReset: {
                        model.editStack.toneCurvePoints = []
                        model.editStack.color.channelCurves = ChannelCurves()
                    }
                ) {
                    CurvePanel(model: model)
                }

                PanelSection(
                    "Local Adjustments",
                    isModified: !model.editStack.localAdjustments.isEmpty,
                    onReset: { model.editStack.localAdjustments = [] }
                ) {
                    LocalAdjustmentPanel(model: model)
                }

                PanelSection("Detail", isModified: isDetailModified, onReset: resetDetail) {
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

                PanelSection("Effects", isModified: isEffectsModified, onReset: resetEffects) {
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

                PanelSection("Presets") {
                    PresetPanel(app: app, model: model)
                }

                PanelSection("Info") {
                    MetadataPanel(metadata: model.metadata, fileName: model.fileName)
                }

                Button("Reset All Adjustments") {
                    model.resetAdjustments()
                }
                .font(Theme.controlFont)
                .disabled(model.editStack == EditStack())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
        }
        .background(Theme.surface)
    }

    // MARK: Section state

    private var isLightModified: Bool {
        let s = model.editStack
        return s.exposure != 0 || s.contrast != 0 || s.highlights != 0
            || s.shadows != 0 || s.whites != 0 || s.blacks != 0
    }

    private func resetLight() {
        model.editStack.exposure = 0
        model.editStack.contrast = 0
        model.editStack.highlights = 0
        model.editStack.shadows = 0
        model.editStack.whites = 0
        model.editStack.blacks = 0
    }

    private var isPresenceModified: Bool {
        let s = model.editStack
        return s.texture != 0 || s.clarity != 0 || s.dehaze != 0
            || s.vibrance != 0 || s.saturation != 0
    }

    private func resetPresence() {
        model.editStack.texture = 0
        model.editStack.clarity = 0
        model.editStack.dehaze = 0
        model.editStack.vibrance = 0
        model.editStack.saturation = 0
    }

    private var isDetailModified: Bool {
        let s = model.editStack
        return s.sharpenAmount != 0 || s.sharpenRadius != 1.5
            || s.luminanceNoiseReduction != 0 || s.colorNoiseReduction != 0
    }

    private func resetDetail() {
        model.editStack.sharpenAmount = 0
        model.editStack.sharpenRadius = 1.5
        model.editStack.luminanceNoiseReduction = 0
        model.editStack.colorNoiseReduction = 0
    }

    private var isEffectsModified: Bool {
        let s = model.editStack
        return s.vignetteAmount != 0 || s.vignetteMidpoint != 50
            || s.grainAmount != 0 || s.grainSize != 25
    }

    private func resetEffects() {
        model.editStack.vignetteAmount = 0
        model.editStack.vignetteMidpoint = 50
        model.editStack.grainAmount = 0
        model.editStack.grainSize = 25
    }
}

/// White balance sliders plus the neutral picker.
struct WhiteBalancePanel: View {
    @Bindable var model: EditorModel

    var body: some View {
        AdjustmentSlider(title: "Temperature",
                         value: $model.editStack.whiteBalanceTemp,
                         range: 2000...10000, format: "%.0f K", neutral: 6500)
        AdjustmentSlider(title: "Tint",
                         value: $model.editStack.whiteBalanceTint,
                         range: -100...100, format: "%.0f", neutral: 0)

        Button {
            model.canvasPicker = model.canvasPicker == .whiteBalance ? nil : .whiteBalance
        } label: {
            Label(model.canvasPicker == .whiteBalance
                  ? "Click a neutral in the photo…"
                  : "Pick Neutral",
                  systemImage: "eyedropper")
                .font(Theme.controlFont)
        }
        .controlSize(.small)
        .help("Click something that should be gray; temperature and tint are set to neutralize it")
    }
}
