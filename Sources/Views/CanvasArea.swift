import SwiftUI

/// The center canvas: the open photo with zoom, pan, crop, mask handles, and
/// eyedropper targeting — or an empty state.
struct CanvasArea: View {
    @Bindable var app: AppModel

    var body: some View {
        ZStack {
            Theme.canvas.ignoresSafeArea()

            if let editor = app.editor {
                EditCanvas(editor: editor, app: app)
            } else {
                placeholder
            }
        }
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo")
                .font(.system(size: 48, weight: .ultraLight))
                .foregroundStyle(Theme.secondaryText)
            Text(app.entries.isEmpty
                 ? "Import a photo, or drop scans here"
                 : "Select a frame in the library")
                .foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            !app.importDropped(urls).isEmpty
        }
    }
}

/// The open photo plus every canvas-level interaction.
private struct EditCanvas: View {
    @Bindable var editor: EditorModel
    @Bindable var app: AppModel

    /// Zoom factor over image pixels; nil fits the frame to the viewport.
    @State private var zoom: Double?

    /// The crop rect as it stood when crop mode was entered, for Cancel.
    @State private var cropRectOnEntry: CGRect = .unitFrame

    @State private var isShowingExport = false

    var body: some View {
        Group {
            if editor.isMissingFile {
                missingFileState
            } else {
                viewport
            }
        }
        .navigationTitle(editor.fileName)
        .navigationSubtitle(subtitle)
        .toolbar { toolbarContent }
        .sheet(isPresented: $isShowingExport) {
            BatchExportSheet(app: app, entries: [editor.entry])
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let dimensions = editor.metadata.dimensions { parts.append(dimensions) }
        if editor.editStack.filmNegative.isEnabled {
            parts.append(editor.editStack.filmNegative.stockName ?? "Film Negative")
        }
        if let zoom {
            parts.append("\(Int((zoom * 100).rounded()))%")
        }
        return parts.joined(separator: " · ")
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
            let scale = zoom.map { CGFloat($0) } ?? min(fitScale, 1.0)
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
                } else if let index = editor.selectedMaskIndex {
                    MaskHandles(
                        adjustment: $editor.editStack.localAdjustments[index],
                        displaySize: displaySize
                    )
                    .frame(width: displaySize.width, height: displaySize.height)
                }

                if editor.isShowingBefore {
                    Text("BEFORE")
                        .font(.caption.weight(.semibold))
                        .kerning(1.2)
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.6), in: Capsule())
                        .frame(width: displaySize.width, height: displaySize.height,
                               alignment: .topLeading)
                        .padding(12)
                }
            }
            .frame(width: contentSize.width, height: contentSize.height)
        }
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
                zoom = zoom == nil ? 1.0 : nil
            }
        return toggleZoom.simultaneously(with: pick)
    }

    // MARK: Picker banner

    private var pickerPrompt: String? {
        switch editor.canvasPicker {
        case .whiteBalance: "Click something that should be neutral gray"
        case .filmBase: "Click a clear piece of film border"
        case nil: nil
        }
    }

    private func pickerBanner(_ prompt: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "eyedropper")
                .font(.system(size: 10))
            Text(prompt)
                .font(Theme.controlFont)
            Button("Cancel") { editor.canvasPicker = nil }
                .buttonStyle(.plain)
                .font(Theme.controlFont)
                .foregroundStyle(Theme.accent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.black.opacity(0.75), in: Capsule())
        .foregroundStyle(Theme.text)
        .padding(.top, 12)
    }

    // MARK: Crop bar

    private var cropBar: some View {
        HStack(spacing: 10) {
            Text("Recompose the frame")
                .font(Theme.controlFont)
                .foregroundStyle(Theme.secondaryText)
            Button("Cancel") {
                editor.editStack.geometry.cropRect = cropRectOnEntry
                editor.isCropping = false
            }
            .keyboardShortcut(.cancelAction)
            Button("Done") { editor.isCropping = false }
                .keyboardShortcut(.defaultAction)
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.black.opacity(0.75), in: Capsule())
        .padding(.bottom, 14)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                editor.undo()
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .disabled(!editor.canUndo)
            .keyboardShortcut("z", modifiers: .command)

            Button {
                editor.redo()
            } label: {
                Label("Redo", systemImage: "arrow.uturn.forward")
            }
            .disabled(!editor.canRedo)
            .keyboardShortcut("z", modifiers: [.command, .shift])

            zoomMenu

            Button {
                if editor.isCropping {
                    editor.isCropping = false
                } else {
                    cropRectOnEntry = editor.editStack.geometry.cropRect
                    editor.isCropping = true
                }
            } label: {
                Label("Crop", systemImage: "crop")
            }
            .help("Recompose the frame on the canvas")
            .background(editor.isCropping ? Theme.accent.opacity(0.35) : .clear,
                        in: RoundedRectangle(cornerRadius: 5))

            Button {
                editor.isFocusPeakingEnabled.toggle()
            } label: {
                Label("Focus Peaking", systemImage: "camera.metering.partial")
            }
            .help("Highlight what's in critical focus")
            .keyboardShortcut("f", modifiers: [.command, .shift])

            Button {
                editor.isShowingBefore.toggle()
            } label: {
                Label(editor.isShowingBefore ? "Showing Before" : "Before / After",
                      systemImage: editor.isShowingBefore
                        ? "rectangle.righthalf.filled" : "rectangle.lefthalf.filled")
            }
            .help("Compare against the unedited original")
            .keyboardShortcut("\\", modifiers: [])

            Button {
                app.copySettings(from: editor.entry)
            } label: {
                Label("Copy Settings", systemImage: "doc.on.doc")
            }
            .help("Copy this look, to paste onto other frames")
            .keyboardShortcut("c", modifiers: [.command, .shift])

            Button {
                isShowingExport = true
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
        }
    }

    private var zoomMenu: some View {
        Menu {
            Button("Fit") { zoom = nil }
                .keyboardShortcut("0", modifiers: .command)
            Button("50%") { zoom = 0.5 }
            Button("100%") { zoom = 1.0 }
                .keyboardShortcut("1", modifiers: .command)
            Button("200%") { zoom = 2.0 }
        } label: {
            Label(zoom == nil ? "Fit" : "\(Int((zoom! * 100).rounded()))%",
                  systemImage: "plus.magnifyingglass")
        }
        .help("Zoom — double-click the photo to toggle Fit and 100%")
    }

    private var missingFileState: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(Theme.secondaryText)
            Text("This photo's file could not be found.")
                .font(.title3)
            Text(editor.fileName)
                .font(.callout)
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
            }
        }
        .allowsHitTesting(true)
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

            pin(at: start, filled: true)
                .gesture(dragPin { adjustment.startPoint = $0 })
                .help("Full effect")
            pin(at: end, filled: false)
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

            pin(at: center, filled: true)
                .gesture(dragPin { adjustment.center = $0 })
                .help("Move")

            pin(at: CGPoint(x: center.x + radiusX, y: center.y), filled: false)
                .gesture(
                    DragGesture(minimumDistance: 1).onChanged { value in
                        let dx = abs(value.location.x - center.x)
                        adjustment.radiusX = min(max(Double(dx / displaySize.width), 0.02), 1)
                    }
                )
                .help("Width")

            pin(at: CGPoint(x: center.x, y: center.y - radiusY), filled: false)
                .gesture(
                    DragGesture(minimumDistance: 1).onChanged { value in
                        let dy = abs(center.y - value.location.y)
                        adjustment.radiusY = min(max(Double(dy / displaySize.height), 0.02), 1)
                    }
                )
                .help("Height")
        }
    }

    // MARK: Pieces

    private func pin(at point: CGPoint, filled: Bool) -> some View {
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

    private func dragPin(_ update: @escaping (CGPoint) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in update(unitPoint(value.location)) }
    }
}
