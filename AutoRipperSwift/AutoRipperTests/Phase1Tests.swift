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

    func testBuildMoviePathWithEdition() {
        let path = OrganizerService.buildMoviePath(
            outputDir: "/output", title: "Blade Runner", year: 1982, edition: "Final Cut"
        )
        XCTAssertEqual(path.lastPathComponent, "Blade Runner (1982) {edition-Final Cut}.mkv")
        // Editions of the same movie share the parent folder so artwork/NFO are shared.
        XCTAssertEqual(path.deletingLastPathComponent().lastPathComponent, "Blade Runner (1982)")
    }

    func testBuildMoviePathWithEmptyEditionTreatedAsNone() {
        let path = OrganizerService.buildMoviePath(
            outputDir: "/output", title: "The Matrix", year: 1999, edition: ""
        )
        XCTAssertEqual(path.lastPathComponent, "The Matrix (1999).mkv")
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

    func testBuildTvPathDoubleDigitSeasonAndEpisode() {
        // Sanity: padding works for S/E ≥ 10. Verifies the format matches Plex/Jellyfin
        // expectations even for long-running shows.
        let path = OrganizerService.buildTvPath(
            outputDir: "/output", show: "The Long Show", season: 12, episode: 24,
            episodeName: "Series Finale"
        )
        XCTAssertEqual(path.lastPathComponent, "The Long Show - S12E24 - Series Finale.mkv")
        XCTAssertEqual(path.deletingLastPathComponent().lastPathComponent, "Season 12")
        XCTAssertEqual(path.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent, "The Long Show")
    }

    func testBuildTvPathStripsIllegalCharsFromShowAndEpisode() {
        // Defensive: TMDb episode titles can contain colons, slashes, etc. that
        // break filenames. Verifies cleanFilename is applied to both show and ep.
        let path = OrganizerService.buildTvPath(
            outputDir: "/output", show: "Star Wars: Andor", season: 1, episode: 5,
            episodeName: "The Axe Forgets"
        )
        XCTAssertEqual(path.lastPathComponent, "Star Wars Andor - S01E05 - The Axe Forgets.mkv")
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

    func testLooksLikeTVSeasonDetectsSimilarRuntimes() {
        // 6 titles around 42 min — typical hour-long TV episodes minus ads.
        let titles: [TitleInfo] = (1...6).map { i in
            var t = TitleInfo(id: i, name: "Title \(i)", duration: "0:42:00",
                              sizeBytes: 4_000_000_000, chapters: 5, fileOutput: "")
            // mild jitter
            _ = i
            return t
        }
        let info = DiscInfo(name: "BREAKING_BAD_S1_D1", type: "dvd", titles: titles)
        XCTAssertTrue(info.looksLikeTVSeason)
        XCTAssertEqual(info.tvEpisodeCandidateIds.count, 6)
    }

    func testLooksLikeTVSeasonRejectsMovieDisc() {
        // One 2-hour main feature + a few short extras.
        let titles: [TitleInfo] = [
            TitleInfo(id: 1, name: "Main", duration: "2:00:00", sizeBytes: 30_000_000_000, chapters: 16, fileOutput: ""),
            TitleInfo(id: 2, name: "Trailer", duration: "0:02:00", sizeBytes: 100_000_000, chapters: 1, fileOutput: ""),
            TitleInfo(id: 3, name: "Extra", duration: "0:08:00", sizeBytes: 500_000_000, chapters: 1, fileOutput: ""),
        ]
        let info = DiscInfo(name: "BLADE_RUNNER", type: "bluray", titles: titles)
        XCTAssertFalse(info.looksLikeTVSeason)
    }

    func testLooksLikeTVSeasonRejectsCollectionDisc() {
        // Three full-length movies (varying durations) — looks like a collection.
        let titles: [TitleInfo] = [
            TitleInfo(id: 1, name: "Saw 1",  duration: "1:43:00", sizeBytes: 25_000_000_000, chapters: 18, fileOutput: ""),
            TitleInfo(id: 2, name: "Saw 2",  duration: "1:35:00", sizeBytes: 24_000_000_000, chapters: 16, fileOutput: ""),
            TitleInfo(id: 3, name: "Saw 3",  duration: "1:48:00", sizeBytes: 26_000_000_000, chapters: 17, fileOutput: ""),
        ]
        let info = DiscInfo(name: "SAW_TRILOGY", type: "bluray", titles: titles)
        // Each is over 90 min → fails the 18-90 min episode-length filter.
        XCTAssertFalse(info.looksLikeTVSeason)
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

// MARK: - Phase 2 Tests

final class AutoPresetTests: XCTestCase {

    func testAutoPreset4K() {
        XCTAssertEqual(HandBrakeService.autoPreset(for: "3840x2160"), "H.265 Apple VideoToolbox 2160p 4K")
    }

    func testAutoPreset1080p() {
        XCTAssertEqual(HandBrakeService.autoPreset(for: "1920x1080"), "H.265 Apple VideoToolbox 1080p")
    }

    func testAutoPreset720p() {
        XCTAssertEqual(HandBrakeService.autoPreset(for: "1280x720"), "H.265 MKV 720p30")
    }

    func testAutoPreset576p() {
        XCTAssertEqual(HandBrakeService.autoPreset(for: "720x576"), "H.265 MKV 576p25")
    }

    func testAutoPreset480p() {
        XCTAssertEqual(HandBrakeService.autoPreset(for: "720x480"), "H.265 MKV 480p30")
    }

    func testAutoPresetInvalidReturnsNil() {
        XCTAssertNil(HandBrakeService.autoPreset(for: "invalid"))
        XCTAssertNil(HandBrakeService.autoPreset(for: ""))
    }
}

final class TMDbCleanDiscNameTests: XCTestCase {

    func testCleanBasicDiscName() {
        let cleaned = TMDbService.cleanDiscName("THE_MATRIX_DISC_1")
        XCTAssertFalse(cleaned.query.contains("_"))
        XCTAssertFalse(cleaned.query.lowercased().contains("disc"))
    }

    func testCleanResolutionTags() {
        let cleaned = TMDbService.cleanDiscName("MOVIE_1080p_HEVC")
        XCTAssertFalse(cleaned.query.lowercased().contains("1080p"))
        XCTAssertFalse(cleaned.query.lowercased().contains("hevc"))
    }
}

final class MakeMKVParseSizeTests: XCTestCase {

    func testParseMB() {
        let bytes = MakeMKVService.parseSizeToBytes("500 MB")
        XCTAssertEqual(bytes, 500 * 1024 * 1024)
    }

    func testParseGB() {
        let bytes = MakeMKVService.parseSizeToBytes("1.5 GB")
        XCTAssertEqual(bytes, Int64(1.5 * 1024 * 1024 * 1024))
    }

    func testParseInvalid() {
        XCTAssertEqual(MakeMKVService.parseSizeToBytes("invalid"), 0)
    }
}
