import SwiftUI

/// Black-and-white treatment plus the per-hue-band color mixer.
struct ColorMixerPanel: View {
    @Bindable var model: EditorModel

    @State private var selectedBand: HueBand = .red

    private var isBlackAndWhite: Bool {
        model.editStack.color.treatment == .blackAndWhite
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TabStrip(
                options: Treatment.allCases.map { ($0, $0.displayName) },
                selection: $model.editStack.color.treatment
            )

            bandPicker

            if isBlackAndWhite {
                AdjustmentSlider(
                    title: "\(selectedBand.displayName) Response",
                    value: blackAndWhiteBinding,
                    range: -100...100, format: "%.0f", neutral: 0
                )
                Text("Brightens or darkens whatever was this color, the way a "
                     + "colored filter does on B&W film.")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
            } else {
                AdjustmentSlider(title: "Hue", value: bandBinding(\.hue),
                                 range: -100...100, format: "%.0f", neutral: 0)
                AdjustmentSlider(title: "Saturation", value: bandBinding(\.saturation),
                                 range: -100...100, format: "%.0f", neutral: 0)
                AdjustmentSlider(title: "Luminance", value: bandBinding(\.luminance),
                                 range: -100...100, format: "%.0f", neutral: 0)
            }
        }
    }

    /// Swatches for each band, marked when that band has been adjusted.
    private var bandPicker: some View {
        HStack(spacing: 4) {
            ForEach(HueBand.allCases) { band in
                let isSelected = band == selectedBand
                Button {
                    selectedBand = band
                } label: {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(swatchColor(for: band))
                        .frame(height: 22)
                        .overlay {
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(isSelected ? Theme.text : .clear, lineWidth: 1.5)
                        }
                        .overlay(alignment: .bottom) {
                            if isAdjusted(band) {
                                Circle()
                                    .fill(.white)
                                    .frame(width: 4, height: 4)
                                    .padding(.bottom, 3)
                            }
                        }
                }
                .buttonStyle(.plain)
                .help(band.displayName)
            }
        }
    }

    private func swatchColor(for band: HueBand) -> Color {
        let rgb = ColorScience.hslToRGB(band.centerHue, 0.85, 0.5)
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    private func isAdjusted(_ band: HueBand) -> Bool {
        isBlackAndWhite
            ? model.editStack.color.mixer.blackAndWhiteWeight(band) != 0
            : !model.editStack.color.mixer[band].isNeutral
    }

    private func bandBinding(_ keyPath: WritableKeyPath<HSLAdjustment, Double>) -> Binding<Double> {
        Binding(
            get: { model.editStack.color.mixer[selectedBand][keyPath: keyPath] },
            set: { model.editStack.color.mixer[selectedBand][keyPath: keyPath] = $0 }
        )
    }

    private var blackAndWhiteBinding: Binding<Double> {
        Binding(
            get: { model.editStack.color.mixer.blackAndWhiteWeight(selectedBand) },
            set: { model.editStack.color.mixer.setBlackAndWhiteWeight($0, for: selectedBand) }
        )
    }
}

/// Three-way color grading: shadows, midtones, and highlights.
struct ColorGradingPanel: View {
    @Bindable var model: EditorModel

    @State private var selectedZone: Zone = .midtones

    enum Zone: String, CaseIterable, Identifiable {
        case shadows, midtones, highlights
        var id: String { rawValue }
        var displayName: String { rawValue.capitalized }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TabStrip(
                options: Zone.allCases.map { ($0, $0.displayName) },
                selection: $selectedZone
            )

            AdjustmentSlider(title: "Hue", value: zoneBinding(\.hue),
                             range: 0...360, format: "%.0f°", neutral: 0)
            AdjustmentSlider(title: "Saturation", value: zoneBinding(\.saturation),
                             range: 0...100, format: "%.0f", neutral: 0)
            AdjustmentSlider(title: "Luminance", value: zoneBinding(\.luminance),
                             range: -100...100, format: "%.0f", neutral: 0)

            Rectangle().fill(Theme.separator).frame(height: Theme.hairline)

            AdjustmentSlider(title: "Blending",
                             value: $model.editStack.color.grading.blending,
                             range: 0...100, format: "%.0f", neutral: 50)
            AdjustmentSlider(title: "Balance",
                             value: $model.editStack.color.grading.balance,
                             range: -100...100, format: "%.0f", neutral: 0)
        }
    }

    private func zoneBinding(
        _ keyPath: WritableKeyPath<ColorGradeZone, Double>
    ) -> Binding<Double> {
        let zonePath: WritableKeyPath<ColorGrading, ColorGradeZone> = switch selectedZone {
        case .shadows: \.shadows
        case .midtones: \.midtones
        case .highlights: \.highlights
        }
        return Binding(
            get: { model.editStack.color.grading[keyPath: zonePath][keyPath: keyPath] },
            set: { model.editStack.color.grading[keyPath: zonePath][keyPath: keyPath] = $0 }
        )
    }
}
