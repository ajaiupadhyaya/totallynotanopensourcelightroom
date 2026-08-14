import SwiftUI

/// The navigator: a fit-view thumbnail with the visible region marked and
/// click/drag-to-pan, shown only while the frame overflows the viewport —
/// the only time it has anything to say. Reuses the already-rendered preview
/// (`displayImage`); no extra render path. Drawn card, machined edge, no
/// drop shadow — the edge is the app's one depth device.
struct NavigatorPanel: View {
    @Bindable var editor: EditorModel
    let viewportSize: CGSize
    let fitInset: CGFloat

    private let cardWidth: CGFloat = 148

    var body: some View {
        if let image = editor.displayImage,
           let size = editor.previewPixelSize,
           let scale = editor.zoomLevel {
            let fit = ZoomMath.fitScale(imageSize: size, viewport: viewportSize, inset: fitInset)
            if scale > fit {
                let cardHeight = cardWidth * size.height / size.width
                let visible = NavigatorMath.visibleUnitRect(
                    viewport: viewportSize, imageSize: size,
                    scale: scale, pan: editor.panOffset)
                ZStack {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .frame(width: cardWidth, height: cardHeight)
                    Rectangle()
                        .stroke(Color.white.opacity(0.9), lineWidth: Theme.hairline * 1.5)
                        .frame(width: visible.width * cardWidth,
                               height: visible.height * cardHeight)
                        .position(x: visible.midX * cardWidth, y: visible.midY * cardHeight)
                }
                .frame(width: cardWidth, height: cardHeight)
                .clipped()
                .background(Theme.background)
                .machinedEdges(radius: Theme.radius)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0).onChanged { value in
                        let p = CGPoint(x: min(max(value.location.x / cardWidth, 0), 1),
                                        y: min(max(value.location.y / cardHeight, 0), 1))
                        editor.panOffset = NavigatorMath.pan(
                            centeringUnitPoint: p, imageSize: size, scale: scale)
                    }
                )
                .padding(Theme.space3)
                .accessibilityLabel("Navigator")
            }
        }
    }
}
