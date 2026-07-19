import SwiftUI

/// Entry point for the editor.
///
/// A single window that shows either the library grid or, when a photo is open,
/// the editor for that photo (see ``RootView``).
@main
struct PhotoEditorApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .commands {
            // No document model, so drop the default "New" menu item.
            CommandGroup(replacing: .newItem) {}
        }
    }
}

/// Switches between the library and the single-photo editor based on whether a
/// photo is currently open.
struct RootView: View {
    @State private var app = AppModel()

    var body: some View {
        Group {
            if let editor = app.editor {
                EditView(editor: editor, app: app, onClose: { app.closeEditor() })
            } else {
                LibraryView(app: app)
            }
        }
        .frame(minWidth: 900, minHeight: 640)
    }
}
