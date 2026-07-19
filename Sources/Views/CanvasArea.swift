import SwiftUI

/// The center canvas: the open photo, or an empty state.
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
                 ? "Import a photo to begin"
                 : "Select a frame in the library")
                .foregroundStyle(Theme.secondaryText)
        }
    }
}

/// The open photo plus its canvas-level controls.
private struct EditCanvas: View {
    @Bindable var editor: EditorModel
    @Bindable var app: AppModel

    @State private var isShowingExport = false

    var body: some View {
        Group {
            if editor.isMissingFile {
                missingFileState
            } else {
                image
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
        return parts.joined(separator: " · ")
    }

    private var image: some View {
        GeometryReader { proxy in
            ZStack {
                if let cgImage = editor.displayImage {
                    Image(decorative: cgImage, scale: 1.0)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(28)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        // A soft edge separates the photo from the surround
                        // without adding a bright border that would bias how
                        // its own tones read.
                        .shadow(color: .black.opacity(0.55), radius: 18, y: 6)
                }

                if editor.isShowingBefore {
                    Text("BEFORE")
                        .font(.caption.weight(.semibold))
                        .kerning(1.2)
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.6), in: Capsule())
                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                               alignment: .topLeading)
                        .padding(24)
                }
            }
        }
    }

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
