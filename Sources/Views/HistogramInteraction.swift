import SwiftUI

/// The five draggable histogram regions and the fields they ARE. There is no
/// mapping layer to drift: each region carries the Light panel's own key path,
/// so the histogram drag and the slider are two handles on one value.
enum HistogramRegion: CaseIterable, Equatable {
    case blacks, shadows, exposure, highlights, whites

    /// Region boundaries on the display-referred axis, left to right. The
    /// middle band is widest because Exposure is the control most drags mean.
    /// Taste constants; verified in-app.
    static let boundaries: [Double] = [0.15, 0.35, 0.65, 0.85]

    /// A full-width drag sweeps this fraction of the bound control's range —
    /// coarse enough to matter, fine enough to steer.
    static let sweepFraction = 0.5

    static func region(atUnitX x: Double) -> HistogramRegion {
        let cases = allCases
        for (index, boundary) in boundaries.enumerated() where x < boundary {
            return cases[index]
        }
        return .whites
    }

    var keyPath: WritableKeyPath<EditStack, Double> {
        switch self {
        case .blacks: \.blacks
        case .shadows: \.shadows
        case .exposure: \.exposure
        case .highlights: \.highlights
        case .whites: \.whites
        }
    }

    /// The bound slider's own range, verbatim from `SliderPanel`.
    var range: ClosedRange<Double> {
        self == .exposure ? -3...3 : -100...100
    }

    var title: String {
        switch self {
        case .blacks: "Blacks"
        case .shadows: "Shadows"
        case .exposure: "Exposure"
        case .highlights: "Highlights"
        case .whites: "Whites"
        }
    }

    /// The drag law: linear, rightward-positive, clamped to the slider range.
    func value(startingFrom start: Double, draggedByUnitDelta delta: Double) -> Double {
        let span = range.upperBound - range.lowerBound
        let proposed = start + delta * span * Self.sweepFraction
        return min(max(proposed, range.lowerBound), range.upperBound)
    }
}

/// The Inspector histogram as a control surface: HistogramView's plot with a
/// drag/hover layer, per-channel clip triangles, and the cursor readout.
struct InteractiveHistogram: View {
    @Bindable var model: EditorModel

    @State private var hoverRegion: HistogramRegion?
    @State private var drag: (region: HistogramRegion, startValue: Double)?

    /// HistogramView's own plot inset and height — the two views must agree
    /// or the region bands sit beside the bins they claim. Change together.
    private let plotInset: CGFloat = 7
    private let plotHeight: CGFloat = 112

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .top) {
                HistogramView(histogram: model.histogram, showsClipFlags: false)
                if !model.histogram.isEmpty {
                    interactionLayer
                        .frame(height: plotHeight)
                        .padding(.horizontal, plotInset)
                }
            }
            .overlay(alignment: .topLeading) {
                clipCorner(model.histogram.shadowClipFlags,
                           isOn: $model.showsShadowClipping,
                           help: "shadow")
            }
            .overlay(alignment: .topTrailing) {
                clipCorner(model.histogram.highlightClipFlags,
                           isOn: $model.showsHighlightClipping,
                           help: "highlight")
            }

            if let reading = model.hoverReadout {
                readoutRow(reading)
            }
        }
    }

    private var interactionLayer: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let active = drag?.region ?? hoverRegion
            ZStack(alignment: .topLeading) {
                if let active {
                    let band = unitBand(of: active)
                    Rectangle()
                        .fill(Theme.text.opacity(0.05))
                        .frame(width: (band.upperBound - band.lowerBound) * width)
                        .offset(x: band.lowerBound * width)
                    Text("\(active.title.uppercased())  "
                         + String(format: active == .exposure ? "%+.2f" : "%+.0f",
                                  model.editStack[keyPath: active.keyPath]))
                        .font(Theme.valueFont)
                        .monospacedDigit()
                        .foregroundStyle(drag == nil ? Theme.secondaryText : Theme.accent)
                        .padding(4)
                }
            }
            .frame(width: width, height: geo.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    hoverRegion = HistogramRegion.region(atUnitX: location.x / width)
                case .ended:
                    hoverRegion = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if drag == nil {
                            let region = HistogramRegion.region(
                                atUnitX: value.startLocation.x / width)
                            drag = (region, model.editStack[keyPath: region.keyPath])
                        }
                        guard let drag else { return }
                        model.setLightValue(drag.region, to: drag.region.value(
                            startingFrom: drag.startValue,
                            draggedByUnitDelta: Double(value.translation.width / width)))
                    }
                    .onEnded { _ in drag = nil }
            )
        }
    }

    private func unitBand(of region: HistogramRegion) -> ClosedRange<CGFloat> {
        let edges = [0.0] + HistogramRegion.boundaries + [1.0]
        let index = HistogramRegion.allCases.firstIndex(of: region) ?? 0
        return CGFloat(edges[index])...CGFloat(edges[index + 1])
    }

    /// A corner triangle that lights per channel and toggles the existing
    /// clipping overlay — the very state ClippingDiagnostics binds (the
    /// View-menu items stay the keyboard-free route).
    private func clipCorner(_ flags: Histogram.ChannelClipFlags,
                            isOn: Binding<Bool>, help: String) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            Icon.Filled(kind: .warningTriangle, size: 8)
                .foregroundStyle(tint(flags))
                .padding(6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Toggle the \(help) clipping overlay")
        .accessibilityLabel("\(help) clipping channels")
    }

    /// Colour is data here: the triangle takes the additive colour of the
    /// clipping channels (all three → white), quiet grey when clean.
    private func tint(_ flags: Histogram.ChannelClipFlags) -> Color {
        guard flags.any else { return Theme.tertiaryText.opacity(0.6) }
        if flags.red && flags.green && flags.blue { return Theme.text }
        return Color(red: flags.red ? 0.95 : 0.2,
                     green: flags.green ? 0.86 : 0.2,
                     blue: flags.blue ? 0.98 : 0.25)
    }

    /// The 2.0 reference-mock readout, finally built. Measured values,
    /// monospace, percent of full scale.
    private func readoutRow(_ reading: PixelReading) -> some View {
        HStack(spacing: 10) {
            readout("R", reading.red)
            readout("G", reading.green)
            readout("B", reading.blue)
            Rule(axis: .vertical).frame(height: 10)
            readout("L", reading.luma)
            Spacer()
        }
        .padding(.horizontal, plotInset)
    }

    private func readout(_ label: String, _ value: Double) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Theme.tertiaryText)
            Text(String(format: "%.1f", value * 100))
                .font(Theme.valueFont)
                .monospacedDigit()
                .foregroundStyle(Theme.secondaryText)
        }
    }
}
