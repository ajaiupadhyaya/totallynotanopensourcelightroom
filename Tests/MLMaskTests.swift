import CoreImage
import XCTest
@testable import PhotoEditor

final class MLMaskTests: XCTestCase {
    private let extent = CGRect(x: 0, y: 0, width: 64, height: 64)

    func testMLMaskShapesDecodeAndContribute() throws {
        let data = try JSONEncoder().encode(MaskComponent(shape: .subject))
        let decoded = try JSONDecoder().decode(MaskComponent.self, from: data)
        XCTAssertEqual(decoded.shape, .subject)
        XCTAssertTrue(decoded.isContributing)
    }

    func testCacheKeyChangesWhenGeometryChanges() {
        let id = UUID()
        let a = MLMaskEnvironment(entryID: id, geometry: Geometry())
        var geometry = Geometry()
        geometry.rotation = .quarter
        let b = MLMaskEnvironment(entryID: id, geometry: geometry)
        XCTAssertNotEqual(a.geometryToken, b.geometryToken)
    }

    func testCacheRoundTrip() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlmask-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let cache = MLMaskCache(directory: temp)
        let environment = MLMaskEnvironment(entryID: UUID(), geometry: Geometry())
        let context = CIContext()
        let mask = CIImage(color: .white).cropped(to: extent)

        cache.store(mask, kind: .subject, environment: environment, context: context)
        let loaded = cache.load(kind: .subject, environment: environment)

        XCTAssertNotNil(loaded)
        let color = TestSupport.readColor(loaded!.cropped(to: CGRect(x: 30, y: 30, width: 4, height: 4)))
        XCTAssertGreaterThan(color.red, 0.9)
    }

    func testSkyMaskProducesCoverageOnBlueTop() {
        let context = CIContext()
        let top = TestSupport.solidImage(red: 0.4, green: 0.6, blue: 0.95,
                                         in: CGRect(x: 0, y: 32, width: 64, height: 32))
        let bottom = TestSupport.solidImage(red: 0.2, green: 0.5, blue: 0.2,
                                            in: CGRect(x: 0, y: 0, width: 64, height: 32))
        let source = top.composited(over: bottom).cropped(to: extent)

        let mask = SubjectMaskProvider.mask(
            kind: .sky, source: source, extent: extent,
            environment: nil, context: context
        )

        XCTAssertNotNil(mask)
        let topCoverage = TestSupport.readColor(
            mask!.cropped(to: CGRect(x: 28, y: 52, width: 8, height: 8))).red
        let bottomCoverage = TestSupport.readColor(
            mask!.cropped(to: CGRect(x: 28, y: 8, width: 8, height: 8))).red
        XCTAssertGreaterThan(topCoverage, bottomCoverage + 0.2)
    }

    func testInvalidateRemovesEntryFiles() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlmask-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let cache = MLMaskCache(directory: temp)
        let entryID = UUID()
        let environment = MLMaskEnvironment(entryID: entryID, geometry: Geometry())
        let context = CIContext()
        let mask = CIImage(color: .white).cropped(to: extent)
        cache.store(mask, kind: .person, environment: environment, context: context)
        XCTAssertNotNil(cache.load(kind: .person, environment: environment))

        cache.invalidate(entryID: entryID)
        XCTAssertNil(cache.load(kind: .person, environment: environment))
    }
}
