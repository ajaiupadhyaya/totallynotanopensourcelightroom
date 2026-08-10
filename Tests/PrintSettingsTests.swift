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
        settings.print.warmth = 60
        settings.print.tint = -35
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
        // The lenient fallback must match the property initializer's house
        // default (Task 8, Phase C), or an old stack missing these keys would
        // decode to a different look than a freshly-created one.
        XCTAssertEqual(decoded.warmth, 24)
        XCTAssertEqual(decoded.tint, -8)
    }

    /// The neutral-edit check must not report a fresh stack as edited just
    /// because these new fields exist with non-zero defaults.
    func testFreshStackIsStillANeutralEdit() {
        XCTAssertTrue(EditStack().isNeutralEdit)
    }

    /// The house look, chosen on visual inspection of a rendered warmth/tint
    /// sweep against the user's own corpus (Task 8, Phase C) — a deliberate
    /// trim of this engine's default look, not a rescue tuned to any one
    /// scan. Pinned as its own test so a future accidental default change
    /// (e.g. a careless edit to the property initializer without its
    /// lenient-decode twin) fails loudly here rather than only showing up as
    /// a diffuse RealScanTests luma shift.
    func testHouseDefaultFiltrationIsWarmth24TintNegative8() {
        XCTAssertEqual(PrintSettings().warmth, 24)
        XCTAssertEqual(PrintSettings().tint, -8)
    }

    /// The freeze asymmetry, same trick as conversionModel: fresh settings are
    /// renderVersion 2; anything decoded from JSON that predates the field is 1.
    func testRenderVersionInitializesTwoDecodesOne() throws {
        XCTAssertEqual(PrintSettings().renderVersion, 2)
        let old = try JSONDecoder().decode(PrintSettings.self,
                                           from: #"{"exposure": 1}"#.data(using: .utf8)!)
        XCTAssertEqual(old.renderVersion, 1)
        XCTAssertEqual(old.toneProfile, .linear)
        XCTAssertEqual(old.punch, 0); XCTAssertEqual(old.fade, 0)
        XCTAssertEqual(old.glow, 0); XCTAssertEqual(old.toeChroma, 0)
    }

    func testApplyToneProfileWritesTheProfileParameters() {
        var p = PrintSettings()
        p.applyToneProfile(.labStandard)
        XCTAssertEqual(p.toneProfile, .labStandard)
        XCTAssertEqual(p.punch, FilmToneProfile.labStandard.punch)
        XCTAssertEqual(p.fade, FilmToneProfile.labStandard.fade)
        XCTAssertEqual(p.glow, FilmToneProfile.labStandard.glow)
        XCTAssertEqual(p.toeChroma, FilmToneProfile.labStandard.toeChroma)
        p.applyToneProfile(.linear)
        XCTAssertEqual(p.punch, 0, "linear must be exactly today's render")
        XCTAssertFalse(FilmToneProfile.linear.enablesAutoColorBalance)
        XCTAssertTrue(FilmToneProfile.labStandard.enablesAutoColorBalance)
    }
}
