import SwiftUI

/// A live RGB histogram drawn as three overlaid channel curves over a dark
/// panel. Channels use a screen blend so overlapping regions brighten toward
/// white — the familiar photo-editor look. Non-interactive.
struct HistogramView: View {
    let histogram: Histogram

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.black.opacity(0.88))

            if !histogram.isEmpty {
                GeometryReader { geo in
                    let peak = histogram.peak
                    ZStack {
                        channelPath(histogram.red, in: geo.size, peak: peak)
                            .fill(Color.red.opacity(0.9)).blendMode(.screen)
                        channelPath(histogram.green, in: geo.size, peak: peak)
                            .fill(Color.green.opacity(0.9)).blendMode(.screen)
                        channelPath(histogram.blue, in: geo.size, peak: peak)
                            .fill(Color.blue.opacity(0.9)).blendMode(.screen)
                    }
                }
                .padding(5)
            } else {
                Text("No photo")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .frame(height: 108)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(.white.opacity(0.08))
        )
    }

    /// Builds a filled area path for one channel's bins, scaled so the tallest
    /// bin across all channels reaches full height.
    private func channelPath(_ bins: [Float], in size: CGSize, peak: Float) -> Path {
        Path { path in
            guard bins.count > 1, size.width > 0, size.height > 0 else { return }
            let stepX = size.width / CGFloat(bins.count - 1)
            path.move(to: CGPoint(x: 0, y: size.height))
            for (i, value) in bins.enumerated() {
                let x = CGFloat(i) * stepX
                let normalized = CGFloat(value / peak)
                let y = size.height - min(max(normalized, 0), 1) * size.height
                path.addLine(to: CGPoint(x: x, y: y))
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()
        }
    }
}
