import XCTest
@testable import AutoRipper

// MARK: - Letterboxd watchlist CSV parser

final class LetterboxdWatchlistCSVTests: XCTestCase {

    func testStandardFreeExportHeader() {
        // The default free-account watchlist.csv: Date,Name,Year,Letterboxd URI
        let csv = """
        Date,Name,Year,Letterboxd URI
        2024-01-02,Garden State,2004,https://boxd.it/abc
        2024-01-03,Disaster Movie,2008,https://boxd.it/def
        """
        let films = LetterboxdWatchlistCSV.parse(csv)
        XCTAssertEqual(films.count, 2)
        XCTAssertEqual(films[0].name, "Garden State")
        XCTAssertEqual(films[0].year, 2004)
        XCTAssertNil(films[0].tmdbId)
        XCTAssertEqual(films[0].letterboxdURI, "https://boxd.it/abc")
        XCTAssertEqual(films[1].name, "Disaster Movie")
        XCTAssertEqual(films[1].year, 2008)
    }

    func testTmdbAndImdbColumnsWhenPresent() {
        let csv = """
        Name,Year,TMDb ID,IMDb ID
        Heat,1995,949,tt0113277
        """
        let films = LetterboxdWatchlistCSV.parse(csv)
        XCTAssertEqual(films.count, 1)
        XCTAssertEqual(films[0].tmdbId, 949)
        XCTAssertEqual(films[0].imdbId, "tt0113277")
    }

    func testQuotedFieldsWithCommasAndEscapedQuotes() {
        // Built as an escaped string so the embedded CSV quotes don't collide
        // with Swift's own multi-line string delimiters.
        let q = "\""
        let csv =
            "Date,Name,Year,Letterboxd URI\n" +
            "2024-01-02,\(q)Good, the Bad and the Ugly, The\(q),1966,https://boxd.it/x\n" +
            "2024-01-03,\(q)He Said \(q)\(q)Hi\(q)\(q)\(q),2020,https://boxd.it/y\n"
        let films = LetterboxdWatchlistCSV.parse(csv)
        XCTAssertEqual(films.count, 2)
        XCTAssertEqual(films[0].name, "Good, the Bad and the Ugly, The")
        XCTAssertEqual(films[0].year, 1966)
        XCTAssertEqual(films[1].name, "He Said \"Hi\"")
    }

    func testColumnOrderIsResolvedByHeaderName() {
        // Columns in a different order than the standard export.
        let csv = """
        Letterboxd URI,Year,Name
        https://boxd.it/z,1999,The Matrix
        """
        let films = LetterboxdWatchlistCSV.parse(csv)
        XCTAssertEqual(films.count, 1)
        XCTAssertEqual(films[0].name, "The Matrix")
        XCTAssertEqual(films[0].year, 1999)
        XCTAssertEqual(films[0].letterboxdURI, "https://boxd.it/z")
    }

    func testCaseInsensitiveHeaders() {
        let csv = """
        name,YEAR,tmdb id
        Dune,2021,438631
        """
        let films = LetterboxdWatchlistCSV.parse(csv)
        XCTAssertEqual(films.count, 1)
        XCTAssertEqual(films[0].name, "Dune")
        XCTAssertEqual(films[0].tmdbId, 438631)
    }

    func testSkipsRowsWithoutAName() {
        let csv = """
        Date,Name,Year,Letterboxd URI
        2024-01-02,,2004,https://boxd.it/abc
        2024-01-03,Real Film,2010,https://boxd.it/def
        """
        let films = LetterboxdWatchlistCSV.parse(csv)
        XCTAssertEqual(films.count, 1)
        XCTAssertEqual(films[0].name, "Real Film")
    }

    func testMissingYearIsNil() {
        let csv = """
        Name,Year
        Untitled Project,
        """
        let films = LetterboxdWatchlistCSV.parse(csv)
        XCTAssertEqual(films.count, 1)
        XCTAssertNil(films[0].year)
    }

    func testCRLFLineEndings() {
        let csv = "Name,Year\r\nFargo,1996\r\nAkira,1988\r\n"
        let films = LetterboxdWatchlistCSV.parse(csv)
        XCTAssertEqual(films.count, 2)
        XCTAssertEqual(films[0].name, "Fargo")
        XCTAssertEqual(films[1].name, "Akira")
    }

    func testEmbeddedNewlineInsideQuotedField() {
        let csv = "Name,Year\r\n\"Line one\nLine two\",2001\r\n"
        let films = LetterboxdWatchlistCSV.parse(csv)
        XCTAssertEqual(films.count, 1)
        XCTAssertEqual(films[0].name, "Line one\nLine two")
        XCTAssertEqual(films[0].year, 2001)
    }

    func testEmptyOrHeaderOnlyInput() {
        XCTAssertTrue(LetterboxdWatchlistCSV.parse("").isEmpty)
        XCTAssertTrue(LetterboxdWatchlistCSV.parse("Date,Name,Year,Letterboxd URI").isEmpty)
    }

    func testStripsLeadingUTF8BOM() {
        let csv = "\u{FEFF}Name,Year\nDune,2021"
        let films = LetterboxdWatchlistCSV.parse(csv)
        XCTAssertEqual(films.count, 1)
        XCTAssertEqual(films[0].name, "Dune")
    }

    func testNoNameColumnYieldsNothing() {
        let csv = """
        Date,Year,Letterboxd URI
        2024-01-02,2004,https://boxd.it/abc
        """
        XCTAssertTrue(LetterboxdWatchlistCSV.parse(csv).isEmpty)
    }
}

// MARK: - Watchlist store

@MainActor
final class LetterboxdWatchlistStoreTests: XCTestCase {

    private func makeStore() -> (LetterboxdWatchlistStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wl-\(UUID().uuidString).json")
        return (LetterboxdWatchlistStore(storeURL: url), url)
    }

    func testContainsHandlesNilAndMembership() {
        let (store, _) = makeStore()
        XCTAssertFalse(store.contains(nil))
        XCTAssertFalse(store.contains(123))
    }

    func testClearOnEmptyStoreIsSafe() {
        let (store, _) = makeStore()
        store.clear()
        XCTAssertFalse(store.hasWatchlist)
        XCTAssertTrue(store.tmdbIds.isEmpty)
    }

    func testImportWithExplicitTmdbIdsResolvesWithoutNetwork() async {
        // Films already carry TMDb IDs, so no TMDb lookup is needed.
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let csv = """
        Name,Year,TMDb ID
        Heat,1995,949
        Dune,2021,438631
        """
        let csvURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wl-\(UUID().uuidString).csv")
        try? csv.write(to: csvURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: csvURL) }

        await store.importCSV(at: csvURL)

        XCTAssertEqual(store.importedCount, 2)
        XCTAssertEqual(store.resolvedCount, 2)
        XCTAssertTrue(store.contains(949))
        XCTAssertTrue(store.contains(438631))
        XCTAssertTrue(store.hasWatchlist)

        // A fresh store backed by the same file should reload the IDs.
        let reloaded = LetterboxdWatchlistStore(storeURL: url)
        XCTAssertTrue(reloaded.contains(949))
        XCTAssertTrue(reloaded.contains(438631))
        XCTAssertEqual(reloaded.resolvedCount, 2)
    }

    func testClearRemovesPersistedFile() async {
        let (store, url) = makeStore()
        let csv = "Name,Year,TMDb ID\nHeat,1995,949"
        let csvURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wl-\(UUID().uuidString).csv")
        try? csv.write(to: csvURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: csvURL) }

        await store.importCSV(at: csvURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        store.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(store.hasWatchlist)
        XCTAssertFalse(store.contains(949))
    }

    func testFailedResolutionPreservesPreviousWatchlist() async {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        // First import succeeds via explicit IDs (no network needed).
        let good = "Name,Year,TMDb ID\nHeat,1995,949"
        let goodURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wl-\(UUID().uuidString).csv")
        try? good.write(to: goodURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: goodURL) }
        await store.importCSV(at: goodURL)
        XCTAssertTrue(store.contains(949))

        // Second import has films needing resolution but no TMDb key, so it
        // can't resolve anything — the previous watchlist must be kept.
        let config = AppConfig()
        let savedKey = config.tmdbApiKey
        config.tmdbApiKey = ""
        defer { config.tmdbApiKey = savedKey }

        let bad = "Name,Year\nSome Obscure Film,1973"
        let badURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wl-\(UUID().uuidString).csv")
        try? bad.write(to: badURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: badURL) }
        await store.importCSV(at: badURL, config: config)

        XCTAssertTrue(store.contains(949), "previous watchlist should survive a failed import")
        XCTAssertTrue(store.hasWatchlist)
        XCTAssertFalse(store.status.isEmpty)
    }
}
