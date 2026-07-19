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

    /// Read-only capture metadata, read once when the photo opens.
    let metadata: PhotoMetadata
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
        self.metadata = PhotoMetadata.read(from: entry.fileURL)
        self.editStack = entry.editStack
        self.lastCommittedStack = entry.editStack
        self.catalog = catalog
        self.thumbnails = thumbnails
        self.commitDelay = commitDelay
        self.onPersist = onPersist
        loadSource()
        renderPreview()
        reloadFilmStocks()
    }

    /// Resets all adjustments to their neutral defaults.
    func resetAdjustments() {
        editStack = EditStack()
    }

    // MARK: Canvas pickers

    /// What the next click on the canvas means.
    enum CanvasPicker {
        /// Click a neutral; temperature/tint are set to make it gray.
        case whiteBalance
        /// Click clear film border; the film base is sampled there.
        case filmBase
    }

    /// The active canvas picker, or nil when clicks do nothing special.
    var canvasPicker: CanvasPicker?

    /// Routes a canvas click (in unit coordinates of the displayed image,
    /// origin bottom-left to match Core Image) to the active picker.
    func handleCanvasClick(atUnitPoint point: CGPoint) {
        switch canvasPicker {
        case .whiteBalance:
            pickWhiteBalance(atUnitPoint: point)
        case .filmBase:
            let side = 0.02
            sampleFilmBase(inUnitRect: CGRect(
                x: point.x - side / 2, y: point.y - side / 2, width: side, height: side
            ))
        case nil:
            return
        }
        canvasPicker = nil
    }

    /// Sets white balance so the clicked color becomes neutral.
    ///
    /// The color is sampled from a render with the WB sliders zeroed — the
    /// exact image the WB stage sees — then its correlated temperature and
    /// tint become the new slider values. Declaring the clicked color to be
    /// the scene's illuminant is precisely what "pick a neutral" means.
    func pickWhiteBalance(atUnitPoint point: CGPoint) {
        guard let source else { return }

        var neutralStack = editStack
        neutralStack.whiteBalanceTemp = 6500
        neutralStack.whiteBalanceTint = 0
        let preWB = renderer.render(source: source, stack: neutralStack)

        let extent = preWB.extent
        let side = max(2.0, extent.width * 0.01)
        let rect = CGRect(
            x: extent.origin.x + point.x * extent.width - side / 2,
            y: extent.origin.y + point.y * extent.height - side / 2,
            width: side, height: side
        )
        guard let sampled = FilmBaseSampler.sampleAverage(
            from: preWB, in: rect, context: renderer.context
        ) else { return }

        guard let wb = ColorScience.temperatureAndTint(
            ofRed: sampled.red, green: sampled.green, blue: sampled.blue
        ) else { return }

        editStack.whiteBalanceTemp = wb.temperature
        editStack.whiteBalanceTint = wb.tint
    }

    // MARK: Local adjustments

    /// The mask currently selected for editing (canvas handles + sliders).
    /// UI state only — never persisted.
    var selectedMaskID: UUID?

    /// The selected mask's index in the stack, if it still exists.
    var selectedMaskIndex: Int? {
        guard let selectedMaskID else { return nil }
        return editStack.localAdjustments.firstIndex { $0.id == selectedMaskID }
    }

    /// Adds a mask and selects it for placement.
    func addLocalAdjustment(_ shape: LocalAdjustment.Shape) {
        var adjustment = LocalAdjustment(shape: shape)
        // A fresh mask starts with a visible nudge, so placing it gives live
        // feedback instead of an invisible no-op.
        adjustment.exposure = shape == .linear ? -0.5 : 0.5
        editStack.localAdjustments.append(adjustment)
        selectedMaskID = adjustment.id
    }

    func removeLocalAdjustment(id: UUID) {
        editStack.localAdjustments.removeAll { $0.id == id }
        if selectedMaskID == id { selectedMaskID = nil }
    }

    // MARK: Crop mode

    /// While true, the preview renders without the crop so the whole frame is
    /// visible for re-composing. The crop rectangle itself is edited by the
    /// canvas overlay and committed straight into ``editStack``.
    var isCropping = false {
        didSet { renderPreview() }
    }

    // MARK: Focus peaking

    /// Tints the in-focus areas of the preview. A viewing aid only — it never
    /// affects the edit stack or what gets exported.
    var isFocusPeakingEnabled = false {
        didSet { renderPreview() }
    }

    // MARK: Before / after

    /// When true the canvas shows the unedited original.
    ///
    /// Note this still applies geometry — comparing a crop against an uncropped
    /// frame would just look like a different photo, so "before" means "before
    /// the *adjustments*," which is what people are actually asking to see.
    var isShowingBefore = false {
        didSet { renderPreview() }
    }

    /// The stack used for the "before" view: geometry and the negative
    /// conversion kept, every adjustment reset.
    private var beforeStack: EditStack {
        var stack = EditStack()
        stack.geometry = editStack.geometry
        stack.filmNegative = editStack.filmNegative
        return stack
    }

    // MARK: Presets

    /// Applies a preset's look to this photo, leaving the frame's own crop and
    /// sampled film base intact.
    func applyPreset(_ preset: DevelopPreset, options: EditTransferOptions = .init()) {
        editStack = editStack.applying(preset.editStack, options: options)
    }

    // MARK: Geometry

    /// Sets a centered crop with the given aspect ratio (width ÷ height),
    /// or clears the crop when `ratio` is nil.
    ///
    /// The ratio is applied against the frame *after* rotation, so asking for
    /// 3:2 on a portrait-rotated image gives a 3:2 crop of what's on screen
    /// rather than of the original orientation.
    func setCropAspectRatio(_ ratio: Double?) {
        guard let ratio, ratio > 0 else {
            editStack.geometry.cropRect = .unitFrame
            return
        }
        guard let source else { return }

        var width = source.extent.width
        var height = source.extent.height
        if editStack.geometry.rotation.swapsAxes {
            swap(&width, &height)
        }
        guard width > 0, height > 0 else { return }

        // Work in normalized space: a ratio of 1 on a 3:2 frame is a square
        // whose normalized width is (height/width) of the frame.
        let frameRatio = Double(width / height)
        var cropWidth = 1.0
        var cropHeight = 1.0
        if ratio > frameRatio {
            cropHeight = frameRatio / ratio
        } else {
            cropWidth = ratio / frameRatio
        }

        editStack.geometry.cropRect = CGRect(
            x: (1 - cropWidth) / 2, y: (1 - cropHeight) / 2,
            width: cropWidth, height: cropHeight
        )
    }

    // MARK: Film

    /// Every stock available for selection (calibrated first, then built-ins).
    private(set) var filmStocks: [FilmStock] = []

    /// Stocks ranked against the sampled film base, closest first. Empty until
    /// a base has been sampled.
    private(set) var stockMatches: [StockMatch] = []

    /// Turns on negative conversion and does the sensible first pass: sample
    /// the film base off the scan, infer the family from it, and rank stocks.
    func enableFilmNegative() {
        editStack.filmNegative.isEnabled = true
        sampleFilmBase()
    }

    /// Samples the film base from the **untouched scan** — not the rendered
    /// preview, which by then has already been inverted.
    func sampleFilmBase() {
        guard let source,
              let base = FilmBaseSampler.sampleBase(from: source, context: renderer.context)
        else { return }
        applySampledBase(base)
    }

    /// Samples the film base from a specific region — the eyedropper path, for
    /// pointing at a piece of clear film border directly.
    ///
    /// - Parameter unitRect: The region in unit coordinates (0–1) of the
    ///   displayed image, which the caller gets from a drag in the canvas.
    func sampleFilmBase(inUnitRect unitRect: CGRect) {
        guard let source else { return }
        let extent = source.extent
        let rect = CGRect(
            x: extent.origin.x + unitRect.origin.x * extent.width,
            y: extent.origin.y + unitRect.origin.y * extent.height,
            width: max(1, unitRect.width * extent.width),
            height: max(1, unitRect.height * extent.height)
        )
        guard let base = FilmBaseSampler.sampleAverage(
            from: source, in: rect, context: renderer.context
        ) else { return }
        applySampledBase(base)
    }

    /// Applies a stock profile, keeping the base color already sampled from
    /// this scan — the user's own base is more accurate than any profile's.
    func applyFilmStock(_ stock: FilmStock) {
        editStack.filmNegative.apply(stock, keepSampledBase: hasSampledBase)
        editStack.filmNegative.isEnabled = true
    }

    /// Saves the current film settings as a reusable calibrated profile.
    ///
    /// This is the reliable direction: the user names the stock they actually
    /// shot, and the base sampled from their own scan captures the whole chain
    /// (stock, development, scanner, light source).
    @discardableResult
    func saveCalibratedStock(name: String, manufacturer: String, iso: Int?) -> FilmStock? {
        let film = editStack.filmNegative
        let stock = FilmStock(
            id: "custom-\(UUID().uuidString)",
            name: name,
            manufacturer: manufacturer,
            iso: iso,
            type: film.type,
            baseColor: film.baseColor,
            channelGains: film.channelGains,
            contrast: film.stockContrast,
            saturation: film.stockSaturation,
            isCustom: true
        )
        do {
            try catalog.saveFilmStock(stock)
            reloadFilmStocks()
            editStack.filmNegative.stockID = stock.id
            editStack.filmNegative.stockName = stock.displayName
            return stock
        } catch {
            return nil
        }
    }

    func deleteCalibratedStock(_ stock: FilmStock) {
        guard stock.isCustom else { return }
        try? catalog.deleteFilmStock(id: stock.id)
        reloadFilmStocks()
    }

    /// True once a base has been read off this scan rather than assumed.
    /// Read from the persisted edit stack, so it survives reopening the photo.
    var hasSampledBase: Bool { editStack.filmNegative.isBaseSampled }

    private func applySampledBase(_ base: FilmColor) {
        editStack.filmNegative.baseColor = base
        editStack.filmNegative.isBaseSampled = true
        if editStack.filmNegative.stockID == nil {
            editStack.filmNegative.type = FilmBaseSampler.inferType(from: base)
        }
        stockMatches = FilmBaseSampler.rankStocks(
            matching: base, in: filmStocks, type: editStack.filmNegative.type
        )
    }

    private func reloadFilmStocks() {
        filmStocks = (try? catalog.allFilmStocks()) ?? FilmStock.builtIn
    }

    // MARK: Export

    /// Renders the current edits against the full-resolution original and
    /// writes them to `url`. The original file is not touched.
    func export(settings: ExportSettings, to url: URL) throws {
        try ExportService(renderer: renderer).export(
            sourceURL: entry.fileURL,
            stack: editStack,
            settings: settings,
            to: url
        )
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
        var stack = isShowingBefore ? beforeStack : editStack
        if isCropping {
            // Show the full frame while composing the crop.
            stack.geometry.cropRect = .unitFrame
        }
        let edited = renderer.render(source: source, stack: stack)

        // The histogram describes the photo, so it is measured before the
        // peaking overlay — which is chrome, not image data.
        histogram = renderer.histogram(of: edited)

        let shown = isFocusPeakingEnabled
            ? FocusPeaking.overlay(on: edited)
            : edited
        displayImage = renderer.makeCGImage(shown)
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
