import AppKit
import SwiftUI

/// Single-key tool selection, the way a darkroom keeps its tools under the
/// hand rather than behind a menu.
///
/// These deliberately are *not* hidden `Button.keyboardShortcut` bindings.
/// This window always keeps text fields on screen — the library search field,
/// preset, snapshot and film-stock names — and a SwiftUI key equivalent fires
/// even while one of them holds focus. Typing "beach" into search would trip
/// Brush, Eyedropper, Crop and Hand. A local event monitor can ask who owns
/// the keyboard first and let the field editor win.
///
/// This assumes the app's single window (``PhotoEditorApp`` removes the New
/// command), so exactly one monitor is ever installed.
struct ToolKeyMonitor: ViewModifier {
    let app: AppModel
    let workspace: WorkspaceModel

    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    handle(event) ? nil : event
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }

    /// Returns true when the keystroke was consumed as a tool shortcut.
    private func handle(_ event: NSEvent) -> Bool {
        guard !isTypingText, !isSheetPresented else { return false }

        // Anything carrying a command/option/control belongs to a real menu
        // shortcut, not to the tool rail.
        let reserved: NSEvent.ModifierFlags = [.command, .option, .control]
        guard event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .isDisjoint(with: reserved) else { return false }

        guard let editor = app.editor,
              let key = event.charactersIgnoringModifiers?.lowercased() else { return false }

        if key == "\\" {
            editor.isShowingBefore.toggle()
            return true
        }

        guard let tool = EditorTool(shortcutKey: key) else { return false }
        workspace.activate(tool, in: editor)
        return true
    }

    /// True while a text field owns the keyboard. SwiftUI text fields are
    /// backed by the window's shared field editor, which reports as an
    /// `NSTextView`, so both cases have to be covered.
    private var isTypingText: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        return responder is NSTextView || responder is NSTextField
    }

    /// Sheets (export, in particular) own their keystrokes outright.
    private var isSheetPresented: Bool {
        NSApp.keyWindow?.isSheet ?? false
    }
}

extension View {
    /// Installs the bare-key tool shortcuts advertised by the tool rail.
    func toolKeyShortcuts(app: AppModel, workspace: WorkspaceModel) -> some View {
        modifier(ToolKeyMonitor(app: app, workspace: workspace))
    }
}
