import SwiftUI

/// Entry point for the editor.
@main
struct PhotoEditorApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
        }
        .windowToolbarStyle(.unified)
        .commands {
            // No document model, so drop the default "New" menu item.
            CommandGroup(replacing: .newItem) {}
        }
    }
}

/// The single application window.
///
/// One window, two sliding sidebars — the library on the left and the develop
/// controls on the right — rather than separate windows or a modal swap between
/// modes. Keeping the photo in the same place on screen the whole time matters
/// more here than it would in most apps: moving the image around while you are
/// judging its color and tone forces your eye to re-adapt every time.
///
/// - `⌘B` toggles the library sidebar
/// - `⌘D` toggles the develop panel
struct RootView: View {
    @State private var app = AppModel()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var isShowingDevelop = true

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            LibrarySidebar(app: app)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 420)
        } detail: {
            DetailArea(app: app, isShowingDevelop: $isShowingDevelop)
        }
        .navigationSplitViewStyle(.balanced)
        .background(Theme.background)
        .frame(minWidth: 1000, minHeight: 680)
        .toolbarBackground(Theme.surface, for: .windowToolbar)
        .background {
            // Menu-less keyboard shortcuts for the two sidebars.
            Group {
                Button("") { toggleLibrary() }
                    .keyboardShortcut("b", modifiers: .command)
                Button("") { isShowingDevelop.toggle() }
                    .keyboardShortcut("d", modifiers: .command)
            }
            .opacity(0)
        }
    }

    private func toggleLibrary() {
        columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
    }
}

/// The center canvas plus the develop panel.
private struct DetailArea: View {
    @Bindable var app: AppModel
    @Binding var isShowingDevelop: Bool

    var body: some View {
        HStack(spacing: 0) {
            CanvasArea(app: app)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if isShowingDevelop, let editor = app.editor {
                Divider()
                SliderPanel(model: editor, app: app)
                    .frame(width: 320)
                    .editorSurface()
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeOut(duration: 0.18), value: isShowingDevelop)
        .background(Theme.background)
    }
}
