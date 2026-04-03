import XCTest
@testable import AutoRipper

// MARK: - AppConfig Tests

final class AppConfigTests: XCTestCase {

    func testDefaultValues() {
        let config = AppConfig()
        XCTAssertFalse(config.outputDir.isEmpty)
        XCTAssertEqual(config.minDuration, 120)
        XCTAssertTrue(config.autoEject)
        XCTAssertEqual(config.defaultPreset, "HQ 1080p30 Surround")
        XCTAssertEqual(config.defaultMediaType, "movie")
        XCTAssertFalse(config.nasUploadEnabled)
        XCTAssertTrue(config.tmdbApiKey.isEmpty)
        XCTAssertTrue(config.discordWebhook.isEmpty)
        XCTAssertTrue(config.nasMoviesPath.isEmpty)
        XCTAssertTrue(config.nasTvPath.isEmpty)
    }

    func testUserDefaultsPersistence() {
        let config = AppConfig()
        config.minDuration = 999
        // Should be written to UserDefaults immediately
        let stored = UserDefaults(suiteName: "com.autoripper.app")!.integer(forKey: "minDuration")
        XCTAssertEqual(stored, 999)
        // Restore
        config.minDuration = 120
    }

    func testPropertyDidSetWritesToDefaults() {
        let config = AppConfig()
        config.outputDir = "/test/path"
        XCTAssertEqual(UserDefaults(suiteName: "com.autoripper.app")!.string(forKey: "outputDir"), "/test/path")
        // Restore
        config.outputDir = NSHomeDirectory() + "/Desktop/Ripped"
    }
}

// MARK: - DiscInfo Extended Tests

final class DiscInfoExtendedTests: XCTestCase {

    func testTitleInfoDurationVariousFormats() {
        // H:MM:SS
        let t1 = TitleInfo(id: 0, name: "T", duration: "2:05:30", sizeBytes: 0, chapters: 1, fileOutput: "")
        XCTAssertEqual(t1.durationSeconds, 7530)

        // MM:SS
        let t2 = TitleInfo(id: 1, name: "T", duration: "15:30", sizeBytes: 0, chapters: 1, fileOutput: "")
        XCTAssertEqual(t2.durationSeconds, 930)

        // Just seconds
        let t3 = TitleInfo(id: 2, name: "T", duration: "45", sizeBytes: 0, chapters: 1, fileOutput: "")
        XCTAssertEqual(t3.durationSeconds, 45)

        // Zero
        let t4 = TitleInfo(id: 3, name: "T", duration: "0:00:00", sizeBytes: 0, chapters: 1, fileOutput: "")
        XCTAssertEqual(t4.durationSeconds, 0)

        // Invalid
        let t5 = TitleInfo(id: 4, name: "T", duration: "invalid", sizeBytes: 0, chapters: 1, fileOutput: "")
        XCTAssertEqual(t5.durationSeconds, 0)
    }

    func testTitleInfoResolutionLabels() {
        func label(for res: String) -> String {
            var t = TitleInfo(id: 0, name: "T", duration: "0:10:00", sizeBytes: 0, chapters: 1, fileOutput: "")
            t.resolution = res
            return t.resolutionLabel
        }

        XCTAssertEqual(label(for: "3840x2160"), "4K")
        XCTAssertEqual(label(for: "1920x1080"), "1080p")
        XCTAssertEqual(label(for: "1280x720"), "720p")
        XCTAssertEqual(label(for: "720x576"), "576p")
        XCTAssertEqual(label(for: "720x480"), "480p")
        XCTAssertEqual(label(for: "640x360"), "480p")
        XCTAssertEqual(label(for: ""), "")
        XCTAssertEqual(label(for: "invalid"), "")
    }

    func testTitleInfoHumanSizeVariousValues() {
        let kb = TitleInfo(id: 0, name: "T", duration: "0:01:00", sizeBytes: 1024, chapters: 1, fileOutput: "")
        XCTAssertFalse(kb.humanSize.isEmpty)

        let mb = TitleInfo(id: 1, name: "T", duration: "0:10:00", sizeBytes: 50 * 1024 * 1024, chapters: 1, fileOutput: "")
        XCTAssertTrue(mb.humanSize.contains("MB") || mb.humanSize.contains("50"))

        let gb = TitleInfo(id: 2, name: "T", duration: "1:30:00", sizeBytes: 25 * 1024 * 1024 * 1024, chapters: 1, fileOutput: "")
        XCTAssertTrue(gb.humanSize.contains("GB") || gb.humanSize.contains("25"))

        let zero = TitleInfo(id: 3, name: "T", duration: "0:00:00", sizeBytes: 0, chapters: 1, fileOutput: "")
        XCTAssertFalse(zero.humanSize.isEmpty)
    }

    func testDiscInfoDefaults() {
        let info = DiscInfo(name: "Test", type: "bluray")
        XCTAssertEqual(info.name, "Test")
        XCTAssertEqual(info.type, "bluray")
        XCTAssertTrue(info.titles.isEmpty)
    }
}

// MARK: - MediaResult & EpisodeInfo Tests

final class MediaResultExtendedTests: XCTestCase {

    func testDisplayTitleVariants() {
        let movie = MediaResult(title: "Inception", year: 2010, mediaType: "movie", tmdbId: 27205)
        XCTAssertEqual(movie.displayTitle, "Inception (2010)")

        let noYear = MediaResult(title: "Unknown", year: nil, mediaType: "movie", tmdbId: 0)
        XCTAssertEqual(noYear.displayTitle, "Unknown")

        let tv = MediaResult(title: "Breaking Bad", year: 2008, mediaType: "tv", tmdbId: 1396)
        XCTAssertEqual(tv.displayTitle, "Breaking Bad (2008)")
    }

    func testMediaResultCodable() throws {
        let original = MediaResult(
            title: "The Matrix", year: 1999, mediaType: "movie",
            tmdbId: 603, overview: "A hacker discovers reality",
            posterPath: "/poster.jpg", backdropPath: "/backdrop.jpg"
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MediaResult.self, from: data)

        XCTAssertEqual(decoded.title, "The Matrix")
        XCTAssertEqual(decoded.year, 1999)
        XCTAssertEqual(decoded.mediaType, "movie")
        XCTAssertEqual(decoded.tmdbId, 603)
        XCTAssertEqual(decoded.overview, "A hacker discovers reality")
        XCTAssertEqual(decoded.posterPath, "/poster.jpg")
        XCTAssertEqual(decoded.backdropPath, "/backdrop.jpg")
    }

    func testEpisodeInfoCodable() throws {
        let original = EpisodeInfo(seasonNumber: 3, episodeNumber: 5, name: "Pilot")

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(EpisodeInfo.self, from: data)

        XCTAssertEqual(decoded.seasonNumber, 3)
        XCTAssertEqual(decoded.episodeNumber, 5)
        XCTAssertEqual(decoded.name, "Pilot")
    }
}

// MARK: - AudioTrack & SubtitleTrack Tests

final class TrackModelTests: XCTestCase {

    func testAudioTrackIdentifiable() {
        let track = AudioTrack(index: 1, language: "English", codec: "AAC", description: "English (AAC)")
        XCTAssertEqual(track.id, 1)
        XCTAssertEqual(track.language, "English")
        XCTAssertEqual(track.codec, "AAC")
    }

    func testSubtitleTrackIdentifiable() {
        let track = SubtitleTrack(index: 2, language: "Spanish", type: "SRT")
        XCTAssertEqual(track.id, 2)
        XCTAssertEqual(track.language, "Spanish")
        XCTAssertEqual(track.type, "SRT")
    }
}
