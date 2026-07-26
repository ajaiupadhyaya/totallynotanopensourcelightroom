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
