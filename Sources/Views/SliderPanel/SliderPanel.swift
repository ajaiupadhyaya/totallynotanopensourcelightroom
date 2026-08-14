import SwiftUI

/// The develop column: histogram on top, then every adjustment group as a
/// numbered, collapsible ``PanelSection``.
///
/// The stage numbers are the order of the render pipeline itself — film
/// conversion first, effects last — so the column reads as the signal chain
/// it actually is. Snapshots, presets, and info follow unnumbered: they are
/// catalog features, not pipeline stages, and the numbering stays honest by
/// excluding them.
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
                if model.editStack.processVersion < 2 {
                    PanelSection("Process") {
                        // One line, text face (monospace means DATA — the
                        // design law this prose broke); the full story lives
                        // in the tooltip.
                        HStack(spacing: Theme.space2) {
                            Text("Original develop engine")
                                .font(Theme.caption)
                                .foregroundStyle(Theme.secondaryText)
                            Spacer()
                            PlateButton(title: "Update") {
                                model.upgradeToProcessVersion2()
                            }
                        }
                        .help("Slider values are kept — only the engine changes, "
                              + "and the current look stays one click away in Snapshots.")
                    }
                }

                PanelGroupHeading(title: "The frame")

                PanelSection(
                    "Film",
                    index: "01",
                    isModified: PipelineSection.film.isModified(in: model.editStack),
                    onReset: { model.editStack.filmNegative = FilmNegativeSettings() }
                ) {
                    FilmPanel(model: model)
                }

                PanelSection(
                    "Frame",
                    index: "02",
                    isModified: PipelineSection.frame.isModified(in: model.editStack),
                    onReset: resetFrame
                ) {
                    GeometryPanel(model: model)
                }

                PanelSection(
                    "Optics",
                    index: "03",
                    isModified: PipelineSection.optics.isModified(in: model.editStack),
                    onReset: resetOptics
                ) {
                    OpticsPanel(model: model)
                }

                PanelSection(
                    "Retouch",
                    index: "04",
                    isModified: PipelineSection.retouch.isModified(in: model.editStack),
                    onReset: {
                        model.editStack.retouch = []
                        model.selectedSpotID = nil
                    }
                ) {
                    RetouchPanel(model: model)
                }

                PanelGroupHeading(title: "Tone")

                PanelSection(
                    "White Balance",
                    index: "05",
                    isModified: PipelineSection.whiteBalance.isModified(in: model.editStack),
                    onReset: {
                        model.editStack.whiteBalanceTemp = 6500
                        model.editStack.whiteBalanceTint = 0
                    }
                ) {
                    WhiteBalancePanel(model: model)
                }

                PanelSection("Light", index: "06",
                             isModified: PipelineSection.light.isModified(in: model.editStack),
                             onReset: resetLight) {
                    AdjustmentSlider(title: "Exposure",
                                     value: $model.editStack.exposure,
                                     range: -3...3, format: "%.2f EV", neutral: 0)
                    // Raw Boost is CIRAWFilter.boostAmount, so it only exists
                    // on the sensor-domain branch — the same condition that
                    // gates the white balance picker. A PV1 RAW (decoded at
                    // Apple's defaults) or a film-negative scan never reaches
                    // the filter, and the slider would move nothing.
                    if model.isSensorDomainWB {
                        AdjustmentSlider(title: "Raw Boost",
                                         value: $model.editStack.rawBoost,
                                         range: 0...100, format: "%.0f", neutral: 100)
                    }
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

                PanelSection("Presence", index: "07",
                             isModified: PipelineSection.presence.isModified(in: model.editStack),
                             onReset: resetPresence) {
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

                PanelGroupHeading(title: "Colour")

                PanelSection(
                    "Color Mixer",
                    index: "08",
                    isModified: PipelineSection.colorMixer.isModified(in: model.editStack),
                    onReset: {
                        model.editStack.color.treatment = .color
                        model.editStack.color.mixer = ColorMixer()
                    }
                ) {
                    ColorMixerPanel(model: model)
                }

                PanelSection(
                    "Color Grade",
                    index: "09",
                    isModified: PipelineSection.colorGrade.isModified(in: model.editStack),
                    onReset: { model.editStack.color.grading = ColorGrading() }
                ) {
                    ColorGradingPanel(model: model)
                }

                PanelSection(
                    "Point Color",
                    index: "10",
                    isModified: PipelineSection.pointColor.isModified(in: model.editStack),
                    onReset: { model.editStack.color.pointColors = [] }
                ) {
                    PointColorPanel(model: model)
                }

                PanelSection(
                    "Tone Curve",
                    index: "11",
                    isModified: PipelineSection.toneCurve.isModified(in: model.editStack),
                    onReset: {
                        model.editStack.toneCurvePoints = []
                        model.editStack.color.channelCurves = ChannelCurves()
                        model.editStack.toneCurveHighlights = 0
                        model.editStack.toneCurveLights = 0
                        model.editStack.toneCurveDarks = 0
                        model.editStack.toneCurveShadows = 0
                    }
                ) {
                    CurvePanel(model: model)
                }

                PanelGroupHeading(title: "Local & finish")

                PanelSection(
                    "Local Masks",
                    index: "12",
                    isModified: PipelineSection.masks.isModified(in: model.editStack),
                    onReset: { model.editStack.localAdjustments = [] }
                ) {
                    LocalAdjustmentPanel(model: model)
                }

                PanelSection("Detail", index: "13",
                             isModified: PipelineSection.detail.isModified(in: model.editStack),
                             onReset: resetDetail) {
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

                PanelSection("Effects", index: "14",
                             isModified: PipelineSection.effects.isModified(in: model.editStack),
                             onReset: resetEffects) {
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
                    AdjustmentSlider(title: "Vignette Roundness",
                                     value: $model.editStack.vignetteRoundness,
                                     range: -100...100, format: "%.0f", neutral: 0)
                    AdjustmentSlider(title: "Vignette Feather",
                                     value: $model.editStack.vignetteFeather,
                                     range: 0...100, format: "%.0f", neutral: 50)
                    AdjustmentSlider(title: "Vignette Highlights",
                                     value: $model.editStack.vignetteHighlights,
                                     range: 0...100, format: "%.0f", neutral: 0)
                }

                // Below the chain: things about this frame in the catalog,
                // deliberately unnumbered because they are not pipeline stages.
                PanelGroupHeading(title: "This frame")

                PanelSection("Snapshots") {
                    SnapshotPanel(model: model)
                }

                PanelSection("Presets") {
                    PresetPanel(app: app, model: model)
                }

                PanelSection("Info") {
                    MetadataPanel(metadata: model.metadata, fileName: model.fileName)
                }

                PlateButton(title: "Reset all adjustments",
                            isEnabled: !model.editStack.isNeutralEdit,
                            fillsWidth: true) {
                    model.resetAdjustments()
                }
                .padding(.horizontal, Theme.panelInset)
                .padding(.top, Theme.space5)
                .padding(.bottom, Theme.space6)
            }
        }
        .scrollIndicators(.automatic)
        .background(Theme.surface)
    }

    // MARK: Section state


    private func resetFrame() {
        model.editStack.geometry.cropRect = .unitFrame
        model.editStack.geometry.rotation = .none
        model.editStack.geometry.straightenAngle = 0
        model.editStack.geometry.flipHorizontal = false
        model.editStack.geometry.flipVertical = false
    }


    private func resetOptics() {
        model.editStack.geometry.distortion = 0
        model.editStack.geometry.perspectiveVertical = 0
        model.editStack.geometry.perspectiveHorizontal = 0
        model.editStack.defringe = Defringe()
    }


    private func resetLight() {
        model.editStack.exposure = 0
        model.editStack.contrast = 0
        model.editStack.highlights = 0
        model.editStack.shadows = 0
        model.editStack.whites = 0
        model.editStack.blacks = 0
        model.editStack.rawBoost = 100
    }


    private func resetPresence() {
        model.editStack.texture = 0
        model.editStack.clarity = 0
        model.editStack.dehaze = 0
        model.editStack.vibrance = 0
        model.editStack.saturation = 0
    }


    private func resetDetail() {
        model.editStack.sharpenAmount = 0
        model.editStack.sharpenRadius = 1.5
        model.editStack.luminanceNoiseReduction = 0
        model.editStack.colorNoiseReduction = 0
    }


    private func resetEffects() {
        model.editStack.vignetteAmount = 0
        model.editStack.vignetteMidpoint = 50
        model.editStack.vignetteRoundness = 0
        model.editStack.vignetteFeather = 50
        model.editStack.vignetteHighlights = 0
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

        PlateButton(title: model.canvasPicker == .whiteBalance
                    ? "Click a neutral in the photo…"
                    : "Pick Neutral",
                    isEnabled: !model.isSensorDomainWB) {
            model.canvasPicker = model.canvasPicker == .whiteBalance ? nil : .whiteBalance
        }

        if model.isSensorDomainWB {
            Text("On a RAW photo these two drive the camera's own white "
                 + "balance, in the sensor's units. The neutral picker "
                 + "estimates in a different unit system, so it stays off "
                 + "here rather than move the photograph the wrong way.")
                .font(Theme.body)
                .foregroundStyle(Theme.secondaryText)
        }
    }
}
