import XCTest
@testable import AutoRipper

// MARK: - TheDiscDBContentHash

final class TheDiscDBContentHashTests: XCTestCase {

    func testEmptyInputMatchesEmptyMD5() {
        // MD5 of zero bytes.
        XCTAssertEqual(TheDiscDBContentHash.contentHash(fileSizes: []),
                       "D41D8CD98F00B204E9800998ECF8427E")
    }

    func testKnownVectorLittleEndian8Byte() {
        // Each size encoded as an 8-byte little-endian Int64, concatenated,
        // then MD5 (uppercase hex). Vectors computed independently in Python.
        XCTAssertEqual(TheDiscDBContentHash.contentHash(fileSizes: [1, 2, 3]),
                       "AA341A15F5ADE44FAAFBE190F98C2587")
        XCTAssertEqual(TheDiscDBContentHash.contentHash(fileSizes: [5017708544]),
                       "58B9F34EEABBAD375B66D80F206B4422")
        XCTAssertEqual(TheDiscDBContentHash.contentHash(fileSizes: [249233408, 117798912]),
                       "70F3EE964CAE6698B63ECA876A2A63B8")
    }

    func testOrderIsSignificant() {
        XCTAssertNotEqual(
            TheDiscDBContentHash.contentHash(fileSizes: [1, 2]),
            TheDiscDBContentHash.contentHash(fileSizes: [2, 1])
        )
    }

    func testOutputIsUppercase32HexChars() {
        let hash = TheDiscDBContentHash.contentHash(fileSizes: [42])
        XCTAssertEqual(hash.count, 32)
        XCTAssertEqual(hash, hash.uppercased())
        XCTAssertTrue(hash.allSatisfy { $0.isHexDigit })
    }
}

// MARK: - TheDiscDBTitleType mapping

final class TheDiscDBTitleTypeTests: XCTestCase {

    func testRawDecodingTolerant() {
        XCTAssertEqual(TheDiscDBTitleType(raw: "MainMovie"), .mainMovie)
        XCTAssertEqual(TheDiscDBTitleType(raw: "deletedscene"), .deletedScene)
        XCTAssertEqual(TheDiscDBTitleType(raw: nil), .none)
        XCTAssertEqual(TheDiscDBTitleType(raw: ""), .none)
        XCTAssertEqual(TheDiscDBTitleType(raw: "SomethingNew"), .unknown("SomethingNew"))
    }

    func testJobIntentMapping() {
        XCTAssertEqual(TheDiscDBTitleType.mainMovie.jobIntent, .movie)
        XCTAssertEqual(TheDiscDBTitleType.episode.jobIntent, .episode)
        XCTAssertEqual(TheDiscDBTitleType.deletedScene.jobIntent, .extra)
        XCTAssertEqual(TheDiscDBTitleType.trailer.jobIntent, .extra)
        XCTAssertEqual(TheDiscDBTitleType.unknown("x").jobIntent, .extra)
        XCTAssertEqual(TheDiscDBTitleType.none.jobIntent, .extra)
    }

    func testCategoryMapping() {
        XCTAssertEqual(TheDiscDBTitleType.mainMovie.titleCategory, .mainFeature)
        XCTAssertEqual(TheDiscDBTitleType.trailer.titleCategory, .trailer)
        XCTAssertEqual(TheDiscDBTitleType.short.titleCategory, .shortExtra)
        XCTAssertEqual(TheDiscDBTitleType.featurette.titleCategory, .featurette)
        XCTAssertNil(TheDiscDBTitleType.none.titleCategory)
        XCTAssertNil(TheDiscDBTitleType.unknown("x").titleCategory)
    }

    func testIsClassified() {
        XCTAssertTrue(TheDiscDBTitleType.extra.isClassified)
        XCTAssertFalse(TheDiscDBTitleType.none.isClassified)
    }

    func testParseDurationSeconds() {
        XCTAssertEqual(TheDiscDBTitle.parseDurationSeconds("1:41:54"), 6114)
        XCTAssertEqual(TheDiscDBTitle.parseDurationSeconds("0:31:23"), 1883)
        XCTAssertEqual(TheDiscDBTitle.parseDurationSeconds("3:20"), 200)
        XCTAssertEqual(TheDiscDBTitle.parseDurationSeconds(""), 0)
    }
}

// MARK: - TheDiscDBMatcher

final class TheDiscDBMatcherTests: XCTestCase {

    // Helpers --------------------------------------------------------------

    private func discTitle(_ id: Int, _ duration: String, _ size: Int64) -> TitleInfo {
        TitleInfo(id: id, name: "T\(id)", duration: duration, sizeBytes: size,
                  chapters: 1, fileOutput: "t\(id).mkv")
    }

    private func dbTitle(_ index: Int, _ seconds: Int, _ size: Int64?,
                         _ type: TheDiscDBTitleType, _ title: String,
                         season: Int? = nil, episode: Int? = nil) -> TheDiscDBTitle {
        TheDiscDBTitle(index: index, durationSeconds: seconds, sizeBytes: size,
                       segmentMap: nil, sourceFile: nil, type: type, title: title,
                       season: season, episode: episode)
    }

    private func disc(format: String, mediaType: String = "Movie",
                      hash: String? = nil, titles: [TheDiscDBTitle]) -> TheDiscDBDisc {
        TheDiscDBDisc(contentHash: hash, name: "GARDEN_STATE", format: format, index: 1,
                      mediaTitle: "Garden State", mediaYear: 2004, mediaType: mediaType,
                      tmdbId: 401, imdbId: "tt0333766", releaseSlug: "2004-dvd",
                      upc: "024543155881", titles: titles)
    }

    /// The real Garden State 2004 DVD, as it comes back from TheDiscDB (subset
    /// of the meaningful titles + a couple of unnamed deleted-scene segments).
    private func gardenStateDB() -> TheDiscDBDisc {
        disc(format: "DVD", titles: [
            dbTitle(0, 6114, 5017698304, .mainMovie, "Garden State"),       // 1:41:54
            dbTitle(1, 1883, 1383720960, .deletedScene, "Deleted Scenes"),  // 0:31:23
            dbTitle(3, 105, nil, .none, ""),                                // 0:01:45 unnamed
            dbTitle(6, 77, nil, .none, ""),                                 // 0:01:17 unnamed
            dbTitle(18, 1648, 1400000000, .extra, "The Making of Garden State"), // 0:27:28
            dbTitle(19, 200, nil, .extra, "Outtakes/Bloopers"),            // 0:03:20
        ])
    }

    /// The real MakeMKV scan of the same disc (the meaningful subset).
    private func gardenStateScan() -> DiscInfo {
        DiscInfo(name: "GARDEN_STATE", type: "dvd", titles: [
            discTitle(0, "1:41:54", 5017708544),
            discTitle(1, "0:31:23", 1383720960),
            discTitle(2, "0:01:45", 74579968),
            discTitle(3, "0:01:17", 54011904),
            discTitle(11, "0:27:28", 1400647680),
            discTitle(12, "0:03:20", 177176576),
        ])
    }

    // Tests ----------------------------------------------------------------

    func testGardenStateResolvesMainFeatureAndNamedExtras() {
        let plan = TheDiscDBMatcher.match(discInfo: gardenStateScan(),
                                          candidates: [gardenStateDB()])
        XCTAssertTrue(plan.trusted, "plan should be trusted: \(plan.reason) \(plan.warnings)")
        XCTAssertEqual(plan.matchRatio, 1.0, accuracy: 0.001)

        // Main feature: high confidence, .movie, named.
        let main = plan.matches.first { $0.discTitleId == 0 }
        XCTAssertEqual(main?.intent, .movie)
        XCTAssertEqual(main?.name, "Garden State")
        XCTAssertEqual(main?.category, .mainFeature)
        XCTAssertEqual(main?.confidence, .high)

        // Named extras resolve.
        XCTAssertEqual(plan.titleNames[1], "Deleted Scenes")
        XCTAssertEqual(plan.titleNames[11], "The Making of Garden State")
        XCTAssertEqual(plan.titleNames[12], "Outtakes/Bloopers")
        XCTAssertEqual(plan.intents[11], .extra)
    }

    func testUnnamedSegmentsAreLowConfidenceGenericExtras() {
        let plan = TheDiscDBMatcher.match(discInfo: gardenStateScan(),
                                          candidates: [gardenStateDB()])
        // MakeMKV titles 2 & 3 map to .none DB segments.
        for id in [2, 3] {
            let m = plan.matches.first { $0.discTitleId == id }
            XCTAssertEqual(m?.confidence, .low, "title \(id) should be low confidence")
            XCTAssertEqual(m?.intent, .extra)
            XCTAssertNil(m?.name, "unnamed segment must not get a name")
            XCTAssertNil(m?.category, "unnamed segment keeps autoLabel's category")
        }
    }

    func testRejectsLowMatchRatio() {
        // A candidate that only covers the main feature → 1/6 ratio.
        let sparse = disc(format: "DVD", titles: [
            dbTitle(0, 6114, 5017698304, .mainMovie, "Garden State"),
        ])
        let plan = TheDiscDBMatcher.match(discInfo: gardenStateScan(), candidates: [sparse])
        XCTAssertFalse(plan.trusted)
        XCTAssertTrue(plan.reason.contains("match ratio"), plan.reason)
    }

    func testRejectsMainFeatureRuntimeDisagreement() {
        // Same titles but the MainMovie runtime is wildly off (different cut).
        let wrong = disc(format: "DVD", titles: [
            dbTitle(0, 7000, 5017698304, .mainMovie, "Garden State"),       // +14 min
            dbTitle(1, 1883, 1383720960, .deletedScene, "Deleted Scenes"),
            dbTitle(18, 1648, 1400000000, .extra, "The Making of Garden State"),
            dbTitle(19, 200, nil, .extra, "Outtakes/Bloopers"),
            dbTitle(3, 105, nil, .none, ""),
            dbTitle(6, 77, nil, .none, ""),
        ])
        let plan = TheDiscDBMatcher.match(discInfo: gardenStateScan(), candidates: [wrong])
        XCTAssertFalse(plan.trusted)
        XCTAssertTrue(plan.reason.contains("main-feature"), plan.reason)
    }

    func testFormatMatchPrefersSameMedium() {
        let dvd = gardenStateDB()
        var blu = gardenStateDB()
        blu = TheDiscDBDisc(contentHash: nil, name: blu.name, format: "Blu-Ray", index: 1,
                            mediaTitle: blu.mediaTitle, mediaYear: blu.mediaYear,
                            mediaType: blu.mediaType, tmdbId: blu.tmdbId, imdbId: blu.imdbId,
                            releaseSlug: "2014-blu-ray", upc: blu.upc, titles: blu.titles)
        // Present blu-ray first; matcher must still pick the DVD for a DVD scan.
        let plan = TheDiscDBMatcher.match(discInfo: gardenStateScan(), candidates: [blu, dvd])
        XCTAssertTrue(plan.trusted)
        XCTAssertEqual(plan.candidate?.releaseSlug, "2004-dvd")
    }

    func testDurationTieDisambiguatedBySize() {
        // Two same-duration extras; size decides which name lands where.
        let scan = DiscInfo(name: "X", type: "bluray", titles: [
            discTitle(0, "0:02:00", 100_000_000),
            discTitle(1, "0:02:00", 500_000_000),
        ])
        let cand = disc(format: "Blu-Ray", titles: [
            dbTitle(0, 120, 100_000_000, .trailer, "Teaser Trailer"),
            dbTitle(1, 120, 500_000_000, .featurette, "Behind the Scenes"),
        ])
        let plan = TheDiscDBMatcher.build(discInfo: scan, candidate: cand,
                                          tolerance: TheDiscDBMatcher.defaultToleranceSeconds)
        // Title 0 (100 MB) should pair with the 100 MB DB title.
        XCTAssertEqual(plan.matches.first { $0.discTitleId == 0 }?.name, "Teaser Trailer")
        XCTAssertEqual(plan.matches.first { $0.discTitleId == 1 }?.name, "Behind the Scenes")
    }

    func testEpisodeAssignmentsExposed() {
        let scan = DiscInfo(name: "SHOW_S1_D1", type: "bluray", titles: [
            discTitle(0, "0:22:05", 800_000_000),
            discTitle(1, "0:21:50", 790_000_000),
        ])
        let cand = disc(format: "Blu-Ray", mediaType: "Series", titles: [
            dbTitle(0, 1325, 800_000_000, .episode, "Pilot", season: 1, episode: 1),
            dbTitle(1, 1310, 790_000_000, .episode, "Second", season: 1, episode: 2),
        ])
        let plan = TheDiscDBMatcher.match(discInfo: scan, candidates: [cand])
        XCTAssertTrue(plan.trusted)
        XCTAssertEqual(plan.episodeAssignments[0]?.episode, 1)
        XCTAssertEqual(plan.episodeAssignments[1]?.episode, 2)
        XCTAssertEqual(plan.intents[0], .episode)
    }

    func testExactHashMatchBypassesFormatGate() {
        // A blu-ray candidate matched by content hash against a "dvd" scan
        // (hypothetical) is still trusted because the hash is authoritative.
        let cand = disc(format: "Blu-Ray", hash: "ABCDEF0123456789ABCDEF0123456789",
                        titles: gardenStateDB().titles)
        let plan = TheDiscDBMatcher.match(discInfo: gardenStateScan(),
                                          candidates: [cand], exactHashMatch: true)
        XCTAssertTrue(plan.trusted)
        XCTAssertTrue(plan.reason.contains("content-hash"), plan.reason)
    }

    func testEmptyCandidatesIsUntrusted() {
        let plan = TheDiscDBMatcher.match(discInfo: gardenStateScan(), candidates: [])
        XCTAssertFalse(plan.trusted)
    }

    /// Real-world Blu-ray case (Requiem for a Dream 2020 BD, tmdb 641): MakeMKV
    /// exposes the main-feature playlist twice (same runtime + size). Only one
    /// copy may become `.movie`; the duplicate must degrade to a safe extra
    /// rather than a second main feature. Named extras/trailers/deleted scenes
    /// still resolve. Data mirrors the live TheDiscDB response.
    func testDuplicateMainFeaturePlaylistDegradesToExtra() {
        let scan = DiscInfo(name: "REQUIEM FOR A DREAM", type: "bluray", titles: [
            discTitle(0, "1:41:25", 32172263424),  // main feature
            discTitle(1, "1:41:25", 32172263424),  // duplicate playlist
            discTitle(3, "0:35:23", 2300289024),   // The Making of
            discTitle(5, "0:01:37", 105375744),    // Teaser Trailer
            discTitle(7, "0:02:03", 137631744),    // a deleted scene
        ])
        let cand = disc(format: "Blu-Ray", titles: [
            dbTitle(0, 6085, 32000000000, .mainMovie, "Requiem for a Dream"),
            dbTitle(1, 6085, nil, .none, ""),                              // duplicate target, unnamed
            dbTitle(14, 2123, 2300000000, .extra, "The Making of Requiem"),
            dbTitle(17, 97, nil, .trailer, "Teaser Trailer"),
            dbTitle(25, 123, nil, .deletedScene, "Tyrone's Confession"),
        ])
        let plan = TheDiscDBMatcher.match(discInfo: scan, candidates: [cand])
        XCTAssertTrue(plan.trusted, "\(plan.reason) \(plan.warnings)")

        // Exactly one main feature, named.
        let mains = plan.matches.filter { $0.intent == .movie }
        XCTAssertEqual(mains.count, 1)
        XCTAssertEqual(mains.first?.discTitleId, 0)
        XCTAssertEqual(mains.first?.name, "Requiem for a Dream")
        // The duplicate playlist is a safe, unnamed extra (matched the unnamed
        // 6085s segment) — never a second movie.
        let dup = plan.matches.first { $0.discTitleId == 1 }
        XCTAssertEqual(dup?.intent, .extra)
        XCTAssertNil(dup?.name)
        // Named bonus content resolves with the right kinds.
        XCTAssertEqual(plan.titleNames[3], "The Making of Requiem")
        XCTAssertEqual(plan.titleNames[5], "Teaser Trailer")
        XCTAssertEqual(plan.titleNames[7], "Tyrone's Confession")
    }
}

// MARK: - RipViewModel application (Slice 2 wiring)

@MainActor
final class TheDiscDBApplyTests: XCTestCase {

    private func discTitle(_ id: Int, _ duration: String, _ size: Int64) -> TitleInfo {
        TitleInfo(id: id, name: "T\(id)", duration: duration, sizeBytes: size,
                  chapters: 1, fileOutput: "t\(id).mkv")
    }

    private func dbTitle(_ index: Int, _ seconds: Int, _ size: Int64?,
                         _ type: TheDiscDBTitleType, _ title: String,
                         season: Int? = nil, episode: Int? = nil) -> TheDiscDBTitle {
        TheDiscDBTitle(index: index, durationSeconds: seconds, sizeBytes: size,
                       segmentMap: nil, sourceFile: nil, type: type, title: title,
                       season: season, episode: episode)
    }

    /// Applying a trusted movie plan sets intents, names extras (but not the
    /// main feature when a cached TMDb result exists), and claims the
    /// `.discDb` assignment source so async writers defer.
    func testApplyMoviePlanSetsIntentsNamesAndSource() {
        let scan = DiscInfo(name: "GARDEN_STATE", type: "dvd", titles: [
            discTitle(0, "1:41:54", 5017708544),
            discTitle(1, "0:31:23", 1383720960),
            discTitle(11, "0:27:28", 1400647680),
        ])
        let cand = TheDiscDBDisc(
            contentHash: nil, name: "GARDEN_STATE", format: "DVD", index: 1,
            mediaTitle: "Garden State", mediaYear: 2004, mediaType: "Movie",
            tmdbId: 401, imdbId: nil, releaseSlug: "2004-dvd", upc: nil,
            titles: [
                dbTitle(0, 6114, 5017698304, .mainMovie, "Garden State"),
                dbTitle(1, 1883, 1383720960, .deletedScene, "Deleted Scenes"),
                dbTitle(18, 1648, 1400000000, .extra, "The Making of Garden State"),
            ])
        let plan = TheDiscDBMatcher.match(discInfo: scan, candidates: [cand])
        XCTAssertTrue(plan.trusted)

        let vm = RipViewModel()
        vm.discInfo = scan
        vm.applyDiscDbPlan(plan, info: scan)

        XCTAssertEqual(vm.assignmentSource, .discDb(release: "2004-dvd"))
        XCTAssertFalse(vm.assignmentSource.isAutomatic)
        XCTAssertEqual(vm.intent(for: 0), .movie)
        XCTAssertEqual(vm.intent(for: 1), .extra)
        XCTAssertEqual(vm.intent(for: 11), .extra)
        // Extras are named; their names flow through as the override.
        XCTAssertEqual(vm.nameOverride(for: 1), "Deleted Scenes")
        XCTAssertEqual(vm.nameOverride(for: 11), "The Making of Garden State")
        // No cached TMDb result in this unit context, so the main feature
        // falls back to the DiscDB title rather than being left blank.
        XCTAssertEqual(vm.nameOverride(for: 0), "Garden State")
    }

    /// A partial TV match must not leave a stale sequential episode number
    /// colliding with a DiscDB-assigned one: unmatched episode titles are
    /// demoted to `.extra` and their assignments cleared.
    func testApplyTVPlanAvoidsEpisodeCollision() {
        let scan = DiscInfo(name: "SHOW_S1_D1", type: "bluray", titles: [
            discTitle(0, "0:22:05", 800_000_000),  // matches DB E01
            discTitle(1, "0:21:50", 790_000_000),  // matches DB E02
            discTitle(2, "0:45:00", 1_900_000_000), // no DB counterpart
        ])
        let cand = TheDiscDBDisc(
            contentHash: nil, name: "SHOW_S1_D1", format: "Blu-Ray", index: 1,
            mediaTitle: "Show", mediaYear: 2010, mediaType: "Series",
            tmdbId: 999, imdbId: nil, releaseSlug: "s1-bd", upc: nil,
            titles: [
                dbTitle(0, 1325, 800_000_000, .episode, "Pilot", season: 1, episode: 1),
                dbTitle(1, 1310, 790_000_000, .episode, "Second", season: 1, episode: 2),
            ])
        let plan = TheDiscDBMatcher.build(discInfo: scan, candidate: cand,
                                          tolerance: TheDiscDBMatcher.defaultToleranceSeconds)

        let vm = RipViewModel()
        vm.discInfo = scan
        // Simulate the sequential fallback having numbered all three —
        // including a collision: title 2 was given S01E02, the same number
        // DiscDB assigns to title 1.
        vm.titleIntents = [0: .episode, 1: .episode, 2: .episode]
        vm.titleEpisodeAssignments = [
            0: TitleEpisodeAssignment(season: 1, episode: 1, title: ""),
            1: TitleEpisodeAssignment(season: 1, episode: 2, title: ""),
            2: TitleEpisodeAssignment(season: 1, episode: 2, title: ""),
        ]

        vm.applyDiscDbPlan(plan, info: scan)

        // DiscDB owns episodes now.
        XCTAssertEqual(vm.assignmentSource, .discDb(release: "s1-bd"))
        XCTAssertEqual(vm.episodeAssignment(for: 0)?.episode, 1)
        XCTAssertEqual(vm.episodeAssignment(for: 1)?.episode, 2)
        XCTAssertEqual(vm.episodeAssignment(for: 1)?.title, "Second")
        // Unmatched title demoted to a generic extra with no number — no
        // collision with title 1's S01E02.
        XCTAssertEqual(vm.intent(for: 2), .extra)
        XCTAssertNil(vm.episodeAssignment(for: 2))

        // No two retained episode assignments share the same (season, episode).
        let eps = vm.titleEpisodeAssignments.values.map { "\($0.season)-\($0.episode)" }
        XCTAssertEqual(Set(eps).count, eps.count, "duplicate SxxExx assignment: \(eps)")
    }
}

// MARK: - TheDiscDBService validation

final class TheDiscDBServiceTests: XCTestCase {

    func testContentHashValidation() {
        XCTAssertTrue(TheDiscDBService.isValidContentHash("2D61282D8DA5EAC2CA87B451BCE9A055"))
        XCTAssertTrue(TheDiscDBService.isValidContentHash("ABCDEF01"))           // 8 chars
        XCTAssertFalse(TheDiscDBService.isValidContentHash("XYZ"))               // too short / non-hex
        XCTAssertFalse(TheDiscDBService.isValidContentHash(""))
        XCTAssertFalse(TheDiscDBService.isValidContentHash("GGGGGGGG"))          // non-hex
    }
}
