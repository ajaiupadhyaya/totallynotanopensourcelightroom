import SwiftUI

/// The center canvas: the open photo with zoom, pan, crop, mask and retouch
/// handles, and eyedropper targeting — or an empty state.
struct CanvasArea: View {
    @Bindable var app: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Theme.canvas.ignoresSafeArea()

                if let editor = app.editor {
                    EditCanvas(editor: editor, app: app)
                } else {
                    placeholder
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let editor = app.editor {
                CanvasStatusBar(editor: editor)
            }
        }
    }

    private var placeholder: some View {
        VStack(spacing: 14) {
            // An empty film frame, drawn — the shape of what belongs here.
            RoundedRectangle(cornerRadius: 2)
                .stroke(Theme.tertiaryText, lineWidth: 1.2)
                .frame(width: 64, height: 44)
                .overlay(alignment: .top) {
                    Text("00")
                        .font(Theme.filmEdgeFont)
                        .foregroundStyle(Theme.filmEdge.opacity(0.7))
                        .offset(y: -14)
                }
            Text(app.entries.isEmpty
                 ? "Import a photo, or drop scans here"
                 : "Select a frame in the library")
                .font(Theme.controlFont)
                .foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            !app.importDropped(urls).isEmpty
        }
    }
}

/// Persistent document facts and viewing state. The bar is deliberately quiet:
/// it answers "what am I looking at?" without competing with the photograph.
private struct CanvasStatusBar: View {
    @Bindable var editor: EditorModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "viewfinder")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Theme.secondaryText)

            Text(editor.zoomLevel.map { "\(Int($0 * 100))%" } ?? "FIT")
                .font(Theme.valueFont)
                .foregroundStyle(Theme.text)

            Rectangle().fill(Theme.separator).frame(width: Theme.hairline, height: 14)

            Text(editor.metadata.colorProfile ?? "sRGB")
                .font(Theme.valueFont)
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)

            if let dimensions = editor.metadata.dimensions {
                Text(dimensions)
                    .font(Theme.valueFont)
                    .foregroundStyle(Theme.tertiaryText)
            }

            Spacer()

            Text(editor.isShowingBefore ? "BEFORE" : "DEVELOPED")
                .font(Theme.plateFont)
                .kerning(Theme.plateTracking)
                .foregroundStyle(editor.isShowingBefore ? Theme.warning : Theme.secondaryText)
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(Theme.background)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.separator).frame(height: Theme.hairline)
        }
    }
}

/// The open photo plus every canvas-level interaction.
private struct EditCanvas: View {
    @Bindable var editor: EditorModel
    @Bindable var app: AppModel

    var body: some View {
        Group {
            if editor.isMissingFile {
                missingFileState
            } else {
                viewport
            }
        }
    }

    // MARK: Viewport

    private var viewport: some View {
        GeometryReader { outer in
            ScrollView([.horizontal, .vertical], showsIndicators: true) {
                canvasContent(viewportSize: outer.size)
            }
            .defaultScrollAnchor(.center)
        }
        .overlay(alignment: .top) {
            if let prompt = pickerPrompt {
                pickerBanner(prompt)
            }
        }
        .overlay(alignment: .bottom) {
            if editor.isCropping {
                cropBar
            }
        }
    }

    @ViewBuilder
    private func canvasContent(viewportSize: CGSize) -> some View {
        if let cgImage = editor.displayImage {
            let imageSize = CGSize(width: cgImage.width, height: cgImage.height)
            let inset: CGFloat = 24
            let available = CGSize(width: max(viewportSize.width - inset * 2, 50),
                                   height: max(viewportSize.height - inset * 2, 50))
            let fitScale = min(available.width / imageSize.width,
                               available.height / imageSize.height)
            let scale = editor.zoomLevel.map { CGFloat($0) } ?? min(fitScale, 1.0)
            let displaySize = CGSize(width: imageSize.width * scale,
                                     height: imageSize.height * scale)
            let contentSize = CGSize(width: max(displaySize.width + inset * 2, viewportSize.width),
                                     height: max(displaySize.height + inset * 2, viewportSize.height))

            ZStack {
                Image(decorative: cgImage, scale: 1.0)
                    .resizable()
                    .interpolation(scale >= 1.0 ? .none : .high)
                    .frame(width: displaySize.width, height: displaySize.height)
                    // A soft edge separates the photo from the surround
                    // without a bright border that would bias its own tones.
                    .shadow(color: .black.opacity(0.55), radius: 16, y: 5)
                    .gesture(clickGesture(displaySize: displaySize))

                if editor.isCropping {
                    CropOverlay(cropRect: $editor.editStack.geometry.cropRect,
                                displaySize: displaySize)
                        .frame(width: displaySize.width, height: displaySize.height)
                } else if let index = editor.selectedSpotIndex {
                    RetouchHandles(
                        spot: $editor.editStack.retouch[index],
                        displaySize: displaySize
                    )
                    .frame(width: displaySize.width, height: displaySize.height)
                } else if let index = editor.selectedMaskIndex {
                    MaskHandles(
                        adjustment: $editor.editStack.localAdjustments[index],
                        displaySize: displaySize
                    )
                    .frame(width: displaySize.width, height: displaySize.height)
                }

                if editor.isShowingBefore {
                    Text("BEFORE")
                        .font(Theme.plateFont)
                        .kerning(Theme.plateTracking)
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 2))
                        .frame(width: displaySize.width, height: displaySize.height,
                               alignment: .topLeading)
                        .padding(12)
                }

                if editor.showsShadowClipping || editor.showsHighlightClipping {
                    clippingReadout
                        .frame(width: displaySize.width, height: displaySize.height,
                               alignment: .bottomLeading)
                        .padding(12)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: contentSize.width, height: contentSize.height)
        }
    }

    private var clippingReadout: some View {
        HStack(spacing: 10) {
            if editor.showsShadowClipping {
                diagnosticLabel(
                    "SHADOWS \(editor.histogram.shadowClippedFraction.formatted(.percent.precision(.fractionLength(1))))",
                    active: editor.histogram.isClippingShadows
                )
            }
            if editor.showsHighlightClipping {
                diagnosticLabel(
                    "HIGHLIGHTS \(editor.histogram.highlightClippedFraction.formatted(.percent.precision(.fractionLength(1))))",
                    active: editor.histogram.isClippingHighlights
                )
            }
        }
    }

    private func diagnosticLabel(_ text: String, active: Bool) -> some View {
        Text(text)
            .font(Theme.plateFont)
            .kerning(Theme.plateTracking)
            .foregroundStyle(active ? Theme.warning : Theme.secondaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.black.opacity(0.76))
            .overlay(Rectangle().stroke(active ? Theme.warning.opacity(0.75) : Theme.separator,
                                        lineWidth: Theme.hairline))
    }

    /// Single click drives the active eyedropper; double click toggles
    /// fit ↔ 100%. The single-tap recognizer only *acts* in picker mode, so
    /// the two never fight.
    private func clickGesture(displaySize: CGSize) -> some Gesture {
        let pick = SpatialTapGesture(count: 1)
            .onEnded { value in
                guard editor.canvasPicker != nil else { return }
                let unit = CGPoint(
                    x: min(max(value.location.x / displaySize.width, 0), 1),
                    y: min(max(1 - value.location.y / displaySize.height, 0), 1)
                )
                editor.handleCanvasClick(atUnitPoint: unit)
            }
        let toggleZoom = SpatialTapGesture(count: 2)
            .onEnded { _ in
                editor.zoomLevel = editor.zoomLevel == nil ? 1.0 : nil
            }
        return toggleZoom.simultaneously(with: pick)
    }

    // MARK: Picker banner

    private var pickerPrompt: String? {
        switch editor.canvasPicker {
        case .whiteBalance: "Click something that should be neutral gray"
        case .filmBase: "Click a clear piece of film border"
        case .retouchPlace: "Click the defect to remove"
        case nil: nil
        }
    }

    private func pickerBanner(_ prompt: String) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Theme.accent)
                .frame(width: 5, height: 5)
            Text(prompt)
                .font(Theme.controlFont)
            Button {
                editor.canvasPicker = nil
            } label: {
                Text("CANCEL")
                    .font(Theme.plateFont)
                    .kerning(Theme.plateTracking)
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 3))
        .foregroundStyle(Theme.text)
        .padding(.top, 12)
    }

    // MARK: Crop bar

    private var cropBar: some View {
        HStack(spacing: 12) {
            Text("Recompose the frame")
                .font(Theme.controlFont)
                .foregroundStyle(Theme.secondaryText)
            PlateButton(title: "Cancel") { editor.cancelCrop() }
            PlateButton(title: "Done") { editor.finishCrop() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 3))
        .padding(.bottom, 14)
        .background {
            // Escape cancels, return commits — invisible, standard keys.
            Group {
                Button("") { editor.cancelCrop() }.keyboardShortcut(.cancelAction)
                Button("") { editor.finishCrop() }.keyboardShortcut(.defaultAction)
            }
            .opacity(0)
        }
    }

    private var missingFileState: some View {
        VStack(spacing: 12) {
            Text("!")
                .font(.system(size: 40, weight: .thin, design: .monospaced))
                .foregroundStyle(Theme.secondaryText)
            Text("This photo's file could not be found.")
                .font(Theme.controlFont)
            Text(editor.fileName)
                .font(Theme.valueFont)
                .foregroundStyle(Theme.secondaryText)
        }
    }
}

// MARK: - Crop overlay

/// The interactive crop: dimmed surround, thirds grid, corner and edge
/// handles, and drag-inside to move.
///
/// `cropRect` is normalized with a **bottom-left** origin (Core Image's
/// convention, shared with export); the view works top-left, so conversion
/// happens exactly once, at the boundary.
private struct CropOverlay: View {
    @Binding var cropRect: CGRect
    let displaySize: CGSize

    private enum DragMode: Equatable {
        case move
        case handle(dx: CGFloat, dy: CGFloat) // which edges move: -1, 0, +1
    }

    @State private var dragStartRect: CGRect?
    @State private var dragMode: DragMode?

    /// Minimum crop dimension, normalized.
    private let minimumSide: CGFloat = 0.05

    var body: some View {
        // View-space rect (top-left origin).
        let rect = viewRect

        ZStack {
            // Dim everything outside the kept region.
            Path { path in
                path.addRect(CGRect(origin: .zero, size: displaySize))
                path.addRect(rect)
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))

            // Thirds grid — the compositional reference, only inside the crop.
            Path { path in
                for third in [1.0 / 3.0, 2.0 / 3.0] {
                    path.move(to: CGPoint(x: rect.minX + rect.width * third, y: rect.minY))
                    path.addLine(to: CGPoint(x: rect.minX + rect.width * third, y: rect.maxY))
                    path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * third))
                    path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * third))
                }
            }
            .stroke(.white.opacity(0.25), lineWidth: 1)

            Rectangle()
                .strokeBorder(.white.opacity(0.9), lineWidth: 1.5)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)

            ForEach(handles, id: \.name) { handle in
                Rectangle()
                    .fill(.white)
                    .frame(width: handle.isCorner ? 9 : 7, height: handle.isCorner ? 9 : 7)
                    .position(handle.position(in: rect))
            }
        }
        .contentShape(Rectangle())
        .gesture(dragGesture)
    }

    // MARK: Geometry conversion

    private var viewRect: CGRect {
        CGRect(
            x: cropRect.origin.x * displaySize.width,
            y: (1 - cropRect.origin.y - cropRect.height) * displaySize.height,
            width: cropRect.width * displaySize.width,
            height: cropRect.height * displaySize.height
        )
    }

    private func store(_ rect: CGRect) {
        // Back to normalized bottom-left.
        let normalized = CGRect(
            x: rect.origin.x / displaySize.width,
            y: 1 - (rect.origin.y + rect.height) / displaySize.height,
            width: rect.width / displaySize.width,
            height: rect.height / displaySize.height
        )
        cropRect = normalized.intersection(.unitFrame)
    }

    // MARK: Handles

    private struct Handle {
        let name: String
        let dx: CGFloat // -1 left edge, 0 none, +1 right edge
        let dy: CGFloat // -1 top edge, 0 none, +1 bottom edge

        var isCorner: Bool { dx != 0 && dy != 0 }

        func position(in rect: CGRect) -> CGPoint {
            CGPoint(
                x: dx < 0 ? rect.minX : dx > 0 ? rect.maxX : rect.midX,
                y: dy < 0 ? rect.minY : dy > 0 ? rect.maxY : rect.midY
            )
        }
    }

    private var handles: [Handle] {
        [
            Handle(name: "tl", dx: -1, dy: -1), Handle(name: "t", dx: 0, dy: -1),
            Handle(name: "tr", dx: 1, dy: -1), Handle(name: "l", dx: -1, dy: 0),
            Handle(name: "r", dx: 1, dy: 0), Handle(name: "bl", dx: -1, dy: 1),
            Handle(name: "b", dx: 0, dy: 1), Handle(name: "br", dx: 1, dy: 1),
        ]
    }

    // MARK: Dragging

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = dragStartRect ?? viewRect
                if dragStartRect == nil {
                    dragStartRect = start
                    dragMode = hitTest(value.startLocation, in: start)
                }
                guard let mode = dragMode else { return }

                var rect = start
                let dx = value.translation.width
                let dy = value.translation.height

                switch mode {
                case .move:
                    rect.origin.x = min(max(start.origin.x + dx, 0),
                                        displaySize.width - rect.width)
                    rect.origin.y = min(max(start.origin.y + dy, 0),
                                        displaySize.height - rect.height)
                case .handle(let hx, let hy):
                    let minW = minimumSide * displaySize.width
                    let minH = minimumSide * displaySize.height
                    if hx < 0 {
                        let newX = min(max(start.minX + dx, 0), start.maxX - minW)
                        rect.origin.x = newX
                        rect.size.width = start.maxX - newX
                    } else if hx > 0 {
                        rect.size.width = min(max(start.width + dx, minW),
                                              displaySize.width - start.minX)
                    }
                    if hy < 0 {
                        let newY = min(max(start.minY + dy, 0), start.maxY - minH)
                        rect.origin.y = newY
                        rect.size.height = start.maxY - newY
                    } else if hy > 0 {
                        rect.size.height = min(max(start.height + dy, minH),
                                               displaySize.height - start.minY)
                    }
                }
                store(rect)
            }
            .onEnded { _ in
                dragStartRect = nil
                dragMode = nil
            }
    }

    /// What a drag starting at `point` grabs: a handle when near one, the
    /// whole crop when inside it, nothing outside.
    private func hitTest(_ point: CGPoint, in rect: CGRect) -> DragMode? {
        let grabRadius: CGFloat = 14
        for handle in handles {
            let position = handle.position(in: rect)
            if hypot(point.x - position.x, point.y - position.y) < grabRadius {
                return .handle(dx: handle.dx, dy: handle.dy)
            }
        }
        return rect.contains(point) ? .move : nil
    }
}

// MARK: - Mask handles

/// On-canvas editing for the selected local adjustment.
///
/// Linear: two pins — full-effect end and fade-out end — joined by a line,
/// with dashed rails marking the gradient band's orientation. Radial: a
/// center pin that moves the ellipse, plus edge pins on the right and top
/// that set each radius.
private struct MaskHandles: View {
    @Binding var adjustment: LocalAdjustment
    let displaySize: CGSize

    var body: some View {
        ZStack {
            switch adjustment.shape {
            case .linear: linearHandles
            case .radial: radialHandles
            case .brush: brushOverlay
            }
        }
        .allowsHitTesting(true)
    }

    // MARK: Brush

    @State private var isPainting = false

    private var brushOverlay: some View {
        ZStack {
            ForEach(adjustment.brushStrokes) { stroke in
                Path { path in
                    guard let first = stroke.points.first else { return }
                    path.move(to: viewPoint(first))
                    for point in stroke.points.dropFirst() {
                        path.addLine(to: viewPoint(point))
                    }
                    if stroke.points.count == 1 {
                        path.addLine(to: viewPoint(first))
                    }
                }
                .stroke(Theme.accent.opacity(0.52),
                        style: StrokeStyle(
                            lineWidth: max(stroke.radius * min(displaySize.width,
                                                               displaySize.height) * 2, 2),
                            lineCap: .round,
                            lineJoin: .round
                        ))
                .allowsHitTesting(false)
            }

            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let point = unitPoint(value.location)
                            if !isPainting {
                                isPainting = true
                                adjustment.brushStrokes.append(BrushStroke(
                                    points: [point], radius: adjustment.brushSize,
                                    feather: adjustment.brushFeather,
                                    flow: adjustment.brushFlow
                                ))
                            } else if let strokeIndex = adjustment.brushStrokes.indices.last,
                                      let previous = adjustment.brushStrokes[strokeIndex].points.last {
                                let threshold = max(adjustment.brushSize * 0.12, 0.001)
                                if hypot(point.x - previous.x, point.y - previous.y) >= threshold {
                                    adjustment.brushStrokes[strokeIndex].points.append(point)
                                }
                            }
                        }
                        .onEnded { _ in isPainting = false }
                )
        }
    }

    // MARK: Coordinate mapping (unit bottom-left ↔ view top-left)

    private func viewPoint(_ unit: CGPoint) -> CGPoint {
        CGPoint(x: unit.x * displaySize.width,
                y: (1 - unit.y) * displaySize.height)
    }

    private func unitPoint(_ view: CGPoint) -> CGPoint {
        CGPoint(x: min(max(view.x / displaySize.width, 0), 1),
                y: min(max(1 - view.y / displaySize.height, 0), 1))
    }

    // MARK: Linear

    private var linearHandles: some View {
        let start = viewPoint(adjustment.startPoint)
        let end = viewPoint(adjustment.endPoint)

        return ZStack {
            Path { path in
                path.move(to: start)
                path.addLine(to: end)
            }
            .stroke(.white.opacity(0.75), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

            CanvasPin(at: start, filled: true)
                .gesture(dragPin { adjustment.startPoint = $0 })
                .help("Full effect")
            CanvasPin(at: end, filled: false)
                .gesture(dragPin { adjustment.endPoint = $0 })
                .help("Fades to nothing")
        }
    }

    // MARK: Radial

    private var radialHandles: some View {
        let center = viewPoint(adjustment.center)
        let radiusX = adjustment.radiusX * displaySize.width
        let radiusY = adjustment.radiusY * displaySize.height

        return ZStack {
            Ellipse()
                .stroke(.white.opacity(0.75),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .frame(width: radiusX * 2, height: radiusY * 2)
                .position(center)
                .allowsHitTesting(false)

            CanvasPin(at: center, filled: true)
                .gesture(dragPin { adjustment.center = $0 })
                .help("Move")

            CanvasPin(at: CGPoint(x: center.x + radiusX, y: center.y), filled: false)
                .gesture(
                    DragGesture(minimumDistance: 1).onChanged { value in
                        let dx = abs(value.location.x - center.x)
                        adjustment.radiusX = min(max(Double(dx / displaySize.width), 0.02), 1)
                    }
                )
                .help("Width")

            CanvasPin(at: CGPoint(x: center.x, y: center.y - radiusY), filled: false)
                .gesture(
                    DragGesture(minimumDistance: 1).onChanged { value in
                        let dy = abs(center.y - value.location.y)
                        adjustment.radiusY = min(max(Double(dy / displaySize.height), 0.02), 1)
                    }
                )
                .help("Height")
        }
    }

    private func dragPin(_ update: @escaping (CGPoint) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in update(unitPoint(value.location)) }
    }
}

// MARK: - Retouch handles

/// On-canvas editing for the selected retouch spot: a solid circle over the
/// destination, a dashed circle over the source, and a connector — drag
/// either circle to move that end.
private struct RetouchHandles: View {
    @Binding var spot: RetouchSpot
    let displaySize: CGSize

    var body: some View {
        let radius = spot.radius * displaySize.width
        let dest = viewPoint(spot.center)
        let source = viewPoint(CGPoint(x: spot.center.x + spot.sourceOffset.dx,
                                       y: spot.center.y + spot.sourceOffset.dy))

        ZStack {
            Path { path in
                path.move(to: dest)
                path.addLine(to: source)
            }
            .stroke(.white.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

            // Destination: solid — this is what gets repaired.
            Circle()
                .stroke(.white.opacity(0.95), lineWidth: 1.5)
                .frame(width: radius * 2, height: radius * 2)
                .position(dest)
                .contentShape(Circle().scale(1.4))
                .gesture(dragCircle { spot.center = $0 })

            // Source: dashed — where the replacement pixels come from.
            Circle()
                .stroke(.white.opacity(0.7),
                        style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                .frame(width: radius * 2, height: radius * 2)
                .position(source)
                .contentShape(Circle().scale(1.4))
                .gesture(dragCircle { point in
                    spot.sourceOffset = CGVector(dx: point.x - spot.center.x,
                                                 dy: point.y - spot.center.y)
                })
        }
    }

    private func viewPoint(_ unit: CGPoint) -> CGPoint {
        CGPoint(x: unit.x * displaySize.width,
                y: (1 - unit.y) * displaySize.height)
    }

    private func unitPoint(_ view: CGPoint) -> CGPoint {
        CGPoint(x: min(max(view.x / displaySize.width, 0), 1),
                y: min(max(1 - view.y / displaySize.height, 0), 1))
    }

    private func dragCircle(_ update: @escaping (CGPoint) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in update(unitPoint(value.location)) }
    }
}

// MARK: - Shared pin

/// A drag pin shared by the mask overlays.
struct CanvasPin: View {
    let point: CGPoint
    let filled: Bool

    init(at point: CGPoint, filled: Bool) {
        self.point = point
        self.filled = filled
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(filled ? Color.white : Theme.canvas)
                .frame(width: 11, height: 11)
            Circle()
                .strokeBorder(filled ? Theme.canvas : .white, lineWidth: 1.5)
                .frame(width: 11, height: 11)
        }
        .shadow(color: .black.opacity(0.6), radius: 2)
        .position(point)
        .contentShape(Circle().scale(2.2))
    }
}
