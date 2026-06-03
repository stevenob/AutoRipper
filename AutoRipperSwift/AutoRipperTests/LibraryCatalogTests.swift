import XCTest
@testable import AutoRipper

final class LibraryCatalogTests: XCTestCase {

    // MARK: - Codable

    func testCatalogRoundTrips() throws {
        let cat = LibraryCatalog(name: "Test", url: "https://x.gov", kind: .externalLink)
        let data = try JSONEncoder().encode(cat)
        let decoded = try JSONDecoder().decode(LibraryCatalog.self, from: data)
        XCTAssertEqual(cat, decoded)
    }

    // MARK: - Seeds / migration

    func testBuiltInSeedsDefaults() {
        let seeds = LibraryCatalog.builtInSeeds(legacyLoudounURL: nil)
        XCTAssertEqual(seeds.count, 2)
        XCTAssertEqual(seeds[0].id, LibraryCatalog.loudounID)
        XCTAssertEqual(seeds[0].kind, .carlConnect)
        XCTAssertEqual(seeds[0].url, "https://catalog.library.loudoun.gov")
        XCTAssertEqual(seeds[1].id, LibraryCatalog.fairfaxID)
        XCTAssertEqual(seeds[1].kind, .externalLink)
        XCTAssertTrue(seeds[1].url.contains(LibraryCatalog.queryPlaceholder))
    }

    func testBuiltInSeedsMigratesLegacyURL() {
        let seeds = LibraryCatalog.builtInSeeds(legacyLoudounURL: "https://my.custom.gov")
        XCTAssertEqual(seeds[0].url, "https://my.custom.gov")
    }

    func testBuiltInSeedsIgnoresEmptyLegacyURL() {
        let seeds = LibraryCatalog.builtInSeeds(legacyLoudounURL: "")
        XCTAssertEqual(seeds[0].url, "https://catalog.library.loudoun.gov")
    }

    // MARK: - Selection resolution

    func testResolveSelectionFallsBackToFirstWhenDangling() {
        let cats = LibraryCatalog.builtInSeeds(legacyLoudounURL: nil)
        let resolved = LibraryCatalog.resolveSelection(id: "not-a-real-id", in: cats)
        XCTAssertEqual(resolved?.id, cats.first?.id)
    }

    func testResolveSelectionMatchesByID() {
        let cats = LibraryCatalog.builtInSeeds(legacyLoudounURL: nil)
        let resolved = LibraryCatalog.resolveSelection(id: LibraryCatalog.fairfaxID.uuidString, in: cats)
        XCTAssertEqual(resolved?.id, LibraryCatalog.fairfaxID)
    }

    func testResolveSelectionEmptyListIsNil() {
        XCTAssertNil(LibraryCatalog.resolveSelection(id: "x", in: []))
    }

    // MARK: - External search URL building

    func testExternalSearchURLSubstitutesAndEncodes() {
        let template = "https://lib.gov/search?term=\(LibraryCatalog.queryPlaceholder)&by=KW"
        let url = LibraryCatalog.externalSearchURL(template: template, query: "batman 1989")
        XCTAssertEqual(url?.absoluteString, "https://lib.gov/search?term=batman%201989&by=KW")
    }

    func testExternalSearchURLEncodesAmpersandAndParens() {
        let template = "https://lib.gov/s?term=\(LibraryCatalog.queryPlaceholder)"
        let url = LibraryCatalog.externalSearchURL(template: template, query: "Wallace & Gromit (2005)")
        // & ( ) and spaces must all be percent-encoded so they don't break the query.
        XCTAssertEqual(url?.absoluteString,
                       "https://lib.gov/s?term=Wallace%20%26%20Gromit%20%282005%29")
    }

    func testExternalSearchURLNilWhenNoPlaceholder() {
        XCTAssertNil(LibraryCatalog.externalSearchURL(template: "https://lib.gov/s?term=foo", query: "x"))
    }

    func testExternalSearchURLNilWhenEmptyQuery() {
        let template = "https://lib.gov/s?term=\(LibraryCatalog.queryPlaceholder)"
        XCTAssertNil(LibraryCatalog.externalSearchURL(template: template, query: "   "))
    }

    func testExternalSearchURLNilWhenNotHTTP() {
        let template = "ftp://lib.gov/s?term=\(LibraryCatalog.queryPlaceholder)"
        XCTAssertNil(LibraryCatalog.externalSearchURL(template: template, query: "x"))
    }

    func testIsValidExternalTemplate() {
        XCTAssertTrue(LibraryCatalog.isValidExternalTemplate(
            "https://lib.gov/s?term=\(LibraryCatalog.queryPlaceholder)"))
        XCTAssertFalse(LibraryCatalog.isValidExternalTemplate("https://lib.gov/s?term=foo"))
        XCTAssertFalse(LibraryCatalog.isValidExternalTemplate(
            "ftp://lib.gov/s?term=\(LibraryCatalog.queryPlaceholder)"))
    }

    // MARK: - View-model routing

    @MainActor
    func testExternalCatalogOpensBrowserWithoutSearching() {
        let config = AppConfig()
        let saved = config.libraryCatalogs
        let savedSel = config.selectedLibraryCatalogID
        defer { config.libraryCatalogs = saved; config.selectedLibraryCatalogID = savedSel }

        let external = LibraryCatalog(
            name: "Fairfax",
            url: "https://fcplcat.fairfaxcounty.gov/s?term=\(LibraryCatalog.queryPlaceholder)&by=KW",
            kind: .externalLink)
        config.libraryCatalogs = [external]
        config.selectedLibraryCatalogID = external.id.uuidString

        let vm = LibraryCatalogViewModel()
        var opened: URL?
        vm.openURL = { opened = $0 }
        vm.query = "batman 1989"
        vm.search(config: config)

        XCTAssertEqual(opened?.absoluteString,
                       "https://fcplcat.fairfaxcounty.gov/s?term=batman%201989&by=KW")
        XCTAssertNotNil(vm.infoMessage)
        XCTAssertFalse(vm.isSearching)
        XCTAssertFalse(vm.hasSearched)
    }
}
