import XCTest
@testable import PhotoEditor

final class PrintSettingsTests: XCTestCase {

    /// The freeze, as a test: an old stack knows nothing about conversion
    /// models, and it must decode to the matrix engine — its rendering is a
    /// promise. Only a *new* conversion gets the density engine.
    func testDecodedDefaultIsMatrixButInitializedDefaultIsDensity() throws {
        XCTAssertEqual(FilmNegativeSettings().conversionModel, .density)

        let old = #"{"isEnabled": true, "type": "colorNegative"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(FilmNegativeSettings.self, from: old)
        XCTAssertEqual(decoded.conversionModel, .matrix)
    }

    /// A stack that recorded a sampled base before `baseOrigin` existed must
    /// come back as `.sampled`, not `.assumed` — same bug class as the
    /// persisted `isBaseSampled` flag itself (see that field's doc comment).
    func testBaseOriginFallsBackToTheLegacySampledFlag() throws {
        let sampled = #"{"isBaseSampled": true}"#.data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(FilmNegativeSettings.self, from: sampled).baseOrigin,
                       .sampled)
        let assumed = #"{"isBaseSampled": false}"#.data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(FilmNegativeSettings.self, from: assumed).baseOrigin,
                       .assumed)
    }

    func testPrintSettingsRoundTripThroughJSON() throws {
        var settings = FilmNegativeSettings()
        settings.print.exposure = 0.7
        settings.print.contrast = 3.5
        settings.print.dmax = DensityTriple(red: 2.4, green: 2.2, blue: 2.0)
        settings.print.gamma = DensityTriple(red: 1.1, green: 1.2, blue: 1.35)
        settings.baseOrigin = .estimated
        let data = try JSONEncoder().encode(settings)
        let back = try JSONDecoder().decode(FilmNegativeSettings.self, from: data)
        XCTAssertEqual(back, settings)
    }

    /// Field-level leniency, same reasoning as the parent type: one missing
    /// key must lose one field, not the whole print block.
    func testPrintSettingsDecodeLeniently() throws {
        let partial = #"{"exposure": 1.5}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(PrintSettings.self, from: partial)
        XCTAssertEqual(decoded.exposure, 1.5)
        XCTAssertEqual(decoded.contrast, 2)
        XCTAssertEqual(decoded.dmax, DensityTriple(red: 2, green: 2, blue: 2))
    }

    /// The neutral-edit check must not report a fresh stack as edited just
    /// because these new fields exist with non-zero defaults.
    func testFreshStackIsStillANeutralEdit() {
        XCTAssertTrue(EditStack().isNeutralEdit)
    }
}
