import CoreImage
import Foundation
import Observation

/// One addressable state in the edit history. Keeping the stack with the row
/// makes history a working Photoshop-like surface rather than a decorative log.
struct EditHistoryEvent: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let timestamp: Date
    let stack: EditStack
}

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

    /// Pixel dimensions of the image used for the live preview (full-res when zoomed).
    private(set) var previewPixelSize: CGSize?

    /// The live Core Image graph for the Metal canvas path.
    private(set) var previewCIImage: CIImage?

    var renderContext: CIContext { renderer.context }

    /// A per-channel histogram of the current preview.
    private(set) var histogram: Histogram = .empty

    /// True when the original file could not be found/decoded.
    private(set) var isMissingFile = false

    /// The decoded preview source, keeping RAW provenance so sensor-domain
    /// edits (white balance, exposure, boost) can reach `CIRAWFilter`.
    private var sourceImage: SourceImage?
    /// The decoded full-resolution source, loaded lazily on zoom/export.
    private var fullSourceImage: SourceImage?
    private var source: CIImage?
    private var fullSource: CIImage?
    private let renderer = EditRenderer()
    private let catalog: CatalogStore
    private let thumbnails: ThumbnailGenerator
    private let onPersist: () -> Void
    private let renderScheduler = RenderScheduler()

    // Undo/redo, captured at debounced commit boundaries.
    private var lastCommittedStack: EditStack
    private var undoStack: [EditStack] = []
    private var redoStack: [EditStack] = []
    private let maxUndoDepth = 100

    /// Recent committed states, newest last. A history row can be clicked to
    /// restore that exact non-destructive stack.
    private(set) var historyEvents: [EditHistoryEvent] = []
    private let maxHistoryDepth = 40

    private var commitWorkItem: DispatchWorkItem?
    private let commitDelay: TimeInterval
    private let renderSynchronously: Bool

    var fileName: String { entry.fileURL.lastPathComponent }

    /// Whether this photo decodes through `CIRAWFilter` — gates the Raw
    /// Boost slider, which is meaningless on an already-rendered source.
    var isRAWSource: Bool { ImageDecoder.isRAW(entry.fileURL) }

    /// Read-only capture metadata, read once when the photo opens.
    let metadata: PhotoMetadata
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var undoDepth: Int { undoStack.count }
    var redoDepth: Int { redoStack.count }

    /// Diagnostic viewing aids. These do not alter the exported image.
    var showsShadowClipping = false
    var showsHighlightClipping = false

    init(
        entry: CatalogEntry,
        catalog: CatalogStore,
        thumbnails: ThumbnailGenerator,
        commitDelay: TimeInterval = 0.4,
        renderSynchronously: Bool = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil,
        onPersist: @escaping () -> Void = {}
    ) {
        self.entry = entry
        self.metadata = PhotoMetadata.read(from: entry.fileURL)
        self.editStack = entry.editStack
        self.lastCommittedStack = entry.editStack
        self.catalog = catalog
        self.thumbnails = thumbnails
        self.commitDelay = commitDelay
        self.renderSynchronously = renderSynchronously
        self.onPersist = onPersist
        loadSource()
        renderPreview()
        reloadFilmStocks()
        reloadSnapshots()
        appendHistory(title: "Opened")
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
        /// Click a defect; a retouch spot is placed there.
        case retouchPlace
        /// Click a colour; the selected colour-range component samples it.
        case colorRangeSample
        /// Click a colour; the selected point-colour target samples it.
        case pointColorSample
    }

    /// Index of the point-colour target awaiting a canvas sample.
    var pointColorSampleIndex: Int?

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
        case .retouchPlace:
            addRetouchSpot(atUnitPoint: point)
        case .colorRangeSample:
            sampleColorRange(at: point)
            return
        case .pointColorSample:
            samplePointColor(at: point)
            return
        case nil:
            return
        }
        canvasPicker = nil
    }

    // MARK: View state (not persisted)

    /// Zoom factor over image pixels; nil fits the frame to the viewport.
    /// Owned here so the top bar and the canvas share one value.
    var zoomLevel: Double? {
        didSet {
            guard zoomLevel != oldValue else { return }
            // Changing magnification re-centres. Keeping an old pan across a
            // zoom change routinely lands you looking at empty canvas, and
            // "where did my photograph go" is not a puzzle worth posing.
            panOffset = .zero
            renderPreview()
        }
    }

    /// How far the photograph is dragged from centre, in points.
    ///
    /// View state only — panning is about what you are looking at, not about
    /// the photograph, so it is never persisted and never reaches the export.
    var panOffset: CGSize = .zero

    /// True when the frame is magnified past fitting the window, which is the
    /// only time panning means anything.
    var canPan: Bool { (zoomLevel ?? 0) > 0 }

    // MARK: Retouch

    /// The mode the next placed spot will use.
    var retouchMode: RetouchSpot.Mode = .heal

    /// The spot currently selected for on-canvas handle editing.
    var selectedSpotID: UUID?

    var selectedSpotIndex: Int? {
        guard let selectedSpotID else { return nil }
        return editStack.retouch.firstIndex { $0.id == selectedSpotID }
    }

    /// Places a spot at the clicked point, sourcing from just beside it —
    /// the most common correct guess — and selects it for adjustment.
    func addRetouchSpot(atUnitPoint point: CGPoint) {
        var spot = RetouchSpot()
        spot.mode = retouchMode
        spot.center = point
        spot.sourceOffset = point.x < 0.85
            ? CGVector(dx: 0.08, dy: 0)
            : CGVector(dx: -0.08, dy: 0)
        editStack.retouch.append(spot)
        selectedSpotID = spot.id
    }

    func beginRetouchStroke(at point: CGPoint) {
        var spot = RetouchSpot()
        spot.mode = retouchMode
        spot.kind = .stroke
        spot.center = point
        spot.strokePoints = [point]
        editStack.retouch.append(spot)
        selectedSpotID = spot.id
    }

    func continueRetouchStroke(to point: CGPoint) {
        guard let index = selectedSpotIndex,
              editStack.retouch[index].kind == .stroke,
              let previous = editStack.retouch[index].strokePoints.last else { return }
        let minimum = max(editStack.retouch[index].radius * 0.12, 0.001)
        guard hypot(point.x - previous.x, point.y - previous.y) >= minimum else { return }
        editStack.retouch[index].strokePoints.append(point)
    }

    func removeRetouchSpot(id: UUID) {
        editStack.retouch.removeAll { $0.id == id }
        if selectedSpotID == id { selectedSpotID = nil }
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

    /// Samples the photograph at `point` into the selected colour-range
    /// component. Reads the developed image, so the sample matches the colour
    /// the photographer actually clicked rather than the raw original.
    func sampleColorRange(at point: CGPoint) {
        guard let mask = selectedMaskIndex, let component = selectedComponentIndex,
              editStack.localAdjustments[mask].components[component].shape == .colorRange,
              let renderSource = activeRenderSource() else { return }

        let developed = renderer.render(source: renderSource, stack: editStack)
        let extent = developed.extent
        guard !extent.isInfinite else { return }

        // FilmBaseSampler enforces a ≥4px integral sample: CIAreaAverage
        // silently returns zeros for tiny non-integral extents.
        let side = max(min(extent.width, extent.height) * 0.02, 4)
        let rect = CGRect(
            x: extent.origin.x + point.x * extent.width - side / 2,
            y: extent.origin.y + point.y * extent.height - side / 2,
            width: side, height: side
        )
        guard let sampled = FilmBaseSampler.sampleAverage(
            from: developed, in: rect, context: renderer.context
        ) else { return }

        editStack.localAdjustments[mask].components[component].sampledColor =
            MaskColor(red: sampled.red, green: sampled.green, blue: sampled.blue)
        canvasPicker = nil
    }

    /// Samples the developed image into the selected point-colour target.
    func samplePointColor(at point: CGPoint) {
        guard let index = pointColorSampleIndex,
              editStack.color.pointColors.indices.contains(index),
              let renderSource = activeRenderSource() else { return }

        let developed = renderer.render(source: renderSource, stack: editStack)
        let extent = developed.extent
        guard !extent.isInfinite else { return }

        let side = max(min(extent.width, extent.height) * 0.02, 4)
        let rect = CGRect(
            x: extent.origin.x + point.x * extent.width - side / 2,
            y: extent.origin.y + point.y * extent.height - side / 2,
            width: side, height: side
        )
        guard let sampled = FilmBaseSampler.sampleAverage(
            from: developed, in: rect, context: renderer.context
        ) else { return }

        editStack.color.pointColors[index].red = sampled.red
        editStack.color.pointColors[index].green = sampled.green
        editStack.color.pointColors[index].blue = sampled.blue
        pointColorSampleIndex = nil
        canvasPicker = nil
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

    /// The component of the selected mask that canvas handles and the options
    /// bar act on.
    var selectedComponentID: UUID?

    /// Index of the selected component inside the selected mask.
    var selectedComponentIndex: Int? {
        guard let maskIndex = selectedMaskIndex, let id = selectedComponentID else { return nil }
        return editStack.localAdjustments[maskIndex].components.firstIndex { $0.id == id }
    }

    /// Adds a mask and selects it for placement.
    func addLocalAdjustment(_ shape: MaskComponent.Shape) {
        var adjustment = LocalAdjustment(shape: shape)
        // A fresh mask starts with a visible nudge, so placing it gives live
        // feedback instead of an invisible no-op.
        adjustment.exposure = shape == .linear ? -0.5 : 0.5
        editStack.localAdjustments.append(adjustment)
        selectedMaskID = adjustment.id
        selectedComponentID = adjustment.components.first?.id
    }

    /// Adds a component to the selected mask, or starts a new mask when none
    /// is selected.
    func addMaskComponent(_ shape: MaskComponent.Shape) {
        guard let index = selectedMaskIndex else {
            addLocalAdjustment(shape)
            return
        }
        let component = MaskComponent(shape: shape)
        editStack.localAdjustments[index].components.append(component)
        selectedComponentID = component.id
    }

    func removeMaskComponent(id: UUID) {
        guard let index = selectedMaskIndex else { return }
        editStack.localAdjustments[index].components.removeAll { $0.id == id }
        if selectedComponentID == id {
            selectedComponentID = editStack.localAdjustments[index].components.first?.id
        }
    }

    /// The selected brush component, if the selection is on one.
    private var selectedBrushIndices: (mask: Int, component: Int)? {
        guard let mask = selectedMaskIndex, let component = selectedComponentIndex,
              editStack.localAdjustments[mask].components[component].shape == .brush
        else { return nil }
        return (mask, component)
    }

    /// Begins a new painted stroke in the selected brush component.
    func beginBrushStroke(at point: CGPoint) {
        guard let (mask, component) = selectedBrushIndices else { return }
        let settings = editStack.localAdjustments[mask].components[component]
        let stroke = BrushStroke(points: [point], radius: settings.brushSize,
                                 feather: settings.brushFeather, flow: settings.brushFlow)
        editStack.localAdjustments[mask].components[component].brushStrokes.append(stroke)
    }

    /// Extends the active stroke, dropping redundant sub-pixel points.
    func continueBrushStroke(to point: CGPoint) {
        guard let (mask, component) = selectedBrushIndices,
              let strokeIndex = editStack.localAdjustments[mask]
                .components[component].brushStrokes.indices.last,
              let previous = editStack.localAdjustments[mask]
                .components[component].brushStrokes[strokeIndex].points.last else { return }
        let minimum = max(editStack.localAdjustments[mask]
            .components[component].brushSize * 0.12, 0.001)
        guard hypot(point.x - previous.x, point.y - previous.y) >= minimum else { return }
        editStack.localAdjustments[mask].components[component]
            .brushStrokes[strokeIndex].points.append(point)
    }

    func removeLastBrushStroke() {
        guard let (mask, component) = selectedBrushIndices,
              !editStack.localAdjustments[mask].components[component].brushStrokes.isEmpty
        else { return }
        editStack.localAdjustments[mask].components[component].brushStrokes.removeLast()
    }

    func removeLocalAdjustment(id: UUID) {
        editStack.localAdjustments.removeAll { $0.id == id }
        if selectedMaskID == id {
            selectedMaskID = nil
            selectedComponentID = nil
        }
    }

    // MARK: Crop mode

    /// While true, the preview renders without the crop so the whole frame is
    /// visible for re-composing. The crop rectangle itself is edited by the
    /// canvas overlay and committed straight into ``editStack``.
    var isCropping = false {
        didSet { renderPreview() }
    }

    /// The crop as it stood when crop mode was entered, for Cancel.
    private var cropRectOnEntry: CGRect = .unitFrame

    func enterCropMode() {
        cropRectOnEntry = editStack.geometry.cropRect
        isCropping = true
    }

    func cancelCrop() {
        editStack.geometry.cropRect = cropRectOnEntry
        isCropping = false
    }

    func finishCrop() {
        isCropping = false
    }

    // MARK: Focus peaking

    /// Tints the in-focus areas of the preview. A viewing aid only — it never
    /// affects the edit stack or what gets exported.
    var isFocusPeakingEnabled = false {
        didSet { renderPreview() }
    }

    /// Tints the selected mask red over the preview. A viewing aid only — it
    /// never affects the edit stack or what gets exported.
    var isShowingMaskOverlay = false {
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

    // MARK: Snapshots

    /// Saved states of this photo's edit stack, newest first.
    private(set) var snapshots: [EditSnapshot] = []

    func reloadSnapshots() {
        snapshots = (try? catalog.snapshots(for: entry.id)) ?? []
    }

    /// Saves the current edit state under a name.
    @discardableResult
    func saveSnapshot(named name: String) -> EditSnapshot? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let snapshot = EditSnapshot(
            entryID: entry.id,
            name: trimmed.isEmpty ? "Snapshot \(snapshots.count + 1)" : trimmed,
            editStack: editStack
        )
        do {
            try catalog.saveSnapshot(snapshot)
            reloadSnapshots()
            return snapshot
        } catch {
            return nil
        }
    }

    /// Restores a snapshot's stack. This is a normal edit — it lands in the
    /// undo history, so restoring is itself reversible.
    func applySnapshot(_ snapshot: EditSnapshot) {
        editStack = snapshot.editStack
    }

    func deleteSnapshot(_ snapshot: EditSnapshot) {
        try? catalog.deleteSnapshot(id: snapshot.id)
        reloadSnapshots()
    }

    /// Re-interprets this photo's slider values through the PV2 engine.
    /// Appearance will change — that is the point — so the PV1 look is
    /// snapshotted first and one click away forever.
    ///
    /// Unlike ``adoptAsShotWhiteBalanceIfNeeded``, this is a deliberate user
    /// action taken from the develop panel, not bookkeeping — so it does *not*
    /// pre-align `lastCommittedStack`. The mutation below flows through the
    /// normal debounced commit path and registers one ordinary undo step,
    /// the same as dragging a slider or applying a preset.
    func upgradeToProcessVersion2() {
        guard editStack.processVersion < 2 else { return }
        _ = saveSnapshot(named: "Before Process Version 2")
        editStack.processVersion = 2
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
            to: url,
            entryID: entry.id
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
        appendHistory(title: "Undo")
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(editStack)
        lastCommittedStack = next
        editStack = next
        appendHistory(title: "Redo")
    }

    /// Restores a visible history state. The restoration remains undoable and
    /// is committed through the same normal debounce boundary as any edit.
    func restoreHistoryEvent(_ event: EditHistoryEvent) {
        guard event.stack != editStack else { return }
        editStack = event.stack
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
            let title = historyTitle(from: lastCommittedStack, to: editStack)
            undoStack.append(lastCommittedStack)
            if undoStack.count > maxUndoDepth { undoStack.removeFirst() }
            redoStack.removeAll()
            lastCommittedStack = editStack
            appendHistory(title: title)
        }
        persist()
    }

    private func appendHistory(title: String) {
        historyEvents.append(EditHistoryEvent(title: title, timestamp: Date(), stack: editStack))
        if historyEvents.count > maxHistoryDepth { historyEvents.removeFirst() }
    }

    /// Names the narrowest changed stage so the history reads like actions,
    /// not anonymous snapshots. Simultaneous changes are recorded honestly.
    private func historyTitle(from old: EditStack, to new: EditStack) -> String {
        var stages: [String] = []
        if old.filmNegative != new.filmNegative { stages.append("Film") }
        if old.geometry != new.geometry { stages.append("Frame") }
        if old.defringe != new.defringe { stages.append("Optics") }
        if old.retouch != new.retouch { stages.append("Retouch") }
        if old.whiteBalanceTemp != new.whiteBalanceTemp
            || old.whiteBalanceTint != new.whiteBalanceTint { stages.append("White Balance") }
        if old.exposure != new.exposure || old.contrast != new.contrast
            || old.highlights != new.highlights || old.shadows != new.shadows
            || old.whites != new.whites || old.blacks != new.blacks
            || old.rawBoost != new.rawBoost { stages.append("Light") }
        if old.texture != new.texture || old.clarity != new.clarity
            || old.dehaze != new.dehaze || old.vibrance != new.vibrance
            || old.saturation != new.saturation { stages.append("Presence") }
        if old.color != new.color { stages.append("Color") }
        if old.toneCurvePoints != new.toneCurvePoints { stages.append("Tone Curve") }
        if old.localAdjustments != new.localAdjustments { stages.append("Masks") }
        if old.sharpenAmount != new.sharpenAmount || old.sharpenRadius != new.sharpenRadius
            || old.luminanceNoiseReduction != new.luminanceNoiseReduction
            || old.colorNoiseReduction != new.colorNoiseReduction { stages.append("Detail") }
        if old.vignetteAmount != new.vignetteAmount
            || old.vignetteMidpoint != new.vignetteMidpoint
            || old.vignetteRoundness != new.vignetteRoundness
            || old.vignetteFeather != new.vignetteFeather
            || old.vignetteHighlights != new.vignetteHighlights
            || old.grainAmount != new.grainAmount || old.grainSize != new.grainSize {
            stages.append("Effects")
        }
        return stages.count == 1 ? stages[0] : "Multiple Adjustments"
    }

    // MARK: Rendering & IO

    private func loadSource() {
        guard let loaded = ImageDecoder.loadSource(from: entry.fileURL, maxDimension: 1600) else {
            isMissingFile = true
            sourceImage = nil
            fullSourceImage = nil
            source = nil
            fullSource = nil
            return
        }
        sourceImage = loaded
        source = loaded.image
        fullSourceImage = nil
        fullSource = nil
        adoptAsShotWhiteBalanceIfNeeded(from: loaded)
    }

    /// First open of a RAW under PV2: the stack's WB defaults become the
    /// file's as-shot neutral instead of an assumed 6500 K.
    private func adoptAsShotWhiteBalanceIfNeeded(from loaded: SourceImage) {
        guard case .raw(let filter) = loaded,
              editStack.processVersion >= 2, !editStack.rawWBInitialized,
              // Film-negative RAWs render through the .rendered/WhiteBalanceStage
              // path instead (the matching `!stack.filmNegative.isEnabled` guard
              // in EditRenderer.render), so seeding sensor-domain as-shot Kelvin
              // here would apply the wrong WB semantics on top of the wrong domain.
              !editStack.filmNegative.isEnabled
        else { return }

        var adopted = editStack
        adopted.whiteBalanceTemp = Double(filter.neutralTemperature)
        adopted.whiteBalanceTint = Double(filter.neutralTint)
        adopted.rawWBInitialized = true

        // Adopting as-shot WB is bookkeeping, not a user edit — align
        // lastCommittedStack to the adopted value *before* assigning editStack
        // so the debounced commit sees no diff and registers no spurious
        // "White Balance" undo/history step (mirrors undo()/redo() above).
        // A single whole-stack assignment also means exactly one
        // renderPreview()/scheduleCommit() instead of three.
        lastCommittedStack = adopted
        editStack = adopted
    }

    private func activeRenderSource() -> SourceImage? {
        guard let sourceImage else { return nil }
        if (zoomLevel ?? 0) >= 1.0 {
            if fullSourceImage == nil {
                fullSourceImage = ImageDecoder.loadSource(from: entry.fileURL, maxDimension: nil)
                fullSource = fullSourceImage?.image
            }
            return fullSourceImage ?? sourceImage
        }
        return sourceImage
    }

    /// Builds the develop graph for the preview.
    ///
    /// There is deliberately **one** render path: whatever the frame's size,
    /// the preview is the same chain the export replays. An earlier version
    /// split large frames into tiles and replayed the whole stack per tile,
    /// which silently broke every stage that measures the frame — crop,
    /// straighten, perspective, vignette, grain, masks all resolved against a
    /// 512 px tile instead of the photograph. Core Image already tiles
    /// internally when it rasterizes, so the graph must never be tiled by hand.
    private func renderEditedImage(
        from renderSource: SourceImage, stack: EditStack
    ) -> CIImage {
        renderer.render(
            source: renderSource, stack: stack,
            mlEnvironment: MLMaskEnvironment(entryID: entry.id, geometry: stack.geometry)
        )
    }

    private func renderPreview() {
        if renderSynchronously {
            renderPreviewNow()
            return
        }
        renderScheduler.schedule { [self] in
            renderPreviewNow()
        }
    }

    private func renderPreviewNow() {
        guard let source else {
            displayImage = nil
            previewCIImage = nil
            previewPixelSize = nil
            histogram = .empty
            return
        }
        var stack = isShowingBefore ? beforeStack : editStack
        if isCropping {
            // Show the full frame while composing the crop.
            stack.geometry.cropRect = .unitFrame
        }
        guard let renderSource = activeRenderSource() else {
            displayImage = nil
            previewCIImage = nil
            previewPixelSize = nil
            histogram = .empty
            return
        }

        previewPixelSize = CGSize(
            width: renderSource.extent.width,
            height: renderSource.extent.height
        )

        let edited = renderEditedImage(from: renderSource, stack: stack)

        // The histogram describes the photo, so it is measured before the
        // peaking overlay — which is chrome, not image data.
        histogram = renderer.histogram(of: edited)

        var shown = isFocusPeakingEnabled
            ? FocusPeaking.overlay(on: edited)
            : edited

        // Chrome, like peaking: drawn after the histogram is measured so it
        // cannot pollute the reading, and never folded into the edit stack.
        if isShowingMaskOverlay, let index = selectedMaskIndex,
           let mask = LocalAdjustmentRenderer.grayscaleMask(
               for: editStack.localAdjustments[index],
               source: edited, extent: edited.extent,
               mlEnvironment: MLMaskEnvironment(entryID: entry.id, geometry: editStack.geometry),
               context: renderer.context
           ) {
            shown = MaskOverlay.tinted(shown, mask: mask, extent: edited.extent)
        }

        displayImage = renderer.makeCGImage(
            ImageDecoder.downsampled(shown, maxDimension: 1600)
        )
        previewCIImage = shown
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
