import SwiftUI

/// The menu bar.
///
/// Every command here already existed as a keystroke; what it lacked was a
/// place to be found. A shortcut nobody can discover is a shortcut for the
/// person who wrote it, and an editor with thirty of them and no menus asks
/// each new user to read the source. The menu bar is also where macOS puts
/// the answers to "what can this app do" — so this is a feature list as much
/// as a control surface.
///
/// **Bare-key tool shortcuts are deliberately not attached here.** `B` for
/// brush and `C` for crop are handled by ``ToolKeyMonitor``, which yields to
/// text fields; binding them as menu shortcuts would make them win everywhere,
/// and typing "crop" into the search field would change tools four times.
struct EditorCommands: Commands {
    @Bindable var app: AppModel
    @Bindable var workspace: WorkspaceModel
    @Bindable var panels: PanelVisibility

    private var editor: EditorModel? { app.editor }

    var body: some Commands {
        // MARK: File

        CommandGroup(replacing: .newItem) {
            Button("Import Photographs…") { app.isShowingImporter = true }
                .keyboardShortcut("i", modifiers: .command)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Export…") { app.isShowingExportSheet = true }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(editor == nil)

            Divider()

            Button("Create Virtual Copy") {
                if let entry = editor?.entry { app.createVirtualCopy(of: entry) }
            }
            .keyboardShortcut("'", modifiers: .command)
            .disabled(editor == nil)
        }

        // MARK: Edit

        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { editor?.undo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(editor?.canUndo != true)

            Button("Redo") { editor?.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(editor?.canRedo != true)
        }

        CommandGroup(after: .pasteboard) {
            Divider()

            Button("Copy Develop Settings") {
                if let entry = editor?.entry { app.copySettings(from: entry) }
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(editor == nil)

            Button(app.copiedFromName.map { "Paste Settings from \($0)" } ?? "Paste Settings") {
                if let entry = editor?.entry { app.pasteSettings(to: [entry]) }
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])
            .disabled(!app.canPasteSettings || editor == nil)

            Divider()

            Button("Reset All Adjustments") { editor?.resetAdjustments() }
                .disabled(editor == nil)
        }

        // MARK: View

        CommandGroup(after: .toolbar) {
            Button("Fit in Window") { editor?.zoomLevel = nil }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(editor == nil)
            Button("Actual Size") { editor?.zoomLevel = 1.0 }
                .keyboardShortcut("1", modifiers: .command)
                .disabled(editor == nil)
            Button("Zoom to 200%") { editor?.zoomLevel = 2.0 }
                .keyboardShortcut("2", modifiers: .command)
                .disabled(editor == nil)

            Divider()

            Toggle("Show Roll", isOn: $panels.isShowingLibrary)
                .keyboardShortcut("b", modifiers: .command)
            Toggle("Show Develop", isOn: $panels.isShowingDevelop)
                .keyboardShortcut("d", modifiers: .command)

            Divider()

            Button(editor?.isShowingBefore == true ? "Show Developed" : "Show Original") {
                editor?.isShowingBefore.toggle()
            }
            .disabled(editor == nil)

            Button(editor?.isFocusPeakingEnabled == true
                   ? "Hide Focus Peaking" : "Show Focus Peaking") {
                editor?.isFocusPeakingEnabled.toggle()
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(editor == nil)

            Button(editor?.isShowingMaskOverlay == true
                   ? "Hide Mask Overlay" : "Show Mask Overlay") {
                editor?.isShowingMaskOverlay.toggle()
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            .disabled(editor == nil)

            Divider()

            Button(editor?.showsShadowClipping == true
                   ? "Hide Shadow Clipping" : "Show Shadow Clipping") {
                editor?.showsShadowClipping.toggle()
            }
            .disabled(editor == nil)

            Button(editor?.showsHighlightClipping == true
                   ? "Hide Highlight Clipping" : "Show Highlight Clipping") {
                editor?.showsHighlightClipping.toggle()
            }
            .disabled(editor == nil)
        }

        // MARK: Develop

        CommandMenu("Develop") {
            Button("Convert Roll") {
                if let entry = editor?.entry,
                   let roll = app.rollModel.roll(for: entry) {
                    Task { await app.rollModel.convertRoll(roll) }
                }
            }
            .disabled(editor.flatMap { app.rollModel.roll(for: $0.entry) } == nil
                      || app.rollModel.isConverting)

            Divider()

            Button("Adjust") { workspace.inspectorMode = .adjust }
                .keyboardShortcut("1", modifiers: [.command, .option])
            Button("Masks") { workspace.inspectorMode = .masks }
                .keyboardShortcut("2", modifiers: [.command, .option])
            Button("History") { workspace.inspectorMode = .history }
                .keyboardShortcut("3", modifiers: [.command, .option])

            Divider()

            Menu("Tool") {
                // No shortcuts attached — see the note on this type.
                ForEach(EditorTool.allCases) { tool in
                    Button(tool.shortcutHint.map { "\(tool.label)  (\($0))" } ?? tool.label) {
                        if let editor { workspace.activate(tool, in: editor) }
                    }
                }
            }
            .disabled(editor == nil)

            Divider()

            Button("Convert Film Negative") { editor?.enableFilmNegative() }
                .disabled(editor == nil)
            Button("Sample Film Base") { editor?.sampleFilmBase() }
                .disabled(editor == nil)
        }

        // MARK: Frame

        CommandMenu("Frame") {
            Menu("Rating") {
                ForEach(0...5, id: \.self) { stars in
                    Button(stars == 0 ? "None" : String(repeating: "★", count: stars)) {
                        if let entry = editor?.entry { app.setRating(stars, for: entry) }
                    }
                }
            }
            .disabled(editor == nil)

            Button("Pick") {
                if let entry = editor?.entry { app.setFlag(.picked, for: entry) }
            }
            .disabled(editor == nil)

            Button("Reject") {
                if let entry = editor?.entry { app.setFlag(.rejected, for: entry) }
            }
            .disabled(editor == nil)

            Button("Remove Flag") {
                if let entry = editor?.entry { app.setFlag(.unflagged, for: entry) }
            }
            .disabled(editor == nil)

            Divider()

            Menu("Colour Label") {
                ForEach(ColorLabel.allCases) { label in
                    Button(label.displayName) {
                        if let entry = editor?.entry { app.setColorLabel(label, for: entry) }
                    }
                }
            }
            .disabled(editor == nil)

            Divider()

            Button("Remove from Library") {
                if let entry = editor?.entry { app.removeFromLibrary(entry) }
            }
            .disabled(editor == nil)
        }

        // MARK: Help

        CommandGroup(replacing: .help) {
            Link("Project on GitHub",
                 destination: URL(string:
                    "https://github.com/ajaiupadhyaya/totallynotanopensourcelightroom")!)
        }
    }
}
