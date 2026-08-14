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
                    .font(Theme.body)
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
                    // The mask's leading component, drawn: a slanted line, an
                    // ellipse, or the glyph for a generated selection. The
                    // first component names the mask, as ``displayName`` does.
                    Group {
                        switch adjustment.components.first?.shape {
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
                        case .luminance:
                            Image(systemName: "circle.righthalf.filled")
                                .font(.system(size: 10, weight: .medium))
                        case .colorRange:
                            Image(systemName: "eyedropper")
                                .font(.system(size: 10, weight: .medium))
                        case .subject:
                            Image(systemName: "person.crop.rectangle")
                                .font(.system(size: 10, weight: .medium))
                        case .person:
                            Image(systemName: "figure.stand")
                                .font(.system(size: 10, weight: .medium))
                        case .background:
                            Image(systemName: "square.dashed")
                                .font(.system(size: 10, weight: .medium))
                        case .sky:
                            Image(systemName: "cloud")
                                .font(.system(size: 10, weight: .medium))
                        case nil:
                            Rectangle()
                                .stroke(style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                                .padding(1)
                        }
                    }
                    .foregroundStyle(isSelected ? Theme.accent : Theme.secondaryText)
                    .frame(width: 12, height: 12)

                    Text(adjustment.displayName)
                        .font(Theme.controlLabel)
                        .foregroundStyle(Theme.text.opacity(adjustment.isEnabled ? 0.9 : 0.4))

                    Spacer()

                    LampToggle(label: "", isOn: binding(for: adjustment.id, \.isEnabled))

                    IconButton(icon: .cross, label: "Delete mask") {
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
                    model.selectedComponentID = isSelected
                        ? nil : adjustment.components.first?.id
                }
            }
        }
    }

    /// The component whose controls this panel shows.
    private func component(_ index: Int) -> MaskComponent? {
        let components = model.editStack.localAdjustments[index].components
        guard let id = model.selectedComponentID,
              let match = components.first(where: { $0.id == id }) else { return components.first }
        return match
    }

    /// Index of the component ``componentBinding`` should address: the
    /// explicitly selected one when it still exists in this mask, otherwise
    /// the first — the same fallback ``component(_:)`` uses, so the sliders
    /// never disagree with the mask-list glyph about which component is live.
    /// `nil` only when the mask genuinely has no components left.
    private func resolvedComponentIndex(_ index: Int) -> Int? {
        let components = model.editStack.localAdjustments[index].components
        if let componentIndex = model.selectedComponentIndex,
           components.indices.contains(componentIndex) {
            return componentIndex
        }
        return components.indices.first
    }

    @ViewBuilder
    private func maskControls(at index: Int) -> some View {
        Rectangle().fill(Theme.separator).frame(height: Theme.hairline)

        MaskComponentList(model: model, maskIndex: index)
        Rectangle().fill(Theme.separator).frame(height: Theme.hairline)
        MaskComponentControls(model: model, maskIndex: index)
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

        localColorControls(at: index)

        if let selected = component(index), selected.shape == .brush {
            HStack {
                Text("\(selected.brushStrokes.count) STROKES")
                    .sectionLabel()
                Spacer()
                PlateButton(title: "Undo Stroke",
                            isEnabled: !selected.brushStrokes.isEmpty) {
                    model.removeLastBrushStroke()
                }
            }
        }

        LampToggle(label: "Invert — apply outside the shape",
                   isOn: maskBinding(index, \.isInverted))

        Text(component(index)?.shape == .brush
             ? "Drag on the photograph to paint this mask."
             : "Drag the handles on the photograph to place this mask.")
            .font(Theme.body)
            .foregroundStyle(Theme.secondaryText)
    }

    // MARK: Local color

    @ViewBuilder
    private func localColorControls(at index: Int) -> some View {
        LocalMaskColorControls(model: model, maskIndex: index)
    }

    // MARK: Bindings

    /// Addresses a property of the *selected component* of the mask at `index`.
    /// Distinct from ``maskBinding(_:_:)``, which addresses the adjustment's
    /// own corrections — the two live on different types now.
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

/// Grading, mixer, and curve controls for a masked local colour LUT.
private struct LocalMaskColorControls: View {
    @Bindable var model: EditorModel
    let maskIndex: Int

    @State private var gradingZone: ColorGradingPanel.Zone = .midtones
    @State private var mixerBand: HueBand = .red
    @State private var curveChannel: CurvePanel.Channel = .red

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.controlSpacing) {
            Text("LOCAL COLOR").sectionLabel()

            TabStrip(
                options: ColorGradingPanel.Zone.allCases.map { ($0, $0.displayName) },
                selection: $gradingZone
            )
            AdjustmentSlider(title: "Grade Hue",
                             value: localGradeBinding(\.hue),
                             range: 0...360, format: "%.0f°", neutral: 0)
            AdjustmentSlider(title: "Grade Sat",
                             value: localGradeBinding(\.saturation),
                             range: 0...100, format: "%.0f", neutral: 0)
            AdjustmentSlider(title: "Grade Lum",
                             value: localGradeBinding(\.luminance),
                             range: -100...100, format: "%.0f", neutral: 0)

            TabStrip(
                options: HueBand.allCases.map { ($0, $0.displayName) },
                selection: $mixerBand
            )
            AdjustmentSlider(title: "Mixer Hue",
                             value: localMixerBinding(\.hue),
                             range: -100...100, format: "%.0f", neutral: 0)
            AdjustmentSlider(title: "Mixer Sat",
                             value: localMixerBinding(\.saturation),
                             range: -100...100, format: "%.0f", neutral: 0)

            TabStrip(
                options: [CurvePanel.Channel.red, .green, .blue].map { ($0, $0.rawValue) },
                selection: $curveChannel
            )
            ToneCurveEditor(points: localCurveBinding, lineColor: curveChannel.color)
                .frame(height: 120)
        }
    }

    private var localCurveBinding: Binding<[CGPoint]> {
        switch curveChannel {
        case .rgb, .red:
            return Binding(
                get: { model.editStack.localAdjustments[maskIndex].color.channelCurves.red },
                set: { model.editStack.localAdjustments[maskIndex].color.channelCurves.red = $0 }
            )
        case .green:
            return Binding(
                get: { model.editStack.localAdjustments[maskIndex].color.channelCurves.green },
                set: { model.editStack.localAdjustments[maskIndex].color.channelCurves.green = $0 }
            )
        case .blue:
            return Binding(
                get: { model.editStack.localAdjustments[maskIndex].color.channelCurves.blue },
                set: { model.editStack.localAdjustments[maskIndex].color.channelCurves.blue = $0 }
            )
        }
    }

    private func localGradeBinding(
        _ keyPath: WritableKeyPath<ColorGradeZone, Double>
    ) -> Binding<Double> {
        let zonePath: WritableKeyPath<ColorGrading, ColorGradeZone> = switch gradingZone {
        case .shadows: \.shadows
        case .midtones: \.midtones
        case .highlights: \.highlights
        case .global: \.global
        }
        return Binding(
            get: {
                model.editStack.localAdjustments[maskIndex].color.grading[keyPath: zonePath][keyPath: keyPath]
            },
            set: {
                model.editStack.localAdjustments[maskIndex].color.grading[keyPath: zonePath][keyPath: keyPath] = $0
            }
        )
    }

    private func localMixerBinding(
        _ keyPath: WritableKeyPath<HSLAdjustment, Double>
    ) -> Binding<Double> {
        Binding(
            get: {
                model.editStack.localAdjustments[maskIndex].color.mixer[mixerBand][keyPath: keyPath]
            },
            set: {
                model.editStack.localAdjustments[maskIndex].color.mixer[mixerBand][keyPath: keyPath] = $0
            }
        )
    }
}
