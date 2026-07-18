import CoreImage
import Foundation
import Observation

/// Drives editing of a single catalog entry: loads its original, renders the
/// live non-destructive preview and histogram, tracks undo/redo, and persists
/// changes back to the catalog.
///
/// Persistence and undo capture are *debounced* — dragging a slider re-renders
/// on every tick (for a live preview) but only writes to SQLite and records a
/// single undo step once the burst of changes settles. Undo and redo run
/// through the same commit boundary, so the whole history stays consistent.
@Observable
final class EditorModel {
    /// The entry being edited. Its `id`, `fileURL`, and `dateImported` are
    /// fixed; `editStack`/`thumbnailPath` are refreshed as edits are committed.
    let entry: CatalogEntry

    /// The active edits. Mutating any field re-renders and schedules a commit.
    var editStack: EditStack {
        didSet {
            renderPreview()
            scheduleCommit()
        }
    }

    /// The rendered preview currently shown on screen.
    private(set) var displayImage: CGImage?

    /// A per-channel histogram of the current preview.
    private(set) var histogram: Histogram = .empty

    /// True when the original file could not be found/decoded.
    private(set) var isMissingFile = false

    private var source: CIImage?
    private let renderer = EditRenderer()
    private let catalog: CatalogStore
    private let thumbnails: ThumbnailGenerator
    private let onPersist: () -> Void

    // Undo/redo, captured at debounced commit boundaries.
    private var lastCommittedStack: EditStack
    private var undoStack: [EditStack] = []
    private var redoStack: [EditStack] = []
    private let maxUndoDepth = 100

    private var commitWorkItem: DispatchWorkItem?
    private let commitDelay: TimeInterval

    var fileName: String { entry.fileURL.lastPathComponent }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    init(
        entry: CatalogEntry,
        catalog: CatalogStore,
        thumbnails: ThumbnailGenerator,
        commitDelay: TimeInterval = 0.4,
        onPersist: @escaping () -> Void = {}
    ) {
        self.entry = entry
        self.editStack = entry.editStack
        self.lastCommittedStack = entry.editStack
        self.catalog = catalog
        self.thumbnails = thumbnails
        self.commitDelay = commitDelay
        self.onPersist = onPersist
        loadSource()
        renderPreview()
    }

    /// Resets all adjustments to their neutral defaults.
    func resetAdjustments() {
        editStack = EditStack()
    }

    // MARK: Undo / redo

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(editStack)
        // Restoring an old value must not itself register as a new undo step,
        // so align lastCommittedStack before mutating editStack.
        lastCommittedStack = previous
        editStack = previous
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(editStack)
        lastCommittedStack = next
        editStack = next
    }

    // MARK: Commit (debounced persistence + undo capture)

    private func scheduleCommit() {
        commitWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.commitEdit() }
        commitWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + commitDelay, execute: work)
    }

    /// Captures an undo step (if the stack actually changed) and persists the
    /// current state. Invoked by the debounce timer in normal use; called
    /// directly by tests and when leaving the editor to flush pending work.
    func commitEdit() {
        commitWorkItem?.cancel()
        if editStack != lastCommittedStack {
            undoStack.append(lastCommittedStack)
            if undoStack.count > maxUndoDepth { undoStack.removeFirst() }
            redoStack.removeAll()
            lastCommittedStack = editStack
        }
        persist()
    }

    // MARK: Rendering & IO

    private func loadSource() {
        guard let image = ImageDecoder.loadPreviewImage(from: entry.fileURL) else {
            isMissingFile = true
            source = nil
            return
        }
        source = image
    }

    private func renderPreview() {
        guard let source else {
            displayImage = nil
            histogram = .empty
            return
        }
        let edited = renderer.render(source: source, stack: editStack)
        displayImage = renderer.makeCGImage(edited)
        histogram = renderer.histogram(of: edited)
    }

    private func persist() {
        var updated = entry
        updated.editStack = editStack
        if let preview = displayImage,
           let thumbnailURL = thumbnails.write(preview, id: entry.id) {
            updated.thumbnailPath = thumbnailURL
        }
        try? catalog.save(updated)
        onPersist()
    }
}
