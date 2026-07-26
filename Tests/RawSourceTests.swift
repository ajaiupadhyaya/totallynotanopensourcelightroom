import CoreImage
import XCTest
@testable import PhotoEditor

final class RawSourceTests: XCTestCase {
    func testRawDevelopSettingsMapsTheStack() {
        var stack = EditStack()
        stack.whiteBalanceTemp = 5200
        stack.whiteBalanceTint = 12
        stack.exposure = 0.7
        stack.rawBoost = 40
        let s = RawDevelopSettings(stack: stack)
        XCTAssertEqual(s.temperature, 5200)
        XCTAssertEqual(s.tint, 12)
        XCTAssertEqual(s.exposure, 0.7)
        XCTAssertEqual(s.boost, 0.4)
    }

    /// The develop must be applied once per *change*, not once per render —
    /// otherwise `CIRAWFilter.outputImage`'s fresh identity misses
    /// `DevelopedSourceCache` on every slider tick. `AnyObject` stands in for
    /// the filter so the memo is testable without a camera file; what remains
    /// fixture-gated is that a real `CIRAWFilter` is the object being keyed.
    func testRawDevelopCacheSkipsUnchangedSettings() {
        let cache = RawDevelopCache()
        let filter = NSObject()
        var develops = 0
        func develop() -> CIImage {
            develops += 1
            return TestSupport.solidImage(red: 0.5, green: 0.5, blue: 0.5, size: 8)
        }

        var stack = EditStack()
        let first = cache.image(filter: filter, settings: RawDevelopSettings(stack: stack),
                                develop: develop)
        XCTAssertEqual(develops, 1, "the first call must develop")

        let again = cache.image(filter: filter, settings: RawDevelopSettings(stack: stack),
                                develop: develop)
        XCTAssertEqual(develops, 1, "equal settings must not re-develop")
        XCTAssertTrue(first === again, "the identity is the whole point — a new one misses downstream")

        // The bug this fixes: a slider that is not in RawDevelopSettings.
        stack.contrast = 40
        let unrelated = cache.image(filter: filter, settings: RawDevelopSettings(stack: stack),
                                    develop: develop)
        XCTAssertEqual(develops, 1, "a Contrast tick cannot change the sensor-domain develop")
        XCTAssertTrue(first === unrelated)

        stack.exposure = 0.5
        let changed = cache.image(filter: filter, settings: RawDevelopSettings(stack: stack),
                                  develop: develop)
        XCTAssertEqual(develops, 2, "a sensor-domain change must re-develop")
        XCTAssertFalse(first === changed)

        // Another photo's filter misses even at identical settings.
        _ = cache.image(filter: NSObject(), settings: RawDevelopSettings(stack: stack),
                        develop: develop)
        XCTAssertEqual(develops, 3)
    }

    func testRenderedSourcesStillRouteThroughTheFullChain() {
        let renderer = EditRenderer()
        var stack = EditStack()
        stack.exposure = 1
        let src = SourceImage.rendered(Calibration.patch(0.25))
        let out = Calibration.displayValue(of: renderer.render(source: src, stack: stack,
                                                               mlEnvironment: nil), x: 2, y: 2)
        XCTAssertGreaterThan(out, 0.3)
    }

    func testNonRawFileLoadsAsRendered() throws {
        let url = try TestSupport.makeTempPNG()
        let source = try XCTUnwrap(ImageDecoder.loadSource(from: url, maxDimension: nil,
                                                           processVersion: 2))
        if case .rendered = source {} else { XCTFail("PNG must load as .rendered") }
    }

    /// The freeze: PV1 photos must keep decoding the way they were edited.
    /// PV2's three decode changes (gamut mapping off, EDR boost on,
    /// scaleFactor previews) are all version-gated, so a stack saved before
    /// PV2 existed renders from the same pixels it always did.
    func testRawDecodePolicyFreezesPV1() throws {
        let pv1 = RawDecodePolicy(processVersion: 1)
        XCTAssertFalse(pv1.disablesGamutMapping, "PV1 decoded with Apple's gamut mapping ON")
        XCTAssertNil(pv1.edrAmount, "PV1 decoded with Apple's default EDR amount")
        XCTAssertFalse(pv1.usesScaleFactorPreviews, "PV1 decoded full-size, then downsampled")

        let pv2 = RawDecodePolicy(processVersion: 2)
        XCTAssertTrue(pv2.disablesGamutMapping)
        XCTAssertEqual(pv2.edrAmount, 1.0)
        XCTAssertTrue(pv2.usesScaleFactorPreviews)

        // A version below 1 (corrupt/absent field) is treated as legacy, never
        // as "newer than everything".
        XCTAssertFalse(RawDecodePolicy(processVersion: 0).disablesGamutMapping)
        XCTAssertTrue(RawDecodePolicy(processVersion: 3).disablesGamutMapping)

        // The policy only speaks about RAW: a rendered file decodes identically
        // under either version.
        let url = try TestSupport.makeTempPNG()
        let one = try XCTUnwrap(ImageDecoder.loadSource(from: url, maxDimension: nil,
                                                        processVersion: 1))
        let two = try XCTUnwrap(ImageDecoder.loadSource(from: url, maxDimension: nil,
                                                        processVersion: 2))
        if case .rendered = one {} else { XCTFail("PNG must load as .rendered under PV1") }
        if case .rendered = two {} else { XCTFail("PNG must load as .rendered under PV2") }
        XCTAssertEqual(one.extent, two.extent)
    }

    /// Integration against a real RAW, gated on a fixture the repo does not
    /// ship (drop any camera RAW at Tests/Fixtures/RAW/sample.dng or
    /// sample.arw to activate). Everything above runs without it.
    func testRawFixtureDecodesInSensorDomain() throws {
        guard let url = RawFixture.url() else {
            throw XCTSkip("no RAW fixture present — see Tests/Fixtures/RAW/README.md")
        }
        // The other half of testRawDecodePolicyFreezesPV1: on a real RAW, a PV1
        // load must come back flattened to .rendered (Apple's defaults,
        // decode-then-downsample) rather than as a live sensor-domain filter.
        let legacy = try XCTUnwrap(ImageDecoder.loadSource(from: url, maxDimension: 1600,
                                                           processVersion: 1))
        if case .rendered = legacy {} else {
            XCTFail("a PV1 RAW must decode to .rendered at Apple's defaults")
        }
        XCTAssertLessThanOrEqual(max(legacy.extent.width, legacy.extent.height), 1700,
                                 "PV1 previews downsample the decoded CIImage")

        let source = try XCTUnwrap(ImageDecoder.loadSource(from: url, maxDimension: 1600,
                                                           processVersion: 2))
        guard case .raw(let filter) = source else { return XCTFail("RAW must load as .raw") }
        XCTAssertFalse(filter.isGamutMappingEnabled)
        XCTAssertGreaterThan(filter.extendedDynamicRangeAmount, 0)
        // As-shot neutral is readable — the eyedropper/default-WB contract.
        XCTAssertGreaterThan(filter.neutralTemperature, 1000)
        // Preview decode is actually preview-sized.
        let img = source.image
        XCTAssertLessThanOrEqual(max(img.extent.width, img.extent.height), 1700)
    }

    /// The white-balance eyedropper is switched off wherever the sliders mean
    /// sensor-domain units (see `EditorModel.pickWhiteBalance`). Gated: it
    /// takes a real RAW to produce a `.raw` source at all.
    func testSensorDomainRawDisablesTheWhiteBalancePicker() throws {
        guard let url = RawFixture.url() else {
            throw XCTSkip("no RAW fixture present — see Tests/Fixtures/RAW/README.md")
        }
        let catalog = try TestSupport.inMemoryCatalog()
        let entry = TestSupport.makeEntry(fileURL: url)
        try catalog.save(entry)
        let editor = EditorModel(entry: entry, catalog: catalog,
                                 thumbnails: TestSupport.tempThumbnails(), commitDelay: 60)

        XCTAssertTrue(editor.isSensorDomainWB, "a PV2 non-film RAW edits in the sensor domain")
        let before = editor.editStack
        editor.canvasPicker = .whiteBalance
        editor.handleCanvasClick(atUnitPoint: CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(editor.editStack, before, "the picker must not write D65 units into sensor WB")

        // Film-negative RAWs render through WhiteBalanceStage, so there the
        // picker is meaningful again.
        editor.editStack.filmNegative.isEnabled = true
        XCTAssertFalse(editor.isSensorDomainWB)
    }

    /// The RAW half of the decode/version invariant. `ProcessVersionTests`
    /// pins the version bookkeeping on a PNG; only a real RAW can show that
    /// crossing the boundary actually swaps a flattened `.rendered` decode for
    /// a live `CIRAWFilter` and back. Gated on the fixture.
    func testCrossingTheVersionBoundaryReDecodesARealRaw() throws {
        guard let url = RawFixture.url() else {
            throw XCTSkip("no RAW fixture present — see Tests/Fixtures/RAW/README.md")
        }
        var legacy = EditStack()
        legacy.processVersion = 1

        let catalog = try TestSupport.inMemoryCatalog()
        let entry = TestSupport.makeEntry(fileURL: url, editStack: legacy)
        try catalog.save(entry)
        let editor = EditorModel(entry: entry, catalog: catalog,
                                 thumbnails: TestSupport.tempThumbnails(), commitDelay: 60)

        XCTAssertEqual(editor.decodedProcessVersion, 1)
        XCTAssertFalse(editor.isSensorDomainWB, "a PV1 RAW decodes flattened to .rendered")
        editor.commitEdit()

        editor.upgradeToProcessVersion2()
        editor.commitEdit()
        XCTAssertEqual(editor.decodedProcessVersion, 2)
        XCTAssertTrue(editor.isSensorDomainWB,
                      "the upgrade must yield a live CIRAWFilter, not the old flattened decode")
        XCTAssertTrue(editor.editStack.rawWBInitialized, "…and seed the as-shot neutral off it")

        editor.undo()
        XCTAssertEqual(editor.editStack.processVersion, 1)
        XCTAssertEqual(editor.decodedProcessVersion, 1,
                       "the frozen PV1 chain must not replay against PV2's decode")
        XCTAssertFalse(editor.isSensorDomainWB)
        XCTAssertFalse(editor.isMissingFile)
    }
}

enum RawFixture {
    static func url() -> URL? {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("Fixtures/RAW")
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        return items.first { ImageDecoder.isRAW($0) }
    }
}
