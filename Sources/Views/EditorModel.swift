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
    ///
    /// The re-decode comes first, and deliberately lives here rather than in
    /// the callers. Undo, redo, Reset, snapshot restore, history restore and
    /// the PV2 upgrade all replace the stack wholesale, and any of them can
    /// swap the process version out from under an already-decoded source —
    /// after which the render below would dispatch the *other* version's chain
    /// at these pixels. Six call sites is six chances to forget; the property
    /// every path has to go through is one.
    var editStack: EditStack {
        didSet {
            syncDecodedSource(for: editStack.processVersion)
            // White balance changes UNITS across the film-negative boundary
            // (see `isSensorDomainWB`), and every path that can cross it —
            // Auto, a film stock, a preset, a whole roll's conversion, the
            // panel's own toggle — ends in an assignment here. Correcting at
            // the crossing keeps the two directions symmetric: leaving the
            // sensor domain returns the field to rendered-domain neutral,
            // re-entering it makes the as-shot decision applicable again.
            //
            // Assigned directly in the observer body, which Swift does not
            // re-enter; both corrections are idempotent besides.
            if let corrected = Self.whiteBalanceDomainCorrected(editStack) {
                editStack = corrected
            } else if let adopted = adoptingAsShot(editStack) {
                editStack = adopted
            }
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

    /// The process version ``sourceImage`` was decoded under, or nil when
    /// nothing is decoded.
    ///
    /// The decode is version-dependent (see ``RawDecodePolicy``), so this is
    /// half of an invariant: it must equal `editStack.processVersion` whenever
    /// a render happens, or the frozen legacy chain replays against PV2 pixels
    /// (or vice versa) — exactly the defect the process version exists to
    /// prevent. Readable so the invariant can be asserted in tests without a
    /// camera file.
    private(set) var decodedProcessVersion: Int?

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

    /// True when white balance, exposure, and the baseline boost are being
    /// routed to `CIRAWFilter`'s sensor-domain controls rather than to the
    /// scene-referred stages — the same predicate `EditRenderer.render` uses
    /// to take that branch.
    ///
    /// It gates the controls that only mean something on one side of that
    /// branch: the Raw Boost slider (a `CIRAWFilter` control) and the white
    /// balance eyedropper (whose estimate is in the wrong units for the
    /// sensor domain — see ``pickWhiteBalance(atUnitPoint:)``).
    var isSensorDomainWB: Bool {
        guard case .raw = sourceImage else { return false }
        return editStack.processVersion >= 2 && !editStack.filmNegative.isEnabled
    }

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
    ///
    /// A fresh stack has `rawWBInitialized` false, which makes the as-shot
    /// white-balance decision applicable again — so on a RAW, Reset returns to
    /// the *camera's* neutral rather than to an assumed 6500 K the file never
    /// had. Folding that into the same assignment keeps Reset one undo step
    /// and one render, exactly as before.
    func resetAdjustments() {
        var fresh = EditStack()
        // Ahead of the assignment, because the adoption below reads
        // `sourceImage`: resetting a PV1 photo crosses into PV2, and until the
        // file is re-decoded a RAW is still the flattened `.rendered` its old
        // version called for, with no filter to read an as-shot neutral from.
        syncDecodedSource(for: fresh.processVersion)
        if let adopted = adoptingAsShot(fresh) { fresh = adopted }
        editStack = fresh
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
        /// Click something that should be neutral; the cast sliders solve to
        /// make it so.
        case neutralCast
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
        case .neutralCast:
            pickNeutralCast(atUnitPoint: point)
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
    ///
    /// Deliberately a no-op while ``isSensorDomainWB`` is true. On a PV2 RAW
    /// the two slider fields are `CIRAWFilter.neutralTemperature` and
    /// `.neutralTint` — a sensor-domain Kelvin against the camera's own
    /// calibration, plus a tint on the camera-calibration scale (roughly
    /// −150…150). What `ColorScience.temperatureAndTint` returns is a
    /// D65-relative estimate of an *already demosaiced* colour, with tint on
    /// its own uv-offset scale. Writing one into the other is not an
    /// approximation, it is a units error in two dimensions: the picked grey
    /// would come out further from neutral than it started. Composing a
    /// correct sensor-domain estimate needs a real RAW fixture to validate
    /// against, so the affordance is switched off until there is one.
    func pickWhiteBalance(atUnitPoint point: CGPoint) {
        guard !isSensorDomainWB, let source else { return }

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
    /// Unlike the as-shot adoption in ``loadSource()``, this is a deliberate
    /// user action taken from the develop panel, not bookkeeping — so it does
    /// *not* pre-align `lastCommittedStack`. The single assignment below flows
    /// through the normal debounced commit path and registers one ordinary
    /// undo step, the same as dragging a slider or applying a preset.
    func upgradeToProcessVersion2() {
        guard editStack.processVersion < 2 else { return }
        _ = saveSnapshot(named: "Before Process Version 2")

        var upgraded = editStack
        upgraded.processVersion = 2
        // Ahead of the assignment, for the same reason Reset does it: the
        // adoption below reads `sourceImage`, and a PV1 RAW was decoded at
        // Apple's defaults and flattened to `.rendered` (see
        // ``RawDecodePolicy``), so neither the sensor-domain chain nor the
        // as-shot neutral it needs exist until the file is re-decoded.
        syncDecodedSource(for: upgraded.processVersion)
        if let adopted = adoptingAsShot(upgraded) { upgraded = adopted }
        // One assignment: the version bump and the WB it implies are a single
        // undo step, not two.
        editStack = upgraded
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

    /// Turns on negative conversion. Density-model photos get the full Auto
    /// solve; matrix-model photos keep the original sample-and-rank behavior.
    func enableFilmNegative() {
        if editStack.filmNegative.conversionModel == .density {
            // The spec's "new conversions default to Lab Standard" rule lands
            // here — the one gesture every new conversion passes through.
            autoConvertNegative(seedProfile: .labStandard)
        } else {
            editStack.filmNegative.isEnabled = true
            sampleFilmBase()
        }
    }

    /// The Auto button: solve the whole conversion off the scan and write it
    /// as ONE stack assignment — one undo step, like every other gesture.
    ///
    /// All mutations, including the stock-family inference, land on the local
    /// `film` var before the single assignment below — mirroring
    /// ``upgradeToProcessVersion2()``'s pattern. (A second `editStack.filmNegative`
    /// write after the main assignment would still coalesce into one commit,
    /// since the debounced commit diffs the *final* `editStack` against
    /// `lastCommittedStack` rather than per-assignment — but it would also
    /// trigger a second, wasted `renderPreview()`/`scheduleCommit()` pass via
    /// `editStack`'s `didSet`. One assignment avoids that.)
    ///
    /// Measures the geometry-cropped scan, not the full frame, when a crop is
    /// set. This is the actual darkroom workflow — you crop to the frame,
    /// *then* convert — and the crop is the one signal in the whole stack that
    /// says exactly which pixels are film: on a medium-format scan the
    /// negative-holder mask surrounding a floating frame is the densest thing
    /// in the image, and left in, it captures Dmax and the median instead of
    /// the photograph, exposing for the holder while the real image lands dark
    /// with a color cast. Cropping first removes that material from the
    /// measurement the same way it removes sprocket holes and rebate on a
    /// 35mm scan. Only the *measurement* is cropped — the render path is
    /// unchanged: film negative conversion still runs on the full frame, and
    /// `Geometry`'s own crop (applied after conversion, see
    /// ``DevelopedSourceCache``) masks the rest at display/export time, same
    /// as ever.
    /// The solved conversion of the roll this photo belongs to, if any — set
    /// by `AppModel.open`. Non-nil turns Auto into a roll-constants re-solve.
    var rollConversion: RollConversion?

    /// - Parameter seedProfile: when non-nil AND the conversion is being
    ///   enabled for the first time (isEnabled false), the profile applied
    ///   before solving — the "new conversions default to Lab Standard" rule.
    ///   The Auto button passes nil: re-solving respects the user's profile.
    /// - Parameter forceProfile: applies the profile regardless of enabled
    ///   state before solving — the profile-switch path (Task 11's strip).
    ///   Deliberately bypasses the roll branch below: switching profiles
    ///   leaves the roll's conversion; Convert Roll re-establishes it.
    func autoConvertNegative(seedProfile: FilmToneProfile? = nil,
                             forceProfile: FilmToneProfile? = nil) {
        guard let source else { return }
        let measured = GeometryTransform.apply(source, geometry: editStack.geometry)
        var film = editStack.filmNegative
        if let seedProfile, !film.isEnabled {
            film.print.applyToneProfile(seedProfile)
        }
        if let forceProfile {
            film.print.applyToneProfile(forceProfile)
        }
        film.isEnabled = true
        var sampled = film.baseOrigin == .sampled ? film.baseColor : nil

        // Frame detection (spec 2026-08-10): an uncropped lightbox scan gets
        // measured through the detected film box, the crop lands in the SAME
        // gesture — visible on the canvas, reviewable, one undo step — and a
        // validated rebate ring stands in as the base sample. A user crop or
        // user-sampled base always wins (the detector never runs); a nil
        // detection leaves Auto exactly as before. Rolled frames keep their
        // roll's own conversion path.
        var detectedRect: CGRect?
        var detectedMeasured = measured
        var detectorSuppliedBase = false
        if editStack.geometry.cropRect == .unitFrame, sampled == nil,
           rollConversion == nil,
           film.conversionModel == .density,
           let detected = FrameDetector.detect(scan: measured,
                                               context: renderer.context) {
            detectedRect = detected.rect
            var geometry = editStack.geometry
            geometry.cropRect = detected.rect
            detectedMeasured = GeometryTransform.apply(source, geometry: geometry)
            if let rebate = detected.rebateBase {
                sampled = rebate
                detectorSuppliedBase = true
            }
        }

        if let rc = rollConversion, forceProfile == nil {
            // A rolled frame re-Autos against its roll's constants: measure
            // this frame, solve exposure only. Constants stay the roll's —
            // that IS the consistency contract.
            guard let m = AutoInvert.measure(scan: measured, sampledBase: sampled,
                                             context: renderer.context) else { return }
            let base = (film.baseOrigin == .sampled) ? film.baseColor : rc.baseColor
            let dminLin = (PaperResponse.srgbDecode(base.red),
                           PaperResponse.srgbDecode(base.green),
                           PaperResponse.srgbDecode(base.blue))
            func density(_ t: Double, _ dm: Double) -> Double {
                log10(max(dm, 1e-4) / max(t, PaperResponse.transmittanceFloor))
            }
            let medianD = DensityTriple(
                red: density(AutoInvert.percentile(m.sortedRed, 0.5), dminLin.0),
                green: density(AutoInvert.percentile(m.sortedGreen, 0.5), dminLin.1),
                blue: density(AutoInvert.percentile(m.sortedBlue, 0.5), dminLin.2))
            let medianT = (dminLin.0 * pow(10, -medianD.red),
                           dminLin.1 * pow(10, -medianD.green),
                           dminLin.2 * pow(10, -medianD.blue))
            if film.baseOrigin != .sampled {
                film.baseColor = rc.baseColor
                film.baseOrigin = rc.baseOrigin
                film.isBaseSampled = false
            }
            // The solve places the median under renderVersion-2 semantics
            // (balanced tint, gradePivot); writing it onto a decoded-v1 stack
            // would render the placement wrong and leave the pivot dead. Auto
            // overwrites the whole conversion (snapshot-protected), so the
            // upgrade cannot violate the freeze.
            film.print.renderVersion = 2
            film.print.gamma = rc.gamma
            film.print.dmax = rc.dmax
            film.print.castRed = rc.castRed
            film.print.castGreen = rc.castGreen
            film.print.castBlue = rc.castBlue
            film.print.applyToneProfile(rc.toneProfile)
            film.print.exposure = AutoInvert.solveExposure(
                medianT: medianT, dminLinear: dminLin, dmax: rc.dmax,
                gamma: rc.gamma,
                cast: DensityTriple(red: rc.castRed, green: rc.castGreen,
                                    blue: rc.castBlue),
                profile: rc.toneProfile)
            film.print.gradePivot = medianD
            film.exposure = 0
            editStack.filmNegative = film
            lastSolveDegradedTerms = m.degradedTerms
            return
        }
        guard let solution = AutoInvert.solve(scan: detectedMeasured, sampledBase: sampled,
                                              profile: film.print.toneProfile,
                                              context: renderer.context) else { return }
        lastSolveDegradedTerms = solution.degradedTerms
        if detectedRect != nil {
            lastSolveDegradedTerms.append("frame detected — review the crop")
        }
        // v2 semantics travel with the solve — see the roll branch's note.
        film.print.renderVersion = 2
        film.baseColor = solution.baseColor
        film.baseOrigin = solution.baseOrigin
        film.isBaseSampled = solution.baseOrigin == .sampled
        film.print.dmax = solution.dmax
        film.print.gamma = solution.gamma
        film.print.exposure = solution.printExposure
        film.print.gradePivot = solution.medianDensity
        film.print.castRed = solution.cast.red
        film.print.castGreen = solution.cast.green
        film.print.castBlue = solution.cast.blue

        // Zero the legacy (matrix-era) EV lift. It was a placement aid for a
        // model with no notion of a print exposure of its own; the density
        // engine places exposure itself (`print.exposure`, solved above), and
        // the field is invisible in the density panel (`FilmPanel` only shows
        // it on the matrix branch) — so a stale nonzero value here is pure
        // dead weight that silently fights the solve with an EV the user can
        // no longer see or clear. Any pre-Auto look is preserved separately,
        // in the "Before Print Engine" snapshot `updateConversion` takes
        // before calling this.
        film.exposure = 0

        // Same courtesy as the matrix path: infer the family off the measured
        // base, folded into the same local var so it lands in the single
        // assignment below rather than a second one.
        if film.stockID == nil {
            film.type = FilmBaseSampler.inferType(from: solution.baseColor)
        }
        // A detector-supplied base is honest about its provenance: it is
        // estimated from the scan (by the ring), not clicked by the user —
        // the swatch caption must say so, and a re-Auto must re-estimate.
        if detectorSuppliedBase {
            film.baseOrigin = .estimated
            film.isBaseSampled = false
        }
        // The detected crop lands in the SAME stack write as the conversion:
        // one gesture, one undo step, and the crop is on the canvas for
        // review the moment Auto returns.
        var stack = editStack
        if let detectedRect {
            stack.geometry.cropRect = detectedRect
        }
        stack.filmNegative = film
        editStack = stack

        stockMatches = FilmBaseSampler.rankStocks(matching: solution.baseColor,
                                                  in: filmStocks)
    }

    /// What the last Auto solve wanted the user to know — the honesty caption
    /// under the colour-balance group. View state, never persisted.
    var lastSolveDegradedTerms: [String] = []

    /// The profile strip's action: write the profile's parameters and, when
    /// the conversion is live, re-solve the placement under it — one gesture,
    /// one undo step. Not enabled yet? Just seed the fields.
    func applyToneProfile(_ profile: FilmToneProfile) {
        if editStack.filmNegative.isEnabled,
           editStack.filmNegative.conversionModel == .density {
            autoConvertNegative(forceProfile: profile)
        } else {
            var film = editStack.filmNegative
            film.print.applyToneProfile(profile)
            editStack.filmNegative = film
        }
    }

    /// The neutral picker: sample a 2%-side patch of the SCAN (not the
    /// rendered positive) around the click, solve the per-channel density
    /// offsets that make it render neutral, and move the cast sliders there.
    /// The solve is a delta on top of what is already dialed in — clicking a
    /// patch that already renders neutral moves nothing.
    func pickNeutralCast(atUnitPoint point: CGPoint) {
        guard let source else { return }
        let side = 0.02
        let extent = source.extent
        let rect = CGRect(
            x: extent.origin.x + (point.x - side / 2) * extent.width,
            y: extent.origin.y + (point.y - side / 2) * extent.height,
            width: max(1, side * extent.width),
            height: max(1, side * extent.height)
        )
        guard let patch = FilmBaseSampler.sampleAverage(
            from: source, in: rect, context: renderer.context
        ) else { return }

        var film = editStack.filmNegative
        let base = film.baseColor.safeForDivision
        let dmin = (PaperResponse.srgbDecode(base.red),
                    PaperResponse.srgbDecode(base.green),
                    PaperResponse.srgbDecode(base.blue))
        func density(_ t: Double, _ dm: Double) -> Double {
            log10(max(dm, 1e-4) / max(t, PaperResponse.transmittanceFloor))
        }
        // Densities as the renderer sees them, current cast included — so the
        // solve returns the ADDITIONAL correction, not a replacement.
        let seen = DensityTriple(
            red: density(PaperResponse.srgbDecode(patch.red), dmin.0)
                + PaperResponse.castDensity(film.print.castRed),
            green: density(PaperResponse.srgbDecode(patch.green), dmin.1)
                + PaperResponse.castDensity(film.print.castGreen),
            blue: density(PaperResponse.srgbDecode(patch.blue), dmin.2)
                + PaperResponse.castDensity(film.print.castBlue))
        let delta = CastSolver.castSliders(neutralDensity: seen,
                                           gamma: film.print.gamma,
                                           dmax: film.print.dmax)
        func clamp(_ v: Double) -> Double { min(max(v, -100), 100) }
        film.print.castRed = clamp(film.print.castRed + delta.red)
        film.print.castGreen = clamp(film.print.castGreen + delta.green)
        film.print.castBlue = clamp(film.print.castBlue + delta.blue)
        editStack.filmNegative = film
    }

    /// Auto colour balance on demand — the menu's Neutral / Warm / Cool.
    /// Fresh midtone measurement of the geometry-cropped scan, gray-world
    /// solve against the CURRENT stack's gamma/dmax, plus a documented bias.
    /// (Grade-independent: equalizing through the un-graded gamma equalizes
    /// the graded line too — the grade scales all three L values equally.)
    func autoColorBalance(bias: (red: Double, green: Double, blue: Double)) {
        guard let source else { return }
        let measured = GeometryTransform.apply(source, geometry: editStack.geometry)
        var film = editStack.filmNegative
        let sampled = film.baseOrigin == .sampled ? film.baseColor : nil
        guard let m = AutoInvert.measure(scan: measured, sampledBase: sampled,
                                         context: renderer.context) else { return }
        let base = film.baseColor.safeForDivision
        let dmin = (PaperResponse.srgbDecode(base.red),
                    PaperResponse.srgbDecode(base.green),
                    PaperResponse.srgbDecode(base.blue))
        func density(_ t: Double, _ dm: Double) -> Double {
            log10(max(dm, 1e-4) / max(t, PaperResponse.transmittanceFloor))
        }
        let medianD = DensityTriple(
            red: density(AutoInvert.percentile(m.sortedRed, 0.5), dmin.0),
            green: density(AutoInvert.percentile(m.sortedGreen, 0.5), dmin.1),
            blue: density(AutoInvert.percentile(m.sortedBlue, 0.5), dmin.2))
        let solved = CastSolver.castSliders(neutralDensity: medianD,
                                            gamma: film.print.gamma,
                                            dmax: film.print.dmax)
        func clamp(_ v: Double) -> Double { min(max(v, -100), 100) }
        film.print.castRed = clamp(solved.red + bias.red)
        film.print.castGreen = clamp(solved.green + bias.green)
        film.print.castBlue = clamp(solved.blue + bias.blue)
        editStack.filmNegative = film
        lastSolveDegradedTerms = m.degradedTerms
    }

    /// Matrix → print engine, as an explicit, snapshotted, undoable action —
    /// the same guarantees as the Process badge. The current look stays one
    /// click away in Snapshots forever.
    func updateConversion() {
        guard editStack.filmNegative.isEnabled,
              editStack.filmNegative.conversionModel == .matrix,
              editStack.filmNegative.type.requiresInversion else { return }
        _ = saveSnapshot(named: "Before Print Engine")
        editStack.filmNegative.conversionModel = .density
        autoConvertNegative()
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
        if editStack.filmNegative.conversionModel == .density {
            if let grade = stock.printContrast { editStack.filmNegative.print.contrast = grade }
            if let sat = stock.printSaturation { editStack.filmNegative.print.saturation = sat }
        }
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
            printContrast: film.conversionModel == .density ? film.print.contrast : nil,
            printSaturation: film.conversionModel == .density ? film.print.saturation : nil,
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
        editStack.filmNegative.baseOrigin = .sampled
        if editStack.filmNegative.stockID == nil {
            editStack.filmNegative.type = FilmBaseSampler.inferType(from: base)
        }
        stockMatches = FilmBaseSampler.rankStocks(
            matching: base, in: filmStocks, type: editStack.filmNegative.type
        )

        // On the print engine a better Dmin should immediately improve the
        // whole solve — the sampled base feeds straight back through Auto.
        if editStack.filmNegative.conversionModel == .density,
           editStack.filmNegative.isEnabled {
            autoConvertNegative()
        }
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
        // The LIVE stack's version, not `entry.editStack`'s: `entry` is a `let`
        // captured when the photo opened, so it goes stale the moment the
        // photographer upgrades this photo to PV2 mid-session. The renderer
        // dispatches on the live stack, and the decode has to agree with it.
        syncDecodedSource(for: editStack.processVersion)
        guard let adopted = adoptingAsShot(editStack) else { return }

        // Adopting as-shot WB *at open* is bookkeeping, not a user edit — align
        // lastCommittedStack to the adopted value *before* assigning editStack
        // so the debounced commit sees no diff and registers no spurious
        // "White Balance" undo/history step (mirrors undo()/redo() below).
        // A single whole-stack assignment also means exactly one
        // renderPreview()/scheduleCommit() instead of three. Reset and the PV2
        // upgrade deliberately skip this alignment: there the adoption rides
        // along with a change the photographer asked for and should be undoable
        // as one step with it.
        lastCommittedStack = adopted
        editStack = adopted
    }

    /// Re-decodes when — and only when — the source on hand was decoded under
    /// a different process version than the one about to render.
    ///
    /// Cheap to call on every mutation: the guard is an integer comparison, and
    /// a crossing is rare. The decode itself builds a lazy `CIImage`/
    /// `CIRAWFilter` graph rather than pixels, so even a crossing costs little
    /// beyond the render that was going to happen anyway.
    private func syncDecodedSource(for processVersion: Int) {
        guard processVersion != decodedProcessVersion else { return }
        reloadSource(processVersion: processVersion)
    }

    /// Decodes the preview source under `processVersion`'s decode policy.
    ///
    /// Separate from ``loadSource()`` because the paths that read `sourceImage`
    /// *before* assigning a stack (Reset, the PV2 upgrade) have to re-decode
    /// ahead of the observer above, without the load-time undo bookkeeping.
    private func reloadSource(processVersion: Int) {
        guard let loaded = ImageDecoder.loadSource(from: entry.fileURL, maxDimension: 1600,
                                                   processVersion: processVersion) else {
            isMissingFile = true
            decodedProcessVersion = nil
            sourceImage = nil
            fullSourceImage = nil
            source = nil
            fullSource = nil
            return
        }
        isMissingFile = false
        decodedProcessVersion = processVersion
        sourceImage = loaded
        source = loaded.image
        // Decoded under the old policy, so no longer valid at any zoom.
        fullSourceImage = nil
        fullSource = nil
    }

    /// The as-shot adoption decision for the *current* source: nil unless it is
    /// a live RAW filter whose neutral can be read.
    private func adoptingAsShot(_ stack: EditStack) -> EditStack? {
        guard case .raw(let filter)? = sourceImage else { return nil }
        return Self.adoptedStack(stack,
                                 asShotTemperature: Double(filter.neutralTemperature),
                                 asShotTint: Double(filter.neutralTint))
    }

    /// Whether — and how — a RAW's as-shot neutral should replace a stack's
    /// white balance, as a pure function of the stack.
    ///
    /// Adoption is *not* a load-time event. Reset clears `rawWBInitialized`
    /// and so makes it applicable again; the PV1→PV2 upgrade makes it
    /// applicable for the first time. Keeping the decision here means all
    /// three callers ask the same question, and the question is testable
    /// without a camera file.
    ///
    /// - Returns: The stack to adopt, or `nil` when nothing should change:
    ///   the stack already carries an adopted (or edited) RAW white balance;
    ///   it is a PV1 stack, whose legacy chain never reads sensor-domain WB;
    ///   or film-negative conversion is on, in which case the RAW renders
    ///   through the `.rendered`/`WhiteBalanceStage` path instead (the
    ///   matching `!stack.filmNegative.isEnabled` guard in
    ///   `EditRenderer.render`) and sensor-domain Kelvin would be the wrong
    ///   units in the wrong domain.
    static func adoptedStack(_ stack: EditStack,
                             asShotTemperature: Double,
                             asShotTint: Double) -> EditStack? {
        guard stack.processVersion >= 2, !stack.rawWBInitialized,
              !stack.filmNegative.isEnabled else { return nil }
        var adopted = stack
        adopted.whiteBalanceTemp = asShotTemperature
        adopted.whiteBalanceTint = asShotTint
        adopted.rawWBInitialized = true
        return adopted
    }

    /// The other direction across the same boundary: a stack whose adopted
    /// sensor-domain white balance has to go back to rendered-domain units
    /// because the film conversion just turned on. nil when there is nothing
    /// to correct.
    ///
    /// ``adoptedStack`` refuses to *put* Kelvin into a film-negative stack.
    /// That guard only covers the order "conversion already on, then adopt";
    /// the order photographers actually work in is the opposite — open a RAW
    /// (which adopts as-shot at load), then press Auto. The stack is then
    /// flagged sensor-domain while ``EditRenderer/render(source:stack:)``
    /// routes it through `WhiteBalanceStage`, which reads the same field on
    /// `ColorScience`'s uv-offset scale. `rawWBInitialized` is the domain
    /// marker, so the inconsistent state is exactly "flagged AND converting".
    ///
    /// Measured on the 2026-08-13 ProRAW corpus: as-shot neutrals of
    /// 3082–3235K landed in a field whose rendered-domain neutral is 6500,
    /// and all 20 frames rendered heavily blue — median RGB (0.079, 0.236,
    /// 0.615) on IMG_7192 against a neutral (0.214, 0.214, 0.214) once the
    /// units agree. HEICs never adopt, so they were never affected: the
    /// corpus's rendered frames all solved to a perfectly neutral median.
    ///
    /// Pure, and a pure function of the stack alone — the correction needs no
    /// as-shot values, which is what lets every path that can enable a
    /// conversion (Auto, a stock, a preset, a whole roll) share it.
    static func whiteBalanceDomainCorrected(_ stack: EditStack) -> EditStack? {
        guard stack.rawWBInitialized, stack.filmNegative.isEnabled else { return nil }
        var corrected = stack
        corrected.whiteBalanceTemp = EditStack().whiteBalanceTemp
        corrected.whiteBalanceTint = EditStack().whiteBalanceTint
        // Cleared, not merely overwritten: it is what makes the as-shot
        // decision applicable again if the conversion is switched back off.
        corrected.rawWBInitialized = false
        return corrected
    }

    private func activeRenderSource() -> SourceImage? {
        guard let sourceImage else { return nil }
        if (zoomLevel ?? 0) >= 1.0 {
            if fullSourceImage == nil {
                fullSourceImage = ImageDecoder.loadSource(from: entry.fileURL, maxDimension: nil,
                                                          processVersion: editStack.processVersion)
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
