import SwiftUI

/// An interactive tone-curve editor with five fixed-x control points whose
/// output (y) is dragged vertically. Binds to the model's tone-curve points
/// (`[]` means the identity curve). The drawn curve is a Catmull-Rom spline, to
/// approximate the smooth interpolation `CIToneCurve` applies to the image.
///
/// On macOS a click-drag inside a `ScrollView` does not scroll, so the vertical
/// drag gesture here composes cleanly with the surrounding scrollable panel.
struct ToneCurveEditor: View {
    /// Bound tone-curve points. Empty means identity; otherwise five points.
    @Binding var points: [CGPoint]

    /// The curve's stroke — white for the composite curve, the channel color
    /// when editing an individual channel.
    var lineColor: Color = .white

    @State private var activeIndex: Int?

    /// The five identity control points, evenly spaced along the diagonal.
    private static let identity: [CGPoint] = [
        CGPoint(x: 0, y: 0),
        CGPoint(x: 0.25, y: 0.25),
        CGPoint(x: 0.5, y: 0.5),
        CGPoint(x: 0.75, y: 0.75),
        CGPoint(x: 1, y: 1),
    ]

    /// The points to display — identity when the binding is empty.
    private var currentPoints: [CGPoint] {
        points.isEmpty ? Self.identity : points
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.black.opacity(0.85))

                gridPath(in: size)
                    .stroke(.white.opacity(0.06), lineWidth: 1)

                // Identity reference diagonal.
                Path { path in
                    path.move(to: screenPoint(CGPoint(x: 0, y: 0), in: size))
                    path.addLine(to: screenPoint(CGPoint(x: 1, y: 1), in: size))
                }
                .stroke(.white.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                curvePath(in: size)
                    .stroke(lineColor.opacity(0.9), lineWidth: 1.5)

                ForEach(currentPoints.indices, id: \.self) { index in
                    Circle()
                        .fill(activeIndex == index ? Color.accentColor : lineColor)
                        .frame(width: 9, height: 9)
                        .position(screenPoint(currentPoints[index], in: size))
                }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(in: size))
            .onTapGesture(count: 2) { points = [] }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(.white.opacity(0.08))
        )
    }

    // MARK: Gestures

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                var working = currentPoints
                let index = activeIndex ?? nearestIndex(to: value.startLocation, in: size)
                activeIndex = index
                let normalizedY = 1 - Double(value.location.y / size.height)
                working[index] = CGPoint(x: working[index].x,
                                         y: min(max(normalizedY, 0), 1))
                points = working
            }
            .onEnded { _ in activeIndex = nil }
    }

    /// The control point whose column is horizontally nearest the touch.
    private func nearestIndex(to location: CGPoint, in size: CGSize) -> Int {
        currentPoints.indices.min(by: { lhs, rhs in
            abs(screenPoint(currentPoints[lhs], in: size).x - location.x)
                < abs(screenPoint(currentPoints[rhs], in: size).x - location.x)
        }) ?? 0
    }

    // MARK: Geometry

    /// Maps a unit-square point (y up) to screen coordinates (y down).
    private func screenPoint(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: point.x * size.width, y: (1 - point.y) * size.height)
    }

    private func gridPath(in size: CGSize) -> Path {
        Path { path in
            for fraction in [0.25, 0.5, 0.75] {
                let x = CGFloat(fraction) * size.width
                let y = CGFloat(fraction) * size.height
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
        }
    }

    /// A Catmull-Rom spline through the control points, converted to cubic
    /// Bézier segments.
    private func curvePath(in size: CGSize) -> Path {
        let pts = currentPoints.map { screenPoint($0, in: size) }
        return Path { path in
            guard pts.count > 1 else { return }
            path.move(to: pts[0])
            for i in 0..<(pts.count - 1) {
                let p0 = pts[max(i - 1, 0)]
                let p1 = pts[i]
                let p2 = pts[i + 1]
                let p3 = pts[min(i + 2, pts.count - 1)]
                let control1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6,
                                       y: p1.y + (p2.y - p0.y) / 6)
                let control2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6,
                                       y: p2.y - (p3.y - p1.y) / 6)
                path.addCurve(to: p2, control1: control1, control2: control2)
            }
        }
    }
}
