import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The library: a filterable grid of catalog thumbnails, culling controls, and
/// the batch operations that make a whole roll manageable.
///
/// Double-click opens a photo; single click selects, with shift/command
/// extending the selection so copy-paste and batch export can act on many
/// frames at once.
struct LibraryView: View {
    @Bindable var app: AppModel

    @State private var isImporting = false
    @State private var selection: Set<UUID> = []
    @State private var filter = LibraryFilter()
    @State private var isShowingBatchExport = false

    private let columns = [GridItem(.adaptive(minimum: 170, maximum: 240), spacing: 16)]

    /// Entries passing the current filter.
    private var visibleEntries: [CatalogEntry] {
        app.entries.filter(filter.matches)
    }

    /// The entries a batch action applies to: the selection, or everything
    /// visible when nothing is selected.
    private var actionTargets: [CatalogEntry] {
        let selected = visibleEntries.filter { selection.contains($0.id) }
        return selected.isEmpty ? visibleEntries : selected
    }

    var body: some View {
        VStack(spacing: 0) {
            if !app.entries.isEmpty {
                LibraryFilterBar(filter: $filter,
                                 visibleCount: visibleEntries.count,
                                 totalCount: app.entries.count)
                Divider()
            }

            ScrollView {
                if app.entries.isEmpty {
                    emptyState.frame(maxWidth: .infinity, minHeight: 420)
                } else if visibleEntries.isEmpty {
                    noMatchesState.frame(maxWidth: .infinity, minHeight: 420)
                } else {
                    grid
                }
            }
        }
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

    private var grid: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
            ForEach(visibleEntries) { entry in
                ThumbnailCell(entry: entry, isSelected: selection.contains(entry.id))
                    .onTapGesture(count: 2) { app.open(entry) }
                    .simultaneousGesture(TapGesture().modifiers(.command).onEnded {
                        toggle(entry)
                    })
                    .onTapGesture { selection = [entry.id] }
                    .contextMenu { contextMenu(for: entry) }
            }
        }
        .padding(20)
    }

    @ViewBuilder
    private func contextMenu(for entry: CatalogEntry) -> some View {
        Button("Edit") { app.open(entry) }

        Divider()

        Menu("Rating") {
            ForEach(0...5, id: \.self) { stars in
                Button(stars == 0 ? "None" : String(repeating: "★", count: stars)) {
                    applyToTargets(including: entry) { app.setRating(stars, for: $0) }
                }
            }
        }
        Menu("Flag") {
            ForEach(PickFlag.allCases) { flag in
                Button(flag.displayName) {
                    applyToTargets(including: entry) { app.setFlag(flag, for: $0) }
                }
            }
        }
        Menu("Color Label") {
            ForEach(ColorLabel.allCases) { label in
                Button(label.displayName) {
                    applyToTargets(including: entry) { app.setColorLabel(label, for: $0) }
                }
            }
        }

        Divider()

        Button("Copy Settings") { app.copySettings(from: entry) }
        Button("Paste Settings") {
            let targets = targetsIncluding(entry)
            app.pasteSettings(to: targets)
        }
        .disabled(!app.canPasteSettings)

        Divider()

        Button("Export…") {
            selection = Set(targetsIncluding(entry).map(\.id))
            isShowingBatchExport = true
        }
        Button("Remove from Library", role: .destructive) {
            for target in targetsIncluding(entry) {
                app.removeFromLibrary(target)
            }
            selection.removeAll()
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

    // MARK: Selection helpers

    private func toggle(_ entry: CatalogEntry) {
        if selection.contains(entry.id) {
            selection.remove(entry.id)
        } else {
            selection.insert(entry.id)
        }
    }

    /// A right-click acts on the whole selection when the clicked photo is part
    /// of it, and on just that photo otherwise — the standard Finder behavior.
    private func targetsIncluding(_ entry: CatalogEntry) -> [CatalogEntry] {
        selection.contains(entry.id) && selection.count > 1
            ? visibleEntries.filter { selection.contains($0.id) }
            : [entry]
    }

    private func applyToTargets(
        including entry: CatalogEntry, _ action: (CatalogEntry) -> Void
    ) {
        for target in targetsIncluding(entry) { action(target) }
    }

    // MARK: States

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 56, weight: .thin))
                .foregroundStyle(.secondary)
            Text("Your library is empty")
                .font(.title2)
            Text("Import a JPEG, PNG, HEIC, TIFF, RAW, or a scanned negative.")
                .foregroundStyle(.secondary)
            Button("Import Photo…") { isImporting = true }
                .controlSize(.large)
                .padding(.top, 4)
        }
    }

    private var noMatchesState: some View {
        VStack(spacing: 12) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 44, weight: .thin))
                .foregroundStyle(.secondary)
            Text("No photos match the current filter")
                .font(.title3)
            Button("Clear Filter") { filter = LibraryFilter() }
        }
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

        // Opening a single import jumps straight into editing; a bulk import
        // stays in the library.
        if urls.count == 1, let entry = lastImported {
            app.open(entry)
        }
    }
}

/// Filter criteria for the library grid.
struct LibraryFilter: Equatable {
    var minimumRating = 0
    var flag: PickFlag?
    var colorLabel: ColorLabel?

    var isActive: Bool {
        minimumRating > 0 || flag != nil || colorLabel != nil
    }

    func matches(_ entry: CatalogEntry) -> Bool {
        if entry.rating < minimumRating { return false }
        if let flag, entry.flag != flag { return false }
        if let colorLabel, entry.colorLabel != colorLabel { return false }
        return true
    }
}

/// The filter controls above the grid.
private struct LibraryFilterBar: View {
    @Binding var filter: LibraryFilter
    let visibleCount: Int
    let totalCount: Int

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 2) {
                ForEach(1...5, id: \.self) { star in
                    Button {
                        // Clicking the active rating clears it.
                        filter.minimumRating = filter.minimumRating == star ? 0 : star
                    } label: {
                        Image(systemName: star <= filter.minimumRating ? "star.fill" : "star")
                            .foregroundStyle(star <= filter.minimumRating
                                             ? AnyShapeStyle(.tint)
                                             : AnyShapeStyle(.secondary))
                    }
                    .buttonStyle(.plain)
                }
            }
            .help("Show photos rated at least this many stars")

            Picker("Flag", selection: $filter.flag) {
                Text("Any").tag(PickFlag?.none)
                ForEach(PickFlag.allCases) { flag in
                    Text(flag.displayName).tag(PickFlag?.some(flag))
                }
            }
            .labelsHidden()
            .frame(width: 110)

            Picker("Label", selection: $filter.colorLabel) {
                Text("Any Label").tag(ColorLabel?.none)
                ForEach(ColorLabel.allCases) { label in
                    Text(label.displayName).tag(ColorLabel?.some(label))
                }
            }
            .labelsHidden()
            .frame(width: 110)

            if filter.isActive {
                Button("Clear") { filter = LibraryFilter() }
                    .controlSize(.small)
            }

            Spacer()

            Text(filter.isActive ? "\(visibleCount) of \(totalCount)" : "\(totalCount) photos")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }
}

/// A single library grid cell: thumbnail, file name, and culling state.
private struct ThumbnailCell: View {
    let entry: CatalogEntry
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.gray.opacity(0.15))
                if let path = entry.thumbnailPath, let image = NSImage(contentsOf: path) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "photo")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 3)
            }
            .overlay(alignment: .topTrailing) {
                if entry.flag != .unflagged {
                    Image(systemName: entry.flag.symbolName)
                        .font(.caption)
                        .padding(4)
                        .background(.thinMaterial, in: Circle())
                        .padding(6)
                }
            }
            .overlay(alignment: .topLeading) {
                if entry.colorLabel != .none {
                    Circle()
                        .fill(labelColor)
                        .frame(width: 10, height: 10)
                        .padding(8)
                }
            }

            Text(entry.fileName)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)

            if entry.rating > 0 {
                HStack(spacing: 1) {
                    ForEach(1...5, id: \.self) { star in
                        Image(systemName: star <= entry.rating ? "star.fill" : "star")
                            .font(.system(size: 8))
                            .foregroundStyle(star <= entry.rating
                                             ? AnyShapeStyle(.tint)
                                             : AnyShapeStyle(.quaternary))
                    }
                }
            }
        }
        .contentShape(Rectangle())
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
