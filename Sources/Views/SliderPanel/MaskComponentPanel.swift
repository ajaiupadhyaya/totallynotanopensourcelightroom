import SwiftUI

/// The pieces the selected mask is built from, in the order they fold
/// together. A selection is read top to bottom: the first row starts it, each
/// row after it adds to, cuts from, or narrows what came before.
struct MaskComponentList: View {
    @Bindable var model: EditorModel
    let maskIndex: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(components.enumerated()), id: \.element.id) { position, component in
                row(component, isFirst: position == 0)
            }
            addRow
        }
    }

    private var components: [MaskComponent] {
        model.editStack.localAdjustments[maskIndex].components
    }

    private func row(_ component: MaskComponent, isFirst: Bool) -> some View {
        let isSelected = component.id == model.selectedComponentID
        return HStack(spacing: 8) {
            // The first component starts the selection, so its combine mode
            // would be a lie — show a neutral marker instead.
            Text(isFirst ? "·" : glyph(component.combine))
                .font(Theme.valueFont)
                .foregroundStyle(isFirst ? Theme.tertiaryText : Theme.accent)
                .frame(width: 12)

            Text(component.displayName.uppercased())
                .font(Theme.sectionTitle)
                .kerning(Theme.sectionTracking)
                .foregroundStyle(isSelected ? Theme.text : Theme.secondaryText)

            Spacer()

            Button {
                model.editStack.localAdjustments[maskIndex]
                    .components[indexOf(component)].isEnabled.toggle()
            } label: {
                Circle()
                    .fill(component.isEnabled ? Theme.accent : Theme.separator)
                    .frame(width: 6, height: 6)
            }
            .buttonStyle(.plain)
            .help(component.isEnabled ? "Disable this piece" : "Enable this piece")

            Button {
                model.removeMaskComponent(id: component.id)
            } label: {
                Text("×").font(Theme.valueFont).foregroundStyle(Theme.tertiaryText)
            }
            .buttonStyle(.plain)
            .help("Remove this piece")
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(isSelected ? Theme.control : .clear)
        .contentShape(Rectangle())
        .onTapGesture { model.selectedComponentID = component.id }
    }

    private var addRow: some View {
        HStack(spacing: 6) {
            Text("ADD").sectionLabel()
            PlateButton(title: "Lum") { model.addMaskComponent(.luminance) }
            PlateButton(title: "Color") { model.addMaskComponent(.colorRange) }
            PlateButton(title: "Grad") { model.addMaskComponent(.linear) }
            PlateButton(title: "Rad") { model.addMaskComponent(.radial) }
            PlateButton(title: "Brush") { model.addMaskComponent(.brush) }
            PlateButton(title: "Subj") { model.addMaskComponent(.subject) }
            PlateButton(title: "Sky") { model.addMaskComponent(.sky) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func glyph(_ combine: MaskComponent.Combine) -> String {
        switch combine {
        case .add: "+"
        case .subtract: "−"
        case .intersect: "∩"
        }
    }

    private func indexOf(_ component: MaskComponent) -> Int {
        components.firstIndex { $0.id == component.id } ?? 0
    }
}

/// Controls for the selected component. Only one component's controls are on
/// screen at a time — the inspector is 320pt wide and a list of every piece's
/// parameters would not fit or read.
struct MaskComponentControls: View {
    @Bindable var model: EditorModel
    let maskIndex: Int

    var body: some View {
        if let index = model.selectedComponentIndex {
            VStack(alignment: .leading, spacing: 8) {
                combineRow(index)
                shapeControls(index)
                refineControls(index)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
    }

    private func binding(
        _ index: Int, _ keyPath: WritableKeyPath<MaskComponent, Double>
    ) -> Binding<Double> {
        Binding(
            get: { model.editStack.localAdjustments[maskIndex].components[index][keyPath: keyPath] },
            set: { model.editStack.localAdjustments[maskIndex].components[index][keyPath: keyPath] = $0 }
        )
    }

    private func component(_ index: Int) -> MaskComponent {
        model.editStack.localAdjustments[maskIndex].components[index]
    }

    private func combineRow(_ index: Int) -> some View {
        HStack(spacing: 6) {
            Text("MODE").sectionLabel()
            ForEach(MaskComponent.Combine.allCases, id: \.self) { mode in
                PlateButton(title: label(mode),
                            isEnabled: true) {
                    model.editStack.localAdjustments[maskIndex].components[index].combine = mode
                }
            }
            Spacer()
            PlateButton(title: component(index).isInverted ? "Inverted" : "Invert") {
                model.editStack.localAdjustments[maskIndex].components[index].isInverted.toggle()
            }
        }
    }

    private func label(_ mode: MaskComponent.Combine) -> String {
        switch mode {
        case .add: "Add"
        case .subtract: "Subtract"
        case .intersect: "Intersect"
        }
    }

    @ViewBuilder
    private func shapeControls(_ index: Int) -> some View {
        switch component(index).shape {
        case .luminance:
            LuminanceRangeControl(histogram: model.histogram,
                                  lower: binding(index, \.luminanceMin),
                                  upper: binding(index, \.luminanceMax))
            AdjustmentSlider(title: "Falloff", value: binding(index, \.luminanceFalloff),
                             range: 0.01...0.5, format: "%.2f", neutral: 0.15)
        case .colorRange:
            HStack(spacing: 8) {
                Text("SAMPLE").sectionLabel()
                swatch(index)
                PlateButton(title: model.canvasPicker == .colorRangeSample
                            ? "Click the photo" : "Sample") {
                    model.canvasPicker = .colorRangeSample
                }
            }
            AdjustmentSlider(title: "Tolerance", value: binding(index, \.colorTolerance),
                             range: 0.01...1, format: "%.2f", neutral: 0.25)
            AdjustmentSlider(title: "Falloff", value: binding(index, \.colorFalloff),
                             range: 0.01...0.5, format: "%.2f", neutral: 0.15)
        case .subject, .person, .background, .sky:
            Text("Generated on-device from the photograph. Refine with blur and expand.")
                .font(Theme.body)
                .foregroundStyle(Theme.secondaryText)
        case .radial:
            AdjustmentSlider(title: "Feather", value: binding(index, \.feather),
                             range: 0...1, format: "%.2f", neutral: 0.5)
        case .brush:
            AdjustmentSlider(title: "Size", value: binding(index, \.brushSize),
                             range: 0.005...0.2, format: "%.3f", neutral: 0.04)
            AdjustmentSlider(title: "Feather", value: binding(index, \.brushFeather),
                             range: 0...1, format: "%.2f", neutral: 0.65)
            AdjustmentSlider(title: "Flow", value: binding(index, \.brushFlow),
                             range: 0.05...1, format: "%.2f", neutral: 0.8)
        case .linear:
            Text("Drag the on-canvas pins to place the gradient")
                .font(Theme.body)
                .foregroundStyle(Theme.secondaryText)
        }
    }

    private func swatch(_ index: Int) -> some View {
        let sampled = component(index).sampledColor
        return Rectangle()
            .fill(sampled.map {
                Color(red: $0.red, green: $0.green, blue: $0.blue)
            } ?? Color.clear)
            .frame(width: 22, height: 14)
            .overlay(Rectangle().stroke(Theme.separator, lineWidth: Theme.hairline))
    }

    private func refineControls(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            AdjustmentSlider(title: "Refine Blur",
                             value: binding(index, \.refine.blur),
                             range: 0...1, format: "%.2f", neutral: 0)
            AdjustmentSlider(title: "Expand",
                             value: binding(index, \.refine.shift),
                             range: -1...1, format: "%.2f", neutral: 0)
        }
    }
}

/// The luminance band drawn over the photograph's own tone distribution.
///
/// A band picked against numbers alone is guesswork. Against the histogram you
/// can see which tones you are actually selecting — which is the whole reason
/// the control exists rather than two more faders.
private struct LuminanceRangeControl: View {
    let histogram: Histogram
    @Binding var lower: Double
    @Binding var upper: Double

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.black.opacity(0.85))

                if !histogram.isEmpty {
                    Path { path in
                        let bins = histogram.green
                        let peak = CGFloat(histogram.peak)
                        for (index, value) in bins.enumerated() {
                            let x = width * CGFloat(index) / CGFloat(max(bins.count - 1, 1))
                            let y = height - height * CGFloat(value) / peak
                            if index == 0 {
                                path.move(to: CGPoint(x: x, y: y))
                            } else {
                                path.addLine(to: CGPoint(x: x, y: y))
                            }
                        }
                    }
                    .stroke(Theme.secondaryText, lineWidth: 1)
                }

                Rectangle()
                    .fill(Theme.accent.opacity(0.22))
                    .frame(width: max(width * CGFloat(upper - lower), 1))
                    .offset(x: width * CGFloat(lower))

                handle(at: lower, width: width, height: height) {
                    lower = min(max($0, 0), upper)
                }
                handle(at: upper, width: width, height: height) {
                    upper = min(max($0, lower), 1)
                }
            }
        }
        .frame(height: 54)
    }

    /// A hairline marker with a wider invisible grab area — one pixel is not
    /// a pointer target.
    private func handle(
        at position: Double, width: CGFloat, height: CGFloat,
        set: @escaping (Double) -> Void
    ) -> some View {
        Color.clear
            .frame(width: 16, height: height)
            .contentShape(Rectangle())
            .overlay(Rectangle().fill(Theme.accent).frame(width: 1))
            .offset(x: width * CGFloat(position) - 8)
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    let x = value.location.x + width * CGFloat(position) - 8
                    set(Double(min(max(x / width, 0), 1)))
                }
            )
    }
}
