import SwiftUI

/// The live RGB histogram.
///
/// Channels draw as translucent filled areas in a screen blend, so overlap
/// brightens toward white — coincident channels read as a neutral image at a
/// glance. Bin heights are square-root scaled: tonal information lives in the
/// quiet regions of the histogram, and linear scaling lets one dominant bin
/// flatten everything else into unreadability.
///
/// Clipping indicators sit in the top corners: a triangle appears when a
/// meaningful fraction of pixels is crushed (left) or blown (right). They are
/// warnings, not decoration — invisible until true.
struct HistogramView: View {
    let histogram: Histogram

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.black.opacity(0.85))

            if !histogram.isEmpty {
                GeometryReader { geo in
                    ZStack {
                        // Quarter-tone gridlines: exposure landmarks, not decor.
                        gridlines(in: geo.size)

                        channelPath(histogram.red, in: geo.size)
                            .fill(Color(red: 0.95, green: 0.25, blue: 0.22).opacity(0.75))
                            .blendMode(.screen)
                        channelPath(histogram.green, in: geo.size)
                            .fill(Color(red: 0.25, green: 0.85, blue: 0.35).opacity(0.75))
                            .blendMode(.screen)
                        channelPath(histogram.blue, in: geo.size)
                            .fill(Color(red: 0.30, green: 0.45, blue: 0.95).opacity(0.75))
                            .blendMode(.screen)
                    }
                }
                .padding(6)
                .overlay(alignment: .topLeading) {
                    if histogram.isClippingShadows {
                        clipIndicator
                            .help("Shadows are clipping to pure black")
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if histogram.isClippingHighlights {
                        clipIndicator
                            .help("Highlights are clipping to pure white")
                    }
                }
            } else {
                Text("No photo")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .frame(height: 116)
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(.white.opacity(0.07))
        )
        .accessibilityLabel("Histogram")
    }

    private var clipIndicator: some View {
        // A drawn warning triangle, matching the chrome's hairline voice.
        Path { path in
            path.move(to: CGPoint(x: 3.5, y: 0))
            path.addLine(to: CGPoint(x: 7, y: 6))
            path.addLine(to: CGPoint(x: 0, y: 6))
            path.closeSubpath()
        }
        .fill(.white.opacity(0.9))
        .frame(width: 7, height: 6)
        .padding(5)
    }

    private func gridlines(in size: CGSize) -> some View {
        Path { path in
            for quarter in 1...3 {
                let x = size.width * CGFloat(quarter) / 4
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }
        }
        .stroke(.white.opacity(0.05), lineWidth: 1)
    }

    /// A filled area for one channel, square-root scaled against the global
    /// peak so every channel shares one vertical scale.
    private func channelPath(_ bins: [Float], in size: CGSize) -> Path {
        Path { path in
            guard bins.count > 1, size.width > 0, size.height > 0 else { return }
            let peak = histogram.peak
            let stepX = size.width / CGFloat(bins.count - 1)
            path.move(to: CGPoint(x: 0, y: size.height))
            for (i, value) in bins.enumerated() {
                let x = CGFloat(i) * stepX
                let normalized = CGFloat((value / peak).squareRoot())
                let y = size.height - min(max(normalized, 0), 1) * size.height
                path.addLine(to: CGPoint(x: x, y: y))
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()
        }
    }
}
