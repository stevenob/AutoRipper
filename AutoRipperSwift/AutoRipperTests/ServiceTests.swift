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
        // A second 90+ min movie on a double-feature disc.
        var info = DiscInfo(name: "DOUBLE", type: "dvd", titles: [
            makeTitle(id: 0, duration: "1:50:00", sizeGB: 4.5),
            makeTitle(id: 1, duration: "1:35:00", sizeGB: 4.0),  // 95 min, ≥90 → bonus feature
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
