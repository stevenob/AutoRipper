import XCTest
@testable import AutoRipper

final class LoudounCatalogServiceTests: XCTestCase {

    /// A trimmed fixture matching the real CARL•Connect Discovery schema
    /// (field names verified against the live catalog).
    private let sampleJSON = """
    {
      "totalHits": 3,
      "resources": [
        {
          "id": 100,
          "format": "DVD",
          "shortTitle": "Oppenheimer",
          "shortAuthor": "Nolan, Christopher",
          "publicationDate": { "publicationDate": "2023" },
          "holdingsInformations": [
            { "id": 1, "onshelf": true,  "branchName": "Gum Spring Library", "collectionName": "DVD", "callClass": "DVD DRAMA OPP" },
            { "id": 2, "onshelf": false, "branchName": "Gum Spring Library", "collectionName": "DVD", "callClass": "DVD DRAMA OPP" },
            { "id": 3, "onshelf": true,  "branchName": "Cascades Library",   "collectionName": "DVD", "callClass": "DVD DRAMA OPP" }
          ]
        },
        {
          "id": 200,
          "format": "Blu-Ray",
          "shortTitle": "Top Gun: Maverick",
          "shortAuthor": "",
          "publicationDate": { "publicationDate": "2022" },
          "holdingsInformations": [
            { "id": 4, "onshelf": false, "branchName": "Rust Library", "collectionName": "Blu-ray", "callClass": "BLU ACTION TOP" }
          ]
        },
        {
          "id": 300,
          "format": "eBook",
          "shortTitle": "Dune",
          "shortAuthor": "Herbert, Frank",
          "publicationDate": { "publicationDate": "1965" },
          "holdingsInformations": []
        }
      ]
    }
    """.data(using: .utf8)!

    func testParsesAllResources() {
        let results = LoudounCatalogService.parse(sampleJSON, baseURL: "https://catalog.library.loudoun.gov")
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results[0].title, "Oppenheimer")
        XCTAssertEqual(results[0].year, "2023")
        XCTAssertEqual(results[0].author, "Nolan, Christopher")
        XCTAssertEqual(results[0].format, "DVD")
    }

    func testAvailabilityCounts() {
        let results = LoudounCatalogService.parse(sampleJSON, baseURL: "https://catalog.library.loudoun.gov")
        let opp = results[0]
        XCTAssertEqual(opp.copyCount, 3)
        XCTAssertEqual(opp.availableCount, 2)
        XCTAssertEqual(opp.availableBranches, ["Cascades Library", "Gum Spring Library"])

        let topGun = results[1]
        XCTAssertEqual(topGun.copyCount, 1)
        XCTAssertEqual(topGun.availableCount, 0, "all copies checked out")
        XCTAssertTrue(topGun.availableBranches.isEmpty)
    }

    func testVideoDiscDetection() {
        let results = LoudounCatalogService.parse(sampleJSON, baseURL: "https://catalog.library.loudoun.gov")
        XCTAssertTrue(results[0].isVideoDisc, "DVD is a video disc")
        XCTAssertTrue(results[1].isVideoDisc, "Blu-Ray is a video disc")
        XCTAssertFalse(results[2].isVideoDisc, "eBook is not a video disc")
    }

    func testDetailURLBuiltFromBaseURL() {
        let results = LoudounCatalogService.parse(sampleJSON, baseURL: "https://catalog.library.loudoun.gov/")
        XCTAssertEqual(results[0].detailURL?.absoluteString,
                       "https://catalog.library.loudoun.gov/#section=resource&resourceid=100")
    }

    func testDisplayTitleIncludesYear() {
        let results = LoudounCatalogService.parse(sampleJSON, baseURL: "https://catalog.library.loudoun.gov")
        XCTAssertEqual(results[0].displayTitle, "Oppenheimer (2023)")
    }

    func testToleratesMissingAndMalformedFields() {
        let json = """
        { "resources": [ { "id": 5, "shortTitle": "Mystery" } ] }
        """.data(using: .utf8)!
        let results = LoudounCatalogService.parse(json, baseURL: "https://x.example")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].title, "Mystery")
        XCTAssertEqual(results[0].year, "")
        XCTAssertEqual(results[0].copyCount, 0)
        XCTAssertFalse(results[0].isVideoDisc)
    }

    func testGarbageDataYieldsEmpty() {
        XCTAssertTrue(LoudounCatalogService.parse(Data("not json".utf8), baseURL: "https://x.example").isEmpty)
        XCTAssertTrue(LoudounCatalogService.parse(Data("{}".utf8), baseURL: "https://x.example").isEmpty)
    }

    func testParseOrThrowThrowsOnUnreadablePayload() {
        XCTAssertThrowsError(try LoudounCatalogService.parseOrThrow(Data("<html>nope".utf8),
                                                                    baseURL: "https://x.example"))
        // A valid envelope with no resources is empty, not an error.
        XCTAssertEqual(try LoudounCatalogService.parseOrThrow(Data("{}".utf8),
                                                              baseURL: "https://x.example").count, 0)
    }

    func testResourcesWithoutIdAreSkipped() {
        let json = """
        { "resources": [ { "shortTitle": "No ID" }, { "id": 9, "shortTitle": "Has ID" } ] }
        """.data(using: .utf8)!
        let results = LoudounCatalogService.parse(json, baseURL: "https://x.example")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].id, 9)
    }

    func testOneMalformedRecordDoesNotDiscardOthers() {
        // Second record has a wrong-typed holdings field; it should be dropped
        // while the valid first record survives.
        let json = """
        {
          "resources": [
            { "id": 1, "shortTitle": "Good", "format": "DVD" },
            { "id": 2, "shortTitle": "Bad", "holdingsInformations": "not-an-array" }
          ]
        }
        """.data(using: .utf8)!
        let results = LoudounCatalogService.parse(json, baseURL: "https://x.example")
        XCTAssertEqual(results.map { $0.title }, ["Good"])
    }

    func testNormalizedRoot() {
        XCTAssertEqual(LoudounCatalogService.normalizedRoot("https://catalog.library.loudoun.gov/"),
                       "https://catalog.library.loudoun.gov")
        XCTAssertEqual(LoudounCatalogService.normalizedRoot("https://x.gov/?section=home#frag"),
                       "https://x.gov")
        XCTAssertNil(LoudounCatalogService.normalizedRoot(""))
        XCTAssertNil(LoudounCatalogService.normalizedRoot("not a url"))
        XCTAssertNil(LoudounCatalogService.normalizedRoot("ftp://x.gov"))
    }
}
