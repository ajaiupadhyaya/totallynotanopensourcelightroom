import SwiftUI

/// The editing screen for a single open photo: the image on the left, the
/// adjustment panel on the right, and a toolbar with Library / undo / redo.
struct EditView: View {
    @Bindable var editor: EditorModel

    /// Called to leave the editor and return to the library.
    let onClose: () -> Void

    @State private var isShowingExport = false

    var body: some View {
        Group {
            if editor.isMissingFile {
                missingFileState
            } else {
                HSplitView {
                    imageCanvas
                    SliderPanel(model: editor)
                        .frame(minWidth: 288, idealWidth: 300, maxWidth: 380)
                }
            }
        }
        .navigationTitle(editor.fileName)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    onClose()
                } label: {
                    Label("Library", systemImage: "chevron.left")
                }
            }
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
                    isShowingExport = true
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(editor.isMissingFile)
                .keyboardShortcut("e", modifiers: [.command, .shift])
            }
        }
        .sheet(isPresented: $isShowingExport) {
            ExportSheet(editor: editor)
        }
    }

    private var imageCanvas: some View {
        ZStack {
            Color.black.opacity(0.92)
            if let image = editor.displayImage {
                Image(decorative: image, scale: 1.0)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var missingFileState: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 44, weight: .thin))
                .foregroundStyle(.secondary)
            Text("This photo's file could not be found.")
                .font(.title3)
            Text(editor.fileName)
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Back to Library") { onClose() }
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
