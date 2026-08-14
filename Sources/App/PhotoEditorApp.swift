import SwiftUI

/// Entry point for the editor.
///
/// The models are owned here rather than inside ``RootView`` because the menu
/// bar needs them: a command in the File menu and a button in the top bar have
/// to act on one editor, not on two copies that drift apart.
@main
struct PhotoEditorApp: App {
    @State private var app = AppModel()
    @State private var workspace = WorkspaceModel()
    @State private var panels = PanelVisibility()

    var body: some Scene {
        WindowGroup {
            RootView(app: app, workspace: workspace, panels: panels)
                .preferredColorScheme(.dark)
        }
        // The system title bar is hidden: the window chrome is drawn by the
        // app itself (see ``TopBar``), so the editor reads as one instrument
        // rather than a Mac document window with panels bolted on.
        .windowStyle(.hiddenTitleBar)
        .commands {
            EditorCommands(app: app, workspace: workspace, panels: panels)
        }
    }
}

/// Which side panels are showing. A tiny model rather than two `@State` flags
/// so the menu bar and the top bar's lamps drive the same switch.
@Observable
final class PanelVisibility {
    var isShowingLibrary = true
    var isShowingDevelop = true
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
    @Bindable var app: AppModel
    @Bindable var workspace: WorkspaceModel
    @Bindable var panels: PanelVisibility

    var body: some View {
        VStack(spacing: 0) {
            TopBar(app: app,
                   isShowingLibrary: $panels.isShowingLibrary,
                   isShowingDevelop: $panels.isShowingDevelop)

            Rule()

            HStack(spacing: 0) {
                if panels.isShowingLibrary {
                    LibrarySidebar(app: app)
                        .frame(width: Theme.libraryWidth)
                        .transition(.move(edge: .leading))
                    Rule(axis: .vertical)
                }

                VStack(spacing: 0) {
                    if let editor = app.editor {
                        ToolOptionsBar(model: editor, workspace: workspace)
                    }

                    HStack(spacing: 0) {
                        if let editor = app.editor {
                            ToolRail(model: editor, workspace: workspace)
                            Rule(axis: .vertical)
                        }

                        CanvasArea(app: app, workspace: workspace)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }

                if panels.isShowingDevelop, let editor = app.editor {
                    Rule(axis: .vertical)
                    InspectorPanel(model: editor, app: app, mode: $workspace.inspectorMode)
                        .frame(width: Theme.inspectorWidth)
                        .transition(.move(edge: .trailing))
                }
            }
            .animation(Theme.standard, value: panels.isShowingDevelop)
            .animation(Theme.standard, value: panels.isShowingLibrary)
            .animation(Theme.standard, value: workspace.activeTool)
        }
        .background(Theme.background)
        .frame(minWidth: 1180, minHeight: 720)
        .toolKeyShortcuts(app: app, workspace: workspace)
        .onChange(of: app.editor?.entry.id) { workspace.resetForNewPhoto() }
        .sheet(isPresented: $app.isShowingExportSheet) {
            if let editor = app.editor {
                BatchExportSheet(app: app, entries: [editor.entry])
            }
        }
        .sheet(isPresented: $app.isShowingCopySettingsSheet) {
            CopySettingsSheet(app: app)
        }
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
        HStack(spacing: Theme.space4) {
            // Traffic-light inset.
            Spacer().frame(width: 68)

            identity

            Spacer(minLength: Theme.space4)

            if let editor = app.editor {
                editingControls(editor)
            }

            Rule(axis: .vertical).frame(height: 16)

            // Panel toggles live at the far edge, nearest the panels they fold.
            HStack(spacing: Theme.space3) {
                LampToggle(label: "Roll", isOn: $isShowingLibrary, style: .quiet)
                LampToggle(label: "Develop", isOn: $isShowingDevelop, style: .quiet)
            }
        }
        .padding(.horizontal, Theme.panelInset)
        .frame(height: Theme.topBarHeight)
        .background(Theme.surface)
    }

    /// Wordmark, then what is open — read left to right the way a drawing's
    /// title block does: whose instrument, then which subject.
    private var identity: some View {
        HStack(spacing: Theme.space3) {
            Text("PHOTOEDITOR")
                .font(Theme.wordmarkFont)
                .kerning(2.6)
                .foregroundStyle(Theme.text)

            if let editor = app.editor {
                Rule(axis: .vertical).frame(height: 16)

                HStack(spacing: 7) {
                    if let number = frameNumber(for: editor) {
                        Text(number)
                            .font(Theme.indexFont)
                            .foregroundStyle(Theme.filmEdge)
                    }

                    Text(editor.fileName)
                        .font(Theme.body)
                        .foregroundStyle(Theme.text.opacity(0.9))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if editor.entry.isVirtualCopy {
                        Text("COPY \(editor.entry.copyNumber)")
                            .font(.system(size: 9, weight: .medium))
                            .kerning(0.6)
                            .foregroundStyle(Theme.secondaryText)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Theme.control, in: Capsule())
                    }
                }
                .layoutPriority(1)
            }
        }
    }

    /// "FRAME 03", the way a frame is numbered on a contact sheet.
    private func frameNumber(for editor: EditorModel) -> String? {
        guard let index = app.entries.firstIndex(where: { $0.id == editor.entry.id })
        else { return nil }
        return String(format: "FRAME %02d", index + 1)
    }

    @ViewBuilder
    private func editingControls(_ editor: EditorModel) -> some View {
        HStack(spacing: Theme.space4) {
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

            Rule(axis: .vertical).frame(height: 16)

            // Viewing aids.
            LampToggle(label: "Peak", isOn: Binding(
                get: { editor.isFocusPeakingEnabled },
                set: { editor.isFocusPeakingEnabled = $0 }
            ))
            LampToggle(label: "Before", isOn: Binding(
                get: { editor.isShowingBefore },
                set: { editor.isShowingBefore = $0 }
            ))

            Rule(axis: .vertical).frame(height: 16)

            HStack(spacing: Theme.space1) {
                IconButton(icon: .undo, label: "Undo",
                           tint: editor.canUndo ? Theme.secondaryText : Theme.disabledText) {
                    editor.undo()
                }
                .disabled(!editor.canUndo)

                IconButton(icon: .redo, label: "Redo",
                           tint: editor.canRedo ? Theme.secondaryText : Theme.disabledText) {
                    editor.redo()
                }
                .disabled(!editor.canRedo)
            }

            PlateButton(title: "Export", emphasis: .prominent) {
                app.isShowingExportSheet = true
            }
        }
    }
}
