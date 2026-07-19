import SwiftUI

/// The tone-curve section: one editor, four curves.
///
/// The composite RGB curve shapes tone through `CIToneCurve`; the R/G/B
/// channels shape color through the LUT's per-channel curves. One editor
/// serves all four — the channel picker swaps which set of points it binds to,
/// and the curve draws in its channel's color so there is never a question of
/// which curve is being pulled.
struct CurvePanel: View {
    @Bindable var model: EditorModel

    enum Channel: String, CaseIterable, Identifiable {
        case rgb = "RGB"
        case red = "R"
        case green = "G"
        case blue = "B"

        var id: String { rawValue }

        var color: Color {
            switch self {
            case .rgb: .white
            case .red: Color(red: 0.95, green: 0.30, blue: 0.28)
            case .green: Color(red: 0.30, green: 0.85, blue: 0.40)
            case .blue: Color(red: 0.35, green: 0.50, blue: 0.95)
            }
        }
    }

    @State private var channel: Channel = .rgb

    var body: some View {
        TabStrip(
            options: Channel.allCases.map { ($0, $0.rawValue) },
            selection: $channel
        )

        ToneCurveEditor(points: pointsBinding, lineColor: channel.color)
            .frame(height: 190)

        Text("Drag a point vertically to reshape. Double-click to reset "
             + "this channel.")
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Theme.secondaryText)
    }

    private var pointsBinding: Binding<[CGPoint]> {
        switch channel {
        case .rgb: $model.editStack.toneCurvePoints
        case .red: $model.editStack.color.channelCurves.red
        case .green: $model.editStack.color.channelCurves.green
        case .blue: $model.editStack.color.channelCurves.blue
        }
    }
}
