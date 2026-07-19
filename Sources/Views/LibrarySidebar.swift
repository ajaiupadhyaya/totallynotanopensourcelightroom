import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The library sidebar: filters, then a filmstrip of every matching frame.
///
/// Selection drives the canvas directly — clicking a frame loads it, so there
/// is no separate "open" step to break the rhythm of working through a roll.
struct LibrarySidebar: View {
    @Bindable var app: AppModel

    @State private var isImporting = false
    @State private var filter = LibraryFilter()
    @State private var searchText = ""
    @State private var isShowingBatchExport = false

    private var visibleEntries: [CatalogEntry] {
        app.entries.filter { filter.matches($0, search: searchText) }
    }

    /// What a batch action applies to: the selection, or everything visible
    /// when nothing is selected.
    private var actionTargets: [CatalogEntry] {
        let selected = visibleEntries.filter { app.selection.contains($0.id) }
        return selected.isEmpty ? visibleEntries : selected
    }

    var body: some View {
        VStack(spacing: 0) {
            LibraryFilterBar(filter: $filter,
                             visibleCount: visibleEntries.count,
                             totalCount: app.entries.count)
            Divider()
            filmstrip
        }
        .editorSurface()
        .searchable(text: $searchText, placement: .sidebar, prompt: "Camera, lens, file…")
        .navigationTitle("Library")
        .toolbar { toolbarContent }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.jpeg, .png, .heic, .tiff, .rawImage, .image],
            allowsMultipleSelection: true
        ) { result in
            handleImport(result)
        }
        .sheet(isPresented: $isShowingBatchExport) {
            BatchExportSheet(app: app, entries: actionTargets)
        }
    }

    @ViewBuilder
    private var filmstrip: some View {
        if app.entries.isEmpty {
            emptyState
        } else if visibleEntries.isEmpty {
            noMatchesState
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(visibleEntries) { entry in
                        // A real Button rather than a view with tap gestures
                        // attached. Stacking `.onTapGesture` handlers on a
                        // custom row hit-tests unreliably — whichever handler
                        // ends up outermost can swallow the tap — and it gives
                        // up the accessibility and keyboard behavior a button
                        // gets for free.
                        Button {
                            select(entry)
                        } label: {
                            FilmstripRow(
                                entry: entry,
                                isSelected: app.selection.contains(entry.id),
                                isOpen: app.editor?.entry.id == entry.id
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(entry.fileName)
                        .contextMenu { contextMenu(for: entry) }
                    }
                }
                .padding(10)
            }
            .focusable()
            .focusEffectDisabled()
            .onKeyPress { press in
                CullingCommands.handle(key: press.key, on: actionTargets, app: app)
                    ? .handled : .ignored
            }
        }
    }

    // MARK: Selection

    /// Command-click extends the selection; a plain click replaces it.
    private func select(_ entry: CatalogEntry) {
        if NSEvent.modifierFlags.contains(.command) {
            if app.selection.contains(entry.id) {
                app.selection.remove(entry.id)
            } else {
                app.selection.insert(entry.id)
            }
        } else {
            app.selection = [entry.id]
            app.open(entry)
        }
    }

    /// A context action applies to the whole selection when the clicked frame
    /// is part of it, and to just that frame otherwise — as in Finder.
    private func targetsIncluding(_ entry: CatalogEntry) -> [CatalogEntry] {
        app.selection.contains(entry.id) && app.selection.count > 1
            ? visibleEntries.filter { app.selection.contains($0.id) }
            : [entry]
    }

    @ViewBuilder
    private func contextMenu(for entry: CatalogEntry) -> some View {
        Button("Edit") { app.open(entry) }

        Divider()

        Menu("Rating") {
            ForEach(0...5, id: \.self) { stars in
                Button(stars == 0 ? "None" : String(repeating: "★", count: stars)) {
                    for target in targetsIncluding(entry) { app.setRating(stars, for: target) }
                }
            }
        }
        Menu("Flag") {
            ForEach(PickFlag.allCases) { flag in
                Button(flag.displayName) {
                    for target in targetsIncluding(entry) { app.setFlag(flag, for: target) }
                }
            }
        }
        Menu("Color Label") {
            ForEach(ColorLabel.allCases) { label in
                Button(label.displayName) {
                    for target in targetsIncluding(entry) { app.setColorLabel(label, for: target) }
                }
            }
        }

        Divider()

        Button("Copy Settings") { app.copySettings(from: entry) }
        Button("Paste Settings") { app.pasteSettings(to: targetsIncluding(entry)) }
            .disabled(!app.canPasteSettings)

        Divider()

        Button("Export…") {
            app.selection = Set(targetsIncluding(entry).map(\.id))
            isShowingBatchExport = true
        }
        Button("Remove from Library", role: .destructive) {
            for target in targetsIncluding(entry) { app.removeFromLibrary(target) }
            app.selection.removeAll()
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if app.canPasteSettings {
                Button {
                    app.pasteSettings(to: actionTargets)
                } label: {
                    Label("Paste Settings", systemImage: "doc.on.clipboard")
                }
                .help("Apply the copied look to \(actionTargets.count) photo(s)")
                .keyboardShortcut("v", modifiers: [.command, .shift])
            }

            Button {
                isShowingBatchExport = true
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .disabled(app.entries.isEmpty)

            Button {
                isImporting = true
            } label: {
                Label("Import Photo", systemImage: "photo.badge.plus")
            }
        }
    }

    // MARK: States

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(Theme.secondaryText)
            Text("Your library is empty")
                .font(.headline)
            Text("Import a JPEG, PNG, HEIC, TIFF, RAW, or a scanned negative.")
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
            Button("Import Photo…") { isImporting = true }
        }
        .padding(24)
        .frame(maxHeight: .infinity)
    }

    private var noMatchesState: some View {
        VStack(spacing: 10) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 32, weight: .thin))
                .foregroundStyle(Theme.secondaryText)
            Text("Nothing matches")
                .font(.headline)
            Button("Clear Filter") {
                filter = LibraryFilter()
                searchText = ""
            }
        }
        .padding(24)
        .frame(maxHeight: .infinity)
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        guard case let .success(urls) = result else {
            if case let .failure(error) = result {
                NSLog("PhotoEditor: import failed — \(error.localizedDescription)")
            }
            return
        }

        var lastImported: CatalogEntry?
        for url in urls {
            let needsScopedAccess = url.startAccessingSecurityScopedResource()
            lastImported = app.importPhoto(from: url) ?? lastImported
            if needsScopedAccess { url.stopAccessingSecurityScopedResource() }
        }
        if let entry = lastImported {
            app.selection = [entry.id]
            app.open(entry)
        }
    }
}

/// One frame in the filmstrip.
private struct FilmstripRow: View {
    let entry: CatalogEntry
    let isSelected: Bool
    let isOpen: Bool

    var body: some View {
        HStack(spacing: 10) {
            thumbnail
                .frame(width: 84, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                // A rejected frame dims rather than disappearing, so the
                // decision stays visible and reversible mid-pass.
                .opacity(entry.flag == .rejected ? Theme.rejectedOpacity : 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.fileName)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 4) {
                    if entry.rating > 0 {
                        HStack(spacing: 1) {
                            ForEach(1...entry.rating, id: \.self) { _ in
                                Image(systemName: "star.fill").font(.system(size: 7))
                            }
                        }
                        .foregroundStyle(Theme.accent)
                    }
                    if entry.flag != .unflagged {
                        Image(systemName: entry.flag.symbolName)
                            .font(.system(size: 8))
                            .foregroundStyle(entry.flag == .rejected
                                             ? AnyShapeStyle(.red) : AnyShapeStyle(Theme.accent))
                    }
                    if entry.colorLabel != .none {
                        Circle().fill(labelColor).frame(width: 7, height: 7)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(isOpen ? Theme.accent.opacity(0.22)
                      : isSelected ? Theme.control : .clear)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(isOpen ? Theme.accent : .clear, lineWidth: 1.5)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let path = entry.thumbnailPath, let image = NSImage(contentsOf: path) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Theme.control
                Image(systemName: "photo").foregroundStyle(Theme.secondaryText)
            }
        }
    }

    private var labelColor: Color {
        switch entry.colorLabel {
        case .none: .clear
        case .red: .red
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .purple: .purple
        }
    }
}

/// Filter criteria for the library.
struct LibraryFilter: Equatable {
    var minimumRating = 0
    var flag: PickFlag?
    var colorLabel: ColorLabel?

    var isActive: Bool {
        minimumRating > 0 || flag != nil || colorLabel != nil
    }

    func matches(_ entry: CatalogEntry, search: String = "") -> Bool {
        if entry.rating < minimumRating { return false }
        if let flag, entry.flag != flag { return false }
        if let colorLabel, entry.colorLabel != colorLabel { return false }

        let query = search.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            let haystack = [entry.fileName, entry.cameraModel, entry.lensModel]
                .compactMap { $0 }
                .joined(separator: " ")
            if !haystack.localizedCaseInsensitiveContains(query) { return false }
        }
        return true
    }
}

/// The filter controls above the filmstrip.
private struct LibraryFilterBar: View {
    @Binding var filter: LibraryFilter
    let visibleCount: Int
    let totalCount: Int

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 2) {
                ForEach(1...5, id: \.self) { star in
                    Button {
                        filter.minimumRating = filter.minimumRating == star ? 0 : star
                    } label: {
                        Image(systemName: star <= filter.minimumRating ? "star.fill" : "star")
                            .font(.system(size: 11))
                            .foregroundStyle(star <= filter.minimumRating
                                             ? AnyShapeStyle(Theme.accent)
                                             : AnyShapeStyle(Theme.secondaryText))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Text(filter.isActive ? "\(visibleCount)/\(totalCount)" : "\(totalCount)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(Theme.secondaryText)
            }

            HStack(spacing: 6) {
                Picker("", selection: $filter.flag) {
                    Text("Any Flag").tag(PickFlag?.none)
                    ForEach(PickFlag.allCases) { flag in
                        Text(flag.displayName).tag(PickFlag?.some(flag))
                    }
                }
                .labelsHidden()

                Picker("", selection: $filter.colorLabel) {
                    Text("Any Label").tag(ColorLabel?.none)
                    ForEach(ColorLabel.allCases) { label in
                        Text(label.displayName).tag(ColorLabel?.some(label))
                    }
                }
                .labelsHidden()
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}
