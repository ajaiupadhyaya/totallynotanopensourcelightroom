import SwiftUI

/// The center canvas: the open photo with zoom, pan, crop, mask and retouch
/// handles, and eyedropper targeting — or an empty state.
struct CanvasArea: View {
    @Bindable var app: AppModel
    @Bindable var workspace: WorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Theme.canvas

                if let editor = app.editor {
                    EditCanvas(editor: editor, app: app, workspace: workspace)
                } else {
                    EmptyCanvas(app: app)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let editor = app.editor {
                CanvasStatusBar(editor: editor)
            }
        }
    }
}

/// What the canvas says when there is nothing open.
///
/// An empty screen is an invitation to act, so this one names the two ways in
/// and draws the shape of what belongs here — an empty frame on a rebate,
/// which is exactly what an unexposed negative looks like.
private struct EmptyCanvas: View {
    @Bindable var app: AppModel

    @State private var isTargeted = false

    private var hasLibrary: Bool { !app.entries.isEmpty }

    var body: some View {
        VStack(spacing: Theme.space5) {
            emptyFrame

            VStack(spacing: Theme.space2) {
                Text(hasLibrary ? "No frame open" : "The roll is empty")
                    .font(Theme.heading)
                    .foregroundStyle(Theme.text)

                Text(hasLibrary
                     ? "Choose a frame in the roll, or drop more scans anywhere here."
                     : "Drop scans and photographs here, or import them from disk.")
                    .font(Theme.body)
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }

            if !hasLibrary {
                PlateButton(title: "Import photographs", emphasis: .prominent) {
                    app.isShowingImporter = true
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .background {
            if isTargeted {
                RoundedRectangle(cornerRadius: Theme.largeRadius)
                    .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .padding(Theme.space6)
            }
        }
        .animation(Theme.standard, value: isTargeted)
        .dropDestination(for: URL.self) { urls, _ in
            !app.importDropped(urls).isEmpty
        } isTargeted: { isTargeted = $0 }
    }

    private var emptyFrame: some View {
        RoundedRectangle(cornerRadius: 2)
            .strokeBorder(Theme.strongSeparator, lineWidth: 1.5)
            .frame(width: 96, height: 66)
            .overlay(alignment: .top) {
                Text("00")
                    .font(Theme.filmEdgeFont)
                    .foregroundStyle(Theme.filmEdge.opacity(0.7))
                    .offset(y: -15)
            }
            .overlay {
                // Sprocket holes, so the mark reads as film rather than as a
                // generic "no content" rectangle.
                HStack(spacing: 7) {
                    ForEach(0..<7, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Theme.separator)
                            .frame(width: 5, height: 4)
                    }
                }
                .offset(y: 46)
            }
    }
}

/// Persistent document facts and viewing state. The bar is deliberately quiet:
/// it answers "what am I looking at?" without competing with the photograph.
private struct CanvasStatusBar: View {
    @Bindable var editor: EditorModel

    var body: some View {
        HStack(spacing: Theme.space3) {
            reading("Zoom", editor.zoomLevel.map { "\(Int($0 * 100))%" } ?? "FIT",
                    emphasis: Theme.text)

            Rule(axis: .vertical).frame(height: 14)

            if let dimensions = editor.metadata.dimensions {
                reading("Size", dimensions)
            }

            Rule(axis: .vertical).frame(height: 14)

            reading("Profile", editor.metadata.colorProfile ?? "sRGB")

            Spacer(minLength: Theme.space3)

            // What you are looking at, said plainly. This is the one thing on
            // the bar that can be wrong in a way that costs you an edit.
            HStack(spacing: 6) {
                Circle()
                    .fill(editor.isShowingBefore ? Theme.warning : Theme.accent)
                    .frame(width: 5, height: 5)
                Text(editor.isShowingBefore ? "Original" : "Developed")
                    .plateLabel()
                    .foregroundStyle(editor.isShowingBefore ? Theme.warning : Theme.secondaryText)
            }
        }
        .padding(.horizontal, Theme.space3)
        .frame(height: Theme.statusBarHeight)
        .background(Theme.background)
        .overlay(alignment: .top) { Rule() }
    }

    /// A labelled instrument reading: quiet caps label, monospaced value.
    private func reading(
        _ label: String, _ value: String, emphasis: Color = Theme.secondaryText
    ) -> some View {
        HStack(spacing: 5) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .medium))
                .kerning(0.7)
                .foregroundStyle(Theme.tertiaryText)
            Text(value)
                .font(Theme.valueFont)
                .monospacedDigit()
                .foregroundStyle(emphasis)
                .lineLimit(1)
        }
    }
}

/// The open photo plus every canvas-level interaction.
private struct EditCanvas: View {
    @Bindable var editor: EditorModel
    @Bindable var app: AppModel
    @Bindable var workspace: WorkspaceModel

    @State private var isRetouchPainting = false
    @State private var panAtDragStart: CGSize?

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

    /// The canvas proper.
    ///
    /// One rectangle governs everything here: `imageRect`, the photograph's
    /// place in the viewport. The Metal view renders into it and every overlay
    /// is positioned onto it, so pixels and handles are incapable of
    /// disagreeing about where the photograph is — which is the bug class this
    /// layout exists to make impossible.
    private var viewport: some View {
        GeometryReader { proxy in
            let viewportSize = proxy.size
            let rect = imageRect(in: viewportSize)

            ZStack {
                MetalCanvasView(image: editor.previewCIImage,
                                context: editor.renderContext,
                                imageRect: rect)
                    .allowsHitTesting(false)

                // A dropped shadow under the frame, so the photograph sits on
                // the canvas rather than being a hole cut in it.
                Rectangle()
                    .fill(.clear)
                    .frame(width: rect.width, height: rect.height)
                    .shadow(color: .black.opacity(0.6), radius: 18, y: 6)
                    .background(Color.black.opacity(0.001))
                    .position(x: rect.midX, y: rect.midY)
                    .allowsHitTesting(false)

                overlays(in: rect)

                Color.clear
                    .contentShape(Rectangle())
                    .gesture(clickGesture(rect: rect))
                    .gesture(panGesture)
            }
            .frame(width: viewportSize.width, height: viewportSize.height)
            .clipped()
        }
        .overlay(alignment: .top) {
            if let prompt = pickerPrompt { pickerBanner(prompt) }
        }
        .overlay(alignment: .bottom) {
            if editor.isCropping { cropBar }
        }
        .overlay(alignment: .topLeading) {
            if editor.isShowingBefore { beforeBadge }
        }
        .overlay(alignment: .bottomLeading) {
            if editor.showsShadowClipping || editor.showsHighlightClipping {
                clippingReadout.padding(Theme.space3).allowsHitTesting(false)
            }
        }
    }

    /// Margin kept between the photograph and the edge of the canvas at Fit, so
    /// the frame is never flush against the chrome.
    private let fitInset: CGFloat = 28

    /// Where the photograph sits in the viewport, at the current zoom and pan.
    private func imageRect(in viewport: CGSize) -> CGRect {
        guard let size = editor.previewPixelSize, size.width > 0, size.height > 0,
              viewport.width > 0, viewport.height > 0 else {
            return CGRect(origin: .zero, size: viewport)
        }

        let available = CGSize(width: max(viewport.width - fitInset * 2, 40),
                               height: max(viewport.height - fitInset * 2, 40))
        // Fit never enlarges: a frame smaller than the window is shown at its
        // own size rather than interpolated up to fill space.
        let fit = min(available.width / size.width, available.height / size.height, 1)
        let scale = editor.zoomLevel.map { CGFloat($0) } ?? fit

        let drawn = CGSize(width: size.width * scale, height: size.height * scale)
        let offset = clampedPan(for: drawn, in: viewport)

        return CGRect(
            x: (viewport.width - drawn.width) / 2 + offset.width,
            y: (viewport.height - drawn.height) / 2 + offset.height,
            width: drawn.width, height: drawn.height
        )
    }

    /// Keeps a pan from throwing the photograph off the canvas.
    ///
    /// On an axis where the frame already fits, it stays centred and the pan is
    /// ignored; on an axis where it overflows, travel stops once that edge
    /// reaches the edge of the viewport.
    private func clampedPan(for drawn: CGSize, in viewport: CGSize) -> CGSize {
        func limit(_ drawnLength: CGFloat, _ viewportLength: CGFloat) -> CGFloat {
            max((drawnLength - viewportLength) / 2, 0)
        }
        let maxX = limit(drawn.width, viewport.width)
        let maxY = limit(drawn.height, viewport.height)
        return CGSize(
            width: min(max(editor.panOffset.width, -maxX), maxX),
            height: min(max(editor.panOffset.height, -maxY), maxY)
        )
    }

    @ViewBuilder
    private func overlays(in rect: CGRect) -> some View {
        Group {
            if editor.isCropping {
                CropOverlay(cropRect: $editor.editStack.geometry.cropRect,
                            displaySize: rect.size)
            } else if let index = editor.selectedSpotIndex {
                RetouchHandles(spot: $editor.editStack.retouch[index], displaySize: rect.size)
            } else if let maskIndex = editor.selectedMaskIndex,
                      let componentIndex = editor.selectedComponentIndex {
                MaskHandles(
                    component: $editor.editStack
                        .localAdjustments[maskIndex].components[componentIndex],
                    displaySize: rect.size
                )
            } else if workspace.activeTool == .heal || workspace.activeTool == .clone {
                retouchPaintOverlay(displaySize: rect.size)
            }
        }
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
    }

    private var beforeBadge: some View {
        Text("BEFORE")
            .plateLabel()
            .foregroundStyle(Theme.text)
            .padding(.horizontal, Theme.space3)
            .padding(.vertical, 6)
            .background(.black.opacity(0.68), in: Capsule())
            .overlay { Capsule().strokeBorder(Theme.warning.opacity(0.5), lineWidth: Theme.hairline) }
            .padding(Theme.space3)
    }

    /// Dragging the canvas moves the photograph under the window when it is
    /// magnified past fitting. `panOffset` is absolute, so each drag starts
    /// from where the last one left off.
    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard editor.canPan, workspace.activeTool == .hand else { return }
                if panAtDragStart == nil { panAtDragStart = editor.panOffset }
                let start = panAtDragStart ?? .zero
                editor.panOffset = CGSize(width: start.width + value.translation.width,
                                          height: start.height + value.translation.height)
            }
            .onEnded { _ in panAtDragStart = nil }
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
    private func clickGesture(rect: CGRect) -> some Gesture {
        let pick = SpatialTapGesture(count: 1)
            .onEnded { value in
                guard editor.canvasPicker != nil else { return }
                let unit = CGPoint(
                    x: min(max((value.location.x - rect.minX) / rect.width, 0), 1),
                    y: min(max(1 - (value.location.y - rect.minY) / rect.height, 0), 1)
                )
                editor.handleCanvasClick(atUnitPoint: unit)
            }
        let toggleZoom = SpatialTapGesture(count: 2)
            .onEnded { _ in
                editor.zoomLevel = editor.zoomLevel == nil ? 1.0 : nil
            }
        return toggleZoom.simultaneously(with: pick)
    }

    private func retouchPaintOverlay(displaySize: CGSize) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let point = unitPoint(value.location, displaySize: displaySize)
                        if !isRetouchPainting {
                            isRetouchPainting = true
                            editor.beginRetouchStroke(at: point)
                        } else {
                            editor.continueRetouchStroke(to: point)
                        }
                    }
                    .onEnded { _ in isRetouchPainting = false }
            )
    }

    private func unitPoint(_ view: CGPoint, displaySize: CGSize) -> CGPoint {
        CGPoint(
            x: min(max(view.x / displaySize.width, 0), 1),
            y: min(max(1 - view.y / displaySize.height, 0), 1)
        )
    }

    // MARK: Picker banner

    private var pickerPrompt: String? {
        switch editor.canvasPicker {
        case .whiteBalance: "Click something that should be neutral gray"
        case .filmBase: "Click a clear piece of film border"
        case .retouchPlace: "Click the defect to remove"
        case .colorRangeSample: "Click the colour to select"
        case .pointColorSample: "Click the colour to target"
        case nil: nil
        }
    }

    private func pickerBanner(_ prompt: String) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Theme.accent)
                .frame(width: 5, height: 5)
            Text(prompt)
                .font(Theme.controlLabel)
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
                .font(Theme.controlLabel)
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
                .font(Theme.controlLabel)
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

/// On-canvas editing for the selected mask component.
///
/// Linear: two pins — full-effect end and fade-out end — joined by a line,
/// with dashed rails marking the gradient band's orientation. Radial: a
/// center pin that moves the ellipse, plus edge pins on the right and top
/// that set each radius. Generated components (luminance, colour range) have
/// no on-canvas geometry, so they draw nothing.
private struct MaskHandles: View {
    @Binding var component: MaskComponent
    let displaySize: CGSize

    var body: some View {
        ZStack {
            switch component.shape {
            case .linear: linearHandles
            case .radial: radialHandles
            case .brush: brushOverlay
            case .luminance, .colorRange, .subject, .person, .background, .sky: EmptyView()
            }
        }
        .allowsHitTesting(true)
    }

    // MARK: Brush

    @State private var isPainting = false

    private var brushOverlay: some View {
        ZStack {
            ForEach(component.brushStrokes) { stroke in
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
                                component.brushStrokes.append(BrushStroke(
                                    points: [point], radius: component.brushSize,
                                    feather: component.brushFeather,
                                    flow: component.brushFlow
                                ))
                            } else if let strokeIndex = component.brushStrokes.indices.last,
                                      let previous = component.brushStrokes[strokeIndex].points.last {
                                let threshold = max(component.brushSize * 0.12, 0.001)
                                if hypot(point.x - previous.x, point.y - previous.y) >= threshold {
                                    component.brushStrokes[strokeIndex].points.append(point)
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
        let start = viewPoint(component.startPoint)
        let end = viewPoint(component.endPoint)

        return ZStack {
            Path { path in
                path.move(to: start)
                path.addLine(to: end)
            }
            .stroke(.white.opacity(0.75), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

            CanvasPin(at: start, filled: true)
                .gesture(dragPin { component.startPoint = $0 })
                .help("Full effect")
            CanvasPin(at: end, filled: false)
                .gesture(dragPin { component.endPoint = $0 })
                .help("Fades to nothing")
        }
    }

    // MARK: Radial

    private var radialHandles: some View {
        let center = viewPoint(component.center)
        let radiusX = component.radiusX * displaySize.width
        let radiusY = component.radiusY * displaySize.height

        return ZStack {
            Ellipse()
                .stroke(.white.opacity(0.75),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .frame(width: radiusX * 2, height: radiusY * 2)
                .position(center)
                .allowsHitTesting(false)

            CanvasPin(at: center, filled: true)
                .gesture(dragPin { component.center = $0 })
                .help("Move")

            CanvasPin(at: CGPoint(x: center.x + radiusX, y: center.y), filled: false)
                .gesture(
                    DragGesture(minimumDistance: 1).onChanged { value in
                        let dx = abs(value.location.x - center.x)
                        component.radiusX = min(max(Double(dx / displaySize.width), 0.02), 1)
                    }
                )
                .help("Width")

            CanvasPin(at: CGPoint(x: center.x, y: center.y - radiusY), filled: false)
                .gesture(
                    DragGesture(minimumDistance: 1).onChanged { value in
                        let dy = abs(center.y - value.location.y)
                        component.radiusY = min(max(Double(dy / displaySize.height), 0.02), 1)
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
        if spot.kind == .stroke {
            strokeOverlay
        } else {
            circleHandles
        }
    }

    private var strokeOverlay: some View {
        Path { path in
            guard let first = spot.strokePoints.first else { return }
            path.move(to: viewPoint(first))
            for point in spot.strokePoints.dropFirst() {
                path.addLine(to: viewPoint(point))
            }
        }
        .stroke(.white.opacity(0.85),
                style: StrokeStyle(
                    lineWidth: max(spot.radius * displaySize.width * 2, 2),
                    lineCap: .round,
                    lineJoin: .round
                ))
    }

    private var circleHandles: some View {
        let radius = spot.radius * displaySize.width
        let dest = viewPoint(spot.center)
        let source = viewPoint(CGPoint(x: spot.center.x + spot.sourceOffset.dx,
                                       y: spot.center.y + spot.sourceOffset.dy))

        return ZStack {
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
