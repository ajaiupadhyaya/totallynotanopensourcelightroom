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
        let source = try XCTUnwrap(ImageDecoder.loadSource(from: url, maxDimension: nil))
        if case .rendered = source {} else { XCTFail("PNG must load as .rendered") }
    }

    /// Integration against a real RAW, gated on a fixture the repo does not
    /// ship (drop any camera RAW at Tests/Fixtures/RAW/sample.dng or
    /// sample.arw to activate). Everything above runs without it.
    func testRawFixtureDecodesInSensorDomain() throws {
        guard let url = RawFixture.url() else {
            throw XCTSkip("no RAW fixture present — see Tests/Fixtures/RAW/README.md")
        }
        let source = try XCTUnwrap(ImageDecoder.loadSource(from: url, maxDimension: 1600))
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
