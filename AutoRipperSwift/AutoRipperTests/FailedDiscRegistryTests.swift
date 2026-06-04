import XCTest
@testable import AutoRipper

final class FailedDiscRegistryTests: XCTestCase {

    private func makeRegistry() -> (FailedDiscRegistry, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = dir.appendingPathComponent("failed-discs.json")
        return (FailedDiscRegistry(storeURL: store), dir)
    }

    private func movie(_ title: String, _ year: Int, _ tmdb: Int,
                       label: String, tid: Int = 1, reason: String = "boom") -> FailedDiscEntry {
        FailedDiscEntry(date: Date(), volumeLabel: label, title: title, year: year,
                        mediaType: "movie", tmdbId: tmdb, reason: reason,
                        failedTitleIds: [tid], readErrors: 0, corruptionEvents: 0)
    }

    func testRecordAndAll() async {
        let (reg, _) = makeRegistry()
        await reg.record(key: "fp1", entry: movie("Avatar", 2022, 76600, label: "AVATAR"))
        let all = await reg.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.entry.tmdbId, 76600)
        XCTAssertEqual(all.first?.entry.displayName, "Avatar (2022)")
    }

    func testDedupMergesFailedTitleIds() async {
        let (reg, _) = makeRegistry()
        await reg.record(key: "fp1", entry: movie("Avatar", 2022, 76600, label: "AVATAR", tid: 1))
        await reg.record(key: "fp1", entry: movie("Avatar", 2022, 76600, label: "AVATAR", tid: 3))
        let all = await reg.all()
        XCTAssertEqual(all.count, 1, "same key must dedup to one entry")
        XCTAssertEqual(all.first?.entry.failedTitleIds, [1, 3])
    }

    func testUnmatchedFailureKeepsEarlierMatch() async {
        let (reg, _) = makeRegistry()
        await reg.record(key: "fp1", entry: movie("Avatar", 2022, 76600, label: "AVATAR", tid: 1))
        // A later failure on the same disc without a TMDb match shouldn't wipe metadata.
        let unmatched = FailedDiscEntry(date: Date(), volumeLabel: "AVATAR", title: nil, year: nil,
                                        mediaType: nil, tmdbId: nil, reason: "again",
                                        failedTitleIds: [2], readErrors: 1, corruptionEvents: 0)
        await reg.record(key: "fp1", entry: unmatched)
        let all = await reg.all()
        XCTAssertEqual(all.first?.entry.tmdbId, 76600)
        XCTAssertEqual(all.first?.entry.failedTitleIds, [1, 2])
    }

    func testRadarrExportMoviesOnly() async throws {
        let (reg, dir) = makeRegistry()
        await reg.record(key: "m", entry: movie("Avatar", 2022, 76600, label: "AVATAR"))
        let tv = FailedDiscEntry(date: Date(), volumeLabel: "SHOW_D1", title: "Some Show", year: 2019,
                                 mediaType: "tv", tmdbId: 1234, reason: "x",
                                 failedTitleIds: [0], readErrors: 0, corruptionEvents: 0)
        await reg.record(key: "t", entry: tv)

        let data = try Data(contentsOf: dir.appendingPathComponent("failed-discs-radarr.json"))
        let arr = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        XCTAssertEqual(arr.count, 1, "Radarr export must include movies only")
        XCTAssertEqual(arr.first?["tmdb_id"] as? Int, 76600)
        XCTAssertEqual(arr.first?["title"] as? String, "Avatar")
    }

    func testCsvEscapesCommasAndQuotes() async throws {
        let (reg, dir) = makeRegistry()
        await reg.record(key: "m", entry: movie("Hello, \"World\"", 2020, 42,
                                                 label: "HELLO", reason: "err, with \"quotes\""))
        let csv = try String(contentsOf: dir.appendingPathComponent("failed-discs.csv"))
        XCTAssertTrue(csv.contains("\"Hello, \"\"World\"\" (2020)\""), "commas/quotes must be CSV-escaped")
        XCTAssertTrue(csv.contains("\"err, with \"\"quotes\"\"\""))
    }

    func testForgetAndClear() async {
        let (reg, _) = makeRegistry()
        await reg.record(key: "a", entry: movie("A", 2000, 1, label: "A"))
        await reg.record(key: "b", entry: movie("B", 2001, 2, label: "B"))
        await reg.forget(key: "a")
        var all = await reg.all()
        XCTAssertEqual(all.map { $0.key }, ["b"])
        await reg.clear()
        all = await reg.all()
        XCTAssertTrue(all.isEmpty)
    }

    func testPersistenceAcrossInstances() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = dir.appendingPathComponent("failed-discs.json")

        let reg1 = FailedDiscRegistry(storeURL: store)
        await reg1.record(key: "fp1", entry: movie("Avatar", 2022, 76600, label: "AVATAR"))

        let reg2 = FailedDiscRegistry(storeURL: store)
        let all = await reg2.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.entry.title, "Avatar")
    }
}
