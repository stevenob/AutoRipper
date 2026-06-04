import XCTest
@testable import AutoRipper

final class FailedDiscLogScannerTests: XCTestCase {

    func testParsesMsg5003FolderAndTitle() {
        let line = #"2026-06-04 08:50:01.285 [INFO] makemkv: MSG:5003,0,2,"Failed to save title 1 to file /Volumes/MacEx/Ripped/Avatar The Way of Water (2022)/Avatar- The Way of Water_t01.mkv","Failed to save title %1 to file %2","1","/Volumes/MacEx/Ripped/Avatar The Way of Water (2022)/Avatar- The Way of Water_t01.mkv""#
        let result = FailedDiscLogScanner.parse(line)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.folderName, "Avatar The Way of Water (2022)")
        XCTAssertEqual(result.first?.titleId, 1)
        XCTAssertNotNil(result.first?.date)
    }

    func testIgnoresNonFailureLines() {
        let text = """
        2026-06-04 08:03:55 [INFO] makemkv: MSG:5014,131072,2,"Saving 1 titles into directory file:///x"
        2026-06-04 08:50:00 [INFO] makemkv: MSG:2003,0,3,"Error reading at offset"
        """
        XCTAssertTrue(FailedDiscLogScanner.parse(text).isEmpty)
    }

    func testDedupKeepsMostRecentPerFolder() {
        let text = """
        2026-06-01 10:00:00.000 [INFO] makemkv: MSG:5003,0,2,"Failed to save title 1 to file /v/Ripped/Movie (2020)/a_t01.mkv","x","1","/v/Ripped/Movie (2020)/a_t01.mkv"
        2026-06-03 12:00:00.000 [INFO] makemkv: MSG:5003,0,2,"Failed to save title 2 to file /v/Ripped/Movie (2020)/a_t02.mkv","x","2","/v/Ripped/Movie (2020)/a_t02.mkv"
        """
        let result = FailedDiscLogScanner.parse(text)
        XCTAssertEqual(result.count, 1, "same folder must dedup")
        XCTAssertEqual(result.first?.titleId, 2, "keeps the most recent occurrence")
    }

    func testMultipleDistinctFoldersNewestFirst() {
        let text = """
        2026-06-01 10:00:00.000 [INFO] makemkv: MSG:5003,0,2,"Failed to save title 1 to file /v/A (2020)/a_t01.mkv","x","1","/v/A (2020)/a_t01.mkv"
        2026-06-05 10:00:00.000 [INFO] makemkv: MSG:5003,0,2,"Failed to save title 1 to file /v/B (2021)/b_t01.mkv","x","1","/v/B (2021)/b_t01.mkv"
        """
        let result = FailedDiscLogScanner.parse(text)
        XCTAssertEqual(result.map { $0.folderName }, ["B (2021)", "A (2020)"])
    }
}
