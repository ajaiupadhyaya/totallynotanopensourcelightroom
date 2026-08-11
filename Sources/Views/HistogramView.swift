import SwiftUI

/// The live RGB histogram — the one place in the chrome where colour is data
/// rather than decoration.
///
/// Channels draw as translucent filled areas in a screen blend, so overlap
/// brightens toward white and a neutral image reads as a single pale shape.
/// Each channel also carries a bright top edge, which is what makes three
/// overlapping fills separable instead of a wash.
///
/// Bin heights are square-root scaled: tonal information lives in the quiet
/// regions of a histogram, and linear scaling lets one dominant bin flatten
/// everything else into unreadability.
///
/// The zone rule underneath is the reason this reads as an instrument. Five
/// marks — black, quarter, mid, three-quarter, white — give the graph a scale,
/// so a shape can be *located* rather than just seen.
struct HistogramView: View {
    let histogram: Histogram

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.largeRadius)
                    .fill(Color.black.opacity(0.9))

                if histogram.isEmpty {
                    Text("No photograph open")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.tertiaryText)
                } else {
                    GeometryReader { geo in
                        ZStack {
                            gridlines(in: geo.size)
                            channel(histogram.red, Theme.histogramRed, in: geo.size)
                            channel(histogram.green, Theme.histogramGreen, in: geo.size)
                            channel(histogram.blue, Theme.histogramBlue, in: geo.size)
                        }
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 6)
                    .overlay(alignment: .topLeading) {
                        if histogram.isClippingShadows { clipFlag(.leading) }
                    }
                    .overlay(alignment: .topTrailing) {
                        if histogram.isClippingHighlights { clipFlag(.trailing) }
                    }
                }
            }
            .frame(height: 112)
            .overlay {
                RoundedRectangle(cornerRadius: Theme.largeRadius)
                    .strokeBorder(Theme.specular, lineWidth: Theme.hairline)
            }

            zoneRule
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Histogram")
        .accessibilityValue(accessibilityReading)
    }

    private var accessibilityReading: String {
        guard !histogram.isEmpty else { return "No photograph open" }
        var parts: [String] = []
        if histogram.isClippingShadows { parts.append("shadows clipping") }
        if histogram.isClippingHighlights { parts.append("highlights clipping") }
        return parts.isEmpty ? "No clipping" : parts.joined(separator: ", ")
    }

    /// Black · quarter · mid · three-quarter · white.
    private var zoneRule: some View {
        HStack(spacing: 0) {
            ForEach(["0", "25", "50", "75", "100"], id: \.self) { mark in
                Text(mark)
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.tertiaryText.opacity(0.75))
                    .frame(maxWidth: .infinity,
                           alignment: mark == "0" ? .leading
                               : (mark == "100" ? .trailing : .center))
            }
        }
        .padding(.horizontal, 7)
    }

    private func clipFlag(_ edge: HorizontalAlignment) -> some View {
        Icon.Filled(kind: .warningTriangle, size: 8)
            .foregroundStyle(Theme.warning)
            .padding(6)
            .help(edge == .leading ? "Shadows are clipping to pure black"
                                   : "Highlights are clipping to pure white")
    }

    private func gridlines(in size: CGSize) -> some View {
        Path { path in
            for quarter in 1...3 {
                let x = size.width * CGFloat(quarter) / 4
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }
        }
        .stroke(.white.opacity(0.06), lineWidth: 1)
    }

    /// One channel: a filled area plus a bright top edge, square-root scaled
    /// against the global peak so every channel shares one vertical scale.
    private func channel(_ bins: [Float], _ tint: Color, in size: CGSize) -> some View {
        let outline = curve(bins, in: size, closed: false)
        return ZStack {
            curve(bins, in: size, closed: true)
                .fill(tint.opacity(0.38))
                .blendMode(.screen)
            outline
                .stroke(tint.opacity(0.82), lineWidth: 1)
                .blendMode(.screen)
        }
    }

    private func curve(_ bins: [Float], in size: CGSize, closed: Bool) -> Path {
        Path { path in
            guard bins.count > 1, size.width > 0, size.height > 0 else { return }
            let peak = histogram.peak
            let stepX = size.width / CGFloat(bins.count - 1)

            func point(_ i: Int) -> CGPoint {
                var normalized = CGFloat((bins[i] / peak).squareRoot())
                // Edge bins hold the CLIPPED mass and are excluded from the
                // scale (see Histogram.peak) — capped just under the ceiling
                // so a clipped spike reads as a maxed column instead of a
                // full-height white wall over the data (design audit).
                if i == 0 || i == bins.count - 1 {
                    normalized = min(normalized, 0.92)
                }
                return CGPoint(x: CGFloat(i) * stepX,
                               y: size.height - min(max(normalized, 0), 1) * size.height)
            }

            if closed { path.move(to: CGPoint(x: 0, y: size.height)) }
            for i in bins.indices {
                let p = point(i)
                if i == 0 && !closed { path.move(to: p) } else { path.addLine(to: p) }
            }
            if closed {
                path.addLine(to: CGPoint(x: size.width, y: size.height))
                path.closeSubpath()
            }
        }
    }
}
