import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The library panel: header, filters, then a filmstrip of every matching
/// frame.
///
/// Selection drives the canvas directly — clicking a frame loads it, so there
/// is no separate "open" step to break the rhythm of working through a roll.
struct LibrarySidebar: View {
    @Bindable var app: AppModel

    @State private var filter = LibraryFilter()
    @State private var searchText = ""
    @State private var isShowingBatchExport = false

    /// Non-nil while the drawn New Roll sheet is up — the frames it will
    /// contain, captured at menu time.
    @State private var newRollTargets: [CatalogEntry]?
    @State private var newRollIdentifier = ""
    @State private var newRollStock = ""

    /// The one roll every target belongs to, or nil (mixed/none) — Convert
    /// Roll only offers itself when the answer is unambiguous.
    private func sharedRoll(of targets: [CatalogEntry]) -> Roll? {
        let ids = Set(targets.compactMap(\.rollID))
        guard ids.count == 1, targets.allSatisfy({ $0.rollID != nil }),
              let id = ids.first else { return nil }
        return app.rollModel.rolls.first { $0.id == id }
    }

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
            header
            Rectangle().fill(Theme.separator).frame(height: Theme.hairline)
            LibraryFilterBar(filter: $filter,
                             searchText: $searchText,
                             visibleCount: visibleEntries.count,
                             totalCount: app.entries.count)
            Rectangle().fill(Theme.separator).frame(height: Theme.hairline)
            filmstrip
        }
        .editorSurface()
        .dropDestination(for: URL.self) { urls, _ in
            !app.importDropped(urls).isEmpty
        }
        .fileImporter(
            isPresented: $app.isShowingImporter,
            allowedContentTypes: [.jpeg, .png, .heic, .tiff, .rawImage, .image],
            allowsMultipleSelection: true
        ) { result in
            handleImport(result)
        }
        .sheet(isPresented: $isShowingBatchExport) {
            BatchExportSheet(app: app, entries: actionTargets)
        }
        .sheet(isPresented: Binding(get: { newRollTargets != nil },
                                    set: { if !$0 { newRollTargets = nil } })) {
            newRollSheet
        }
    }

    /// The drawn New Roll sheet — two InstrumentFields and a PlateButton,
    /// never a stock alert (the house rule the preset-naming alert once
    /// broke).
    private var newRollSheet: some View {
        VStack(alignment: .leading, spacing: Theme.space3) {
            Text("NEW ROLL")
                .sectionLabel(Theme.text)
            InstrumentField(placeholder: "Identifier — \u{201C}2026-08 Portra roll 3\u{201D}",
                            text: $newRollIdentifier)
            InstrumentField(placeholder: "Stock (optional)", text: $newRollStock)
            Text("\(newRollTargets?.count ?? 0) frames, numbered in import order")
                .font(Theme.caption)
                .foregroundStyle(Theme.secondaryText)
            HStack {
                Spacer()
                PlateButton(title: "Cancel") { newRollTargets = nil }
                PlateButton(title: "Create", emphasis: .prominent,
                            isEnabled: !newRollIdentifier
                                .trimmingCharacters(in: .whitespaces).isEmpty) {
                    if let targets = newRollTargets {
                        app.rollModel.createRoll(identifier: newRollIdentifier,
                                                 stock: newRollStock,
                                                 from: targets)
                    }
                    newRollTargets = nil
                    newRollIdentifier = ""
                    newRollStock = ""
                }
            }
        }
        .padding(Theme.space4)
        .frame(width: 340)
        .background(Theme.surface)
    }

    /// "ROLL" + the working actions. The panel is the roll; the header says so.
    private var header: some View {
        HStack(spacing: Theme.space2) {
            Text("ROLL")
                .sectionLabel(Theme.text)

            Spacer()

            if app.canPasteSettings {
                PlateButton(title: "Paste") {
                    app.pasteSettings(to: actionTargets)
                }
            }
            PlateButton(title: "Export", isEnabled: !app.entries.isEmpty) {
                isShowingBatchExport = true
            }
            PlateButton(title: "Import") { app.isShowingImporter = true }
        }
        .padding(.horizontal, Theme.panelInset)
        .padding(.vertical, 9)
        .background {
            // ⇧⌘V pastes onto the working targets, mirroring the button.
            Button("") { app.pasteSettings(to: actionTargets) }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .disabled(!app.canPasteSettings)
                .opacity(0)
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
                LazyVStack(spacing: 6) {
                    ForEach(Array(visibleEntries.enumerated()), id: \.element.id) { index, entry in
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
                                frameNumber: index + 1,
                                rollIdentifier: app.rollModel.roll(for: entry)?.identifier,
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

        Button("Create Virtual Copy") {
            if let copy = app.createVirtualCopy(of: entry) {
                app.selection = [copy.id]
                app.open(copy)
            }
        }

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

        Menu("Roll") {
            Button("New Roll from Selection…") {
                newRollTargets = targetsIncluding(entry)
            }
            if !app.rollModel.rolls.isEmpty {
                Menu("Add to Roll") {
                    ForEach(app.rollModel.rolls) { roll in
                        Button(roll.identifier) {
                            app.rollModel.add(targetsIncluding(entry), to: roll)
                        }
                    }
                }
            }
            if let roll = sharedRoll(of: targetsIncluding(entry)) {
                Button(app.rollModel.isConverting
                       ? "Converting…" : "Convert Roll \u{201C}\(roll.identifier)\u{201D}") {
                    Task { await app.rollModel.convertRoll(roll) }
                }
                .disabled(app.rollModel.isConverting)
            }
        }

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

    // MARK: States

    private var emptyState: some View {
        VStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 2)
                .stroke(Theme.tertiaryText, lineWidth: 1.2)
                .frame(width: 54, height: 38)
            Text("The roll is empty")
                .font(Theme.controlLabel)
            Text("Import a JPEG, PNG, HEIC, TIFF, RAW, or a scanned negative.")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
            PlateButton(title: "Import photographs", emphasis: .prominent) { app.isShowingImporter = true }
        }
        .padding(24)
        .frame(maxHeight: .infinity)
    }

    private var noMatchesState: some View {
        VStack(spacing: 12) {
            Text("0/\(app.entries.count)")
                .font(Theme.valueFont)
                .foregroundStyle(Theme.secondaryText)
            Text("Nothing matches")
                .font(Theme.controlLabel)
            PlateButton(title: "Clear Filter") {
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

/// One frame in the filmstrip, drawn as a frame on a film rebate.
///
/// The frame's image sits on a near-black strip, and above it runs the edge
/// print — frame number, then the stock or camera — in the dim amber of
/// exposed film-edge legend. The rebate isn't decoration: it encodes what the
/// library actually is, frames on rolls, and carries the frame's provenance
/// (what it was shot on) in the place a negative carries it. A virtual copy
/// prints its copy number the same way — it's another frame of the same
/// negative.
private struct FilmstripRow: View {
    let entry: CatalogEntry
    let frameNumber: Int
    let rollIdentifier: String?
    let isSelected: Bool
    let isOpen: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Edge print along the rebate above the frame.
            HStack {
                Text(frameDesignation)
                Spacer()
                Text(edgeLegend)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(Theme.filmEdgeFont)
            .foregroundStyle(Theme.filmEdge.opacity(isOpen || isSelected ? 1 : 0.75))
            .padding(.horizontal, 10)
            .padding(.top, 7)
            .padding(.bottom, 5)

            thumbnail
                .frame(maxWidth: .infinity)
                .frame(height: 108)
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .padding(.horizontal, 8)
                // A rejected frame dims rather than disappearing, so the
                // decision stays visible and reversible mid-pass.
                .opacity(entry.flag == .rejected ? Theme.rejectedOpacity : 1)

            // Culling state along the lower rebate.
            HStack(spacing: 5) {
                if entry.rating > 0 {
                    HStack(spacing: 1.5) {
                        ForEach(1...entry.rating, id: \.self) { _ in
                            StarShape()
                                .fill(Theme.text.opacity(0.85))
                                .frame(width: 7, height: 7)
                        }
                    }
                }
                if entry.flag == .picked {
                    Text("P")
                        .font(Theme.filmEdgeFont)
                        .foregroundStyle(Theme.text.opacity(0.85))
                } else if entry.flag == .rejected {
                    Text("X")
                        .font(Theme.filmEdgeFont)
                        .foregroundStyle(.red.opacity(0.85))
                }
                if entry.colorLabel != .none {
                    Circle().fill(labelColor).frame(width: 6, height: 6)
                }
                Spacer()
                Text(entry.fileName)
                    .font(Theme.filmEdgeFont)
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 10)
            .padding(.top, 5)
            .padding(.bottom, 7)
        }
        .background {
            RoundedRectangle(cornerRadius: 4)
                .fill(Theme.rebate)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(
                    isOpen ? Theme.accent
                    : isSelected ? Theme.separator
                    : Color.white.opacity(0.04),
                    lineWidth: isOpen ? 1.5 : 1
                )
        }
        .contentShape(Rectangle())
    }

    private var frameDesignation: String {
        entry.isVirtualCopy
            ? String(format: "%02d·C%d", frameNumber, entry.copyNumber)
            : String(format: "%02d", frameNumber)
    }

    /// What a rebate legend says: the roll when assigned (the edge print
    /// finally printing something true of the physical roll), else the stock,
    /// else the camera, else the file type — most specific truth available.
    private var edgeLegend: String {
        if let rollIdentifier, !rollIdentifier.isEmpty {
            return rollIdentifier.uppercased()
        }
        if let stock = entry.editStack.filmNegative.stockName, !stock.isEmpty {
            return stock.uppercased()
        }
        if let camera = entry.cameraModel, !camera.isEmpty {
            return camera.uppercased()
        }
        return entry.fileURL.pathExtension.uppercased()
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let path = entry.thumbnailPath, let image = NSImage(contentsOf: path) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Theme.control
                RoundedRectangle(cornerRadius: 2)
                    .stroke(Theme.secondaryText, lineWidth: 1)
                    .frame(width: 28, height: 20)
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

/// The filter controls above the filmstrip: search, minimum rating, flag,
/// and color label — all drawn.
private struct LibraryFilterBar: View {
    @Binding var filter: LibraryFilter
    @Binding var searchText: String
    let visibleCount: Int
    let totalCount: Int

    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 9) {
            searchField

            HStack(spacing: 1) {
                ForEach(1...5, id: \.self) { star in
                    Button {
                        filter.minimumRating = filter.minimumRating == star ? 0 : star
                    } label: {
                        StarShape()
                            .fill(star <= filter.minimumRating
                                  ? AnyShapeStyle(Theme.accent)
                                  : AnyShapeStyle(.clear))
                            .overlay {
                                StarShape()
                                    .stroke(star <= filter.minimumRating
                                            ? Theme.accent : Theme.tertiaryText,
                                            lineWidth: 1)
                            }
                            .frame(width: 11, height: 11)
                            .frame(width: 18, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(filter.minimumRating == star
                          ? "Show every rating" : "Show \(star) stars and above")
                }

                Spacer()

                // The count is the answer to "is a filter hiding something?",
                // so it says so in words rather than making a bare fraction
                // carry the meaning.
                Group {
                    if filter.isActive || !searchText.isEmpty {
                        HStack(spacing: 5) {
                            Text("\(visibleCount) of \(totalCount)")
                                .font(Theme.valueFont)
                                .monospacedDigit()
                                .foregroundStyle(Theme.text)
                            Button {
                                filter = LibraryFilter()
                                searchText = ""
                            } label: {
                                Text("CLEAR")
                                    .plateLabel()
                                    .foregroundStyle(Theme.accent)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Show every frame")
                        }
                    } else {
                        Text(totalCount == 1 ? "1 frame" : "\(totalCount) frames")
                            .font(Theme.valueFont)
                            .monospacedDigit()
                            .foregroundStyle(Theme.tertiaryText)
                    }
                }
            }

            HStack(spacing: Theme.space2) {
                TabStrip(
                    options: [
                        (PickFlag?.none, "All"),
                        (PickFlag?.some(.picked), "Pick"),
                        (PickFlag?.some(.rejected), "Rej"),
                        (PickFlag?.some(.unflagged), "None"),
                    ],
                    selection: $filter.flag,
                    spacing: 11
                )
                .fixedSize()

                Spacer()

                // Color labels as their own colors — data, not chrome.
                HStack(spacing: 0) {
                    ForEach(ColorLabel.allCases.filter { $0 != .none }) { label in
                        let isActive = filter.colorLabel == label
                        Button {
                            filter.colorLabel = isActive ? nil : label
                        } label: {
                            Circle()
                                .fill(color(for: label).opacity(isActive ? 1 : 0.4))
                                .frame(width: 9, height: 9)
                                .overlay {
                                    if isActive {
                                        Circle()
                                            .stroke(Theme.text, lineWidth: 1)
                                            .padding(-2.5)
                                    }
                                }
                                .frame(width: 15, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(label.displayName)
                    }
                }
            }
        }
        .padding(.horizontal, Theme.panelInset)
        .padding(.vertical, 10)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(isSearchFocused ? Theme.accent : Theme.tertiaryText)

            TextField("", text: $searchText,
                      prompt: Text("Camera, lens, file…")
                        .font(Theme.controlLabel)
                        .foregroundStyle(Theme.tertiaryText))
                .textFieldStyle(.plain)
                .font(Theme.controlLabel)
                .foregroundStyle(Theme.text)
                .focused($isSearchFocused)

            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Icon(kind: .cross, size: 8)
                        .foregroundStyle(Theme.tertiaryText)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, Theme.space2)
        .frame(height: 26)
        .background(Theme.canvas.opacity(0.7), in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.radius)
                .strokeBorder(isSearchFocused ? Theme.accent.opacity(0.7) : Theme.separator,
                              lineWidth: Theme.hairline)
        }
        .animation(Theme.quick, value: isSearchFocused)
    }

    private func color(for label: ColorLabel) -> Color {
        switch label {
        case .none: .clear
        case .red: .red
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .purple: .purple
        }
    }
}
