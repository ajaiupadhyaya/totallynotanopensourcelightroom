import CoreImage
import Observation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Editor state

/// Holds the currently-open photo, its edit stack, the rendered preview, and a
/// live histogram of that preview.
///
/// Editing is non-destructive: ``source`` is the (preview-scaled) original and
/// is never mutated. Any change to ``editStack`` re-renders the preview and its
/// histogram by replaying the stack through ``EditRenderer``.
@Observable
final class EditorModel {
    /// The active edits. Mutating any field re-renders the preview.
    var editStack = EditStack() {
        didSet { renderPreview() }
    }

    /// The rendered preview currently shown on screen.
    private(set) var displayImage: CGImage?

    /// A per-channel histogram of the current preview.
    private(set) var histogram: Histogram = .empty

    /// File name of the open photo, for display in the panel.
    private(set) var fileName: String?

    /// The untouched, preview-scaled source. Never mutated after import.
    private var source: CIImage?

    private let renderer = EditRenderer()

    var hasImage: Bool { source != nil }

    /// Imports a photo from disk, resetting any prior edits.
    func importImage(from url: URL) {
        guard let image = ImageDecoder.loadPreviewImage(from: url) else {
            NSLog("PhotoEditor: failed to decode image at \(url.path)")
            return
        }
        source = image
        fileName = url.lastPathComponent
        editStack = EditStack() // fresh edits for the new photo; triggers a render
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
}

// MARK: - Main editing screen

/// The main editing screen: the photo on the left, adjustment panel on the
/// right. Shows an empty state with an import prompt until a photo is opened.
struct EditView: View {
    @State private var model = EditorModel()
    @State private var isImporting = false

    var body: some View {
        Group {
            if model.hasImage {
                editorLayout
            } else {
                emptyState
            }
        }
        .frame(minWidth: 900, minHeight: 620)
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
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 56, weight: .thin))
                .foregroundStyle(.secondary)
            Text("No photo open")
                .font(.title2)
            Text("Import a JPEG, PNG, HEIC, or TIFF to start editing.")
                .foregroundStyle(.secondary)
            Button("Import Photo…") { isImporting = true }
                .controlSize(.large)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var editorLayout: some View {
        HSplitView {
            imageCanvas
            SliderPanel(model: model)
                .frame(minWidth: 288, idealWidth: 300, maxWidth: 380)
        }
    }

    private var imageCanvas: some View {
        ZStack {
            Color.black.opacity(0.92)
            if let image = model.displayImage {
                Image(decorative: image, scale: 1.0)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            guard let url = urls.first else { return }
            let needsScopedAccess = url.startAccessingSecurityScopedResource()
            defer {
                if needsScopedAccess { url.stopAccessingSecurityScopedResource() }
            }
            model.importImage(from: url)
        case let .failure(error):
            NSLog("PhotoEditor: import failed — \(error.localizedDescription)")
        }
    }
}
