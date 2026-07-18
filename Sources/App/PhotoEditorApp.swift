import SwiftUI

/// Entry point for the editor.
///
/// A single-window app for now. Document management, multiple photos, and the
/// library grid arrive with the catalog in Phase 3 — until then the window
/// hosts one photo at a time via `EditView`.
@main
struct PhotoEditorApp: App {
    var body: some Scene {
        WindowGroup {
            EditView()
        }
        .commands {
            // No document model yet, so drop the default "New" menu item.
            CommandGroup(replacing: .newItem) {}
        }
    }
}
