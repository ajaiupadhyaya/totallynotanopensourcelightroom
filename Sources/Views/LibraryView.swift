import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The library: a grid of catalog thumbnails and the import entry point.
/// Clicking a thumbnail opens that photo in the editor.
struct LibraryView: View {
    @Bindable var app: AppModel
    @State private var isImporting = false

    private let columns = [GridItem(.adaptive(minimum: 170, maximum: 240), spacing: 16)]

    var body: some View {
        ScrollView {
            if app.entries.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, minHeight: 420)
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    ForEach(app.entries) { entry in
                        ThumbnailCell(entry: entry)
                            .onTapGesture { app.open(entry) }
                            .contextMenu {
                                Button("Remove from Library", role: .destructive) {
                                    app.removeFromLibrary(entry)
                                }
                            }
                    }
                }
                .padding(20)
            }
        }
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isImporting = true
                } label: {
                    Label("Import Photo", systemImage: "photo.badge.plus")
                }
            }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.jpeg, .png, .heic, .tiff, .image],
            allowsMultipleSelection: true
        ) { result in
            handleImport(result)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 56, weight: .thin))
                .foregroundStyle(.secondary)
            Text("Your library is empty")
                .font(.title2)
            Text("Import a JPEG, PNG, HEIC, or TIFF to start editing.")
                .foregroundStyle(.secondary)
            Button("Import Photo…") { isImporting = true }
                .controlSize(.large)
                .padding(.top, 4)
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

/// A single library grid cell: thumbnail image plus file name.
private struct ThumbnailCell: View {
    let entry: CatalogEntry

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

            Text(entry.fileURL.lastPathComponent)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .contentShape(Rectangle())
    }
}
