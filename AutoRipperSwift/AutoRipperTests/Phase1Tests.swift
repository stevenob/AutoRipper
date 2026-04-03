import XCTest
@testable import AutoRipper

final class OrganizerServiceTests: XCTestCase {

    func testCleanFilenameStripsIllegalChars() {
        XCTAssertEqual(OrganizerService.cleanFilename("My:Movie/Title"), "MyMovieTitle")
    }

    func testCleanFilenameNormalizesWhitespace() {
        XCTAssertEqual(OrganizerService.cleanFilename("  Hello  World  "), "Hello World")
    }

    func testBuildMoviePathWithYear() {
        let path = OrganizerService.buildMoviePath(outputDir: "/output", title: "The Matrix", year: 1999)
        XCTAssertEqual(path.lastPathComponent, "The Matrix (1999).mkv")
        XCTAssertEqual(path.deletingLastPathComponent().lastPathComponent, "The Matrix (1999)")
    }

    func testBuildMoviePathWithoutYear() {
        let path = OrganizerService.buildMoviePath(outputDir: "/output", title: "Untitled")
        XCTAssertEqual(path.lastPathComponent, "Untitled.mkv")
    }

    func testBuildTvPathBasic() {
        let path = OrganizerService.buildTvPath(
            outputDir: "/output", show: "Breaking Bad", season: 1, episode: 3
        )
        XCTAssertEqual(path.lastPathComponent, "Breaking Bad - S01E03.mkv")
        XCTAssertEqual(path.deletingLastPathComponent().lastPathComponent, "Season 01")
    }

    func testBuildTvPathWithEpisodeName() {
        let path = OrganizerService.buildTvPath(
            outputDir: "/output", show: "Show", season: 2, episode: 5, episodeName: "Pilot"
        )
        XCTAssertEqual(path.lastPathComponent, "Show - S02E05 - Pilot.mkv")
    }
}

final class DiscInfoTests: XCTestCase {

    func testTitleInfoDurationParsing() {
        let t = TitleInfo(id: 0, name: "Title", duration: "1:30:00", sizeBytes: 0, chapters: 1, fileOutput: "")
        XCTAssertEqual(t.durationSeconds, 5400)
    }

    func testTitleInfoResolutionLabel() {
        var t = TitleInfo(id: 0, name: "Title", duration: "0:10:00", sizeBytes: 0, chapters: 1, fileOutput: "")
        t.resolution = "1920x1080"
        XCTAssertEqual(t.resolutionLabel, "1080p")
    }

    func testTitleInfoHumanSize() {
        let t = TitleInfo(id: 0, name: "Title", duration: "0:10:00", sizeBytes: 1_073_741_824, chapters: 1, fileOutput: "")
        XCTAssertTrue(t.humanSize.contains("GB") || t.humanSize.contains("1"))
    }
}

final class JobTests: XCTestCase {

    func testJobDefaults() {
        let j = Job(discName: "Test", rippedFile: URL(fileURLWithPath: "/tmp/test.mkv"))
        XCTAssertEqual(j.status, .queued)
        XCTAssertEqual(j.progress, 0)
        XCTAssertEqual(j.progressText, "Queued")
        XCTAssertTrue(j.id.hasPrefix("job_"))
    }
}

final class MediaResultTests: XCTestCase {

    func testDisplayTitleWithYear() {
        let m = MediaResult(title: "The Matrix", year: 1999, mediaType: "movie", tmdbId: 603)
        XCTAssertEqual(m.displayTitle, "The Matrix (1999)")
    }

    func testDisplayTitleWithoutYear() {
        let m = MediaResult(title: "Unknown", year: nil, mediaType: "movie", tmdbId: 0)
        XCTAssertEqual(m.displayTitle, "Unknown")
    }
}
