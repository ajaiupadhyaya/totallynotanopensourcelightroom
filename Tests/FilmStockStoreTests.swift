import XCTest
@testable import PhotoEditor

/// Verifies that calibrated film stocks persist alongside the catalog and that
/// applying a stock behaves correctly against an already-sampled base.
final class FilmStockStoreTests: XCTestCase {
    private func customStock(name: String = "House Portra") -> FilmStock {
        FilmStock(
            id: "custom-\(name)", name: name, manufacturer: "Calibrated",
            iso: 400, type: .colorNegative,
            baseColor: FilmColor(red: 0.98, green: 0.60, blue: 0.35),
            channelGains: .white, contrast: 2, saturation: 3, isCustom: true
        )
    }

    func testCustomStocksRoundTrip() throws {
        let store = try TestSupport.inMemoryCatalog()
        let stock = customStock()
        try store.saveFilmStock(stock)

        let fetched = try XCTUnwrap(store.customFilmStocks().first)
        XCTAssertEqual(fetched, stock,
                       "A calibrated stock should come back exactly as saved.")
    }

    func testAllStocksPutsCalibratedProfilesFirst() throws {
        let store = try TestSupport.inMemoryCatalog()
        try store.saveFilmStock(customStock())

        let all = try store.allFilmStocks()
        XCTAssertTrue(all.first?.isCustom == true)
        XCTAssertEqual(all.count, FilmStock.builtIn.count + 1)
    }

    func testDeletingACustomStock() throws {
        let store = try TestSupport.inMemoryCatalog()
        let stock = customStock()
        try store.saveFilmStock(stock)
        try store.deleteFilmStock(id: stock.id)

        XCTAssertTrue(try store.customFilmStocks().isEmpty)
        XCTAssertEqual(try store.allFilmStocks().count, FilmStock.builtIn.count)
    }

    func testBuiltInStocksAreNotStoredInTheDatabase() throws {
        // Built-ins live in code so they can be corrected in an update without
        // migrating anyone's catalog.
        let store = try TestSupport.inMemoryCatalog()
        XCTAssertTrue(try store.customFilmStocks().isEmpty)
    }

    func testApplyingAStockKeepsASampledBase() throws {
        let sampled = FilmColor(red: 0.93, green: 0.57, blue: 0.31)
        var settings = FilmNegativeSettings()
        settings.baseColor = sampled

        let stock = try XCTUnwrap(FilmStock.builtIn(id: "kodak-gold-200"))
        settings.apply(stock, keepSampledBase: true)

        XCTAssertEqual(settings.baseColor, sampled,
                       "The base measured from the user's own scan must win.")
        XCTAssertEqual(settings.stockID, "kodak-gold-200")
        XCTAssertEqual(settings.channelGains, stock.channelGains)
    }

    func testApplyingAStockWithoutASampledBaseUsesTheProfileBase() throws {
        var settings = FilmNegativeSettings()
        let stock = try XCTUnwrap(FilmStock.builtIn(id: "fuji-superia-400"))
        settings.apply(stock)

        XCTAssertEqual(settings.baseColor, stock.baseColor)
        XCTAssertEqual(settings.type, .colorNegative)
    }
}
