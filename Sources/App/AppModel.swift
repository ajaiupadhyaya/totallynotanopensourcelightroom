import Foundation
import Observation

/// Top-level application state: owns the catalog, the list of library entries,
/// and the editor for the currently-open photo. Navigation is simply whether
/// ``editor`` is non-nil (photo open) or nil (showing the library).
@Observable
final class AppModel {
    /// All catalog entries, newest first.
    private(set) var entries: [CatalogEntry] = []

    /// The editor for the open photo, or nil when showing the library.
    private(set) var editor: EditorModel?

    /// A user-facing message when catalog IO fails.
    private(set) var errorMessage: String?

    private let catalog: CatalogStore
    private let thumbnails: ThumbnailGenerator

    init() {
        if let base = try? AppModel.baseDirectory(),
           let store = try? CatalogStore(path: base.appendingPathComponent("catalog.sqlite").path) {
            catalog = store
            thumbnails = ThumbnailGenerator(directory: base.appendingPathComponent("thumbnails", isDirectory: true))
        } else {
            // Fall back to an in-memory catalog so the app still runs.
            catalog = (try? CatalogStore()) ?? CatalogStore.inMemoryUnsafe()
            thumbnails = ThumbnailGenerator(
                directory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("PhotoEditorThumbnails", isDirectory: true)
            )
            errorMessage = "Could not open the on-disk catalog; the library won't persist this session."
        }
        reload()
    }

    // MARK: Library

    func reload() {
        do {
            entries = try catalog.allEntries()
        } catch {
            errorMessage = "Failed to load the library: \(error.localizedDescription)"
        }
    }

    /// Imports a photo: records a catalog entry and generates its initial
    /// thumbnail from the untouched original. Returns the stored entry.
    @discardableResult
    func importPhoto(from url: URL) -> CatalogEntry? {
        var entry = CatalogEntry(
            id: UUID(),
            fileURL: url,
            dateImported: Date(),
            editStack: EditStack(),
            thumbnailPath: nil
        )
        if let cgImage = ThumbnailGenerator.thumbnailCGImage(for: url),
           let thumbnailURL = thumbnails.write(cgImage, id: entry.id) {
            entry.thumbnailPath = thumbnailURL
        }
        do {
            try catalog.save(entry)
            reload()
            return entry
        } catch {
            errorMessage = "Import failed: \(error.localizedDescription)"
            return nil
        }
    }

    /// Removes an entry from the library and deletes its thumbnail. The
    /// original photo file on disk is never touched.
    func removeFromLibrary(_ entry: CatalogEntry) {
        if editor?.entry.id == entry.id { editor = nil }
        try? catalog.delete(id: entry.id)
        thumbnails.remove(id: entry.id)
        entries.removeAll { $0.id == entry.id }
    }

    // MARK: Editor navigation

    func open(_ entry: CatalogEntry) {
        editor = EditorModel(
            entry: entry,
            catalog: catalog,
            thumbnails: thumbnails,
            onPersist: { [weak self] in self?.refreshEntry(entry.id) }
        )
    }

    func closeEditor() {
        editor?.commitEdit() // flush any pending edits before leaving
        editor = nil
    }

    // MARK: Private

    /// Splices a single re-fetched entry back into the list so the library grid
    /// reflects committed edits (e.g. an updated thumbnail).
    private func refreshEntry(_ id: UUID) {
        guard let updated = try? catalog.entry(id: id),
              let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index] = updated
    }

    private static func baseDirectory() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = support.appendingPathComponent("PhotoEditor", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private extension CatalogStore {
    /// Last-resort in-memory store for the (near-impossible) case where even the
    /// in-memory open throws; keeps `AppModel.init` non-throwing.
    static func inMemoryUnsafe() -> CatalogStore {
        // swiftlint:disable:next force_try
        try! CatalogStore()
    }
}
