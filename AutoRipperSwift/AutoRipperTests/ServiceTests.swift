import XCTest
@testable import AutoRipper

// MARK: - HandBrakeService Tests

final class HandBrakeServiceTests: XCTestCase {

    func testMatchExtractsGroups() {
        let result = HandBrakeService.match("Encoding: 45.2% done", pattern: #"(\d+\.\d+)\s*%"#)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?[1], "45.2")
    }

    func testMatchReturnsNilOnNoMatch() {
        let result = HandBrakeService.match("no match here", pattern: #"\d+%"#)
        XCTAssertNil(result)
    }

    func testMatchExtractsETA() {
        let line = "Encoding: task 1 of 1, 65.23 % 91.45 fps, avg 88.12 fps, ETA 00h12m34s"
        let eta = HandBrakeService.match(line, pattern: #"ETA\s+(\S+)"#)
        XCTAssertNotNil(eta)
        XCTAssertEqual(eta?[1], "00h12m34s")
    }

    func testMatchExtractsFps() {
        let line = "Encoding: 65.23 % (91.45 fps, avg 88.12 fps, ETA 00h12m34s)"
        let fps = HandBrakeService.match(line, pattern: #"(\d+\.\d+)\s*fps"#)
        XCTAssertNotNil(fps)
        XCTAssertEqual(fps?[1], "91.45")
    }

    func testAutoPresetAllResolutions() {
        XCTAssertEqual(HandBrakeService.autoPreset(for: "3840x2160"), "H.265 Apple VideoToolbox 2160p 4K")
        XCTAssertEqual(HandBrakeService.autoPreset(for: "1920x1080"), "H.265 Apple VideoToolbox 1080p")
        XCTAssertEqual(HandBrakeService.autoPreset(for: "1280x720"), "H.265 MKV 720p30")
        XCTAssertEqual(HandBrakeService.autoPreset(for: "720x576"), "H.265 MKV 576p25")
        XCTAssertEqual(HandBrakeService.autoPreset(for: "720x480"), "H.265 MKV 480p30")
        XCTAssertEqual(HandBrakeService.autoPreset(for: "640x360"), "H.265 MKV 480p30")
    }

    func testAutoPresetEdgeCases() {
        XCTAssertNil(HandBrakeService.autoPreset(for: ""))
        XCTAssertNil(HandBrakeService.autoPreset(for: "invalid"))
        XCTAssertNil(HandBrakeService.autoPreset(for: "1920"))
        XCTAssertNil(HandBrakeService.autoPreset(for: "x1080"))
    }

    func testHandBrakeErrorDescriptions() {
        let notFound = HandBrakeError.notFound("missing")
        XCTAssertEqual(notFound.localizedDescription, "missing")
        let failed = HandBrakeError.encodeFailed("bad exit")
        XCTAssertEqual(failed.localizedDescription, "bad exit")
    }
}

// MARK: - MakeMKVService Tests

final class MakeMKVServiceTests: XCTestCase {

    func testParseSizeBytes() {
        XCTAssertEqual(MakeMKVService.parseSizeToBytes("500 MB"), 500 * 1024 * 1024)
        XCTAssertEqual(MakeMKVService.parseSizeToBytes("1.5 GB"), Int64(1.5 * 1024 * 1024 * 1024))
        XCTAssertEqual(MakeMKVService.parseSizeToBytes("2 TB"), 2 * 1024 * 1024 * 1024 * 1024)
        XCTAssertEqual(MakeMKVService.parseSizeToBytes("100 KB"), 100 * 1024)
    }

    func testParseSizeInvalidReturnsZero() {
        XCTAssertEqual(MakeMKVService.parseSizeToBytes(""), 0)
        XCTAssertEqual(MakeMKVService.parseSizeToBytes("invalid"), 0)
        XCTAssertEqual(MakeMKVService.parseSizeToBytes("500"), 0)
        XCTAssertEqual(MakeMKVService.parseSizeToBytes("MB"), 0)
    }

    func testMatchRegex() {
        let result = MakeMKVService.match("PRGV:100,200,1000", pattern: #"PRGV:(\d+),(\d+),(\d+)"#)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?[1], "100")
        XCTAssertEqual(result?[2], "200")
        XCTAssertEqual(result?[3], "1000")
    }

    func testMatchCINFO() {
        let line = #"CINFO:2,0,"THE_MATRIX""#
        let result = MakeMKVService.match(line, pattern: #"CINFO:(\d+),\d+,"(.+)""#)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?[1], "2")
        XCTAssertEqual(result?[2], "THE_MATRIX")
    }

    func testMatchTINFO() {
        let line = #"TINFO:0,9,0,"1:52:30""#
        let result = MakeMKVService.match(line, pattern: #"TINFO:(\d+),(\d+),\d+,"(.+)""#)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?[1], "0")
        XCTAssertEqual(result?[2], "9")
        XCTAssertEqual(result?[3], "1:52:30")
    }

    func testMatchSINFO() {
        let line = #"SINFO:0,0,19,0,"1920x1080""#
        let result = MakeMKVService.match(line, pattern: #"SINFO:(\d+),\d+,(\d+),\d+,"(.+)""#)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?[1], "0")
        XCTAssertEqual(result?[2], "19")
        XCTAssertEqual(result?[3], "1920x1080")
    }

    func testMatchCaseInsensitive() {
        let result = MakeMKVService.match("1.5 gb", pattern: #"([\d.]+)\s*(GB|MB|KB|TB)"#, options: .caseInsensitive)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?[1], "1.5")
        XCTAssertEqual(result?[2], "gb")
    }

    func testMakeMKVErrorDescriptions() {
        XCTAssertEqual(MakeMKVError.noDisc.localizedDescription, "No disc found in the drive")
        XCTAssertEqual(MakeMKVError.notFound("path").localizedDescription, "path")
        XCTAssertEqual(MakeMKVError.ripFailed("fail").localizedDescription, "fail")
        XCTAssertEqual(MakeMKVError.generalError("oops").localizedDescription, "oops")
    }

    func testOutputHas5010ErrorDetectsExactMessage() {
        let lines = [
            "MSG:1005,0,1,\"MakeMKV v1.17.7 darwin started\"",
            "MSG:5010,0,0,\"Failed to open disc\",\"Failed to open disc\"",
            "MSG:5021,0,0,\"Scan finished\""
        ]
        XCTAssertTrue(MakeMKVService.outputHas5010Error(lines))
    }

    func testOutputHas5010ErrorAbsent() {
        let lines = [
            "MSG:1005,0,1,\"MakeMKV started\"",
            "TINFO:0,2,0,\"Title 1\"",
            "MSG:5021,0,0,\"Scan finished\""
        ]
        XCTAssertFalse(MakeMKVService.outputHas5010Error(lines))
    }

    func testOutputHas5010ErrorEmptyInput() {
        XCTAssertFalse(MakeMKVService.outputHas5010Error([]))
    }

    func testOutputHas5010DoesNotMatchSubstring() {
        // Make sure we only match the prefix, not unrelated lines that mention "5010".
        let lines = ["MSG:1005,0,1,\"Disc copy progress: 5010 sectors read\""]
        XCTAssertFalse(MakeMKVService.outputHas5010Error(lines))
    }
}

// MARK: - OrganizerService Extended Tests

final class OrganizerServiceExtendedTests: XCTestCase {

    func testCleanFilenameEmpty() {
        XCTAssertEqual(OrganizerService.cleanFilename(""), "Untitled")
    }

    func testCleanFilenameSpecialChars() {
        XCTAssertEqual(OrganizerService.cleanFilename("A*B?C<D>E"), "ABCDE")
    }

    func testCleanFilenamePreservesNormalChars() {
        XCTAssertEqual(OrganizerService.cleanFilename("Hello World 2024"), "Hello World 2024")
    }

    func testBuildMoviePathStructure() {
        let path = OrganizerService.buildMoviePath(outputDir: "/movies", title: "Inception", year: 2010)
        XCTAssertTrue(path.path.contains("Inception (2010)/Inception (2010).mkv"))
    }

    func testBuildTvPathStructure() {
        let path = OrganizerService.buildTvPath(
            outputDir: "/tv", show: "The Office", season: 3, episode: 12, episodeName: "Traveling Salesmen"
        )
        XCTAssertTrue(path.path.contains("The Office/Season 03/"))
        XCTAssertEqual(path.lastPathComponent, "The Office - S03E12 - Traveling Salesmen.mkv")
    }

    func testBuildTvPathNoEpisodeName() {
        let path = OrganizerService.buildTvPath(
            outputDir: "/tv", show: "Lost", season: 1, episode: 1
        )
        XCTAssertEqual(path.lastPathComponent, "Lost - S01E01.mkv")
    }

    func testOrganizeFileCreatesDirectories() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = tmp.appendingPathComponent("source.mkv")
        let dest = tmp.appendingPathComponent("deep/nested/dir/movie.mkv")

        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: source.path, contents: Data("test".utf8))

        let result = try OrganizerService.organizeFile(source: source, destination: dest)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.path))
        XCTAssertEqual(result.lastPathComponent, "movie.mkv")

        try? FileManager.default.removeItem(at: tmp)
    }

    func testOrganizeFileAvoidsDuplicates() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let dest = tmp.appendingPathComponent("output/movie.mkv")

        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Create first file at destination
        FileManager.default.createFile(atPath: dest.path, contents: Data("existing".utf8))

        // Create source
        let source = tmp.appendingPathComponent("source.mkv")
        FileManager.default.createFile(atPath: source.path, contents: Data("new".utf8))

        let result = try OrganizerService.organizeFile(source: source, destination: dest)
        XCTAssertNotEqual(result.path, dest.path)
        XCTAssertTrue(result.lastPathComponent.contains("_1"))

        try? FileManager.default.removeItem(at: tmp)
    }
}

// MARK: - ArtworkService Tests

final class ArtworkServiceTests: XCTestCase {

    func testCreateNFOMovie() {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let media = MediaResult(title: "The Matrix", year: 1999, mediaType: "movie", tmdbId: 603, overview: "A hacker discovers reality is a simulation.")

        let artwork = ArtworkService()
        let nfoPath = artwork.createNFO(media: media, destDir: tmp)

        XCTAssertEqual(nfoPath.lastPathComponent, "movie.nfo")
        let content = try! String(contentsOf: nfoPath)
        XCTAssertTrue(content.contains("<movie>"))
        XCTAssertTrue(content.contains("<title>The Matrix</title>"))
        XCTAssertTrue(content.contains("<year>1999</year>"))
        XCTAssertTrue(content.contains("<tmdbid>603</tmdbid>"))
        XCTAssertTrue(content.contains("</movie>"))

        try? FileManager.default.removeItem(at: tmp)
    }

    func testCreateNFOTVShow() {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let media = MediaResult(title: "Breaking Bad", year: 2008, mediaType: "tv", tmdbId: 1396, overview: "A teacher turns to crime.")

        let artwork = ArtworkService()
        let nfoPath = artwork.createNFO(media: media, destDir: tmp)

        XCTAssertEqual(nfoPath.lastPathComponent, "tvshow.nfo")
        let content = try! String(contentsOf: nfoPath)
        XCTAssertTrue(content.contains("<tvshow>"))
        XCTAssertTrue(content.contains("<title>Breaking Bad</title>"))
        XCTAssertTrue(content.contains("</tvshow>"))

        try? FileManager.default.removeItem(at: tmp)
    }

    func testCreateEpisodeNFO() {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let media = MediaResult(title: "Breaking Bad", year: 2008, mediaType: "tv", tmdbId: 1396, overview: "A teacher turns to crime.")

        let artwork = ArtworkService()
        let nfoPath = artwork.createEpisodeNFO(
            media: media, season: 1, episode: 1, episodeName: "Pilot", destDir: tmp
        )

        let content = try! String(contentsOf: nfoPath)
        XCTAssertTrue(content.contains("<episodedetails>"))
        XCTAssertTrue(content.contains("<title>Pilot</title>"))
        XCTAssertTrue(content.contains("<showtitle>Breaking Bad</showtitle>"))
        XCTAssertTrue(content.contains("<season>1</season>"))
        XCTAssertTrue(content.contains("<episode>1</episode>"))
        XCTAssertTrue(content.contains("</episodedetails>"))

        try? FileManager.default.removeItem(at: tmp)
    }

    func testCreateNFOEscapesXML() {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let media = MediaResult(title: "Tom & Jerry", year: 2021, mediaType: "movie", tmdbId: 587807, overview: "Cat <chases> mouse & \"more\"")

        let artwork = ArtworkService()
        let nfoPath = artwork.createNFO(media: media, destDir: tmp)

        let content = try! String(contentsOf: nfoPath)
        XCTAssertTrue(content.contains("Tom &amp; Jerry"))
        XCTAssertTrue(content.contains("&lt;chases&gt;"))
        XCTAssertTrue(content.contains("&amp;"))
        XCTAssertTrue(content.contains("&quot;more&quot;"))

        try? FileManager.default.removeItem(at: tmp)
    }
}

// MARK: - ProcessTracker Tests

final class ProcessTrackerTests: XCTestCase {

    func testRegisterAndUnregister() {
        let tracker = ProcessTracker()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try! proc.run()
        proc.waitUntilExit()

        tracker.register(proc)
        tracker.unregister(proc)
        // No crash = success; unregistering a completed process is fine
    }

    func testTerminateAllKillsRunning() {
        let tracker = ProcessTracker()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sleep")
        proc.arguments = ["60"]
        try! proc.run()

        tracker.register(proc)
        XCTAssertTrue(proc.isRunning)

        tracker.terminateAll()
        proc.waitUntilExit()
        XCTAssertFalse(proc.isRunning)
    }
}

// MARK: - TMDb CleanDiscName Extended Tests

final class TMDbCleanDiscNameExtendedTests: XCTestCase {

    func testRemovesUnderscores() {
        let cleaned = TMDbService.cleanDiscName("THE_MATRIX_RELOADED")
        XCTAssertFalse(cleaned.query.contains("_"))
        XCTAssertTrue(cleaned.query.lowercased().contains("matrix"))
    }

    func testRemovesDiscNumbers() {
        let cleaned = TMDbService.cleanDiscName("INCEPTION_DISC_2")
        XCTAssertFalse(cleaned.query.lowercased().contains("disc"))
    }

    func testRemovesResolutionTags() {
        let cleaned = TMDbService.cleanDiscName("MOVIE_1080p_HEVC_HDR")
        XCTAssertFalse(cleaned.query.lowercased().contains("1080p"))
        XCTAssertFalse(cleaned.query.lowercased().contains("hevc"))
        XCTAssertFalse(cleaned.query.lowercased().contains("hdr"))
    }

    func testRemovesBDTag() {
        let cleaned = TMDbService.cleanDiscName("MOVIE_BD")
        XCTAssertFalse(cleaned.query.lowercased().contains(" bd"))
    }

    func testTitleCasesResult() {
        let cleaned = TMDbService.cleanDiscName("the dark knight")
        XCTAssertEqual(cleaned.query, "The Dark Knight")
    }

    func testEmptyInput() {
        let cleaned = TMDbService.cleanDiscName("")
        XCTAssertEqual(cleaned.query, "")
    }

    func testExtractsYear() {
        let cleaned = TMDbService.cleanDiscName("THE_DARK_KNIGHT_2008")
        XCTAssertEqual(cleaned.year, 2008)
        XCTAssertTrue(cleaned.query.lowercased().contains("dark knight"))
    }

    func testStripsParentheticalVersionTags() {
        let cleaned = TMDbService.cleanDiscName("DIRTY_GRANDPA_(UNRATED)")
        XCTAssertFalse(cleaned.query.lowercased().contains("unrated"))
        XCTAssertTrue(cleaned.query.lowercased().contains("dirty grandpa"))
    }
}

// MARK: - GenericWebhookService payload tests

final class GenericWebhookPayloadTests: XCTestCase {

    func testCompletePayloadIncludesCoreFields() {
        var job = Job(discName: "Blade Runner", rippedFile: URL(fileURLWithPath: "/tmp/br.mkv"),
                      ripElapsed: 60, resolution: "1920x1080", mediaResult: nil, intent: .movie)
        job.status = .done
        job.encodeElapsed = 120
        job.finishedAt = Date()

        let p = GenericWebhookService.payload(event: "job.completed", job: job)
        XCTAssertEqual(p["event"] as? String, "job.completed")
        XCTAssertEqual(p["discName"] as? String, "Blade Runner")
        XCTAssertEqual(p["status"] as? String, "done")
        XCTAssertEqual(p["intent"] as? String, "movie")
        XCTAssertEqual(p["ripElapsed"] as? Double, 60)
        XCTAssertEqual(p["encodeElapsed"] as? Double, 120)
        XCTAssertEqual(p["resolution"] as? String, "1920x1080")
        XCTAssertNotNil(p["finishedAt"])
    }

    func testFailedPayloadIncludesErrorAndOmitsAbsentMedia() {
        var job = Job(discName: "Bad Disc", rippedFile: URL(fileURLWithPath: "/tmp/x.mkv"))
        job.status = .failed
        job.error = "HandBrakeCLI exited with code 4"

        let p = GenericWebhookService.payload(event: "job.failed", job: job)
        XCTAssertEqual(p["event"] as? String, "job.failed")
        XCTAssertEqual(p["status"] as? String, "failed")
        XCTAssertEqual(p["error"] as? String, "HandBrakeCLI exited with code 4")
        // No mediaResult set, so these keys must be absent.
        XCTAssertNil(p["title"])
        XCTAssertNil(p["year"])
        XCTAssertNil(p["mediaType"])
    }

    func testEpisodePayloadIncludesSeasonEpisodeFields() {
        var job = Job(discName: "Show", rippedFile: URL(fileURLWithPath: "/tmp/s.mkv"),
                      intent: .episode, seasonNumber: 2, episodeNumber: 5, episodeTitle: "The Pilot")
        job.status = .done

        let p = GenericWebhookService.payload(event: "job.completed", job: job)
        XCTAssertEqual(p["intent"] as? String, "episode")
        XCTAssertEqual(p["season"] as? Int, 2)
        XCTAssertEqual(p["episode"] as? Int, 5)
        XCTAssertEqual(p["episodeTitle"] as? String, "The Pilot")
    }

    func testPayloadEncodesAsValidJSON() throws {
        let job = Job(discName: "X", rippedFile: URL(fileURLWithPath: "/tmp/x.mkv"))
        let p = GenericWebhookService.payload(event: "job.completed", job: job)
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: p, options: [.sortedKeys]))
    }
}
