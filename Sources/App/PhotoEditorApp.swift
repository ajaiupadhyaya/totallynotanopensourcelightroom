import SwiftUI

/// Entry point for the editor.
@main
struct PhotoEditorApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
        }
        // The system title bar is hidden: the window chrome is drawn by the
        // app itself (see ``TopBar``), so the editor reads as one instrument
        // rather than a Mac document window with panels bolted on.
        .windowStyle(.hiddenTitleBar)
        .commands {
            // No document model, so drop the default "New" menu item.
            CommandGroup(replacing: .newItem) {}
        }
    }
}

/// The single application window: a drawn top bar over three panes — the
/// library filmstrip, the canvas, and the develop column.
///
/// One window, two sliding side panels rather than separate windows or a modal
/// swap between modes. Keeping the photo in the same place on screen the whole
/// time matters more here than it would in most apps: moving the image around
/// while you are judging its color and tone forces your eye to re-adapt every
/// time.
///
/// - `⌘B` toggles the library panel
/// - `⌘D` toggles the develop panel
struct RootView: View {
    @State private var app = AppModel()
    @State private var isShowingLibrary = true
    @State private var isShowingDevelop = true
    @State private var activeTool: EditorTool = .hand
    @State private var inspectorMode: InspectorMode = .adjust

    var body: some View {
        VStack(spacing: 0) {
            TopBar(app: app,
                   isShowingLibrary: $isShowingLibrary,
                   isShowingDevelop: $isShowingDevelop)

            Rectangle().fill(Theme.separator).frame(height: Theme.hairline)

            HStack(spacing: 0) {
                if isShowingLibrary {
                    LibrarySidebar(app: app)
                        .frame(width: Theme.libraryWidth)
                        .transition(.move(edge: .leading))
                    Rectangle().fill(Theme.separator).frame(width: Theme.hairline)
                }

                VStack(spacing: 0) {
                    if let editor = app.editor {
                        ToolOptionsBar(model: editor, activeTool: $activeTool)
                    }

                    HStack(spacing: 0) {
                        if let editor = app.editor {
                            ToolRail(model: editor,
                                     activeTool: $activeTool,
                                     inspectorMode: $inspectorMode)
                            Rectangle().fill(Theme.separator).frame(width: Theme.hairline)
                        }

                        CanvasArea(app: app)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }

                if isShowingDevelop, let editor = app.editor {
                    Rectangle().fill(Theme.separator).frame(width: Theme.hairline)
                    InspectorPanel(model: editor, app: app, mode: $inspectorMode)
                        .frame(width: Theme.inspectorWidth)
                        .transition(.move(edge: .trailing))
                }
            }
            .animation(.easeOut(duration: 0.18), value: isShowingDevelop)
            .animation(.easeOut(duration: 0.18), value: isShowingLibrary)
        }
        .background(Theme.background)
        .frame(minWidth: 1180, minHeight: 720)
        .background { keyboardShortcuts }
        .sheet(isPresented: $app.isShowingExportSheet) {
            if let editor = app.editor {
                BatchExportSheet(app: app, entries: [editor.entry])
            }
        }
    }

    /// Menu-less keyboard shortcuts, active regardless of focus.
    private var keyboardShortcuts: some View {
        Group {
            Button("") { isShowingLibrary.toggle() }
                .keyboardShortcut("b", modifiers: .command)
            Button("") { isShowingDevelop.toggle() }
                .keyboardShortcut("d", modifiers: .command)

            if let editor = app.editor {
                Button("") { editor.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                Button("") { editor.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                Button("") { editor.zoomLevel = nil }
                    .keyboardShortcut("0", modifiers: .command)
                Button("") { editor.zoomLevel = 1.0 }
                    .keyboardShortcut("1", modifiers: .command)
                Button("") { editor.isShowingBefore.toggle() }
                    .keyboardShortcut("\\", modifiers: [])
                Button("") { editor.isFocusPeakingEnabled.toggle() }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                Button("") { app.copySettings(from: editor.entry) }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                Button("") { app.isShowingExportSheet = true }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("") { inspectorMode = .adjust }
                    .keyboardShortcut("1", modifiers: [.command, .option])
                Button("") { inspectorMode = .masks }
                    .keyboardShortcut("2", modifiers: [.command, .option])
                Button("") { inspectorMode = .history }
                    .keyboardShortcut("3", modifiers: [.command, .option])
            }
        }
        .opacity(0)
    }
}

/// The drawn title bar: wordmark, the open frame's designation, and the
/// working controls — zoom, view lamps, undo/redo, export.
///
/// Reads left to right the way a drawing's title block does: identity, then
/// subject, then tools. The leading inset leaves room for the window's
/// traffic lights.
private struct TopBar: View {
    @Bindable var app: AppModel
    @Binding var isShowingLibrary: Bool
    @Binding var isShowingDevelop: Bool

    var body: some View {
        HStack(spacing: 14) {
            // Traffic-light inset.
            Spacer().frame(width: 66)

            Text("PHOTOEDITOR")
                .font(Theme.wordmarkFont)
                .kerning(3)
                .foregroundStyle(Theme.text.opacity(0.9))

            if let editor = app.editor {
                Rectangle()
                    .fill(Theme.separator)
                    .frame(width: Theme.hairline, height: 16)

                Text(designation(for: editor))
                    .font(Theme.valueFont)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            if let editor = app.editor {
                editingControls(editor)
            }

            // Panel toggles live at the far edge, nearest the panels they fold.
            HStack(spacing: 10) {
                LampToggle(label: "Roll", isOn: $isShowingLibrary)
                LampToggle(label: "Develop", isOn: $isShowingDevelop)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: Theme.topBarHeight)
        .background(Theme.surface)
    }

    /// "frame 03 · file.tiff · 3000×2000", like a sleeve label.
    private func designation(for editor: EditorModel) -> String {
        var parts: [String] = []
        if let index = app.entries.firstIndex(where: { $0.id == editor.entry.id }) {
            var frame = String(format: "FRAME %02d", index + 1)
            if editor.entry.isVirtualCopy { frame += " · COPY \(editor.entry.copyNumber)" }
            parts.append(frame)
        }
        parts.append(editor.fileName)
        if let dimensions = editor.metadata.dimensions { parts.append(dimensions) }
        return parts.joined(separator: "  ·  ")
    }

    @ViewBuilder
    private func editingControls(_ editor: EditorModel) -> some View {
        HStack(spacing: 14) {
            // Zoom.
            TabStrip(
                options: [
                    (Optional<Double>.none, "Fit"),
                    (Optional(0.5), "50"),
                    (Optional(1.0), "100"),
                    (Optional(2.0), "200"),
                ],
                selection: Binding(
                    get: { editor.zoomLevel },
                    set: { editor.zoomLevel = $0 }
                )
            )

            Rectangle().fill(Theme.separator).frame(width: Theme.hairline, height: 16)

            // Viewing aids.
            LampToggle(label: "Peak", isOn: Binding(
                get: { editor.isFocusPeakingEnabled },
                set: { editor.isFocusPeakingEnabled = $0 }
            ))
            LampToggle(label: "Before", isOn: Binding(
                get: { editor.isShowingBefore },
                set: { editor.isShowingBefore = $0 }
            ))

            Rectangle().fill(Theme.separator).frame(width: Theme.hairline, height: 16)

            PlateButton(title: "Undo", isEnabled: editor.canUndo) { editor.undo() }
            PlateButton(title: "Redo", isEnabled: editor.canRedo) { editor.redo() }
            PlateButton(title: "Export") { app.isShowingExportSheet = true }
        }
    }
}
