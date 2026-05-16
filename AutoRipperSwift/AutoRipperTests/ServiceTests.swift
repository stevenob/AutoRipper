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
        // v3.8.2: 720p / 576p / 480p / 360p all now route through Apple
        // VideoToolbox H.265 1080p (which means "up to 1080p" — HandBrake
        // does not upscale). 5-10x faster than the stock x265 presets on
        // Apple Silicon.
        XCTAssertEqual(HandBrakeService.autoPreset(for: "1280x720"), "H.265 Apple VideoToolbox 1080p")
        XCTAssertEqual(HandBrakeService.autoPreset(for: "720x576"), "H.265 Apple VideoToolbox 1080p")
        XCTAssertEqual(HandBrakeService.autoPreset(for: "720x480"), "H.265 Apple VideoToolbox 1080p")
        XCTAssertEqual(HandBrakeService.autoPreset(for: "640x360"), "H.265 Apple VideoToolbox 1080p")
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

    // MARK: - Encode warning detection (v3.11.14)

    func testIsEncodeWarningMatchesStructuredErrorTag() {
        XCTAssertTrue(HandBrakeService.isEncodeWarning("[hb-error]: codec init failed"))
        XCTAssertTrue(HandBrakeService.isEncodeWarning(" [hb-error] something"))
    }

    func testIsEncodeWarningMatchesERRORAndWARNINGPrefixes() {
        XCTAssertTrue(HandBrakeService.isEncodeWarning("ERROR: VideoToolbox unavailable"))
        XCTAssertTrue(HandBrakeService.isEncodeWarning("Error: bad input"))
        XCTAssertTrue(HandBrakeService.isEncodeWarning("WARNING: falling back to software encoder"))
        XCTAssertTrue(HandBrakeService.isEncodeWarning("Warning: subtitle track 3 ignored"))
    }

    func testIsEncodeWarningMatchesUnstructuredFailedPatterns() {
        XCTAssertTrue(HandBrakeService.isEncodeWarning("failed to allocate buffer"))
        XCTAssertTrue(HandBrakeService.isEncodeWarning("Could not initialize VideoToolbox"))
        XCTAssertTrue(HandBrakeService.isEncodeWarning("FAILED TO read input"))  // case-insensitive
    }

    func testIsEncodeWarningDoesNotMatchProgressOrInfo() {
        XCTAssertFalse(HandBrakeService.isEncodeWarning("Encoding: task 1 of 1, 45.2 %"))
        XCTAssertFalse(HandBrakeService.isEncodeWarning("hb_stream_open: ok"))
        XCTAssertFalse(HandBrakeService.isEncodeWarning("HandBrake 1.11.1 (2026032200)"))
        XCTAssertFalse(HandBrakeService.isEncodeWarning(""))
        // Word "error" inside an otherwise informational line shouldn't fire.
        XCTAssertFalse(HandBrakeService.isEncodeWarning("scan: no error reports for title 1"))
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

// MARK: - StagingService Tests

final class StagingServiceTests: XCTestCase {

    private var tmpRoot: URL!

    override func setUp() {
        super.setUp()
        tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("staging-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpRoot)
        super.tearDown()
    }

    private func writeFile(at url: URL, sizeBytes: Int) throws {
        var data = Data(count: sizeBytes)
        // Make non-zero so size verification differentiates from a freshly-
        // created empty file on the dest side.
        for i in 0..<min(sizeBytes, 1024) { data[i] = UInt8(i & 0xFF) }
        try data.write(to: url)
    }

    func testCheckReachableSucceedsForWritableDir() async throws {
        let service = StagingService()
        try await service.checkReachable(path: tmpRoot.path)
    }

    func testCheckReachableFailsForMissingDir() async {
        let service = StagingService()
        do {
            try await service.checkReachable(path: tmpRoot.appendingPathComponent("nope").path)
            XCTFail("expected destinationUnreachable")
        } catch let err as StagingError {
            if case .destinationUnreachable = err { return }
            XCTFail("wrong error: \(err)")
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testCheckReachableFailsForFilePath() async throws {
        let file = tmpRoot.appendingPathComponent("not-a-dir")
        try writeFile(at: file, sizeBytes: 4)
        let service = StagingService()
        do {
            try await service.checkReachable(path: file.path)
            XCTFail("expected destinationUnreachable for non-directory")
        } catch let err as StagingError {
            if case .destinationUnreachable = err { return }
            XCTFail("wrong error: \(err)")
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testCopyAndVerifyHappyPath() async throws {
        let source = tmpRoot.appendingPathComponent("src.mkv")
        let dest = tmpRoot.appendingPathComponent("staged/disc/title.mkv")
        // 17 MB — exercises chunk boundary (8 MB chunks).
        try writeFile(at: source, sizeBytes: 17 * 1024 * 1024)
        let originalSize = try FileManager.default
            .attributesOfItem(atPath: source.path)[.size] as? Int64

        let service = StagingService()
        let result = try await service.copyAndVerify(from: source, to: dest)

        XCTAssertEqual(result, dest)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path),
                       "source should be deleted after successful copy")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path + ".partial"),
                       "partial file should be cleaned up")
        let destSize = try FileManager.default
            .attributesOfItem(atPath: dest.path)[.size] as? Int64
        XCTAssertEqual(destSize, originalSize)
    }

    func testCopyAndVerifyReportsProgress() async throws {
        let source = tmpRoot.appendingPathComponent("src.bin")
        let dest = tmpRoot.appendingPathComponent("dst/file.bin")
        try writeFile(at: source, sizeBytes: 17 * 1024 * 1024)

        // Use an actor-isolated counter — closure runs off-main from the
        // service actor, so a plain mutable Int wouldn't be safe.
        actor Counter {
            var count = 0
            var lastTotal: Int64 = 0
            var lastCopied: Int64 = 0
            func tick(_ copied: Int64, _ total: Int64) {
                count += 1
                lastCopied = copied
                lastTotal = total
            }
        }
        let counter = Counter()
        let service = StagingService()
        _ = try await service.copyAndVerify(from: source, to: dest, progress: { copied, total in
            // Bridge the sync callback back into the actor.
            Task { await counter.tick(copied, total) }
        })

        // Allow the trailing detached tasks to run.
        try await Task.sleep(nanoseconds: 50_000_000)

        let calls = await counter.count
        let lastCopied = await counter.lastCopied
        let lastTotal = await counter.lastTotal
        XCTAssertGreaterThan(calls, 0, "progress should fire at least once")
        XCTAssertEqual(lastCopied, lastTotal,
                       "final progress tick should report bytesCopied == total")
    }

    func testCopyAndVerifyFailsOnMissingSource() async throws {
        let source = tmpRoot.appendingPathComponent("missing.bin")
        let dest = tmpRoot.appendingPathComponent("dst/file.bin")

        let service = StagingService()
        do {
            _ = try await service.copyAndVerify(from: source, to: dest)
            XCTFail("expected sourceMissing")
        } catch let err as StagingError {
            if case .sourceMissing = err { return }
            XCTFail("wrong error: \(err)")
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testCopyAndVerifyReplacesExistingDestSafely() async throws {
        let source = tmpRoot.appendingPathComponent("new.bin")
        let dest = tmpRoot.appendingPathComponent("dest/file.bin")
        // Pre-existing destination with different content.
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try writeFile(at: dest, sizeBytes: 1024)
        try writeFile(at: source, sizeBytes: 9 * 1024 * 1024)

        let service = StagingService()
        _ = try await service.copyAndVerify(from: source, to: dest)

        // New file replaced old file; sizes match the new source.
        let destSize = try FileManager.default
            .attributesOfItem(atPath: dest.path)[.size] as? Int64
        XCTAssertEqual(destSize, 9 * 1024 * 1024)
    }

    func testCopyAndVerifyCleansUpStaleDotPartial() async throws {
        let source = tmpRoot.appendingPathComponent("src.bin")
        let dest = tmpRoot.appendingPathComponent("d/file.bin")
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        // Stale partial from a previous failed run — must not block the new copy.
        let stalePartial = dest.appendingPathExtension("partial")
        try writeFile(at: stalePartial, sizeBytes: 999)
        try writeFile(at: source, sizeBytes: 5 * 1024 * 1024)

        let service = StagingService()
        _ = try await service.copyAndVerify(from: source, to: dest)

        XCTAssertFalse(FileManager.default.fileExists(atPath: stalePartial.path))
        let destSize = try FileManager.default
            .attributesOfItem(atPath: dest.path)[.size] as? Int64
        XCTAssertEqual(destSize, 5 * 1024 * 1024)
    }
}

// MARK: - InFlightRip Tests

final class InFlightRipTests: XCTestCase {

    func testEncodesAndDecodes() throws {
        let original = InFlightRip(
            phase: .ripping,
            titleId: 3,
            ripFile: "/tmp/scratch/Movie/title_t03.mkv",
            stagingDest: nil
        )
        let data = try JSONEncoder().encode(original)
        let round = try JSONDecoder().decode(InFlightRip.self, from: data)
        XCTAssertEqual(round, original)
    }

    func testStagingPhaseCarriesDestination() throws {
        let staging = InFlightRip(
            phase: .staging,
            titleId: 0,
            ripFile: "/tmp/scratch/Movie/title.mkv",
            stagingDest: "/Volumes/NAS/Downloaded/Movie/title.mkv"
        )
        let data = try JSONEncoder().encode(staging)
        let round = try JSONDecoder().decode(InFlightRip.self, from: data)
        XCTAssertEqual(round.phase, .staging)
        XCTAssertEqual(round.stagingDest, "/Volumes/NAS/Downloaded/Movie/title.mkv")
    }
}

// MARK: - StagingService directory copy tests

final class StagingDirectoryTests: XCTestCase {

    private var tmpRoot: URL!

    override func setUp() {
        super.setUp()
        tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("staging-dir-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpRoot)
        super.tearDown()
    }

    private func writeFile(at url: URL, sizeBytes: Int) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data(count: sizeBytes)
        for i in 0..<min(sizeBytes, 256) { data[i] = UInt8(i & 0xFF) }
        try data.write(to: url)
    }

    func testCopyDirectoryHappyPath() async throws {
        let source = tmpRoot.appendingPathComponent("source")
        let dest   = tmpRoot.appendingPathComponent("dest")

        // Mirror what AutoRipper would lay down: an MKV plus an NFO + poster.
        try writeFile(at: source.appendingPathComponent("Movie (Year).mkv"), sizeBytes: 5 * 1024 * 1024)
        try writeFile(at: source.appendingPathComponent("Movie (Year).nfo"), sizeBytes: 4096)
        try writeFile(at: source.appendingPathComponent("poster.jpg"),       sizeBytes: 80_000)

        let service = StagingService()
        let result = try await service.copyDirectoryAndVerify(from: source, to: dest)

        XCTAssertEqual(result, dest)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("Movie (Year).mkv").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("Movie (Year).nfo").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("poster.jpg").path))
        // Source dir is consumed during copy.
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        // No partial scaffold left behind.
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path + ".partial"))
    }

    func testCopyDirectoryPreservesNestedStructure() async throws {
        let source = tmpRoot.appendingPathComponent("show")
        let dest   = tmpRoot.appendingPathComponent("staged-show")

        try writeFile(at: source.appendingPathComponent("Season 01/Show - S01E01.mkv"), sizeBytes: 1024 * 1024)
        try writeFile(at: source.appendingPathComponent("Season 01/Show - S01E02.mkv"), sizeBytes: 1024 * 1024)
        try writeFile(at: source.appendingPathComponent("Season 02/Show - S02E01.mkv"), sizeBytes: 1024 * 1024)

        let service = StagingService()
        _ = try await service.copyDirectoryAndVerify(from: source, to: dest)

        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: dest.appendingPathComponent("Season 01/Show - S01E01.mkv").path))
        XCTAssertTrue(fm.fileExists(atPath: dest.appendingPathComponent("Season 01/Show - S01E02.mkv").path))
        XCTAssertTrue(fm.fileExists(atPath: dest.appendingPathComponent("Season 02/Show - S02E01.mkv").path))
    }

    func testCopyDirectoryReplacesExistingDestination() async throws {
        let source = tmpRoot.appendingPathComponent("new")
        let dest   = tmpRoot.appendingPathComponent("dest")

        // Old destination with a stale file the new copy doesn't have — must be
        // replaced, not merged into.
        try writeFile(at: dest.appendingPathComponent("stale.txt"), sizeBytes: 32)
        try writeFile(at: source.appendingPathComponent("new.mkv"), sizeBytes: 4 * 1024 * 1024)

        let service = StagingService()
        _ = try await service.copyDirectoryAndVerify(from: source, to: dest)

        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: dest.appendingPathComponent("new.mkv").path))
        XCTAssertFalse(fm.fileExists(atPath: dest.appendingPathComponent("stale.txt").path),
                       "stale destination contents should be replaced, not merged")
    }

    func testCopyDirectoryReportsProgressBytes() async throws {
        let source = tmpRoot.appendingPathComponent("src")
        let dest   = tmpRoot.appendingPathComponent("dst")
        try writeFile(at: source.appendingPathComponent("a.bin"), sizeBytes: 6 * 1024 * 1024)
        try writeFile(at: source.appendingPathComponent("b.bin"), sizeBytes: 4 * 1024 * 1024)
        let expectedTotal: Int64 = 10 * 1024 * 1024

        actor Counter {
            var lastCopied: Int64 = 0
            var lastTotal: Int64 = 0
            var sawIncreasing = true
            var prev: Int64 = 0
            func tick(_ copied: Int64, _ total: Int64) {
                if copied < prev { sawIncreasing = false }
                prev = copied
                lastCopied = copied
                lastTotal = total
            }
        }
        let counter = Counter()
        let service = StagingService()
        _ = try await service.copyDirectoryAndVerify(from: source, to: dest, progress: { copied, total in
            Task { await counter.tick(copied, total) }
        })

        try await Task.sleep(nanoseconds: 50_000_000)
        let lastCopied = await counter.lastCopied
        let lastTotal = await counter.lastTotal
        let monotone = await counter.sawIncreasing
        XCTAssertEqual(lastTotal, expectedTotal)
        XCTAssertEqual(lastCopied, expectedTotal,
                       "final progress must equal total bytes")
        XCTAssertTrue(monotone, "progress must be monotonically non-decreasing")
    }

    func testCopyDirectoryFailsForMissingSource() async throws {
        let source = tmpRoot.appendingPathComponent("ghost")
        let dest   = tmpRoot.appendingPathComponent("dst")
        let service = StagingService()
        do {
            _ = try await service.copyDirectoryAndVerify(from: source, to: dest)
            XCTFail("expected sourceMissing")
        } catch let err as StagingError {
            if case .sourceMissing = err { return }
            XCTFail("wrong error: \(err)")
        }
    }
}

// MARK: - PublishService Tests

final class PublishServiceTests: XCTestCase {

    private var tmpRoot: URL!

    override func setUp() {
        super.setUp()
        tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("publish-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpRoot)
        super.tearDown()
    }

    private func writeFile(at url: URL, sizeBytes: Int) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        var data = Data(count: sizeBytes)
        for i in 0..<min(sizeBytes, 256) { data[i] = UInt8(i & 0xFF) }
        try data.write(to: url)
    }

    func testPublishMoviePreservesEditionSiblings() async throws {
        // Library already has a Theatrical edition + a poster; publish a
        // Director's Cut. Expect both editions + the poster to coexist.
        let library = tmpRoot.appendingPathComponent("Movies")
        let movieFolder = library.appendingPathComponent("Blade Runner (1982)")
        try writeFile(at: movieFolder.appendingPathComponent("Blade Runner (1982).mkv"), sizeBytes: 1024)
        try writeFile(at: movieFolder.appendingPathComponent("poster.jpg"), sizeBytes: 64)

        let scratchFolder = tmpRoot.appendingPathComponent("scratch/Blade Runner (1982)")
        try writeFile(
            at: scratchFolder.appendingPathComponent("Blade Runner (1982) {edition-Director's Cut}.mkv"),
            sizeBytes: 2048
        )

        let svc = PublishService()
        _ = try await svc.publish(localDir: scratchFolder, libraryRoot: library)

        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: movieFolder.appendingPathComponent("Blade Runner (1982).mkv").path),
                      "Theatrical edition must survive publish of Director's Cut")
        XCTAssertTrue(fm.fileExists(atPath: movieFolder.appendingPathComponent("poster.jpg").path),
                      "Poster must survive")
        XCTAssertTrue(fm.fileExists(atPath: movieFolder.appendingPathComponent("Blade Runner (1982) {edition-Director's Cut}.mkv").path),
                      "New edition must be present")
    }

    func testPublishTVPreservesOtherEpisodes() async throws {
        // Library has Show/Season 01/E01.mkv + E02.mkv. Publish E03.mkv.
        // Expect all three present.
        let library = tmpRoot.appendingPathComponent("TV")
        let showFolder = library.appendingPathComponent("Some Show")
        try writeFile(at: showFolder.appendingPathComponent("Season 01/Some Show - S01E01.mkv"), sizeBytes: 1024)
        try writeFile(at: showFolder.appendingPathComponent("Season 01/Some Show - S01E02.mkv"), sizeBytes: 1024)

        let scratchShow = tmpRoot.appendingPathComponent("scratch/Some Show")
        try writeFile(at: scratchShow.appendingPathComponent("Season 01/Some Show - S01E03.mkv"), sizeBytes: 2048)

        let svc = PublishService()
        _ = try await svc.publish(localDir: scratchShow, libraryRoot: library)

        let fm = FileManager.default
        for ep in ["S01E01", "S01E02", "S01E03"] {
            XCTAssertTrue(
                fm.fileExists(atPath: showFolder.appendingPathComponent("Season 01/Some Show - \(ep).mkv").path),
                "\(ep) must be present after publish"
            )
        }
    }

    func testPublishReplacesSameNameFile() async throws {
        // Re-publishing the same edition name overwrites the prior copy.
        let library = tmpRoot.appendingPathComponent("Movies")
        let movieFolder = library.appendingPathComponent("Some Movie (2020)")
        try writeFile(at: movieFolder.appendingPathComponent("Some Movie (2020).mkv"), sizeBytes: 100)

        let scratchFolder = tmpRoot.appendingPathComponent("scratch/Some Movie (2020)")
        try writeFile(at: scratchFolder.appendingPathComponent("Some Movie (2020).mkv"), sizeBytes: 555)

        let svc = PublishService()
        _ = try await svc.publish(localDir: scratchFolder, libraryRoot: library)

        let attrs = try FileManager.default
            .attributesOfItem(atPath: movieFolder.appendingPathComponent("Some Movie (2020).mkv").path)
        XCTAssertEqual(attrs[.size] as? Int64, 555,
                       "same-named file at dest must be overwritten")
    }

    func testPublishProgressMonotonic() async throws {
        let scratchFolder = tmpRoot.appendingPathComponent("scratch/Big Movie")
        try writeFile(at: scratchFolder.appendingPathComponent("Big Movie.mkv"), sizeBytes: 4 * 1024 * 1024)
        try writeFile(at: scratchFolder.appendingPathComponent("Big Movie.nfo"), sizeBytes: 1024)
        let library = tmpRoot.appendingPathComponent("Library")

        actor Counter {
            var prev: Int64 = 0
            var monotonic = true
            func tick(_ copied: Int64) {
                if copied < prev { monotonic = false }
                prev = copied
            }
        }
        let counter = Counter()
        let svc = PublishService()
        _ = try await svc.publish(localDir: scratchFolder, libraryRoot: library, progress: { copied, _ in
            Task { await counter.tick(copied) }
        })
        try await Task.sleep(nanoseconds: 50_000_000)
        let mono = await counter.monotonic
        XCTAssertTrue(mono, "publish progress must be monotonically non-decreasing")
    }

    // MARK: - destFolderName override (v3.11.8)
    //
    // The override lets the local scratch folder carry a per-job-unique
    // suffix while the NAS folder stays clean. Critical for both the
    // movie case (one-level rename) and the TV case (two-level subpath).

    func testPublishUsesExplicitDestFolderNameForMovie() async throws {
        // Local dir has a job-unique suffix; NAS should land at the clean
        // name passed via destFolderName.
        let library = tmpRoot.appendingPathComponent("Movies")
        let scratchFolder = tmpRoot.appendingPathComponent("scratch/job-abc123def456/Mortal Kombat (1995)")
        try writeFile(at: scratchFolder.appendingPathComponent("Mortal Kombat (1995).mkv"), sizeBytes: 1024)

        let svc = PublishService()
        let published = try await svc.publish(
            localDir: scratchFolder,
            libraryRoot: library,
            destFolderName: "Mortal Kombat (1995)"
        )

        XCTAssertEqual(published.lastPathComponent, "Mortal Kombat (1995)",
                       "NAS folder should use the clean override, not the suffixed scratch name")
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: library.appendingPathComponent("Mortal Kombat (1995)/Mortal Kombat (1995).mkv").path))
    }

    func testPublishUsesTwoLevelDestFolderNameForTV() async throws {
        // TV layout: scratch is .../job-XXX/Show/Season 01/episode.mkv,
        // and publish should land it under <libraryRoot>/Show/Season 01/.
        // destFolderName carries the "Show/Season 01" subpath.
        let library = tmpRoot.appendingPathComponent("TV")
        let scratchSeasonDir = tmpRoot.appendingPathComponent("scratch/job-xyz789abc/Breaking Bad/Season 01")
        try writeFile(at: scratchSeasonDir.appendingPathComponent("Breaking Bad - S01E01.mkv"), sizeBytes: 512)

        let svc = PublishService()
        let published = try await svc.publish(
            localDir: scratchSeasonDir,
            libraryRoot: library,
            destFolderName: "Breaking Bad/Season 01"
        )

        // Final NAS path: <library>/Breaking Bad/Season 01/...
        let fm = FileManager.default
        let expectedEpisode = library.appendingPathComponent("Breaking Bad/Season 01/Breaking Bad - S01E01.mkv")
        XCTAssertTrue(fm.fileExists(atPath: expectedEpisode.path),
                      "TV episode should land at <library>/Show/Season XX/...")
        XCTAssertEqual(published.lastPathComponent, "Season 01")
    }

    func testPublishLegacyBehaviorWhenDestFolderNameNil() async throws {
        // Back-compat: when destFolderName is nil, the legacy behavior of
        // using localDir.lastPathComponent is preserved.
        let library = tmpRoot.appendingPathComponent("Movies")
        let scratchFolder = tmpRoot.appendingPathComponent("scratch/Spawn (1997)")
        try writeFile(at: scratchFolder.appendingPathComponent("Spawn (1997).mkv"), sizeBytes: 256)

        let svc = PublishService()
        let published = try await svc.publish(localDir: scratchFolder, libraryRoot: library)

        XCTAssertEqual(published.lastPathComponent, "Spawn (1997)",
                       "nil destFolderName should fall back to localDir.lastPathComponent")
    }
}

// MARK: - ScratchReservationService tests

final class ScratchReservationServiceTests: XCTestCase {

    func testReserveAndRelease() async {
        let svc = ScratchReservationService()
        await svc.reserve(jobId: "a", bytes: 100)
        await svc.reserve(jobId: "b", bytes: 200)
        var total = await svc.totalReserved
        XCTAssertEqual(total, 300)
        await svc.release(jobId: "a")
        total = await svc.totalReserved
        XCTAssertEqual(total, 200)
    }

    func testReplacingReservationOverwrites() async {
        let svc = ScratchReservationService()
        await svc.reserve(jobId: "a", bytes: 100)
        await svc.reserve(jobId: "a", bytes: 999)
        let total = await svc.totalReserved
        XCTAssertEqual(total, 999, "subsequent reserve(jobId:) replaces, not adds")
    }

    func testCanReserveAccountsForOtherClaims() async {
        // canReserve at /tmp considers our existing reservations + safety margin.
        // Use a tiny additionalBytes to avoid flaky outcomes on real free space.
        let svc = ScratchReservationService()
        // Pretend something else has already taken a huge chunk.
        await svc.reserve(jobId: "occupier", bytes: Int64.max - 10)
        let result = await svc.canReserve(atPath: "/tmp", additionalBytes: 1_000_000_000, safetyMargin: 0)
        XCTAssertFalse(result.ok, "should refuse when prior reservations consume all space")
        await svc._testReset()
    }
}

// MARK: - URL.sameVolume tests

final class URLSameVolumeTests: XCTestCase {

    func testSamePathIsSameVolume() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
        XCTAssertTrue(url.sameVolume(as: url))
    }

    func testTwoTempDirsAreSameVolume() throws {
        let a = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("a-\(UUID().uuidString)")
        let b = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("b-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }
        XCTAssertTrue(a.sameVolume(as: b))
    }

    func testNonexistentPathFailsSafe() {
        let nope1 = URL(fileURLWithPath: "/nonexistent/path/a")
        let nope2 = URL(fileURLWithPath: "/another/missing/b")
        // Either both unreadable -> false (the safe default) or both happen
        // to resolve to the same root volume -> true. Whatever the result,
        // the API must not crash.
        _ = nope1.sameVolume(as: nope2)
    }
}

// MARK: - Job model new fields tests

final class JobV360FieldsTests: XCTestCase {

    func testNewFieldsRoundTripThroughCodable() throws {
        var job = Job(discName: "Foo", rippedFile: URL(fileURLWithPath: "/tmp/foo.mkv"))
        job.workDir = URL(fileURLWithPath: "/tmp/scratch/Foo")
        job.publishedFile = URL(fileURLWithPath: "/Volumes/NAS/Movies/Foo/Foo.mkv")
        job.publishPhase = .swapping

        let data = try JSONEncoder().encode(job)
        let decoded = try JSONDecoder().decode(Job.self, from: data)
        XCTAssertEqual(decoded.workDir, job.workDir)
        XCTAssertEqual(decoded.publishedFile, job.publishedFile)
        XCTAssertEqual(decoded.publishPhase, .swapping)
    }

    func testDefaultsAreNilNotStarted() {
        let job = Job(discName: "Bar", rippedFile: URL(fileURLWithPath: "/tmp/bar.mkv"))
        XCTAssertNil(job.workDir)
        XCTAssertNil(job.publishedFile)
        XCTAssertEqual(job.publishPhase, .notStarted)
    }
}

// MARK: - Long-IO regression guard

/// Source-level lint: no synchronous, blocking `FileManager` operations
/// (.copyItem, .moveItem on potentially-large folders, .removeItem on
/// potentially-large folders) in @MainActor view models. They must always
/// be wrapped in an actor (StagingService, PublishService) or detached
/// Task so the UI never freezes during long disk/network IO.
///
/// This caught the v3.4.6 -> v3.5.0 lockup (FileManager.copyItem on the
/// 6 GB NAS upload step). Lives as a test so the same class of regression
/// can't sneak back in.
final class LongIORegressionTests: XCTestCase {

    /// Path to the source files we want to lint. Resolved via #file so the
    /// test works regardless of where xctest is invoked from.
    private var viewModelsDir: URL {
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent()        // .../AutoRipperTests
            .deletingLastPathComponent()        // .../AutoRipperSwift
            .appendingPathComponent("AutoRipper")
            .appendingPathComponent("ViewModels")
    }

    /// Lines we DON'T want to see in @MainActor view models. Each is matched
    /// as a substring on lines that aren't comments or whitespace-only.
    private static let bannedPatterns: [String] = [
        "FileManager.default.copyItem",   // big folder copies must run via StagingService/PublishService
        "fm.copyItem",
    ]

    func testViewModelsHaveNoSyncBigCopyCalls() throws {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: viewModelsDir, includingPropertiesForKeys: nil) else {
            // If the directory layout has changed the test should fail loudly
            // rather than silently pass.
            XCTFail("ViewModels directory not found at \(viewModelsDir.path)")
            return
        }

        var violations: [String] = []
        for url in entries where url.pathExtension == "swift" {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let lines = content.components(separatedBy: .newlines)
            for (i, raw) in lines.enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                // Skip comment lines & blank lines
                if line.hasPrefix("//") || line.hasPrefix("///") || line.isEmpty { continue }
                for pattern in Self.bannedPatterns where line.contains(pattern) {
                    violations.append("\(url.lastPathComponent):\(i + 1)  \(pattern) — \(line)")
                }
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            "Synchronous big-IO call on @MainActor view model. Wrap in StagingService/PublishService "
            + "or a detached Task so the UI does not freeze during long copies. Violations:\n  "
            + violations.joined(separator: "\n  ")
        )
    }
}

// MARK: - LibraryNotifierService tests
//
// Uses a custom URLProtocol that intercepts HTTP requests so we can assert
// the right URL/headers without ever hitting a network. The mock holds the
// last request observed in a thread-safe class-level static; we drain it
// before each test.

private final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var responseStatus: Int = 200
    nonisolated(unsafe) static var responseError: Error?

    static func reset() {
        lastRequest = nil
        responseStatus = 200
        responseError = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = self.request
        if let err = Self.responseError {
            client?.urlProtocol(self, didFailWithError: err)
            return
        }
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://x")!,
            statusCode: Self.responseStatus,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class LibraryNotifierServiceTests: XCTestCase {

    private func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    private func makeConfig(
        plexUrl: String = "",
        plexToken: String = "",
        plexMovies: String = "",
        plexTv: String = "",
        jellyfinUrl: String = "",
        jellyfinKey: String = ""
    ) -> AppConfig {
        let c = AppConfig()
        c.plexUrl = plexUrl
        c.plexToken = plexToken
        c.plexMoviesSectionId = plexMovies
        c.plexTvSectionId = plexTv
        c.jellyfinUrl = jellyfinUrl
        c.jellyfinApiKey = jellyfinKey
        return c
    }

    override func tearDown() {
        // Reset all v3.7 plex/jellyfin keys back to empty so test pollution
        // does not leak into the next case (AppConfig is a singleton).
        let c = AppConfig.shared
        c.plexUrl = ""
        c.plexToken = ""
        c.plexMoviesSectionId = ""
        c.plexTvSectionId = ""
        c.jellyfinUrl = ""
        c.jellyfinApiKey = ""
        MockURLProtocol.reset()
        super.tearDown()
    }

    func testPlexRefreshSkippedWhenUnconfigured() async {
        MockURLProtocol.reset()
        let svc = LibraryNotifierService(config: makeConfig(), session: makeSession())
        let result = await svc.refreshPlex(isTV: false)
        if case .skipped = result { return }
        XCTFail("expected skipped, got \(result)")
    }

    func testPlexRefreshHitsCorrectMoviesEndpoint() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.responseStatus = 200
        let cfg = makeConfig(
            plexUrl: "http://192.168.1.10:32400",
            plexToken: "abc123",
            plexMovies: "5",
            plexTv: "9"
        )
        let svc = LibraryNotifierService(config: cfg, session: makeSession())
        let result = await svc.refreshPlex(isTV: false)
        if case .success(let server) = result { XCTAssertEqual(server, "Plex") }
        else { XCTFail("expected .success, got \(result)") }

        let req = MockURLProtocol.lastRequest
        XCTAssertNotNil(req)
        XCTAssertEqual(req?.httpMethod, "POST")
        let url = req?.url?.absoluteString ?? ""
        XCTAssertTrue(url.contains("/library/sections/5/refresh"),
                      "expected movies section endpoint, got \(url)")
        XCTAssertTrue(url.contains("X-Plex-Token=abc123"),
                      "expected token in query, got \(url)")
    }

    func testPlexRefreshUsesTVSectionWhenIsTVTrue() async {
        MockURLProtocol.reset()
        MockURLProtocol.responseStatus = 200
        let cfg = makeConfig(
            plexUrl: "http://plex.local:32400",
            plexToken: "tt",
            plexMovies: "1",
            plexTv: "2"
        )
        let svc = LibraryNotifierService(config: cfg, session: makeSession())
        _ = await svc.refreshPlex(isTV: true)
        let url = MockURLProtocol.lastRequest?.url?.absoluteString ?? ""
        XCTAssertTrue(url.contains("/library/sections/2/refresh"),
                      "expected TV section, got \(url)")
    }

    func testPlexRefreshFailsOnNon2xx() async {
        MockURLProtocol.reset()
        MockURLProtocol.responseStatus = 401
        let cfg = makeConfig(plexUrl: "http://x", plexToken: "t", plexMovies: "1")
        let svc = LibraryNotifierService(config: cfg, session: makeSession())
        let result = await svc.refreshPlex(isTV: false)
        if case .failure(_, let err) = result {
            XCTAssertTrue(err.contains("401"), "got \(err)")
        } else {
            XCTFail("expected .failure, got \(result)")
        }
    }

    func testJellyfinRefreshSkippedWhenUnconfigured() async {
        MockURLProtocol.reset()
        let svc = LibraryNotifierService(config: makeConfig(), session: makeSession())
        let result = await svc.refreshJellyfin()
        if case .skipped = result { return }
        XCTFail("expected skipped, got \(result)")
    }

    func testJellyfinRefreshHitsCorrectEndpointWithApiKeyHeader() async {
        MockURLProtocol.reset()
        MockURLProtocol.responseStatus = 204  // Jellyfin returns 204 No Content
        let cfg = makeConfig(
            jellyfinUrl: "http://jelly.local:8096",
            jellyfinKey: "k3y"
        )
        let svc = LibraryNotifierService(config: cfg, session: makeSession())
        let result = await svc.refreshJellyfin()
        if case .success(let server) = result {
            XCTAssertEqual(server, "Jellyfin")
        } else {
            XCTFail("expected .success, got \(result)")
        }
        let req = MockURLProtocol.lastRequest
        XCTAssertEqual(req?.httpMethod, "POST")
        XCTAssertEqual(req?.url?.absoluteString, "http://jelly.local:8096/Library/Refresh")
        XCTAssertEqual(req?.value(forHTTPHeaderField: "X-Emby-Token"), "k3y")
    }

    func testNotifyAfterPublishSkipsBothWhenNothingConfigured() async {
        MockURLProtocol.reset()
        let svc = LibraryNotifierService(config: makeConfig(), session: makeSession())
        let results = await svc.notifyAfterPublish(isTV: false)
        XCTAssertEqual(results.count, 2)
        for r in results {
            if case .skipped = r {} else {
                XCTFail("expected all skipped, got \(r)")
            }
        }
    }

    func testTrailingSlashInBaseUrlIsTolerated() async {
        MockURLProtocol.reset()
        MockURLProtocol.responseStatus = 200
        let cfg = makeConfig(
            plexUrl: "http://plex.local:32400/",   // trailing slash
            plexToken: "x",
            plexMovies: "1"
        )
        let svc = LibraryNotifierService(config: cfg, session: makeSession())
        _ = await svc.refreshPlex(isTV: false)
        let url = MockURLProtocol.lastRequest?.url?.absoluteString ?? ""
        XCTAssertFalse(url.contains("//library"), "must not double-slash, got \(url)")
        XCTAssertTrue(url.contains("/library/sections/1/refresh"))
    }
}

// MARK: - DiscFingerprintService tests

final class DiscFingerprintServiceTests: XCTestCase {

    private func makeInfo(name: String = "TEST_DISC",
                         type: String = "dvd",
                         titles: [(id: Int, duration: String, size: Int64)]) -> DiscInfo {
        let mapped = titles.map { t in
            TitleInfo(id: t.id, name: "Title \(t.id)", duration: t.duration,
                      sizeBytes: t.size, chapters: 1, fileOutput: "")
        }
        return DiscInfo(name: name, type: type, titles: mapped)
    }

    func testFingerprintIsStable() {
        let info1 = makeInfo(titles: [(0, "1:30:00", 5_000_000_000), (1, "0:10:00", 800_000_000)])
        let info2 = makeInfo(titles: [(0, "1:30:00", 5_000_000_000), (1, "0:10:00", 800_000_000)])
        XCTAssertEqual(DiscFingerprintService.fingerprint(info1),
                       DiscFingerprintService.fingerprint(info2))
    }

    func testFingerprintIgnoresTitleOrder() {
        let a = makeInfo(titles: [(0, "1:30:00", 5_000_000_000), (1, "0:10:00", 800_000_000)])
        let b = makeInfo(titles: [(1, "0:10:00", 800_000_000), (0, "1:30:00", 5_000_000_000)])
        XCTAssertEqual(DiscFingerprintService.fingerprint(a),
                       DiscFingerprintService.fingerprint(b))
    }

    func testFingerprintDiffersForDifferentDiscs() {
        let a = makeInfo(name: "DISC_A", titles: [(0, "1:30:00", 5_000_000_000)])
        let b = makeInfo(name: "DISC_B", titles: [(0, "1:30:00", 5_000_000_000)])
        XCTAssertNotEqual(DiscFingerprintService.fingerprint(a),
                          DiscFingerprintService.fingerprint(b))
    }

    func testFingerprintDiffersForDifferentDuration() {
        let a = makeInfo(titles: [(0, "1:30:00", 5_000_000_000)])
        let b = makeInfo(titles: [(0, "1:31:00", 5_000_000_000)])
        XCTAssertNotEqual(DiscFingerprintService.fingerprint(a),
                          DiscFingerprintService.fingerprint(b))
    }

    func testFingerprintIs64HexChars() {
        let info = makeInfo(titles: [(0, "1:30:00", 5_000_000_000)])
        let fp = DiscFingerprintService.fingerprint(info)
        XCTAssertEqual(fp.count, 64, "SHA256 hex should be 64 chars")
        XCTAssertNotNil(fp.range(of: "^[0-9a-f]{64}$", options: .regularExpression))
    }
}

// MARK: - RippedDiscRegistry tests

final class RippedDiscRegistryTests: XCTestCase {

    private var tmpStoreURL: URL!

    override func setUp() {
        super.setUp()
        tmpStoreURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ripped-test-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpStoreURL)
        super.tearDown()
    }

    func testRecordAndLookup() async {
        let registry = RippedDiscRegistry(storeURL: tmpStoreURL)
        let entry = RippedDiscEntry(date: Date(),
                                    discName: "Foo",
                                    publishedPath: "/Volumes/NAS/Movies/Foo/Foo.mkv")
        await registry.record(fingerprint: "abc", entry: entry)
        let got = await registry.entry(forFingerprint: "abc")
        XCTAssertEqual(got, entry)
    }

    func testLookupMissReturnsNil() async {
        let registry = RippedDiscRegistry(storeURL: tmpStoreURL)
        let got = await registry.entry(forFingerprint: "nope")
        XCTAssertNil(got)
    }

    func testRecordPersistsAcrossReinit() async {
        let r1 = RippedDiscRegistry(storeURL: tmpStoreURL)
        let entry = RippedDiscEntry(date: Date(timeIntervalSince1970: 100),
                                    discName: "Bar",
                                    publishedPath: "/path")
        await r1.record(fingerprint: "xyz", entry: entry)

        let r2 = RippedDiscRegistry(storeURL: tmpStoreURL)
        let got = await r2.entry(forFingerprint: "xyz")
        XCTAssertEqual(got, entry, "entry must survive new instance reading from disk")
    }

    func testIdempotentRecord() async {
        let registry = RippedDiscRegistry(storeURL: tmpStoreURL)
        let entry = RippedDiscEntry(date: Date(timeIntervalSince1970: 200),
                                    discName: "Same",
                                    publishedPath: "/")
        await registry.record(fingerprint: "k", entry: entry)
        let firstMtime = (try? FileManager.default
            .attributesOfItem(atPath: tmpStoreURL.path)[.modificationDate]) as? Date
        XCTAssertNotNil(firstMtime)
        try? await Task.sleep(nanoseconds: 20_000_000)
        await registry.record(fingerprint: "k", entry: entry)  // no-op
        let secondMtime = (try? FileManager.default
            .attributesOfItem(atPath: tmpStoreURL.path)[.modificationDate]) as? Date
        XCTAssertEqual(firstMtime, secondMtime,
                       "redundant record must not rewrite the file")
    }

    func testForgetRemovesEntry() async {
        let registry = RippedDiscRegistry(storeURL: tmpStoreURL)
        await registry.record(fingerprint: "a", entry: RippedDiscEntry(date: Date(), discName: "x", publishedPath: ""))
        await registry.forget(fingerprint: "a")
        let got = await registry.entry(forFingerprint: "a")
        XCTAssertNil(got)
    }

    func testClearRemovesAll() async {
        let registry = RippedDiscRegistry(storeURL: tmpStoreURL)
        await registry.record(fingerprint: "a", entry: RippedDiscEntry(date: Date(), discName: "x", publishedPath: ""))
        await registry.record(fingerprint: "b", entry: RippedDiscEntry(date: Date(), discName: "y", publishedPath: ""))
        await registry.clear()
        let all = await registry.all()
        XCTAssertTrue(all.isEmpty)
    }

    func testAllReturnsMostRecentFirst() async {
        let registry = RippedDiscRegistry(storeURL: tmpStoreURL)
        let older = RippedDiscEntry(date: Date(timeIntervalSince1970: 100), discName: "old", publishedPath: "")
        let newer = RippedDiscEntry(date: Date(timeIntervalSince1970: 200), discName: "new", publishedPath: "")
        await registry.record(fingerprint: "old", entry: older)
        await registry.record(fingerprint: "new", entry: newer)
        let all = await registry.all()
        XCTAssertEqual(all.first?.fingerprint, "new")
        XCTAssertEqual(all.last?.fingerprint, "old")
    }
}

// MARK: - RipStartupPhase parser tests (v3.7.2)

@MainActor
final class RipStartupPhaseTests: XCTestCase {

    func testParserStartsAtStartingProcessAndProgressesViaMSG() {
        var phase: RipStartupPhase = .startingProcess
        RipViewModel.advanceStartupPhase(&phase, fromLine: "MSG:1011,0,1,\"Using LibreDrive mode (v06.3 id=…)\",\"…\"")
        XCTAssertEqual(phase, .openingDrive)
        RipViewModel.advanceStartupPhase(&phase, fromLine: "MSG:2010,0,1,\"Optical drive opened in OS access mode\",\"…\"")
        XCTAssertEqual(phase, .openingDrive)
        RipViewModel.advanceStartupPhase(&phase, fromLine: "DRV:0,2,999,12,\"BD-RE HL-DT-ST BD-RE\"")
        XCTAssertEqual(phase, .readingDiscStructure)
        RipViewModel.advanceStartupPhase(&phase, fromLine: "TINFO:0,9,0,\"1:30:00\"")
        XCTAssertEqual(phase, .readingDiscStructure)
        RipViewModel.advanceStartupPhase(&phase, fromLine: "MSG:5014,131072,2,\"Saving 1 titles into directory ...\",\"…\"")
        if case .preparingTitle = phase {} else { XCTFail("expected .preparingTitle, got \(phase)") }
    }

    func testParserNeverMovesBackOnceRipping() {
        var phase: RipStartupPhase = .ripping
        RipViewModel.advanceStartupPhase(&phase, fromLine: "MSG:1011,0,1,\"Using LibreDrive mode\",\"…\"")
        XCTAssertEqual(phase, .ripping, "should stay .ripping once reached")
        RipViewModel.advanceStartupPhase(&phase, fromLine: "DRV:0,...")
        XCTAssertEqual(phase, .ripping)
    }

    func testCaptionExtractorPullsHumanMessage() {
        let line = "MSG:5014,131072,2,\"Saving 1 titles into directory file:///Volumes/X/Foo\",\"format\""
        let cap = RipViewModel.extractInformationalCaption(line)
        XCTAssertEqual(cap, "Saving 1 titles into directory file:///Volumes/X/Foo")
    }

    func testCaptionExtractorSkipsStructuralLines() {
        XCTAssertNil(RipViewModel.extractInformationalCaption("DRV:0,2,999"))
        XCTAssertNil(RipViewModel.extractInformationalCaption("CINFO:1,0,\"…\""))
        XCTAssertNil(RipViewModel.extractInformationalCaption("TINFO:1,9,0,\"1:30:00\""))
        XCTAssertNil(RipViewModel.extractInformationalCaption("SINFO:1,0,1,0,\"…\""))
        XCTAssertNil(RipViewModel.extractInformationalCaption("PRGV:50,100,65535"))
        XCTAssertNil(RipViewModel.extractInformationalCaption("PRGC:0,0,\"…\""))
        XCTAssertNil(RipViewModel.extractInformationalCaption("PRGT:0,0,\"…\""))
    }

    func testCaptionExtractorReturnsNilForMalformed() {
        XCTAssertNil(RipViewModel.extractInformationalCaption("not-a-msg-line"))
        XCTAssertNil(RipViewModel.extractInformationalCaption(""))
    }

    // MARK: - Read-error parser (v3.11.5)

    func testReadErrorParserCountsMSG2003() {
        XCTAssertTrue(RipViewModel.isReadErrorLine("MSG:2003,0,3,\"Error 'Posix error - Input/output error' occurred while reading '/dev/rdisk4' at offset '2083123200'\",\"…\",\"…\",\"…\",\"…\""))
        XCTAssertTrue(RipViewModel.isReadErrorLine("MSG:2003"))
    }

    func testReadErrorParserIgnoresSummaryAndUnrelatedLines() {
        // MSG:2022 is the end-of-rip aggregate ("Encountered N read errors")
        // and we deliberately don't count it to avoid double-counting.
        XCTAssertFalse(RipViewModel.isReadErrorLine("MSG:2022,0,1,\"Encountered 3 read errors\""))
        XCTAssertFalse(RipViewModel.isReadErrorLine("MSG:2010,0,1,\"Optical drive opened\""))
        XCTAssertFalse(RipViewModel.isReadErrorLine("PRGV:50,100,65535"))
        XCTAssertFalse(RipViewModel.isReadErrorLine(""))
    }

    func testReadErrorSuggestThresholdIsFive() {
        XCTAssertEqual(RipViewModel.readErrorSuggestThreshold, 5)
    }

    // MARK: - Offset parser (v3.11.12)

    func testOffsetParserExtractsValueFromRealMSG2003() {
        let line = "MSG:2003,0,3,\"Error 'Posix error - Input/output error' occurred while reading '/dev/rdisk4' at offset '2083123200'\",\"Error '%1' occurred while reading '%2' at offset '%3'\",\"Posix error - Input/output error\",\"/dev/rdisk4\",\"2083123200\""
        XCTAssertEqual(RipViewModel.extractReadErrorOffset(line), 2083123200)
    }

    func testOffsetParserReturnsNilForNonReadErrorLines() {
        XCTAssertNil(RipViewModel.extractReadErrorOffset("MSG:2002,0,3,\"corrupt\""))
        XCTAssertNil(RipViewModel.extractReadErrorOffset("PRGV:50,100,65535"))
        XCTAssertNil(RipViewModel.extractReadErrorOffset(""))
    }

    func testOffsetParserReturnsNilForMalformedMSG2003() {
        XCTAssertNil(RipViewModel.extractReadErrorOffset("MSG:2003,0,3,\"unrelated\""))
        XCTAssertNil(RipViewModel.extractReadErrorOffset("MSG:2003,0,3,\"at offset '123"))
        XCTAssertNil(RipViewModel.extractReadErrorOffset("MSG:2003,0,3,\"at offset 'XYZ'\""))
    }

    func testOffsetParserHandlesLargeValues() {
        // 32 GB offset — needs Int64
        let line = "MSG:2003,0,3,\"at offset '34359738368'\""
        XCTAssertEqual(RipViewModel.extractReadErrorOffset(line), 34_359_738_368)
    }

    func testOffsetCapIsFifty() {
        XCTAssertEqual(RipViewModel.readErrorOffsetCap, 50)
    }

    // MARK: - Data-corruption parser (v3.11.7)

    func testCorruptionParserMatchesMSG2002() {
        // Per-chunk "corrupt or invalid at offset X, attempting to work around"
        XCTAssertTrue(RipViewModel.isCorruptionLine(
            "MSG:2002,0,3,\"The source file '/BDMV/STREAM/00042.m2ts' is corrupt or invalid at offset '2096381952', attempting to work around\",\"…\""
        ))
        XCTAssertTrue(RipViewModel.isCorruptionLine("MSG:2002"))
    }

    func testCorruptionParserMatchesMSG2017AndMSG2018() {
        // 2017 = "Hash check failed for file ... at offset Y, file is corrupt"
        XCTAssertTrue(RipViewModel.isCorruptionLine(
            "MSG:2017,0,3,\"Hash check failed for file 00042.m2ts at offset 2096818176, file is corrupt\",\"…\""
        ))
        // 2018 = "Too many hash check errors in file ..."
        XCTAssertTrue(RipViewModel.isCorruptionLine(
            "MSG:2018,0,1,\"Too many hash check errors in file 00042.m2ts\",\"…\""
        ))
    }

    func testCorruptionParserDoesNotMatchUnrelatedCodes() {
        // The drive-side read-error code lives in `isReadErrorLine` and MUST
        // NOT also be picked up by the corruption parser (would double-count).
        XCTAssertFalse(RipViewModel.isCorruptionLine("MSG:2003,0,3,\"Posix error - Input/output error\",\"…\""))
        // 4009 (AV sync) is informational, intentionally excluded.
        XCTAssertFalse(RipViewModel.isCorruptionLine(
            "MSG:4009,0,2,\"Too many AV synchronization issues in file '00042.m2ts' (title #-), future messages will be printed only to log file\",\"…\""
        ))
        XCTAssertFalse(RipViewModel.isCorruptionLine("MSG:2010,0,1,\"Optical drive opened\",\"…\""))
        XCTAssertFalse(RipViewModel.isCorruptionLine("PRGV:50,100,65535"))
        XCTAssertFalse(RipViewModel.isCorruptionLine(""))
    }

    func testReadAndCorruptionParsersAreDisjoint() {
        // No single MSG line should ever satisfy BOTH parsers — if it did,
        // appendMakeMKVLog would double-count. This is a defensive invariant.
        let samples = [
            "MSG:2002,0,3,\"corrupt or invalid at offset\",\"…\"",
            "MSG:2003,0,3,\"Posix error\",\"…\"",
            "MSG:2017,0,3,\"Hash check failed\",\"…\"",
            "MSG:2018,0,1,\"Too many hash check errors\",\"…\"",
        ]
        for s in samples {
            let a = RipViewModel.isReadErrorLine(s)
            let b = RipViewModel.isCorruptionLine(s)
            XCTAssertFalse(a && b, "line counted by BOTH parsers: \(s)")
        }
    }
}

// MARK: - Scratch folder naming (v3.11.6)
//
// Per-disc-unique scratch folder names prevent the v3.11.5 wipeout where
// two queued rips that resolved to the same human-readable folder name
// shared a scratch dir, and the first job's publish cleanup deleted the
// second job's not-yet-encoded source.

@MainActor
final class ScratchFolderNameTests: XCTestCase {

    private func makeInfo(name: String, titles: [(Int, String, Int64)]) -> DiscInfo {
        let mapped = titles.map { (id, dur, sz) in
            TitleInfo(id: id, name: "Title \(id)", duration: dur,
                      sizeBytes: sz, chapters: 1, fileOutput: "")
        }
        return DiscInfo(name: name, type: "bluray", titles: mapped)
    }

    func testScratchFolderNameIncludesFingerprintSuffix() {
        let info = makeInfo(name: "MORTAL_KOMBAT", titles: [(0, "1:41:00", 16_000_000_000)])
        let folder = RipViewModel.scratchFolderName(cleanName: "Mortal Kombat (1995)", info: info)
        XCTAssertTrue(folder.hasPrefix("Mortal Kombat (1995) ["), "should keep clean name + open bracket: \(folder)")
        XCTAssertTrue(folder.hasSuffix("]"), "should end with close bracket: \(folder)")
        // 12-char hex fingerprint suffix (48 bits of entropy)
        let fp = DiscFingerprintService.fingerprint(info)
        XCTAssertEqual(folder, "Mortal Kombat (1995) [\(String(fp.prefix(12)))]")
    }

    func testTwoDifferentDiscsWithSameCleanNameProduceDifferentFolders() {
        // The exact scenario that caused the v3.11.5 data loss: two
        // physically distinct discs resolve via TMDb scrape to the same
        // human-readable folder name. With per-disc-unique scratch names
        // their scratch folders MUST diverge so cleanup of one cannot
        // touch the other's rip source.
        let disc1 = makeInfo(name: "MORTAL_KOMBAT",   titles: [(0, "1:41:00", 16_000_000_000)])
        let disc2 = makeInfo(name: "MORTAL_COMBAT_2", titles: [(0, "1:35:00", 15_700_000_000)])
        let f1 = RipViewModel.scratchFolderName(cleanName: "Mortal Kombat II (2026)", info: disc1)
        let f2 = RipViewModel.scratchFolderName(cleanName: "Mortal Kombat II (2026)", info: disc2)
        XCTAssertNotEqual(f1, f2, "different discs must NEVER share a scratch folder, even when clean names collide")
    }

    func testSameDiscReinsertedProducesSameFolder() {
        // The fingerprint is stable for the same physical disc; the scratch
        // folder name should also be stable so retry / resume paths land
        // on the existing partial rip rather than starting a parallel one.
        let infoA = makeInfo(name: "MORTAL_KOMBAT", titles: [(0, "1:41:00", 16_000_000_000)])
        let infoB = makeInfo(name: "MORTAL_KOMBAT", titles: [(0, "1:41:00", 16_000_000_000)])
        let fA = RipViewModel.scratchFolderName(cleanName: "Mortal Kombat (1995)", info: infoA)
        let fB = RipViewModel.scratchFolderName(cleanName: "Mortal Kombat (1995)", info: infoB)
        XCTAssertEqual(fA, fB)
    }
}

// MARK: - QueueViewModel cleanup safety (v3.11.6)
//
// Guards the post-publish and post-done cleanup paths against the
// sibling-wipeout class of bug. Verifies that the helper only removes
// files this job explicitly owns and only drops the parent dir if
// nothing foreign remains.

@MainActor
final class QueueCleanupSafetyTests: XCTestCase {

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoRipperCleanupTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func touch(_ url: URL, bytes: Int = 4) throws {
        try Data(repeating: 0xAB, count: bytes).write(to: url)
    }

    override func tearDown() {
        // Best-effort cleanup of anything we missed.
        let parent = FileManager.default.temporaryDirectory
        if let kids = try? FileManager.default.contentsOfDirectory(atPath: parent.path) {
            for k in kids where k.hasPrefix("AutoRipperCleanupTests-") {
                try? FileManager.default.removeItem(at: parent.appendingPathComponent(k))
            }
        }
        super.tearDown()
    }

    func testRemovesOwnedFilesAndDirWhenEmpty() throws {
        let dir = tempDir()
        let owned = dir.appendingPathComponent("rip.mkv")
        try touch(owned, bytes: 32)
        QueueViewModel.cleanupOwnedFilesAndRemoveDirIfEmpty(dir: dir, ownedFiles: [owned])
        XCTAssertFalse(FileManager.default.fileExists(atPath: owned.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path), "empty dir should be removed")
    }

    func testKeepsForeignFilesAndDirWhenForeignFilesPresent() throws {
        // THE regression test for the Mortal Kombat data loss: a sibling
        // job's rip source sits in the same dir as this job's owned file.
        // Cleanup must remove only the owned file and leave the foreign
        // file (and the dir) intact.
        let dir = tempDir()
        let owned = dir.appendingPathComponent("organized.mkv")
        let foreign = dir.appendingPathComponent("sibling-rip-still-needed.mkv")
        try touch(owned, bytes: 32)
        try touch(foreign, bytes: 64)
        QueueViewModel.cleanupOwnedFilesAndRemoveDirIfEmpty(dir: dir, ownedFiles: [owned])
        XCTAssertFalse(FileManager.default.fileExists(atPath: owned.path), "owned file should be removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path), "foreign file MUST NOT be removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path), "dir must stay because foreign file lives in it")
    }

    func testIgnoresOwnedFilesNotInsideTargetDir() throws {
        // Defense in depth: a caller hands us a file URL whose parent is
        // NOT the target dir. We must not reach across and delete it.
        let dir = tempDir()
        let outside = tempDir().appendingPathComponent("not-ours.mkv")
        try touch(outside)
        QueueViewModel.cleanupOwnedFilesAndRemoveDirIfEmpty(dir: dir, ownedFiles: [outside])
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path), "must not delete file outside target dir")
    }

    func testTreatsHiddenFilesAsNoiseAndRemovesDir() throws {
        // .DS_Store etc shouldn't keep the dir alive after the owned file
        // is gone — they're OS noise, not user data.
        let dir = tempDir()
        let owned = dir.appendingPathComponent("organized.mkv")
        let dsStore = dir.appendingPathComponent(".DS_Store")
        try touch(owned)
        try touch(dsStore)
        QueueViewModel.cleanupOwnedFilesAndRemoveDirIfEmpty(dir: dir, ownedFiles: [owned])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path), "dir should be removed even with .DS_Store left")
    }

    func testNoOpWhenDirDoesNotExist() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID())")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        // Should not crash, should not throw.
        QueueViewModel.cleanupOwnedFilesAndRemoveDirIfEmpty(dir: dir, ownedFiles: [])
    }
}

// MARK: - SafeFSCleanup tests (v3.11.8)
//
// Exercises the shared free-function helpers extracted in v3.11.8 so
// non-MainActor services can use the same ownership-aware cleanup
// semantics. The QueueViewModel-scoped shim is covered above; these
// tests target the moved-out implementation directly.

@MainActor
final class SafeFSCleanupTests: XCTestCase {

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoRipperSafeFS-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func touch(_ url: URL, bytes: Int = 4) throws {
        try Data(repeating: 0xAB, count: bytes).write(to: url)
    }

    override func tearDown() {
        let parent = FileManager.default.temporaryDirectory
        if let kids = try? FileManager.default.contentsOfDirectory(atPath: parent.path) {
            for k in kids where k.hasPrefix("AutoRipperSafeFS-") {
                try? FileManager.default.removeItem(at: parent.appendingPathComponent(k))
            }
        }
        super.tearDown()
    }

    func testRemoveDirIfEmptyRemovesEmptyDir() {
        let dir = tempDir()
        SafeFSCleanup.removeDirIfEmpty(dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    func testRemoveDirIfEmptyKeepsDirWithFiles() throws {
        let dir = tempDir()
        try touch(dir.appendingPathComponent("foo.mkv"))
        SafeFSCleanup.removeDirIfEmpty(dir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path), "dir with files must NOT be removed")
    }

    func testRemoveDirIfEmptyIgnoresHiddenFiles() throws {
        let dir = tempDir()
        try touch(dir.appendingPathComponent(".DS_Store"))
        SafeFSCleanup.removeDirIfEmpty(dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path), "dir with only hidden files should be removed")
    }

    func testRemoveDirIfEmptyNoOpForMissingDir() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID())")
        SafeFSCleanup.removeDirIfEmpty(dir)
        // No crash, no throw.
    }
}

// MARK: - MakeMKVService stale-file purge (v3.11.8)
//
// The pre-rip and post-retry cleanup paths need to remove any
// `<media-title>_tNN.mkv` files to avoid hanging on MakeMKV's
// overwrite prompt. v3.11.8 adds a soft volumeLabel ownership check
// so foreign-looking files (no token overlap with the disc label)
// are skipped instead of deleted.

@MainActor
final class MakeMKVPurgeTests: XCTestCase {

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoRipperPurgeTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func touch(_ url: URL) throws {
        try Data().write(to: url)
    }

    override func tearDown() {
        let parent = FileManager.default.temporaryDirectory
        if let kids = try? FileManager.default.contentsOfDirectory(atPath: parent.path) {
            for k in kids where k.hasPrefix("AutoRipperPurgeTests-") {
                try? FileManager.default.removeItem(at: parent.appendingPathComponent(k))
            }
        }
        super.tearDown()
    }

    func testPurgesMatchingTitleId() throws {
        let dir = tempDir()
        try touch(dir.appendingPathComponent("Mortal Kombat_t00.mkv"))
        try touch(dir.appendingPathComponent("Mortal Kombat_t01.mkv"))
        MakeMKVService.purgeStaleTitleFiles(
            outputDir: dir.path,
            titleId: 0,
            volumeLabel: "MORTAL_KOMBAT",
            log: nil
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Mortal Kombat_t00.mkv").path),
                       "t00 file should be purged")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Mortal Kombat_t01.mkv").path),
                      "t01 file (different titleId) must NOT be touched")
    }

    func testSkipsForeignFilesWhenLabelGiven() throws {
        // A foreign file in the dir (no token overlap with volumeLabel) MUST
        // NOT be purged even though the _tNN.mkv suffix matches. This is the
        // defense-in-depth guard that protects against future scenarios
        // where two discs' files end up in the same dir.
        let dir = tempDir()
        try touch(dir.appendingPathComponent("Star Wars_t00.mkv"))  // foreign
        MakeMKVService.purgeStaleTitleFiles(
            outputDir: dir.path,
            titleId: 0,
            volumeLabel: "MORTAL_KOMBAT",
            log: nil
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Star Wars_t00.mkv").path),
                      "foreign file (no token overlap) must NOT be purged")
    }

    func testFallsBackToSuffixOnlyWhenNoLabel() throws {
        // Legacy behavior: when volumeLabel is nil/empty, suffix match alone
        // governs deletion. Preserves backward compatibility for any call
        // site that doesn't have a label available.
        let dir = tempDir()
        try touch(dir.appendingPathComponent("Anything_t00.mkv"))
        MakeMKVService.purgeStaleTitleFiles(
            outputDir: dir.path,
            titleId: 0,
            volumeLabel: nil,
            log: nil
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Anything_t00.mkv").path),
                       "without a label, suffix match alone purges")
    }

    func testTokenOverlapAcceptsCleanedTitle() throws {
        // MakeMKV converts "MORTAL_KOMBAT" volume label to "Mortal Kombat"
        // as the media-title prefix. The token comparison must be tolerant
        // to underscore/space/case differences.
        let dir = tempDir()
        try touch(dir.appendingPathComponent("Mortal Kombat_t02.mkv"))
        MakeMKVService.purgeStaleTitleFiles(
            outputDir: dir.path,
            titleId: 2,
            volumeLabel: "MORTAL_KOMBAT",
            log: nil
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Mortal Kombat_t02.mkv").path))
    }
}

// MARK: - Recently-skipped cooldown tests (v3.7.2)

@MainActor
final class RecentlySkippedCooldownTests: XCTestCase {

    func testEmptyVolumeNameNeverMatches() {
        let vm = RipViewModel()
        XCTAssertFalse(vm.isRecentlySkipped(volumeName: ""))
    }

    func testFreshVolumeNameDoesNotMatch() {
        let vm = RipViewModel()
        XCTAssertFalse(vm.isRecentlySkipped(volumeName: "RANDOM_DISC"))
    }
}

// MARK: - DiscInfo autoLabel categorization tests (v3.8)

final class DiscInfoAutoLabelV380Tests: XCTestCase {

    private func makeTitle(id: Int, duration: String, sizeGB: Double) -> TitleInfo {
        TitleInfo(
            id: id, name: "Title \(id)", duration: duration,
            sizeBytes: Int64(sizeGB * 1_073_741_824), chapters: 1, fileOutput: ""
        )
    }

    func testLargestIsMainFeature() {
        var info = DiscInfo(name: "X", type: "dvd", titles: [
            makeTitle(id: 0, duration: "1:50:00", sizeGB: 6.5),
            makeTitle(id: 1, duration: "0:10:00", sizeGB: 0.8),
            makeTitle(id: 2, duration: "0:02:00", sizeGB: 0.1),
        ])
        info.autoLabel()
        XCTAssertEqual(info.titles[0].category, .mainFeature)
    }

    func testAlternateCutDetectedAtSameRuntime() {
        // Same runtime ±5% as main, smaller size, ≥60 min → .alternateCut.
        // (Smaller size makes it .alternateAudio if it's ALSO within ±0.5%.)
        var info = DiscInfo(name: "X", type: "bluray", titles: [
            makeTitle(id: 0, duration: "2:00:00", sizeGB: 32.0),
            makeTitle(id: 1, duration: "2:03:00", sizeGB: 28.0),  // alt cut (2.5% off, ≥60 min)
        ])
        info.autoLabel()
        XCTAssertEqual(info.titles[0].category, .mainFeature)
        XCTAssertEqual(info.titles[1].category, .alternateCut,
                       "near-runtime + ≥60min should be alt cut")
    }

    func testAlternateAudioDetectedAtIdenticalRuntime() {
        // Exact same runtime, much smaller — typical commentary track structure.
        var info = DiscInfo(name: "X", type: "bluray", titles: [
            makeTitle(id: 0, duration: "2:00:00", sizeGB: 30.0),
            makeTitle(id: 1, duration: "2:00:00", sizeGB: 5.0),
        ])
        info.autoLabel()
        XCTAssertEqual(info.titles[1].category, .alternateAudio)
    }

    func testFeaturetteCategory() {
        var info = DiscInfo(name: "X", type: "dvd", titles: [
            makeTitle(id: 0, duration: "1:50:00", sizeGB: 7.0),
            makeTitle(id: 1, duration: "0:45:00", sizeGB: 1.5),    // featurette (30–90 min)
        ])
        info.autoLabel()
        XCTAssertEqual(info.titles[1].category, .featurette)
    }

    func testExtraCategory() {
        var info = DiscInfo(name: "X", type: "dvd", titles: [
            makeTitle(id: 0, duration: "1:50:00", sizeGB: 7.0),
            makeTitle(id: 1, duration: "0:15:00", sizeGB: 0.4),    // extra (5–30 min)
        ])
        info.autoLabel()
        XCTAssertEqual(info.titles[1].category, .extra)
    }

    func testShortExtraAndTrailer() {
        var info = DiscInfo(name: "X", type: "dvd", titles: [
            makeTitle(id: 0, duration: "1:50:00", sizeGB: 7.0),
            makeTitle(id: 1, duration: "0:02:30", sizeGB: 0.1),    // short extra (1–5 min)
            makeTitle(id: 2, duration: "0:00:30", sizeGB: 0.01),   // trailer (<60s)
        ])
        info.autoLabel()
        XCTAssertEqual(info.titles[1].category, .shortExtra)
        XCTAssertEqual(info.titles[2].category, .trailer)
    }

    func testTVSeasonOverridesMainFeature() {
        // 3 episodes of similar runtime, plus a short trailer.
        var info = DiscInfo(name: "S01D01", type: "dvd", titles: [
            makeTitle(id: 0, duration: "0:42:00", sizeGB: 1.5),
            makeTitle(id: 1, duration: "0:43:00", sizeGB: 1.5),
            makeTitle(id: 2, duration: "0:42:30", sizeGB: 1.4),
            makeTitle(id: 3, duration: "0:01:00", sizeGB: 0.05),
        ])
        info.autoLabel()
        XCTAssertEqual(info.titles[0].category, .episode)
        XCTAssertEqual(info.titles[1].category, .episode)
        XCTAssertEqual(info.titles[2].category, .episode)
        XCTAssertNotEqual(info.titles[0].category, .mainFeature,
                          "TV-shape should not produce a main feature")
    }

    func testBonusFeatureForLong90PlusMinNonMain() {
        // A clearly-separate film on a double-feature disc. >60 min runtime
        // delta from the main is the boundary v3.10.0 uses to distinguish
        // bonus features from alternate cuts.
        var info = DiscInfo(name: "DOUBLE", type: "dvd", titles: [
            makeTitle(id: 0, duration: "3:00:00", sizeGB: 7.5),     // 180 min main
            makeTitle(id: 1, duration: "1:35:00", sizeGB: 4.0),     // 95 min — 85 min apart
        ])
        info.autoLabel()
        XCTAssertEqual(info.titles[1].category, .bonusFeature)
    }

    func testCategorySummaryFormatting() {
        var info = DiscInfo(name: "X", type: "bluray", titles: [
            makeTitle(id: 0, duration: "2:00:00", sizeGB: 30.0),
            makeTitle(id: 1, duration: "0:45:00", sizeGB: 1.5),    // featurette
            makeTitle(id: 2, duration: "0:10:00", sizeGB: 0.3),    // extra
            makeTitle(id: 3, duration: "0:00:30", sizeGB: 0.01),   // trailer
            makeTitle(id: 4, duration: "0:00:30", sizeGB: 0.01),   // trailer
        ])
        info.autoLabel()
        let summary = info.categorySummary
        XCTAssertTrue(summary.contains("1 main"), summary)
        XCTAssertTrue(summary.contains("1 featurette"), summary)
        XCTAssertTrue(summary.contains("1 extra"), summary)
        XCTAssertTrue(summary.contains("2 trailers"), summary)
    }

    func testCategorySummaryIsEmptyForEmptyDisc() {
        let info = DiscInfo(name: "X", type: "dvd", titles: [])
        XCTAssertEqual(info.categorySummary, "")
    }

    func testEmptyDiscAutoLabelDoesNotCrash() {
        var info = DiscInfo(name: "X", type: "dvd", titles: [])
        info.autoLabel()  // must not crash
        XCTAssertEqual(info.titles.count, 0)
    }

    func testLabelDisplayStringSet() {
        var info = DiscInfo(name: "X", type: "dvd", titles: [
            makeTitle(id: 0, duration: "1:50:00", sizeGB: 6.0),
        ])
        info.autoLabel()
        XCTAssertEqual(info.titles[0].label, TitleCategory.mainFeature.displayLabel)
        XCTAssertTrue(info.titles[0].label.contains("Main Feature"))
    }
}

// MARK: - HistoryStats tests (v3.8.3)

final class HistoryStatsTests: XCTestCase {

    func testFormatsCountAndTimes() {
        let s = HistoryStats(
            count: 33,
            totalPipelineSeconds: 42 * 3600 + 18 * 60,
            totalRipSeconds: 15 * 3600,
            averagePerJobSeconds: 77 * 60
        )
        let line = s.summaryLine
        XCTAssertTrue(line.contains("33 discs"), line)
        XCTAssertTrue(line.contains("42h 18m"), line)
        XCTAssertTrue(line.contains("1h 17m"), line)
        XCTAssertTrue(line.contains("avg/job"), line)
    }

    func testSingularNounForOneDisc() {
        let s = HistoryStats(count: 1, totalPipelineSeconds: 3600, totalRipSeconds: 1200,
                             averagePerJobSeconds: 3600)
        XCTAssertTrue(s.summaryLine.contains("1 disc"), s.summaryLine)
        XCTAssertFalse(s.summaryLine.contains("1 discs"), s.summaryLine)
    }

    func testHandlesSubHourValues() {
        let s = HistoryStats(count: 2, totalPipelineSeconds: 25 * 60, totalRipSeconds: 10 * 60,
                             averagePerJobSeconds: 12 * 60)
        let line = s.summaryLine
        XCTAssertTrue(line.contains("25m"), line)
        XCTAssertTrue(line.contains("12m"), line)
        // No "0h" prefix for sub-hour values
        XCTAssertFalse(line.contains("0h"), line)
    }

    func testEquatable() {
        let a = HistoryStats(count: 5, totalPipelineSeconds: 3000, totalRipSeconds: 1000, averagePerJobSeconds: 600)
        let b = HistoryStats(count: 5, totalPipelineSeconds: 3000, totalRipSeconds: 1000, averagePerJobSeconds: 600)
        XCTAssertEqual(a, b)
    }
}

// MARK: - DriveHealthAnalyzer tests (v3.11.9)
//
// Pure-function aggregator over completed jobs. Verifies that the
// threshold-based verdict tips correctly between healthy /
// someIssues / driveSuspect / insufficientData and that the per-
// counter aggregates are computed right.

final class DriveHealthAnalyzerTests: XCTestCase {

    private func makeJob(readErrors: Int = 0, corruption: Int = 0) -> Job {
        Job(discName: "test", rippedFile: URL(fileURLWithPath: "/tmp/x.mkv"),
            ripReadErrors: readErrors, ripCorruptionEvents: corruption)
    }

    func testInsufficientDataForFewerThanMinimumJobs() {
        // Single rip can't generalize — even if it had errors.
        let r1 = DriveHealthAnalyzer.analyze(jobs: [])
        XCTAssertEqual(r1.verdict, .insufficientData)
        XCTAssertEqual(r1.analyzedCount, 0)

        let r2 = DriveHealthAnalyzer.analyze(jobs: [makeJob(readErrors: 5)])
        XCTAssertEqual(r2.verdict, .insufficientData)

        let r3 = DriveHealthAnalyzer.analyze(jobs: [makeJob(), makeJob()])
        XCTAssertEqual(r3.verdict, .insufficientData)
    }

    func testHealthyWhenAllJobsClean() {
        let jobs = (0..<5).map { _ in makeJob() }
        let r = DriveHealthAnalyzer.analyze(jobs: jobs)
        XCTAssertEqual(r.verdict, .healthy)
        XCTAssertEqual(r.ripsWithAnyIssue, 0)
        XCTAssertEqual(r.anyIssuePercent, 0)
    }

    func testSomeIssuesBelowThreshold() {
        // 1 of 10 affected (10%) — well below the 40% suspect threshold.
        var jobs = (0..<9).map { _ in makeJob() }
        jobs.append(makeJob(readErrors: 3))
        let r = DriveHealthAnalyzer.analyze(jobs: jobs)
        XCTAssertEqual(r.verdict, .someIssues)
        XCTAssertEqual(r.ripsWithAnyIssue, 1)
        XCTAssertEqual(r.anyIssuePercent, 10)
    }

    func testDriveSuspectAtOrAboveThreshold() {
        // 4 of 10 affected (40%) — exactly the threshold.
        var jobs: [Job] = []
        for _ in 0..<4 { jobs.append(makeJob(readErrors: 2)) }
        for _ in 0..<6 { jobs.append(makeJob()) }
        let r = DriveHealthAnalyzer.analyze(jobs: jobs)
        XCTAssertEqual(r.verdict, .driveSuspect)
        XCTAssertEqual(r.ripsWithAnyIssue, 4)
        XCTAssertEqual(r.anyIssuePercent, 40)
    }

    func testCountsReadAndCorruptionSeparately() {
        // Disjoint sets of jobs with each kind of error + one job that
        // has both — verifies the union counting in ripsWithAnyIssue.
        let jobs: [Job] = [
            makeJob(readErrors: 1),
            makeJob(readErrors: 2),
            makeJob(corruption: 3),
            makeJob(readErrors: 1, corruption: 1),  // counted ONCE in anyIssue
            makeJob(),
        ]
        let r = DriveHealthAnalyzer.analyze(jobs: jobs)
        XCTAssertEqual(r.ripsWithReadErrors, 3)
        XCTAssertEqual(r.ripsWithCorruption, 2)
        XCTAssertEqual(r.ripsWithAnyIssue, 4, "the job with both errors counts once toward anyIssue")
        XCTAssertEqual(r.totalReadErrors, 4)
        XCTAssertEqual(r.totalCorruptionEvents, 4)
    }

    func testVerdictExplanationsAreNonEmptyAndAdapt() {
        // Each verdict should produce a usable explainer string.
        let reports: [(DriveHealthAnalyzer.Verdict, DriveHealthAnalyzer.Report)] = [
            (.healthy, DriveHealthAnalyzer.analyze(jobs: (0..<5).map { _ in makeJob() })),
            (.someIssues, DriveHealthAnalyzer.analyze(jobs: [makeJob(readErrors: 1)] + (0..<9).map { _ in makeJob() })),
            (.driveSuspect, DriveHealthAnalyzer.analyze(jobs: (0..<5).map { _ in makeJob(readErrors: 1) } + (0..<5).map { _ in makeJob() })),
            (.insufficientData, DriveHealthAnalyzer.analyze(jobs: [makeJob()])),
        ]
        for (expected, r) in reports {
            XCTAssertEqual(r.verdict, expected)
            XCTAssertFalse(r.verdict.explanation(report: r).isEmpty, "explanation must be non-empty for \(expected)")
            XCTAssertFalse(r.verdict.headline.isEmpty)
            XCTAssertFalse(r.verdict.sfSymbol.isEmpty)
        }
    }

    func testThresholdConstantsMatchDocs() {
        // Hand-tuned values are part of the API contract — assert them
        // so a future tweak isn't accidental.
        XCTAssertEqual(DriveHealthAnalyzer.suspectThresholdPercent, 40)
        XCTAssertEqual(DriveHealthAnalyzer.minimumSampleSize, 3)
    }

    // MARK: - affectedJobsWithFingerprint (v3.11.11)

    private func makeFingerprintedJob(readErrors: Int = 0, corruption: Int = 0, fp: String?) -> Job {
        Job(discName: "test",
            rippedFile: URL(fileURLWithPath: "/tmp/x.mkv"),
            discFingerprint: fp,
            ripReadErrors: readErrors,
            ripCorruptionEvents: corruption)
    }

    func testAffectedJobsFilterIncludesEitherCounter() {
        let jobs: [Job] = [
            makeFingerprintedJob(readErrors: 1, fp: "fpA"),
            makeFingerprintedJob(corruption: 2, fp: "fpB"),
            makeFingerprintedJob(readErrors: 1, corruption: 3, fp: "fpC"),
        ]
        let affected = DriveHealthAnalyzer.affectedJobsWithFingerprint(jobs)
        XCTAssertEqual(Set(affected.compactMap { $0.discFingerprint }), Set(["fpA", "fpB", "fpC"]))
    }

    func testAffectedJobsFilterExcludesCleanRips() {
        let jobs: [Job] = [
            makeFingerprintedJob(fp: "clean1"),
            makeFingerprintedJob(fp: "clean2"),
        ]
        XCTAssertTrue(DriveHealthAnalyzer.affectedJobsWithFingerprint(jobs).isEmpty)
    }

    func testAffectedJobsFilterExcludesMissingFingerprint() {
        // Without a fingerprint we can't suppress the dup banner on
        // re-insert, so re-ripping is pointless — skip these.
        let jobs: [Job] = [
            makeFingerprintedJob(readErrors: 5, fp: nil),
            makeFingerprintedJob(corruption: 5, fp: ""),
            makeFingerprintedJob(readErrors: 1, fp: "valid"),
        ]
        let affected = DriveHealthAnalyzer.affectedJobsWithFingerprint(jobs)
        XCTAssertEqual(affected.count, 1)
        XCTAssertEqual(affected.first?.discFingerprint, "valid")
    }

    func testAffectedJobsFilterEmptyInput() {
        XCTAssertTrue(DriveHealthAnalyzer.affectedJobsWithFingerprint([]).isEmpty)
    }

    // MARK: - Offset clustering (v3.11.12)

    private func makeJobWithOffsets(_ offsets: [Int64]) -> Job {
        Job(discName: "test", rippedFile: URL(fileURLWithPath: "/tmp/x.mkv"),
            ripReadErrors: offsets.count, readErrorOffsets: offsets)
    }

    func testOffsetClusteringEmpty() {
        let r = DriveHealthAnalyzer.analyzeOffsetClustering([])
        XCTAssertFalse(r.isCluster)
        XCTAssertEqual(r.sampleSize, 0)
        XCTAssertEqual(r.distinctJobs, 0)
        XCTAssertNil(r.medianBytes)
    }

    func testOffsetClusteringSingleDiscIsNotCluster() {
        // Only one disc contributing offsets — even if narrowly grouped,
        // we can't conclude anything about the drive (could just be a
        // single damaged disc).
        let jobs = [makeJobWithOffsets([2_000_000_000, 2_050_000_000, 2_100_000_000])]
        let r = DriveHealthAnalyzer.analyzeOffsetClustering(jobs)
        XCTAssertFalse(r.isCluster)
        XCTAssertEqual(r.distinctJobs, 1)
        XCTAssertEqual(r.sampleSize, 3)
    }

    func testOffsetClusteringNarrowSpreadAcrossMultipleDiscs() {
        // The exact scenario the user observed: errors on different discs
        // all happening at ~2 GB. This should fire the cluster finding.
        let jobs = [
            makeJobWithOffsets([2_083_123_200]),
            makeJobWithOffsets([2_096_381_952]),
            makeJobWithOffsets([2_100_000_000]),
        ]
        let r = DriveHealthAnalyzer.analyzeOffsetClustering(jobs)
        XCTAssertTrue(r.isCluster, "narrow spread across 3 discs should cluster")
        XCTAssertEqual(r.distinctJobs, 3)
        XCTAssertEqual(r.sampleSize, 3)
    }

    func testOffsetClusteringWideSpreadIsNotCluster() {
        // Errors scattered across the full disc — not a cluster.
        let jobs = [
            makeJobWithOffsets([500_000_000]),     // ~ 500 MB
            makeJobWithOffsets([8_000_000_000]),   // ~ 8 GB
            makeJobWithOffsets([15_000_000_000]),  // ~ 15 GB
        ]
        let r = DriveHealthAnalyzer.analyzeOffsetClustering(jobs)
        XCTAssertFalse(r.isCluster, "spread >> 500 MiB should not cluster")
        XCTAssertEqual(r.distinctJobs, 3)
    }

    func testOffsetClusteringIgnoresJobsWithNoOffsets() {
        // Only counts jobs that actually contributed offsets toward
        // distinctJobs. Three clean jobs alongside two errored ones
        // should still report distinctJobs = 2.
        let jobs = [
            makeJobWithOffsets([2_000_000_000]),
            makeJobWithOffsets([]),  // clean — should not count
            makeJobWithOffsets([2_100_000_000]),
            makeJobWithOffsets([]),
        ]
        let r = DriveHealthAnalyzer.analyzeOffsetClustering(jobs)
        XCTAssertEqual(r.distinctJobs, 2)
    }

    func testClusterConstantsAreExposed() {
        // Hand-tuned thresholds — assert them as part of the API
        // contract so a future tweak isn't accidental.
        XCTAssertEqual(DriveHealthAnalyzer.clusterSpreadThresholdBytes, 500 * 1024 * 1024)
        XCTAssertEqual(DriveHealthAnalyzer.clusterMinDistinctJobs, 2)
    }
}

// MARK: - UpdateService.parseMountPointFromHdiutilPlist (v3.11.13)
//
// Fixture-based tests for the hdiutil `-plist` output parser. v3.11.13
// switched the mount-point extraction from a regex over `-quiet` output
// (which silently returned empty on macOS 14+) to PropertyListSerialization
// over `-plist` output. These tests pin the parser's contract so the
// fix doesn't quietly regress in a future cleanup.

final class HdiutilPlistParserTests: XCTestCase {

    /// Realistic snippet from `hdiutil attach <dmg> -plist`. Two system
    /// entities: the GPT scheme (no mount-point) and the HFS+ slice
    /// (which mounts at /Volumes/AutoRipper).
    private let realisticPlist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>system-entities</key>
        <array>
            <dict>
                <key>content-hint</key>
                <string>GUID_partition_scheme</string>
                <key>dev-entry</key>
                <string>/dev/disk6</string>
            </dict>
            <dict>
                <key>content-hint</key>
                <string>Apple_HFS</string>
                <key>dev-entry</key>
                <string>/dev/disk6s1</string>
                <key>mount-point</key>
                <string>/Volumes/AutoRipper</string>
                <key>volume-kind</key>
                <string>hfs</string>
            </dict>
        </array>
    </dict>
    </plist>
    """

    func testParsesRealisticHdiutilOutput() {
        let data = Data(realisticPlist.utf8)
        let mount = UpdateService.parseMountPointFromHdiutilPlist(data)
        XCTAssertEqual(mount, "/Volumes/AutoRipper")
    }

    func testReturnsFirstNonEmptyMountPointWhenMultiple() {
        // Edge case: a multi-partition DMG. We just want any valid
        // mount-point — the first one encountered is fine.
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0">
        <dict>
            <key>system-entities</key>
            <array>
                <dict>
                    <key>mount-point</key>
                    <string>/Volumes/First</string>
                </dict>
                <dict>
                    <key>mount-point</key>
                    <string>/Volumes/Second</string>
                </dict>
            </array>
        </dict>
        </plist>
        """
        XCTAssertEqual(
            UpdateService.parseMountPointFromHdiutilPlist(Data(plist.utf8)),
            "/Volumes/First"
        )
    }

    func testSkipsEmptyMountPoint() {
        // The first entity has an empty mount-point (e.g. the GPT
        // scheme entry MakeMKV's DMG often includes). Parser should
        // skip it and return the next non-empty one.
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0">
        <dict>
            <key>system-entities</key>
            <array>
                <dict>
                    <key>mount-point</key>
                    <string></string>
                </dict>
                <dict>
                    <key>mount-point</key>
                    <string>/Volumes/Good</string>
                </dict>
            </array>
        </dict>
        </plist>
        """
        XCTAssertEqual(
            UpdateService.parseMountPointFromHdiutilPlist(Data(plist.utf8)),
            "/Volumes/Good"
        )
    }

    func testReturnsNilForMalformedXML() {
        XCTAssertNil(UpdateService.parseMountPointFromHdiutilPlist(Data("not a plist".utf8)))
        XCTAssertNil(UpdateService.parseMountPointFromHdiutilPlist(Data()))
    }

    func testReturnsNilWhenNoSystemEntities() {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0">
        <dict>
            <key>other-key</key>
            <string>not what we're looking for</string>
        </dict>
        </plist>
        """
        XCTAssertNil(UpdateService.parseMountPointFromHdiutilPlist(Data(plist.utf8)))
    }

    func testReturnsNilWhenNoEntityHasMountPoint() {
        // Some hdiutil output (rare, e.g. raw block-device images) has
        // system-entities but no mount-point. Parser returns nil so the
        // caller falls back to the legacy tabular search.
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0">
        <dict>
            <key>system-entities</key>
            <array>
                <dict>
                    <key>dev-entry</key>
                    <string>/dev/disk6</string>
                </dict>
            </array>
        </dict>
        </plist>
        """
        XCTAssertNil(UpdateService.parseMountPointFromHdiutilPlist(Data(plist.utf8)))
    }
}

// MARK: - Edition hint heuristic tests (v3.10)

final class EditionHintTests: XCTestCase {

    private func hint(_ titleSec: Int, vsMain mainSec: Int) -> String {
        DiscInfo.editionHintForAlternateCut(titleSeconds: titleSec, mainSeconds: mainSec)
    }

    func testAltVersionForSmallDelta() {
        // Within ±2 min: "Alt Version"
        XCTAssertTrue(hint(7200, vsMain: 7260).contains("Alt Version"))
        XCTAssertTrue(hint(7320, vsMain: 7200).contains("Alt Version"))
    }

    func testExtendedCutForModestLengthening() {
        let h = hint(7200 + 10*60, vsMain: 7200)  // main + 10 min
        XCTAssertTrue(h.contains("Extended Cut"), h)
        XCTAssertTrue(h.contains("+10 min"), h)
    }

    func testDirectorsCutForSignificantLengthening() {
        let h = hint(7200 + 25*60, vsMain: 7200)  // main + 25 min
        XCTAssertTrue(h.contains("Director's Cut"), h)
        XCTAssertTrue(h.contains("+25 min"), h)
    }

    func testUltimateCutForExtremeLengthening() {
        let h = hint(7200 + 60*60, vsMain: 7200)  // main + 60 min
        XCTAssertTrue(h.contains("Ultimate Cut"), h)
    }

    func testTVCutForModestShortening() {
        let h = hint(7200 - 10*60, vsMain: 7200)  // main - 10 min
        XCTAssertTrue(h.contains("TV Cut"), h)
        XCTAssertTrue(h.contains("−10 min"), h)
    }

    func testTheatricalCutForSignificantShortening() {
        let h = hint(7200 - 25*60, vsMain: 7200)
        XCTAssertTrue(h.contains("Theatrical Cut"), h)
    }

    func testBoundaryAtTwoMinutes() {
        // 2 min exact is Alt Version (inclusive). 3 min is Extended.
        XCTAssertTrue(hint(7200 + 2*60, vsMain: 7200).contains("Alt Version"))
        XCTAssertTrue(hint(7200 + 3*60, vsMain: 7200).contains("Extended Cut"))
    }

    func testEmojiPresent() {
        XCTAssertTrue(hint(7200 + 10*60, vsMain: 7200).hasPrefix("🎬"))
    }

    func testAutoLabelAppliesEditionHint() {
        // Main 120 min + alt at 145 min should become a Director's Cut hint.
        let main = TitleInfo(id: 0, name: "Main", duration: "2:00:00",
                             sizeBytes: 30_000_000_000, chapters: 1, fileOutput: "")
        let alt = TitleInfo(id: 1, name: "Alt", duration: "2:25:00",
                            sizeBytes: 28_000_000_000, chapters: 1, fileOutput: "")
        var info = DiscInfo(name: "X", type: "bluray", titles: [main, alt])
        info.autoLabel()
        XCTAssertEqual(info.titles[1].category, .alternateCut)
        XCTAssertTrue(info.titles[1].label.contains("Director's Cut"),
                      "label=\(info.titles[1].label)")
        XCTAssertTrue(info.titles[1].label.contains("+25 min"),
                      "label=\(info.titles[1].label)")
    }
}

// MARK: - MakeMKVConfigService tests (v3.11.3)

final class MakeMKVConfigServiceTests: XCTestCase {

    func testApplySettingAddsNewKey() {
        let input: [String] = []
        let out = MakeMKVConfigService.applySetting(lines: input, key: "io_SingleDriveReadSpeed", value: "8")
        XCTAssertEqual(out, ["io_SingleDriveReadSpeed = \"8\""])
    }

    func testApplySettingReplacesExistingKey() {
        let input = [
            "# top comment",
            "app_DefaultOutputFileName = \"foo\"",
            "io_SingleDriveReadSpeed = \"32\"",
            "app_ExpertMode = \"true\"",
        ]
        let out = MakeMKVConfigService.applySetting(lines: input, key: "io_SingleDriveReadSpeed", value: "8")
        XCTAssertEqual(out.count, 4)
        XCTAssertEqual(out[2], "io_SingleDriveReadSpeed = \"8\"")
        // Other lines untouched
        XCTAssertEqual(out[0], "# top comment")
        XCTAssertEqual(out[1], "app_DefaultOutputFileName = \"foo\"")
        XCTAssertEqual(out[3], "app_ExpertMode = \"true\"")
    }

    func testApplySettingNilRemovesKey() {
        let input = [
            "app_KeepTracks = \"true\"",
            "io_SingleDriveReadSpeed = \"8\"",
            "app_Verbose = \"true\"",
        ]
        let out = MakeMKVConfigService.applySetting(lines: input, key: "io_SingleDriveReadSpeed", value: nil)
        XCTAssertEqual(out.count, 2)
        XCTAssertFalse(out.contains { $0.contains("io_SingleDriveReadSpeed") })
    }

    func testApplySettingDoesNotMatchKeyPrefix() {
        // io_SingleDriveReadSpeed_Foo must NOT be touched when we update
        // io_SingleDriveReadSpeed.
        let input = ["io_SingleDriveReadSpeedFoo = \"bar\""]
        let out = MakeMKVConfigService.applySetting(lines: input, key: "io_SingleDriveReadSpeed", value: "8")
        // Expect the existing line preserved AND a new line appended.
        XCTAssertTrue(out.contains("io_SingleDriveReadSpeedFoo = \"bar\""))
        XCTAssertTrue(out.contains("io_SingleDriveReadSpeed = \"8\""))
    }

    func testApplySettingPreservesCommentsThatMentionKey() {
        let input = [
            "# io_SingleDriveReadSpeed default is fast",
            "app_Foo = \"bar\"",
        ]
        let out = MakeMKVConfigService.applySetting(lines: input, key: "io_SingleDriveReadSpeed", value: "4")
        // Comment should still be there.
        XCTAssertTrue(out[0].hasPrefix("#"))
        XCTAssertTrue(out.contains("io_SingleDriveReadSpeed = \"4\""))
    }
}
