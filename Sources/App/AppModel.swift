import AppKit
import CoreImage
import Foundation
import Observation
import UniformTypeIdentifiers

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

    /// Frames selected in the library. Batch actions apply to these.
    var selection: Set<UUID> = []

    /// Whether the export sheet for the open photo is showing. Lives here so
    /// the top bar, keyboard shortcut, and sheet share one source of truth.
    var isShowingExportSheet = false

    /// Whether the import panel is showing. Lives here so the roll's button,
    /// the empty canvas, and the File menu all raise the same one panel rather
    /// than each owning a private copy that the others cannot open.
    var isShowingImporter = false

    /// Internal (not private) so peer models — `RollModel` today, Phase 4's
    /// sync — can read/write catalog records through their own actions
    /// rather than growing this class a passthrough per query.
    let catalog: CatalogStore
    private let thumbnails: ThumbnailGenerator
    private let renderer = EditRenderer()

    /// Roll actions live in their own model (the roadmap's instruction —
    /// EditorModel is long enough). Lazy so `self` exists; observation
    /// happens on RollModel itself, not this container.
    @ObservationIgnored private(set) lazy var rollModel = RollModel(app: self)

    /// The one place peer models surface catalog IO failures to the user.
    func reportError(_ message: String) {
        errorMessage = message
    }

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
        reloadPresets()
        restoreLastSession()
        repairMissingThumbnails()
    }

    /// Injectable seam for tests: the real model against an isolated store,
    /// so nothing touches the user's actual library.
    init(catalog: CatalogStore, thumbnails: ThumbnailGenerator) {
        self.catalog = catalog
        self.thumbnails = thumbnails
        reload()
        reloadPresets()
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
        entry.applyMetadata(PhotoMetadata.read(from: url))
        if let cgImage = makeThumbnailImage(for: entry),
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

    // MARK: Thumbnails

    /// True when the entry's thumbnail is a file we can actually read.
    ///
    /// A recorded path is not proof of a thumbnail: the file may never have
    /// been written, or may have been cleared out from under the catalog.
    private func thumbnailIsReadable(_ entry: CatalogEntry) -> Bool {
        guard let path = entry.thumbnailPath else { return false }
        return FileManager.default.fileExists(atPath: path.path)
    }

    /// Builds a thumbnail image for an entry.
    ///
    /// An unedited frame goes through ImageIO, which is far cheaper than the
    /// develop chain and uses the embedded preview when the format has one. An
    /// edited frame has to be rendered, or the library would show a picture the
    /// photograph no longer is. ImageIO failing is not fatal — some sources it
    /// declines are still decodable — so the render path is also the fallback.
    private func makeThumbnailImage(for entry: CatalogEntry) -> CGImage? {
        if entry.editStack.isNeutralEdit,
           let image = ThumbnailGenerator.thumbnailCGImage(for: entry.fileURL) {
            return image
        }
        // The entry's own process version, so a PV1 photo's thumbnail is
        // decoded — not just rendered — the way its edit was made.
        guard let source = ImageDecoder.loadPreviewImage(
            from: entry.fileURL, maxDimension: 640,
            processVersion: entry.editStack.processVersion
        ) else { return nil }
        return renderer.makeCGImage(renderer.render(source: source, stack: entry.editStack))
    }

    /// Re-renders an entry's thumbnail from its current edit stack **and
    /// records where it went**.
    ///
    /// Storing the path is the half that used to be missing: writing the file
    /// without saving its location leaves the library drawing the empty-frame
    /// placeholder over a thumbnail that exists on disk.
    @discardableResult
    func refreshThumbnail(for entry: CatalogEntry) -> CatalogEntry {
        guard let cgImage = makeThumbnailImage(for: entry),
              let url = thumbnails.write(cgImage, id: entry.id) else { return entry }

        var updated = entry
        updated.thumbnailPath = url
        try? catalog.save(updated)
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = updated
        }
        return updated
    }

    /// Rebuilds every thumbnail that is missing from disk.
    ///
    /// Import can fail to produce one — the original may be briefly unreadable,
    /// on a volume that is not mounted yet, or the thumbnail may be deleted
    /// later. Without a repair pass that frame shows an empty placeholder for
    /// the rest of the library's life, because nothing ever tries again.
    ///
    /// Runs one frame at a time, yielding between each, so a library with a lot
    /// of repairs to do never blocks the window.
    func repairMissingThumbnails() {
        let broken = entries.filter { !thumbnailIsReadable($0) }
        guard !broken.isEmpty else { return }
        Task { @MainActor [weak self] in
            for entry in broken {
                guard let self else { return }
                self.refreshThumbnail(for: entry)
                await Task.yield()
            }
        }
    }

    /// Imports files dropped from Finder, skipping anything that isn't an
    /// image. Returns the entries created.
    ///
    /// Non-images are filtered rather than imported-and-broken: a dropped
    /// folder selection often sweeps in sidecar files (`.xmp`, `.txt`), and a
    /// library full of unreadable placeholders helps nobody.
    @discardableResult
    func importDropped(_ urls: [URL]) -> [CatalogEntry] {
        let imported = urls.filter { url in
            guard let type = UTType(filenameExtension: url.pathExtension.lowercased())
            else { return false }
            return type.conforms(to: .image)
        }.compactMap { importPhoto(from: $0) }

        // A single dropped photo opens straight into the editor, matching the
        // file-picker behavior.
        if imported.count == 1, let entry = imported.first {
            open(entry)
        }
        return imported
    }

    /// Creates a virtual copy: a second catalog entry for the same original
    /// file with an independent edit stack — one negative, several
    /// interpretations, no duplicated pixels.
    ///
    /// The copy starts from the source's current state (edits, rating, label)
    /// and sorts adjacent to it in the filmstrip.
    @discardableResult
    func createVirtualCopy(of entry: CatalogEntry) -> CatalogEntry? {
        let number = (try? catalog.nextCopyNumber(forFileURL: entry.fileURL)) ?? 1
        var copy = CatalogEntry(
            id: UUID(),
            fileURL: entry.fileURL,
            // Copies share the master's import date. CatalogStore performs a
            // stable group sort, keeping every interpretation together even
            // when several files are imported within the same millisecond.
            dateImported: entry.dateImported,
            editStack: entry.editStack,
            thumbnailPath: nil,
            rating: entry.rating,
            flag: entry.flag,
            colorLabel: entry.colorLabel,
            cameraMake: entry.cameraMake,
            cameraModel: entry.cameraModel,
            lensModel: entry.lensModel,
            iso: entry.iso,
            captureDate: entry.captureDate
        )
        copy.copyNumber = number
        do {
            try catalog.save(copy)
            refreshThumbnail(for: copy)
            reload()
            return entries.first { $0.id == copy.id } ?? copy
        } catch {
            errorMessage = "Could not create a virtual copy: \(error.localizedDescription)"
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

    // MARK: Culling — rating, flag, label

    func setRating(_ rating: Int, for entry: CatalogEntry) {
        update(entry) { $0.rating = max(0, min(5, rating)) }
    }

    func setFlag(_ flag: PickFlag, for entry: CatalogEntry) {
        update(entry) { $0.flag = flag }
    }

    func setColorLabel(_ label: ColorLabel, for entry: CatalogEntry) {
        update(entry) { $0.colorLabel = label }
    }

    private func update(_ entry: CatalogEntry, _ mutate: (inout CatalogEntry) -> Void) {
        var updated = entry
        mutate(&updated)
        do {
            try catalog.save(updated)
            if let index = entries.firstIndex(where: { $0.id == entry.id }) {
                entries[index] = updated
            }
        } catch {
            errorMessage = "Could not update the photo: \(error.localizedDescription)"
        }
    }

    // MARK: Copy / paste settings

    /// The edit stack most recently copied, if any.
    private(set) var copiedStack: EditStack?

    /// The name of the photo the copied settings came from, for the UI.
    private(set) var copiedFromName: String?

    var canPasteSettings: Bool { copiedStack != nil }

    func copySettings(from entry: CatalogEntry) {
        copiedStack = entry.editStack
        copiedFromName = entry.fileName
    }

    /// Pastes the copied settings onto the given entries.
    ///
    /// This is the operation that makes a roll of film tractable: develop one
    /// frame, then carry that look across the rest. By default it deliberately
    /// leaves each frame's crop and its own sampled film base alone — see
    /// ``EditTransferOptions``.
    @discardableResult
    func pasteSettings(
        to targets: [CatalogEntry],
        options: EditTransferOptions = .init()
    ) -> Int {
        guard let copiedStack else { return 0 }
        return apply(copiedStack, to: targets, options: options)
    }

    /// Applies a stack to entries, regenerating their thumbnails so the library
    /// grid reflects the change.
    @discardableResult
    func apply(
        _ stack: EditStack,
        to targets: [CatalogEntry],
        options: EditTransferOptions = .init()
    ) -> Int {
        updateStacks(targets.map {
            ($0, $0.editStack.applying(stack, options: options))
        })
    }

    /// Saves prepared (entry, stack) pairs: persists, updates ``entries``,
    /// refreshes thumbnails, reopens the editor if it shows one of them.
    /// The roll-wide / sync-across-selection shared mechanism (spec §Roll
    /// model; Phase 4's sync reuses this) — `apply(_:to:options:)` is now a
    /// caller of this one implementation.
    @discardableResult
    func updateStacks(_ updates: [(CatalogEntry, EditStack)]) -> Int {
        var applied = 0
        for (target, stack) in updates {
            var updated = target
            updated.editStack = stack
            guard updated != target else { continue }
            do {
                try catalog.save(updated)
                if let index = entries.firstIndex(where: { $0.id == target.id }) {
                    entries[index] = updated
                }
                refreshThumbnail(for: updated)
                applied += 1
            } catch {
                errorMessage = "Could not update \(target.fileName): \(error.localizedDescription)"
            }
        }
        // The open editor would otherwise keep showing its stale stack.
        if let editor, updates.contains(where: { $0.0.id == editor.entry.id }) {
            open(entries.first { $0.id == editor.entry.id } ?? editor.entry)
        }
        return applied
    }

    /// Saves entry METADATA changes (rollID, frameNumber — not stacks):
    /// persists and updates ``entries``, no thumbnail work, no editor
    /// reopen. RollModel's assignment path.
    @discardableResult
    func updateEntries(_ updates: [CatalogEntry]) -> Int {
        var applied = 0
        for updated in updates {
            do {
                try catalog.save(updated)
                if let index = entries.firstIndex(where: { $0.id == updated.id }) {
                    entries[index] = updated
                }
                applied += 1
            } catch {
                errorMessage = "Could not update \(updated.fileName): \(error.localizedDescription)"
            }
        }
        return applied
    }

    // MARK: Presets

    private(set) var presets: [DevelopPreset] = []

    func reloadPresets() {
        presets = (try? catalog.allPresets()) ?? []
    }

    @discardableResult
    func savePreset(named name: String, from stack: EditStack, group: String = "User Presets")
        -> DevelopPreset? {
        let preset = DevelopPreset(name: name, group: group, editStack: stack)
        do {
            try catalog.savePreset(preset)
            reloadPresets()
            return preset
        } catch {
            errorMessage = "Could not save the preset: \(error.localizedDescription)"
            return nil
        }
    }

    func deletePreset(_ preset: DevelopPreset) {
        try? catalog.deletePreset(id: preset.id)
        reloadPresets()
    }

    /// All presets as a JSON array — the same Codable the catalog stores.
    func exportedPresetData() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(presets)
    }

    /// Decodes a preset file (a single object or an array), minting fresh ids
    /// so importing twice duplicates rather than silently clobbers. Returns
    /// the count imported.
    @discardableResult
    func importPresetData(_ data: Data) -> Int {
        let decoder = JSONDecoder()
        let decoded: [DevelopPreset]
        if let list = try? decoder.decode([DevelopPreset].self, from: data) {
            decoded = list
        } else if let one = try? decoder.decode(DevelopPreset.self, from: data) {
            decoded = [one]
        } else {
            errorMessage = "That file is not a preset export."
            return 0
        }
        var imported = 0
        for preset in decoded {
            var fresh = preset
            fresh.id = UUID().uuidString
            if (try? catalog.savePreset(fresh)) != nil { imported += 1 }
        }
        reloadPresets()
        return imported
    }

    /// Reads a preset file the person picks. The panel work is here so the
    /// panels stay declarative — the same shape as `ColorMixerPanel.importLUT`.
    func importPresets() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }
        importPresetData(data)
    }

    func exportPresets() {
        guard let data = exportedPresetData() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Presets.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
        } catch {
            errorMessage = "Could not write the preset file: \(error.localizedDescription)"
        }
    }

    // MARK: Batch export

    /// Progress of a running export, or nil when none is in flight.
    private(set) var exportProgress: (completed: Int, total: Int)?

    var isExporting: Bool { exportProgress != nil }

    /// Exports several photos into `directory`, rendering each from its own
    /// full-resolution original.
    ///
    /// The rendering runs off the main actor. A full-resolution render is
    /// hundreds of milliseconds per frame, so exporting a roll on the main
    /// thread freezes the window for the whole batch — the UI has to stay live
    /// enough to show progress and let the work be watched.
    ///
    /// - Returns: The URLs written and any per-photo failures, so the caller
    ///   can report partial success honestly rather than claiming everything
    ///   worked.
    func batchExport(
        _ targets: [CatalogEntry],
        settings: ExportSettings,
        to directory: URL
    ) async -> (written: [URL], failures: [(entry: CatalogEntry, error: Error)]) {
        exportProgress = (0, targets.count)
        defer { exportProgress = nil }

        var written: [URL] = []
        var failures: [(entry: CatalogEntry, error: Error)] = []

        for (index, target) in targets.enumerated() {
            let name = ExportService.suggestedFileName(for: target.fileURL, settings: settings)
            let destination = uniqueURL(in: directory, preferredName: name)
            let sourceURL = target.fileURL
            let stack = target.editStack

            do {
                try await Task.detached(priority: .userInitiated) {
                    // A fresh context per task: CIContext holds caches sized to
                    // the images it has seen, and reusing the preview context
                    // for full-resolution work balloons its memory.
                    let service = ExportService(renderer: EditRenderer(context: CIContext()))
                    try service.export(sourceURL: sourceURL, stack: stack,
                                       settings: settings, to: destination,
                                       entryID: target.id)
                }.value
                written.append(destination)
            } catch {
                failures.append((target, error))
            }
            exportProgress = (index + 1, targets.count)
        }
        return (written, failures)
    }

    /// Avoids silently overwriting an existing file by appending a counter.
    private func uniqueURL(in directory: URL, preferredName: String) -> URL {
        let candidate = directory.appendingPathComponent(preferredName)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }

        let base = candidate.deletingPathExtension().lastPathComponent
        let ext = candidate.pathExtension
        var counter = 2
        while counter < 10_000 {
            let next = directory.appendingPathComponent("\(base)-\(counter).\(ext)")
            if !FileManager.default.fileExists(atPath: next.path) { return next }
            counter += 1
        }
        return candidate
    }

    // MARK: Editor navigation

    func open(_ entry: CatalogEntry) {
        editor = EditorModel(
            entry: entry,
            catalog: catalog,
            thumbnails: thumbnails,
            onPersist: { [weak self] in self?.refreshEntry(entry.id) }
        )
        // A rolled frame's Auto re-solves against its roll's constants — the
        // consistency contract travels with the open photo.
        editor?.rollConversion = rollModel.roll(for: entry)?.conversion
        selection = [entry.id]
        Self.lastOpenedID = entry.id
    }

    func closeEditor() {
        editor?.commitEdit() // flush any pending edits before leaving
        editor = nil
    }

    // MARK: Session restore

    /// The frame that was open when the app last quit.
    ///
    /// Editing a roll is a long, interrupted activity — you quit, come back,
    /// and want to be where you left off rather than hunting for the frame
    /// again. Only the id is stored; if that photo has since been removed from
    /// the library, restoring is simply skipped.
    private static var lastOpenedID: UUID? {
        get {
            guard let raw = UserDefaults.standard.string(forKey: lastOpenedKey) else { return nil }
            return UUID(uuidString: raw)
        }
        set {
            UserDefaults.standard.set(newValue?.uuidString, forKey: lastOpenedKey)
        }
    }

    private static let lastOpenedKey = "lastOpenedEntryID"

    private func restoreLastSession() {
        guard let id = Self.lastOpenedID,
              let entry = entries.first(where: { $0.id == id }) else { return }
        open(entry)
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
