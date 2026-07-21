import XCTest
@testable import PhotoEditor

/// Verifies the canvas tool rail: that picking a tool actually puts the editor
/// into that tool's state, that leaving one tidies up after it, and that the
/// keys the rail advertises in its tooltips are the keys that really work.
final class ToolActivationTests: XCTestCase {
    private func makeWorkspace() throws -> (WorkspaceModel, EditorModel, URL) {
        let url = try TestSupport.makeTempPNG()
        let catalog = try TestSupport.inMemoryCatalog()
        let entry = TestSupport.makeEntry(fileURL: url)
        try catalog.save(entry)
        let editor = EditorModel(
            entry: entry, catalog: catalog,
            thumbnails: TestSupport.tempThumbnails(), commitDelay: 60
        )
        return (WorkspaceModel(), editor, url)
    }

    // MARK: Advertised shortcuts

    /// The rail shows "Brush · B" in every tooltip. Each of those keys must
    /// select the tool it names — a hint for a key nothing listens to is a
    /// promise the app does not keep.
    func testEveryAdvertisedShortcutSelectsTheToolItNames() {
        for tool in EditorTool.allCases where tool != .compare {
            guard let hint = tool.shortcutHint else {
                XCTFail("\(tool.label) shows no shortcut hint.")
                continue
            }
            XCTAssertEqual(EditorTool(shortcutKey: hint), tool,
                           "\(tool.label) advertises \(hint) but that key does not select it.")
        }
    }

    func testAdvertisedShortcutsAreUniqueAndCaseInsensitive() {
        let keys = EditorTool.allCases.compactMap { $0.shortcutHint?.lowercased() }
        XCTAssertEqual(Set(keys).count, keys.count, "Two tools claim the same key.")
        XCTAssertEqual(EditorTool(shortcutKey: "b"), .brush)
        XCTAssertEqual(EditorTool(shortcutKey: "B"), .brush)
    }

    func testUnboundKeysSelectNothing() {
        XCTAssertNil(EditorTool(shortcutKey: "q"))
        XCTAssertNil(EditorTool(shortcutKey: ""))
        XCTAssertNil(EditorTool(shortcutKey: "\\"),
                     "Before/after is momentary, not a tool to enter.")
    }

    // MARK: Activation

    func testBrushCreatesThenReusesOneMask() throws {
        let (workspace, editor, url) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: url) }

        workspace.activate(.brush, in: editor)
        XCTAssertEqual(editor.editStack.localAdjustments.count, 1)
        XCTAssertEqual(editor.editStack.localAdjustments.first?.shape, .brush)
        XCTAssertEqual(workspace.inspectorMode, .masks)
        let first = editor.selectedMaskID

        workspace.activate(.hand, in: editor)
        workspace.activate(.brush, in: editor)
        XCTAssertEqual(editor.editStack.localAdjustments.count, 1,
                       "Returning to the brush must not pile up empty masks.")
        XCTAssertEqual(editor.selectedMaskID, first)
    }

    func testEyedropperAndHealArmTheirCanvasPickers() throws {
        let (workspace, editor, url) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: url) }

        workspace.activate(.eyedropper, in: editor)
        XCTAssertEqual(editor.canvasPicker, .whiteBalance)

        workspace.activate(.heal, in: editor)
        XCTAssertEqual(editor.canvasPicker, .retouchPlace)
        XCTAssertEqual(editor.retouchMode, .heal)

        workspace.activate(.clone, in: editor)
        XCTAssertEqual(editor.retouchMode, .clone)

        workspace.activate(.hand, in: editor)
        XCTAssertNil(editor.canvasPicker, "Leaving a tool must disarm its picker.")
        XCTAssertNil(editor.selectedSpotID)
    }

    func testLeavingCropCommitsIt() throws {
        let (workspace, editor, url) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: url) }

        workspace.activate(.crop, in: editor)
        XCTAssertTrue(editor.isCropping)

        workspace.activate(.hand, in: editor)
        XCTAssertFalse(editor.isCropping)
    }

    /// `\` is a momentary look at the original. It must not disturb the tool
    /// in hand — routing it through activation would silently commit a crop
    /// the moment someone glanced at the before state.
    func testCompareIsMomentaryAndLeavesAnInProgressCropAlone() throws {
        let (workspace, editor, url) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: url) }

        workspace.activate(.crop, in: editor)
        workspace.activate(.compare, in: editor)

        XCTAssertTrue(editor.isShowingBefore)
        XCTAssertTrue(editor.isCropping, "Comparing must not commit the crop.")
        XCTAssertEqual(workspace.activeTool, .crop, "Comparing must not change tools.")

        workspace.activate(.compare, in: editor)
        XCTAssertFalse(editor.isShowingBefore)
    }

    func testOpeningAnotherPhotoReturnsToTheNeutralTool() throws {
        let (workspace, editor, url) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: url) }

        workspace.activate(.crop, in: editor)
        XCTAssertEqual(workspace.activeTool, .crop)

        workspace.resetForNewPhoto()
        XCTAssertEqual(workspace.activeTool, .hand,
                       "A new frame must not inherit the previous frame's tool.")
    }
}
