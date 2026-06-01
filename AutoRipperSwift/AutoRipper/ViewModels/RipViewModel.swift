import Foundation
import SwiftUI
import os

private let log = Logger(subsystem: "com.autoripper.app", category: "rip-vm")

@MainActor
final class RipViewModel: ObservableObject {
    @Published var discInfo: DiscInfo?
    @Published var ripProgress: Double = 0
    @Published var isScanning: Bool = false
    @Published var isRipping: Bool = false
    @Published var selectedTitles: Set<Int> = []
    @Published var statusText: String = "Idle"
    @Published var logLines: [String] = []
    @Published var errorMessage: String?
    @Published var detectedDiscType: String = ""
    @Published var detectedDiscName: String = ""
    /// Active phase of the rip pipeline currently driven by THIS view model.
    /// Used by the disc hero block to show "RIPPING" vs "STAGING" instead of
    /// always saying "RIPPING" while we're actually copying files to the NAS
    /// during staging. Cleared back to `.idle` between titles and at end.
    @Published var activePhase: RipPhase = .idle
    /// Set after a scan when TMDb couldn't identify the disc. UI shows a dismissible
    /// banner prompting the user to set per-title search overrides. Cleared on dismiss
    /// or new scan.
    @Published var unidentifiedDiscName: String?
    /// Top TMDb candidates from the disc-level search, so the user can swap the
    /// auto-picked one for a different match (e.g. when TMDb returned a sequel
    /// when we wanted the original). Set during scan, cleared on new scan.
    @Published var discCandidates: [MediaResult] = []
    /// Per-title rip status, used by the hero "now ripping" view. Keyed by titleId.
    @Published var titleRipStatuses: [Int: TitleRipStatus] = [:]
    /// The title currently being ripped (so the hero can highlight the right row).
    @Published var currentRippingTitleId: Int?
    /// MediaResult of the most recent successful rip, used to give the
    /// "Insert next disc" hero a brief celebratory state.
    @Published var lastCompletedMedia: MediaResult?
    /// Display name of the disc whose rip just finished (for the "next disc" hero).
    @Published var lastCompletedDiscName: String?
    /// Set by `scanDisc` after each scan. When non-nil, the inserted disc's
    /// fingerprint already exists in `RippedDiscRegistry` — i.e., the user
    /// has previously ripped this exact disc. UI uses this to show a
    /// "Already ripped on <date>" banner so the user doesn't accidentally
    /// re-rip the same content during a long batch session.
    /// Cleared on new scan or banner dismiss.
    @Published var previousRipMatch: RippedDiscEntry?
    /// v3.7.2: substate of `activePhase == .ripping`. Tracks where the rip
    /// is in its own startup sequence so the UI can show "Reading disc…"
    /// instead of leaving the user staring at "RIPPING 0%" while
    /// makemkvcon re-walks the disc structure (~20–60 s on Blu-ray).
    /// Resets to `.notStarted` between titles and at end of rip.
    @Published var startupPhase: RipStartupPhase = .notStarted
    /// v3.11.5: count of MakeMKV `MSG:2003` "Posix I/O error" reads emitted
    /// during the current rip. Reset on new rip / scan. Drives a small
    /// indicator in the rip hero block and the auto-suggest-quieter-speed
    /// banner when the count crosses a threshold. Per-job final count
    /// is also persisted onto `Job.ripReadErrors` for History display.
    @Published var readErrorCount: Int = 0
    /// v3.11.5: when on, the disc panel shows a "Try slower drive speed?"
    /// banner because the read-error count exceeded the threshold. The
    /// user can dismiss or click the action button. Cleared on new rip /
    /// scan / dismiss.
    @Published var suggestLowerDriveSpeed: Bool = false
    /// v3.11.7: count of MakeMKV data-corruption events during the current
    /// rip. Tracks a *different* failure mode from `readErrorCount` —
    /// these are cases where the drive returned data successfully but the
    /// data itself fails validation (MSG:2002 "source file corrupt or
    /// invalid at offset", MSG:2017 "Hash check failed", MSG:2018 "Too
    /// many hash check errors"). Persisted onto `Job.ripCorruptionEvents`
    /// for History display.
    ///
    /// Why separate from `readErrorCount`?
    /// - **Read errors** (MSG:2003) usually point at the **drive** — the
    ///   laser couldn't physically read a sector. Mitigation: slower drive
    ///   speed, clean lens, replace drive.
    /// - **Corruption events** (MSG:2002 / 2017 / 2018) usually point at
    ///   the **disc** — surface scratches, bit-rot, smudges. Mitigation:
    ///   clean the disc, replace the disc. A high corruption count on a
    ///   brand-new disc is more likely a drive problem though.
    ///
    /// Tracking them separately lets the user pattern-match across discs:
    /// "every disc has corruption at offset ~2 GB" = drive at fault;
    /// "this one disc has corruption everywhere but others are clean" =
    /// disc at fault. This is exactly the diagnostic a single combined
    /// count can't surface.
    @Published var corruptionEventCount: Int = 0
    /// v3.11.12: per-event byte offsets where MSG:2003 read errors fired
    /// during the current rip. Capped at `readErrorOffsetCap` per rip so
    /// the persisted JSON on `Job` stays bounded for runaway-error
    /// scenarios. Persisted onto `Job.readErrorOffsets` so the Drive
    /// Health pane can analyse offset clustering across all discs —
    /// errors clustering in a narrow range across MULTIPLE different
    /// discs is the smoking gun for a drive laser-tracking fault.
    @Published var readErrorOffsets: [Int64] = []
    /// v3.7.2: most-recent informational MakeMKV log line, surfaced as a
    /// caption beneath the rip status. Filters out high-frequency progress
    /// ticks (PRGV/PRGC/PRGT) and structural data lines (DRV/CINFO/TINFO/SINFO).
    /// Lets the impatient user see *something* moving during rip startup.
    @Published var lastInformationalMakeMKVLine: String?
    /// v3.7.2: when the current rip's MakeMKV process was launched. Used by
    /// the UI to show an "elapsed" counter while in startup phase.
    /// Reset between titles. Nil when not ripping.
    @Published var ripStartedAt: Date?

    /// Per-title intent (Movie / Episode / Edition / Extra). Defaults to .movie when unset.
    @Published var titleIntents: [Int: JobIntent] = [:]
    /// v4.0.5: per-disc TV/Movie mode override. When `.auto`, the
    /// existing heuristic decides (looksLikeTVSeason + TMDb media
    /// type). When `.tv` or `.movie`, the user's choice wins regardless
    /// of the heuristic — solves edge cases like Bluey (short-form
    /// children's TV that wouldn't pass the auto-detect cleanly
    /// even with the v4.0.5 widened window) and short DVD movies
    /// that happen to have 4+ similar-runtime extras.
    ///
    /// Reset to `.auto` whenever a new disc is detected. The picker
    /// is in the main window toolbar so the user can set it before
    /// the scan starts.
    @Published var scanMode: DiscScanMode = .auto
    /// v4.0.6: when the size-based main-feature pick is far from
    /// TMDb's runtime for this movie AND a closer title exists on
    /// the disc, surface a banner so the user can confirm. We don't
    /// auto-override — for Extended-Edition releases the longer cut
    /// IS the main feature and TMDb's theatrical runtime would
    /// (correctly!) flag a mismatch. The user decides which is right.
    ///
    /// Populated in `scanDisc` after both `autoLabel` and `lookupTMDb`
    /// have run. `nil` when no mismatch detected, no TMDb runtime
    /// available, or the user dismissed it for this scan.
    @Published var mainFeatureRuntimeMismatch: MainFeatureMismatch?
    /// v4.0.15: pending "Apply known disc map?" prompt. Set by
    /// `scanDisc` when `KnownDiscRegistry.lookup` matches the scanned
    /// disc and the user hasn't already declined it for the same
    /// fingerprint this session. Cleared by `applyKnownDiscMap` (which
    /// applies the map) or `declineKnownDiscMap` (which records the
    /// decline).
    @Published var pendingKnownDiscMap: KnownDiscMap?
    /// v4.0.15: who currently owns the per-title assignments. When set
    /// to `.knownMap`, late-arriving async writers (TMDb runtime
    /// matching, TVEpisodePicker auto-resequence) step aside so the
    /// curated map isn't clobbered. Reset to `.automatic` at the top
    /// of every scan and when the user explicitly picks a different
    /// TMDb match via `selectDiscMatch`.
    @Published private(set) var assignmentSource: AssignmentSource = .automatic
    /// v4.0.15: per-session memory of "user declined the known map for
    /// this disc fingerprint". Suppresses re-prompts on re-scan after
    /// drive hiccups. Key format: `<fingerprint>::<mapId>`.
    private var declinedKnownDiscMaps: Set<String> = []
    /// v3.12.0: per-title audio track selection. Outer key is title id,
    /// inner set holds the MakeMKV stream IDs of audio tracks the user
    /// wants included in the encode. Empty set means "use HandBrake
    /// default" (all-audio) — the natural-default starting state until
    /// the user explicitly toggles something. Reset on scan; populated
    /// to all-included when a scan reports per-title audio tracks.
    @Published var selectedAudioTracks: [Int: Set<Int>] = [:]
    /// v3.12.0: per-title subtitle track selection. Same shape and
    /// semantics as `selectedAudioTracks`.
    @Published var selectedSubtitleTracks: [Int: Set<Int>] = [:]
    /// Per-title edition label (e.g. "Theatrical", "Director's Cut"). Used only when intent == .edition.
    @Published var titleEditionLabels: [Int: String] = [:]
    /// Per-title TMDb search override. When set (and intent == .movie), the title is queued
    /// with this name as the search query instead of the disc name. Used for collection discs
    /// where each title is a different movie (e.g. Saw 1+2+3 on one disc).
    @Published var titleNameOverrides: [Int: String] = [:]
    /// Per-title TV episode assignment. Populated by the v3.3.0 episode picker UI;
    /// `RipViewModel.ripSelected` reads this when calling onRipComplete to set
    /// `Job.{seasonNumber, episodeNumber, episodeTitle}`. Empty today.
    @Published var titleEpisodeAssignments: [Int: TitleEpisodeAssignment] = [:]

    func intent(for titleId: Int) -> JobIntent { titleIntents[titleId] ?? .movie }
    func editionLabel(for titleId: Int) -> String { titleEditionLabels[titleId] ?? "" }
    func nameOverride(for titleId: Int) -> String { titleNameOverrides[titleId] ?? "" }
    func episodeAssignment(for titleId: Int) -> TitleEpisodeAssignment? { titleEpisodeAssignments[titleId] }

    private let config: AppConfig
    private let makemkv: MakeMKVService
    private let discord: DiscordService
    private let stagingService = StagingService()
    private var runningTask: Task<Void, Never>?
    /// TMDb match for the current disc. Published so the rip hero / queue rows can
    /// observe and update reactively if the user picks a different match mid-rip.
    @Published private(set) var cachedMediaResult: MediaResult?

    /// v4.0.14: called when a rip completes, with the full payload
    /// the queue needs to enqueue an encode→organize→publish job.
    /// See `CompletedRip` for field semantics.
    var onRipComplete: ((CompletedRip) -> Void)?

    var minDuration: Int { config.minDuration }

    /// Forwards a raw makemkvcon output line to both the in-app log panel
    /// (`logLines`) and the persistent file log. Filters out the high-frequency
    /// progress ticks (`PRGV`/`PRGC`/`PRGT`) — they'd otherwise dominate the
    /// log file (~10 lines/sec during a rip). Everything else, especially
    /// `MSG:` rows and `Error` lines, is preserved for post-mortem analysis.
    ///
    /// v3.7.2 also: parses MakeMKV's MSG codes during rip startup to keep
    /// `startupPhase` in sync, and captures the most-recent informational
    /// MSG line into `lastInformationalMakeMKVLine` so the UI can show it
    /// as a caption.
    @MainActor
    private func appendMakeMKVLog(_ line: String) {
        logLines.append(line)
        // Progress ticks: don't log, but PRGV moves the startup phase to
        // .ripping if we haven't already seen it.
        if line.hasPrefix("PRGV:") {
            if case .ripping = startupPhase {} else {
                startupPhase = .ripping
            }
            return
        }
        if line.hasPrefix("PRGC:") || line.hasPrefix("PRGT:") {
            return
        }
        FileLogger.shared.info("makemkv", line)
        // Update startup phase from MSG codes. Best-effort: a missed code
        // just means the UI shows a less-specific status, never an error.
        Self.advanceStartupPhase(&startupPhase, fromLine: line)
        // v3.11.5: count read errors. Pure helper makes this testable.
        if Self.isReadErrorLine(line) {
            readErrorCount += 1
            // v3.11.12: also capture the byte offset where the error fired,
            // up to a cap so a runaway rip can't bloat the persisted Job.
            if let offset = Self.extractReadErrorOffset(line),
               readErrorOffsets.count < Self.readErrorOffsetCap {
                readErrorOffsets.append(offset)
            }
            // Crossing the threshold (default 5) flips the suggest banner.
            // Idempotent once set — stays true until dismissed or next scan.
            if readErrorCount >= Self.readErrorSuggestThreshold {
                suggestLowerDriveSpeed = true
            }
        }
        // v3.11.7: count data-corruption events. Same parse-and-bump pattern
        // but a different failure class — see the corruptionEventCount doc
        // comment for the drive-vs-disc separation rationale.
        if Self.isCorruptionLine(line) {
            corruptionEventCount += 1
        }
        // Capture informational caption lines. Skip raw structure rows
        // (DRV/CINFO/TINFO/SINFO) — too noisy and useless to a casual user.
        if let caption = Self.extractInformationalCaption(line) {
            lastInformationalMakeMKVLine = caption
        }
    }

    /// v4.0.3: copy a freshly-staged .extra raw rip to the NAS extras
    /// folder. Best-effort — failure is logged but doesn't fail the
    /// rip (the file is still on local output, the user just has to
    /// manually move it).
    ///
    /// Destination layout (Plex convention):
    ///   * Movies: `<nasMoviesPath>/<Movie Title (Year)>/extras/<file>.mkv`
    ///   * TV     : `<nasTvPath>/<Show Title>/extras/<file>.mkv`
    ///
    /// Falls back to `<nasPath>/<cleanDiscName>/extras/<file>.mkv`
    /// when TMDb didn't resolve, so the file still lands SOMEWHERE
    /// on NAS rather than getting stranded.
    private func publishExtraToNAS(localFile: URL, info: DiscInfo) async {
        let isTV = info.looksLikeTVSeason
            || cachedMediaResult?.mediaType == "tv"
        let nasBase = isTV ? config.nasTvPath : config.nasMoviesPath
        guard !nasBase.isEmpty else {
            FileLogger.shared.warn("rip-vm",
                "extras-to-NAS: no \(isTV ? "TV" : "movies") NAS path configured, skipping")
            return
        }
        // Folder name: prefer TMDb media title; fall back to cleaned
        // disc name. Movies get `Title (Year)`; TV gets just the show name.
        let folderName: String
        if let media = cachedMediaResult {
            if isTV {
                folderName = OrganizerService.cleanFilename(media.title)
            } else if let year = media.year, year > 0 {
                folderName = "\(OrganizerService.cleanFilename(media.title)) (\(year))"
            } else {
                folderName = OrganizerService.cleanFilename(media.title)
            }
        } else {
            folderName = OrganizerService.cleanFilename(
                info.mediaTitle.isEmpty ? info.name : info.mediaTitle
            )
        }
        let destDir = URL(fileURLWithPath: nasBase)
            .appendingPathComponent(folderName)
            .appendingPathComponent("extras")
        let dest = destDir.appendingPathComponent(localFile.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
            FileLogger.shared.info("rip-vm",
                "extras-to-NAS: copying \(localFile.path) -> \(dest.path)")
            try await stagingService.copyFileKeepingSource(from: localFile, to: dest)
            FileLogger.shared.info("rip-vm",
                "extras-to-NAS: done -> \(dest.path)")
        } catch {
            FileLogger.shared.error("rip-vm",
                "extras-to-NAS: copy failed (\(error.localizedDescription)) — file remains on local at \(localFile.path)")
        }
    }

    /// v4.0.5: apply the user's pre-scan TV/Movie mode override on
    /// top of the heuristic categorization that `DiscInfo.autoLabel`
    /// just produced. The override wins regardless of `looksLikeTVSeason`
    /// (so Bluey-shape discs the heuristic might miss still get
    /// proper TV handling), but the override never reaches into the
    /// per-title bucket logic — non-episode titles still bucket by
    /// runtime as before.
    ///
    /// v4.0.6: compare the size-picked main-feature title against the
    /// TMDb-reported movie runtime. Returns a `MainFeatureMismatch` when:
    ///   * the picked main feature's runtime is > `toleranceSeconds` off TMDb's
    ///   * AND another disc title is at least 60 sec closer to TMDb
    /// Otherwise returns nil (no actionable suggestion).
    ///
    /// Pure logic — no UI, no actor isolation. Easy to test (see
    /// `MainFeaturePickerTests` in ServiceTests.swift).
    nonisolated static func detectMainFeatureMismatch(
        in info: DiscInfo,
        tmdbRuntimeMinutes: Int?,
        toleranceSeconds: Int = 5 * 60
    ) -> MainFeatureMismatch? {
        guard let mins = tmdbRuntimeMinutes, mins > 0 else { return nil }
        let tmdbSeconds = mins * 60
        guard let picked = info.titles.first(where: { $0.category == .mainFeature }) else {
            return nil
        }
        let pickedDelta = abs(picked.durationSeconds - tmdbSeconds)
        guard pickedDelta > toleranceSeconds else { return nil }

        // Find the disc title whose runtime is closest to TMDb's.
        // Restrict to titles plausibly large enough to be a movie
        // (≥ 60 min) so a commentary-bonus exactly the runtime
        // doesn't get suggested for a doc-style disc.
        let minPlausibleMovieSeconds = 60 * 60
        let candidates = info.titles.filter { $0.durationSeconds >= minPlausibleMovieSeconds }
        guard let best = candidates.min(by: {
            abs($0.durationSeconds - tmdbSeconds) < abs($1.durationSeconds - tmdbSeconds)
        }) else { return nil }

        // Only suggest if best is meaningfully closer than picked.
        let bestDelta = abs(best.durationSeconds - tmdbSeconds)
        guard bestDelta + 60 < pickedDelta else { return nil }
        // And the suggestion must not be the same title we already picked.
        guard best.id != picked.id else { return nil }

        return MainFeatureMismatch(
            tmdbRuntimeSeconds: tmdbSeconds,
            pickedTitleId: picked.id,
            pickedRuntimeSeconds: picked.durationSeconds,
            suggestedTitleId: best.id,
            suggestedRuntimeSeconds: best.durationSeconds
        )
    }

    /// v4.0.6: user clicked "Use TMDb match" on the mismatch banner.
    /// Swaps categories: the suggested title becomes .mainFeature,
    /// the previously-picked title falls back to .alternateCut (most
    /// common case: theatrical-vs-extended on the same disc). Clears
    /// the mismatch so the banner dismisses.
    func acceptMainFeatureMismatchSuggestion() {
        guard let mismatch = mainFeatureRuntimeMismatch, var info = discInfo else { return }
        for i in info.titles.indices {
            if info.titles[i].id == mismatch.pickedTitleId {
                info.titles[i].category = .alternateCut
                info.titles[i].label = TitleCategory.alternateCut.displayLabel
            } else if info.titles[i].id == mismatch.suggestedTitleId {
                info.titles[i].category = .mainFeature
                info.titles[i].label = TitleCategory.mainFeature.displayLabel
            }
        }
        discInfo = info
        mainFeatureRuntimeMismatch = nil
        FileLogger.shared.info("rip-vm",
            "main-feature mismatch: user accepted swap to title \(mismatch.suggestedTitleId)")
    }

    /// v4.0.6: user clicked dismiss on the mismatch banner. Common
    /// case: an Extended-Edition disc where the longer cut IS what
    /// the user wants as the main feature.
    func dismissMainFeatureMismatch() {
        if let mismatch = mainFeatureRuntimeMismatch {
            FileLogger.shared.info("rip-vm",
                "main-feature mismatch: user kept size-based pick (title \(mismatch.pickedTitleId))")
        }
        mainFeatureRuntimeMismatch = nil
    }

    /// v4.0.5: apply user-selected mode override. When the user
    /// pre-picked TV / Movie before scan, force the categorization
    /// to match — overrides the heuristic.
    ///
    /// `.auto` is a no-op (default). `.tv` promotes every in-window
    /// (5-90 min) title to `.episode`, except the play-all outlier
    /// which falls through to its normal duration bucket. `.movie`
    /// demotes every `.episode` from autoLabel back to its
    /// duration-bucket category, then marks the largest title as
    /// `.mainFeature`.
    private func applyScanModeOverride(to info: inout DiscInfo) {
        switch scanMode {
        case .auto:
            return
        case .tv:
            // Force-categorize every in-window title as .episode,
            // minus the play-all outlier.
            let episodeIds = Set(DiscInfo.trimmedTVCandidates(in: info.titles).map { $0.id })
            for i in info.titles.indices {
                if episodeIds.contains(info.titles[i].id) {
                    info.titles[i].category = .episode
                    info.titles[i].label = TitleCategory.episode.displayLabel
                }
            }
            FileLogger.shared.info("rip-vm",
                "scanMode=.tv: forced \(episodeIds.count) titles to .episode")
        case .movie:
            // Demote any .episode categorization back to duration-
            // bucket. Then pick the largest as .mainFeature.
            var largestIndex = 0
            for i in info.titles.indices {
                if info.titles[i].sizeBytes > info.titles[largestIndex].sizeBytes {
                    largestIndex = i
                }
            }
            for i in info.titles.indices {
                if info.titles[i].category == .episode {
                    // Fall back to duration-bucket using a mini-cascade.
                    let secs = info.titles[i].durationSeconds
                    let cat: TitleCategory
                    switch secs {
                    case 5400...: cat = .bonusFeature
                    case 1800...: cat = .featurette
                    case 300...:  cat = .extra
                    case 60...:   cat = .shortExtra
                    default:      cat = .trailer
                    }
                    info.titles[i].category = cat
                    info.titles[i].label = cat.displayLabel
                }
            }
            info.titles[largestIndex].category = .mainFeature
            info.titles[largestIndex].label = TitleCategory.mainFeature.displayLabel
            FileLogger.shared.info("rip-vm",
                "scanMode=.movie: largest title (id \(info.titles[largestIndex].id)) = mainFeature")
        }
    }

    /// v4.0.2 + v4.0.4: walk titles, find .episode-categorized ones,
    /// assign sequential SxxExx numbers by disc title order, mark
    /// intent as .episode. The user can override per-title via
    /// TVEpisodePicker before clicking Rip.
    ///
    /// v4.0.4 enhancement: when the TMDb media result is a TV show,
    /// fetch the season episode list and use TVEpisodeMatcher to pair
    /// each disc title to its closest-runtime episode. Hugely better
    /// than naive sequential numbering when the disc interleaves
    /// extras/featurettes between episodes (very common — see the
    /// Mortal Kombat Legacy disc that prompted v4.0.4: 16 disc
    /// titles, 9 actual episodes, extras scattered throughout).
    ///
    /// Falls back to the v4.0.2 sequential-by-title-order behavior
    /// when:
    ///   * No TMDb match was found
    ///   * Match is for a movie, not TV
    ///   * Episode list is empty or has no runtime metadata
    ///   * Matcher couldn't pair any disc title to an episode
    ///     (all deltas > maxDeltaSeconds)
    private func autoAssignTvEpisodeNumbers(from info: DiscInfo) {
        let episodeTitles = info.titles.filter { $0.category == .episode }
        guard !episodeTitles.isEmpty else { return }

        // v4.0.4: try TMDb-runtime matching first.
        if let media = cachedMediaResult, media.mediaType == "tv" {
            let season = 1  // disc-detected season default; user can override
            // We need an async API but this function is sync. Spin a
            // Task to fetch the episode list, then come back to MainActor
            // to apply. Keep the sequential fallback in the meantime so
            // the UI doesn't show "no assignments" while the TMDb call
            // is in flight.
            applySequentialAssignment(episodeTitles: episodeTitles, info: info)
            Task { [weak self] in
                guard let self else { return }
                let tmdb = TMDbService(config: config)
                let episodes = await tmdb.getSeasonEpisodes(tvId: media.tmdbId, season: season)
                guard !episodes.isEmpty else { return }
                await MainActor.run {
                    self.applyRuntimeMatchedAssignment(
                        episodeTitles: info.titles.filter { $0.category == .episode },
                        episodes: episodes
                    )
                }
            }
            return
        }

        // No TMDb TV match — fall back to sequential.
        applySequentialAssignment(episodeTitles: episodeTitles, info: info)
    }

    /// v4.0.2 sequential fallback: number disc titles by title id order.
    ///
    /// v4.0.15: no-op when `assignmentSource != .automatic` — a curated
    /// known-disc map (or manual override) owns the assignments and we
    /// must not clobber them with shuffled-disc-incorrect sequential
    /// numbering.
    private func applySequentialAssignment(episodeTitles: [TitleInfo], info: DiscInfo) {
        guard assignmentSource.isAutomatic else {
            FileLogger.shared.info("rip-vm",
                "applySequentialAssignment: skipped — assignmentSource=\(assignmentSource)")
            return
        }
        let sorted = episodeTitles.sorted { $0.id < $1.id }
        for (idx, title) in sorted.enumerated() {
            guard titleEpisodeAssignments[title.id] == nil else { continue }
            titleEpisodeAssignments[title.id] = TitleEpisodeAssignment(
                season: 1,
                episode: idx + 1,
                title: ""
            )
            titleIntents[title.id] = .episode
        }
        FileLogger.shared.info("rip-vm",
            "sequential-assigned S01E01..\(sorted.count) for \(sorted.count) episode-categorized titles")
    }

    /// v4.0.4 runtime-matched assignment: replace any existing
    /// assignments with TMDb-runtime-closest pairings. Disc titles
    /// that didn't find a match within the matcher's tolerance keep
    /// their sequential fallback (so they still flow through the TV
    /// publish pipeline rather than silently disappearing).
    ///
    /// v4.0.15: no-op when `assignmentSource != .automatic`. This is
    /// the race fix — the async Task that calls this can complete
    /// AFTER the user has clicked Apply on a known-disc banner; without
    /// the guard, it would overwrite the curated mapping.
    private func applyRuntimeMatchedAssignment(episodeTitles: [TitleInfo], episodes: [EpisodeInfo]) {
        guard assignmentSource.isAutomatic else {
            FileLogger.shared.info("rip-vm",
                "applyRuntimeMatchedAssignment: skipped — assignmentSource=\(assignmentSource)")
            return
        }
        let matches = TVEpisodeMatcher.match(titles: episodeTitles, episodes: episodes)
        guard !matches.isEmpty else { return }
        for match in matches {
            titleEpisodeAssignments[match.discTitleId] = TitleEpisodeAssignment(
                season: match.episode.seasonNumber,
                episode: match.episode.episodeNumber,
                title: match.episode.name
            )
            titleIntents[match.discTitleId] = .episode
        }
        // Disc titles NOT matched: demote intent from .episode to .extra
        // so they get extras-to-NAS treatment (v4.0.3) instead of being
        // queued as a phantom episode that collides with a real one.
        let matchedTitleIds = Set(matches.map { $0.discTitleId })
        for title in episodeTitles where !matchedTitleIds.contains(title.id) {
            titleEpisodeAssignments.removeValue(forKey: title.id)
            titleIntents[title.id] = .extra
        }
        FileLogger.shared.info("rip-vm",
            "runtime-matched \(matches.count) of \(episodeTitles.count) episode titles via TMDb (avg Δ = \(matches.map(\.deltaSeconds).reduce(0, +) / max(matches.count, 1))s); \(episodeTitles.count - matches.count) unmatched -> .extra")
    }

    /// v3.14.0: apply the first matching `DiscRule` from `AppConfig`
    /// to the just-scanned disc. Mutates RipViewModel + AppConfig
    /// state in place. No-op when no rule matches. Each action is
    /// independently guarded so a rule with only a preset override
    /// doesn't accidentally clobber an intent the user already set.
    private func applyMatchingRule(for info: DiscInfo) {
        let mediaType = cachedMediaResult?.mediaType ?? ""
        guard let rule = DiscRuleMatcher.firstMatch(
            in: config.discRules,
            discName: info.name,
            mediaTitle: info.mediaTitle,
            mediaType: mediaType,
            discType: info.type
        ) else { return }
        FileLogger.shared.info("rip-vm",
            "rule matched: '\(rule.name)' for disc '\(info.name)'")
        if !rule.presetOverride.isEmpty {
            config.defaultPreset = rule.presetOverride
        }
        if !rule.intentOverride.isEmpty,
           let intent = JobIntent(rawValue: rule.intentOverride) {
            // Apply to every selected title.
            for tid in selectedTitles {
                titleIntents[tid] = intent
            }
        }
        if rule.driveSpeedOverride > 0 {
            config.makemkvReadSpeed = rule.driveSpeedOverride
        }
    }

    /// v3.11.6: how many MSG:2003 read errors trigger the "try slower drive
    /// speed" banner. 5 is a reasonable balance — single transient errors
    /// are routine on used media (don't pester the user); persistent
    /// per-sector failures (5+ in one rip) signal a disc or drive issue
    /// worth pausing for.
    static let readErrorSuggestThreshold = 5

    /// v3.12.0: convert the user's per-title audio track selection
    /// (keyed by MakeMKV stream IDs) into the 1-indexed ordinal
    /// positions HandBrake expects on `--audio`. The ordinal is the
    /// stream's position within the title's audioTracks array.
    ///
    /// Returns nil when:
    ///   * The title has no audio tracks (don't constrain HandBrake), OR
    ///   * Every audio track is selected (passing nil lets HandBrake's
    ///     `--all-audio` auto-fallback handle codec compatibility).
    ///
    /// Visible as `internal` so unit tests can validate the mapping.
    func audioOrdinals(forTitle titleId: Int, in info: DiscInfo) -> [Int]? {
        guard let title = info.titles.first(where: { $0.id == titleId }) else { return nil }
        let tracks = title.audioTracks
        guard !tracks.isEmpty else { return nil }
        let selectedIds = selectedAudioTracks[titleId] ?? Set(tracks.map { $0.id })
        if selectedIds.count == tracks.count { return nil }
        var ordinals: [Int] = []
        for (idx, track) in tracks.enumerated() where selectedIds.contains(track.id) {
            ordinals.append(idx + 1)
        }
        return ordinals.isEmpty ? nil : ordinals
    }

    /// v3.12.0: same as `audioOrdinals` but for subtitles.
    func subtitleOrdinals(forTitle titleId: Int, in info: DiscInfo) -> [Int]? {
        guard let title = info.titles.first(where: { $0.id == titleId }) else { return nil }
        let tracks = title.subtitleTracks
        guard !tracks.isEmpty else { return nil }
        let selectedIds = selectedSubtitleTracks[titleId] ?? Set(tracks.map { $0.id })
        if selectedIds.count == tracks.count { return nil }
        var ordinals: [Int] = []
        for (idx, track) in tracks.enumerated() where selectedIds.contains(track.id) {
            ordinals.append(idx + 1)
        }
        return ordinals.isEmpty ? nil : ordinals
    }


    /// v3.11.6: pure check for whether a MakeMKV log line represents a
    /// single read-error event worth counting. MSG:2003 = "Posix error"
    /// raw read failure at a specific offset (one per failed sector).
    /// MSG:2022 = end-of-rip summary ("Encountered N read errors") — we
    /// deliberately ignore that one because the per-event MSG:2003 lines
    /// have already given us the count, and counting both would double.
    static func isReadErrorLine(_ line: String) -> Bool {
        line.hasPrefix("MSG:2003")
    }

    /// v3.11.12: how many MSG:2003 offsets we capture per rip before
    /// dropping further ones. 50 is enough to characterise the pattern
    /// (cluster vs scatter) without bloating persisted JSON on a runaway
    /// disc that fires thousands of read errors.
    static let readErrorOffsetCap = 50

    /// v3.11.12: extract the byte offset from a MSG:2003 line, or nil if
    /// the line isn't a MSG:2003 or the offset can't be parsed.
    ///
    /// MakeMKV emits MSG:2003 lines in this exact shape:
    ///
    ///     MSG:2003,0,3,"Error 'Posix error - Input/output error' \
    ///     occurred while reading '/dev/rdisk4' at offset '2083123200'", \
    ///     "Error '%1' occurred while reading '%2' at offset '%3'", \
    ///     "Posix error - Input/output error","/dev/rdisk4","2083123200"
    ///
    /// The offset appears twice: once inside the human message (with
    /// single quotes around it), and once as the last comma-separated
    /// parameter (also quoted). We parse the human-message instance
    /// because it's more positionally predictable (always preceded by
    /// the literal string "at offset '") and forgives reordering of
    /// trailing parameters in future MakeMKV versions.
    static func extractReadErrorOffset(_ line: String) -> Int64? {
        guard line.hasPrefix("MSG:2003") else { return nil }
        let marker = "at offset '"
        guard let markerRange = line.range(of: marker) else { return nil }
        let after = line[markerRange.upperBound...]
        guard let closeQuote = after.firstIndex(of: "'") else { return nil }
        let digits = String(after[after.startIndex..<closeQuote])
        return Int64(digits)
    }

    /// v3.11.7: pure check for whether a MakeMKV log line represents a
    /// single data-corruption event. Three closely-related MSG codes:
    ///   * `MSG:2002` — "The source file '...' is corrupt or invalid at
    ///     offset X, attempting to work around" — fired per discovered
    ///     bad chunk during decode.
    ///   * `MSG:2017` — "Hash check failed for file ... at offset Y,
    ///     file is corrupt" — fired per failed crypto-hash verification.
    ///   * `MSG:2018` — "Too many hash check errors in file ..." —
    ///     fired ONCE when MakeMKV gives up retrying that file.
    ///
    /// We count all three because they each tell the user something
    /// different (per-chunk vs hash-failed vs gave-up) and seeing a
    /// 2018 alone without 2002/2017 leading up to it would be confusing.
    /// 2018 is rare and bounded so it doesn't materially skew the count.
    ///
    /// Intentionally excluded:
    ///   * `MSG:4009` "Too many AV synchronization issues" — informational,
    ///     usually downstream of 2002/2017. Counting it would double-count.
    ///   * `MSG:2003` Posix I/O — see `isReadErrorLine` (drive-side).
    static func isCorruptionLine(_ line: String) -> Bool {
        line.hasPrefix("MSG:2002")
            || line.hasPrefix("MSG:2017")
            || line.hasPrefix("MSG:2018")
    }

    /// v3.11.6: build the per-disc-unique scratch folder name used during
    /// rip + encode. Appends a short disc-fingerprint suffix so two
    /// simultaneously queued rips with the same human-readable name can
    /// never share a folder (which previously caused a sibling-rip
    /// wipeout when the first job's publish cleanup touched the shared
    /// parent dir — see v3.11.6 changelog).
    ///
    /// The suffix is enclosed in `[]` rather than `()` to avoid clashing
    /// with year-bearing names like `Mortal Kombat (1995)`. The final NAS
    /// destination folder name is **not** affected by this suffix — the
    /// organize step renames the file to its clean form before publish,
    /// and PublishService uses the organized dir's name (no suffix).
    ///
    /// Suffix length: 12 hex chars = 48 bits of entropy → birthday
    /// collisions only become non-negligible above a few million queued
    /// discs in one session, which is well past any realistic workload.
    static func scratchFolderName(cleanName: String, info: DiscInfo) -> String {
        let fp = DiscFingerprintService.fingerprint(info)
        let suffix = String(fp.prefix(12))
        return "\(cleanName) [\(suffix)]"
    }

    /// Pure parser for the rip-startup phase machine. Inputs a current phase
    /// and a single MakeMKV log line; mutates the phase if the line signals
    /// a transition. Visible-for-tests so unit tests can drive the FSM
    /// without spinning up a full RipViewModel + MakeMKV process.
    static func advanceStartupPhase(_ phase: inout RipStartupPhase, fromLine line: String) {
        // Once we've reached .ripping, no further MSG can move us back.
        if case .ripping = phase { return }
        if line.hasPrefix("MSG:1011") {
            // "Using LibreDrive mode" — drive auth handshake
            phase = .openingDrive
        } else if line.hasPrefix("MSG:2010") {
            // "Optical drive opened in OS access mode"
            phase = .openingDrive
        } else if line.hasPrefix("MSG:3007") {
            // "Using direct disc access mode" — title walk is starting
            if phase != .readingDiscStructure {
                phase = .readingDiscStructure
            }
        } else if line.hasPrefix("DRV:") || line.hasPrefix("CINFO:") || line.hasPrefix("TINFO:") || line.hasPrefix("SINFO:") {
            // Structure walk in progress
            switch phase {
            case .notStarted, .startingProcess, .openingDrive:
                phase = .readingDiscStructure
            default:
                break
            }
        } else if line.hasPrefix("MSG:5014") {
            // "Saving N titles into directory ..." — extract title id if present
            // Format: MSG:5014,131072,2,"Saving 1 titles into directory ...","..."
            // The structured fields don't directly include a title id, but we
            // can extract from the saving-title message. For now record that
            // we've moved past structure-reading.
            phase = .preparingTitle(extractTitleIdFromSaving(line) ?? -1)
        }
    }

    /// Extract a title-id from `MSG:5014` if it's discoverable. Heuristic;
    /// returns nil if not present.
    private static func extractTitleIdFromSaving(_ line: String) -> Int? {
        // Look for "title #N" or "title NN" inside the message string.
        if let r = line.range(of: #"title\s*#?(\d+)"#, options: .regularExpression) {
            let match = String(line[r])
            let digits = match.filter { $0.isNumber }
            return Int(digits)
        }
        return nil
    }

    /// Pull a human-readable caption out of a MakeMKV log line. Returns nil
    /// for lines that aren't worth showing in the UI (raw structure, progress
    /// ticks, malformed). Visible-for-tests.
    static func extractInformationalCaption(_ line: String) -> String? {
        if line.hasPrefix("DRV:") || line.hasPrefix("CINFO:")
            || line.hasPrefix("TINFO:") || line.hasPrefix("SINFO:")
            || line.hasPrefix("PRGV:") || line.hasPrefix("PRGC:")
            || line.hasPrefix("PRGT:") {
            return nil
        }
        if line.hasPrefix("MSG:") {
            // Format: MSG:CODE,FLAGS,COUNT,"MESSAGE","FORMAT",arg1,arg2,...
            // The first quoted string is a fully-formatted human message.
            // Extract it for display.
            if let firstQ = line.firstIndex(of: "\"") {
                let after = line.index(after: firstQ)
                if let closing = line[after...].firstIndex(of: "\"") {
                    let msg = String(line[after..<closing])
                    if !msg.isEmpty { return msg }
                }
            }
        }
        return nil
    }

    init(config: AppConfig = .shared) {
        self.config = config
        self.makemkv = MakeMKVService(config: config)
        self.discord = DiscordService(config: config)
        cleanupOrphanedRip()
        detectDisc()
    }

    /// If a rip (or its post-rip staging copy) was in flight when the app exited
    /// or crashed, clean up the partial files left behind based on the persisted
    /// `InFlightRip.phase`.
    ///
    /// `.ripping`: MakeMKV was writing into `ripFile` — guaranteed incomplete.
    /// Delete it and any empty parent dir.
    ///
    /// `.staging`: `StagingService` was copying `ripFile` -> `stagingDest`.
    /// Delete `stagingDest.partial` (always partial). Also delete `stagingDest`
    /// if its size doesn't match the source — it's an interrupted rename.
    /// `ripFile` is the authoritative copy and stays.
    private func cleanupOrphanedRip() {
        guard let inFlight = config.inFlightRip else { return }
        let fm = FileManager.default
        switch inFlight.phase {
        case .ripping:
            let path = inFlight.ripFile
            // v3.11.6: previously we required `titleId == -1` (legacy
            // migration) to walk-for-partials. That meant a crash mid-rip
            // with a real titleId left us blindly doing
            // `removeItem(atPath: path)` on what is actually the rip
            // **directory** (we persist the dir as ripFile because the
            // exact filename isn't known until MakeMKV reports it). This
            // could wipe successful prior-title rips on a multi-title
            // disc, or another job's rip if a future scratch-folder
            // collision occurred. Fix: whenever `path` resolves to a
            // directory, always walk it for zero-byte partials and never
            // recursive-delete the dir itself. The narrow file case is
            // still handled below.
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: path, isDirectory: &isDir) {
                if isDir.boolValue {
                    if let entries = try? fm.contentsOfDirectory(atPath: path) {
                        for entry in entries where entry.hasSuffix(".mkv") {
                            let entryPath = (path as NSString).appendingPathComponent(entry)
                            if let attrs = try? fm.attributesOfItem(atPath: entryPath),
                               (attrs[.size] as? Int64) == 0 {
                                try? fm.removeItem(atPath: entryPath)
                                FileLogger.shared.warn("rip-vm", "removed zero-byte partial after crash: \(entryPath)")
                            }
                        }
                    }
                } else {
                    try? fm.removeItem(atPath: path)
                    FileLogger.shared.warn("rip-vm", "cleaned up partial rip from previous session: \(path)")
                    let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
                    if let contents = try? fm.contentsOfDirectory(atPath: dir.path), contents.isEmpty {
                        try? fm.removeItem(at: dir)
                    }
                }
            }
        case .staging:
            if let dest = inFlight.stagingDest {
                let partial = dest + ".partial"
                if fm.fileExists(atPath: partial) {
                    try? fm.removeItem(atPath: partial)
                    FileLogger.shared.warn("rip-vm", "cleaned up partial staging copy: \(partial)")
                }
                // If a stale `dest` exists but its size doesn't match the source,
                // it's a truncated/interrupted rename — drop it.
                if fm.fileExists(atPath: dest),
                   let destAttrs = try? fm.attributesOfItem(atPath: dest),
                   let destSize = destAttrs[.size] as? Int64,
                   let srcAttrs = try? fm.attributesOfItem(atPath: inFlight.ripFile),
                   let srcSize = srcAttrs[.size] as? Int64,
                   destSize != srcSize {
                    try? fm.removeItem(atPath: dest)
                    FileLogger.shared.warn("rip-vm", "cleaned up size-mismatched staging dest: \(dest)")
                }
            }
            // ripFile is the authoritative copy — leave it; the user can retry
            // and the staging step will pick up where it left off.
        }
        config.inFlightRip = nil
    }

    func detectDisc() {
        Task.detached {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/drutil")
            proc.arguments = ["status"]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            try? proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()

            guard let output = String(data: data, encoding: .utf8) else { return }

            var discType = ""
            var discName = ""

            for line in output.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("Type:") {
                    let value = trimmed.replacingOccurrences(of: "Type:", with: "").trimmingCharacters(in: .whitespaces)
                    if value.lowercased().contains("bd") || value.lowercased().contains("blu") {
                        discType = "Blu-ray"
                    } else if value.lowercased().contains("dvd") {
                        discType = "DVD"
                    } else if !value.isEmpty {
                        discType = value
                    }
                }
                if trimmed.hasPrefix("Name:") && trimmed.contains("/dev/") {
                    // Get volume name from diskutil
                    let devPath = trimmed.components(separatedBy: .whitespaces).last ?? ""
                    if !devPath.isEmpty {
                        let duProc = Process()
                        duProc.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
                        duProc.arguments = ["info", devPath]
                        let duPipe = Pipe()
                        duProc.standardOutput = duPipe
                        try? duProc.run()
                        let duData = duPipe.fileHandleForReading.readDataToEndOfFile()
                        duProc.waitUntilExit()
                        if let duOutput = String(data: duData, encoding: .utf8) {
                            for duLine in duOutput.components(separatedBy: .newlines) {
                                if duLine.contains("Volume Name:") {
                                    discName = duLine.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces) ?? ""
                                }
                            }
                        }
                    }
                }
            }

            await MainActor.run { [weak self, discType, discName] in
                guard let self else { return }
                let isNewDisc = !discType.isEmpty && self.detectedDiscType.isEmpty
                self.detectedDiscType = discType
                self.detectedDiscName = discName
                if !discType.isEmpty {
                    let name = discName.isEmpty ? "" : " — \(discName)"
                    self.statusText = "\(discType) detected\(name)"
                    if isNewDisc {
                        // New disc inserted — clear the "just finished" celebration.
                        self.lastCompletedMedia = nil
                        self.lastCompletedDiscName = nil
                    }
                } else {
                    self.statusText = "No disc detected"
                }
            }
        }
    }

    /// Looks up the disc on TMDb, sets `cachedMediaResult` and `info.mediaTitle` on
    /// success, or `unidentifiedDiscName` (for the banner) on miss. Also populates
    /// `discCandidates` with the top results so the user can swap the auto-pick.
    /// Used by both manual scan and Full Auto.
    private func lookupTMDb(for info: inout DiscInfo) async {
        FileLogger.shared.info("rip-vm",
            "lookupTMDb: entry — info.name='\(info.name)' (type=\(info.type), \(info.titles.count) titles)")
        let tmdb = TMDbService(config: config)
        let results = await tmdb.searchMedia(query: info.name)
        self.discCandidates = Array(results.prefix(5))
        if var match = results.first {
            FileLogger.shared.info("rip-vm",
                "lookupTMDb: top match '\(match.displayTitle)' (\(match.mediaType), tmdbId=\(match.tmdbId)) — enriching")
            if match.mediaType == "movie", let details = await tmdb.getMovieDetails(tmdbId: match.tmdbId) {
                match = details
            } else if match.mediaType == "tv", let details = await tmdb.getTvDetails(tmdbId: match.tmdbId) {
                match = details
            }
            info.mediaTitle = match.displayTitle
            self.cachedMediaResult = match
            self.unidentifiedDiscName = nil
            // Auto-classify titles when the disc resolves to a TV series — saves
            // the user clicking "Episode" N times for a season disc. v3.3.0's
            // picker UI will then populate season/episode/title per row.
            applyAutoIntent(for: match)
            FileLogger.shared.info("rip-vm",
                "lookupTMDb: enriched match set — cachedMediaResult='\(match.displayTitle)' (\(match.mediaType))")
        } else {
            FileLogger.shared.warn("rip-vm",
                "lookupTMDb: no results from TMDb for '\(info.name)' — surfacing unidentified-disc banner")
            await discord.notifyError("⚠️ TMDb could not identify disc: \(info.name)")
            NotificationService.shared.notify(title: "Unknown Disc", message: info.name)
            self.cachedMediaResult = nil
            self.unidentifiedDiscName = info.name
        }
    }

    /// Replace the auto-picked TMDb match with one of the alternatives, or with
    /// a result from a manual search. Updates `discInfo.mediaTitle` so the UI
    /// header reflects the choice and the rip uses the right folder name.
    ///
    /// v4.0.15: if a known-disc map is in force, the user explicitly
    /// choosing a different TMDb match means they're overriding our
    /// curated mapping. Drop back to `.automatic` source so subsequent
    /// auto-assignments can flow.
    func selectDiscMatch(_ match: MediaResult) {
        if !assignmentSource.isAutomatic {
            FileLogger.shared.info("rip-vm",
                "selectDiscMatch: user picked alternate match — releasing assignmentSource (\(assignmentSource) -> .automatic)")
            assignmentSource = .automatic
            pendingKnownDiscMap = nil
        }
        Task {
            let tmdb = TMDbService(config: config)
            var enriched = match
            if match.mediaType == "movie", let d = await tmdb.getMovieDetails(tmdbId: match.tmdbId) {
                enriched = d
            } else if match.mediaType == "tv", let d = await tmdb.getTvDetails(tmdbId: match.tmdbId) {
                enriched = d
            }
            cachedMediaResult = enriched
            unidentifiedDiscName = nil
            applyAutoIntent(for: enriched)
            if var info = discInfo {
                info.mediaTitle = enriched.displayTitle
                discInfo = info
            }
            FileLogger.shared.info("rip-vm", "user picked disc match: \(enriched.displayTitle)")
        }
    }

    /// v4.0.15: apply a curated known-disc map (e.g. Bluey BBC slipcover
    /// BD). Computed by `KnownDiscRegistry.resolve` as a pure plan, then
    /// installed atomically on the viewmodel state. Switches
    /// `assignmentSource` to `.knownMap` so the existing async
    /// assignment writers (sequential + TMDb runtime) step aside.
    ///
    /// Skipped titles (e.g. French-only duplicates on Bluey BDs) are
    /// removed from `selectedTitles`, their `titleEpisodeAssignments`
    /// entry cleared, and their `titleIntents` demoted to `.extra` so
    /// they show up correctly in the titles table even when deselected.
    ///
    /// Also overrides `cachedMediaResult.displayTitle` with the map's
    /// `showName` (and `info.mediaTitle`) so the publish pipeline uses
    /// the curated name regardless of what TMDb returned.
    func applyKnownDiscMap(_ map: KnownDiscMap) {
        guard let info = discInfo else {
            FileLogger.shared.warn("rip-vm",
                "applyKnownDiscMap: no discInfo — ignoring")
            return
        }
        let plan = KnownDiscRegistry.resolve(for: info, map: map)

        // v4.0.16: the known map is now authoritative — wipe any
        // sequential-assigned or TMDb-runtime-matched assignments first
        // so unmapped titles can't keep stale S01EXX labels written by
        // the async writers between scan completion and Apply click.
        // Then re-install only what the map says.
        titleEpisodeAssignments = [:]

        // Install assignments + intents for mapped titles.
        for (titleId, assignment) in plan.assignments {
            titleEpisodeAssignments[titleId] = assignment
        }
        for (titleId, intent) in plan.intents {
            titleIntents[titleId] = intent
        }
        // v4.0.16: claim authority over which titles are episodes.
        // Any title currently classified as .episode that the map
        // doesn't cover gets demoted to .extra — otherwise the disc's
        // bonus content that the auto-classifier promoted to .episode
        // would carry a stale S01EXX label (from sequential-assign or
        // runtime-match) into the rip queue and Plex library.
        for titleId in plan.unmappedTitleIds where titleIntents[titleId] == .episode {
            titleIntents[titleId] = .extra
        }
        // Deselect skipped titles and clear any stale assignment entries
        // that the sequential fallback may have inserted earlier.
        for titleId in plan.deselectedTitleIds {
            selectedTitles.remove(titleId)
            titleEpisodeAssignments.removeValue(forKey: titleId)
        }
        // Override the disc display name with the curated show name.
        if var updated = discInfo {
            updated.mediaTitle = map.showName
            discInfo = updated
        }

        assignmentSource = .knownMap(id: map.id)
        pendingKnownDiscMap = nil

        let appliedCount = plan.assignments.count
        let skippedCount = plan.deselectedTitleIds.count
        let unmappedCount = plan.unmappedTitleIds.count
        let demotedCount = plan.unmappedTitleIds.filter { titleIntents[$0] == .extra }.count
        FileLogger.shared.info("rip-vm",
            "applyKnownDiscMap: '\(map.id)' applied — \(appliedCount) episodes, \(skippedCount) skipped, \(unmappedCount) unmapped (\(demotedCount) demoted from .episode → .extra), \(plan.missingTitleIds.count) missing title ids")
        if !plan.missingTitleIds.isEmpty {
            FileLogger.shared.warn("rip-vm",
                "applyKnownDiscMap: \(plan.missingTitleIds.count) mapped title ids not present on disc — \(plan.missingTitleIds.sorted())")
        }
    }

    /// v4.0.15: user dismissed the known-disc banner. Records the
    /// decline so a re-scan of the same physical disc doesn't re-prompt.
    func declineKnownDiscMap() {
        guard let map = pendingKnownDiscMap, let info = discInfo else {
            pendingKnownDiscMap = nil
            return
        }
        let fp = DiscFingerprintService.fingerprint(info)
        declinedKnownDiscMaps.insert("\(fp)::\(map.id)")
        pendingKnownDiscMap = nil
        FileLogger.shared.info("rip-vm",
            "declineKnownDiscMap: '\(map.id)' dismissed for fingerprint \(fp) — will not re-prompt this session")
    }

    /// v4.0.15: user already applied a known-disc map but wants to fall
    /// back to the standard automatic flow. Drops `assignmentSource` back
    /// to `.automatic` and clears the cached assignments so the picker
    /// can repopulate them. Does NOT touch `selectedTitles` — if the
    /// user wants the French dupes back, they can re-select them
    /// manually.
    func releaseKnownDiscMap() {
        guard !assignmentSource.isAutomatic else { return }
        FileLogger.shared.info("rip-vm",
            "releaseKnownDiscMap: switching from \(assignmentSource) back to .automatic — clearing curated assignments")
        assignmentSource = .automatic
        titleEpisodeAssignments = [:]
    }

    // MARK: - v4.1.0 — TheDiscDB integration

    /// Look the scanned disc up on TheDiscDB and, if a conservatively-
    /// trusted match comes back, apply its per-title classification on
    /// top of the heuristic labelling. Best-effort and non-fatal: any
    /// miss (toggle off, no candidates, untrusted plan) simply leaves the
    /// existing heuristic state untouched.
    ///
    /// Strategy mirrors the proven PoC: try an exact content-hash lookup
    /// first (cheap, unambiguous when present), then fall back to the
    /// TMDb-id + per-title duration-signature match.
    func applyDiscDbMatch(to info: DiscInfo) async {
        guard config.discDbMatchEnabled else { return }
        // Only act while we still own the assignments — a user action or
        // known-disc map taking over mid-lookup must win.
        guard assignmentSource.isAutomatic else {
            FileLogger.shared.info("rip-vm",
                "discdb: skipped — assignmentSource=\(assignmentSource)")
            return
        }

        let service = TheDiscDBService()
        var candidates: [TheDiscDBDisc] = []
        var exactHash = false

        // Best-effort content hash from the mounted volume. The on-disc
        // file ordering is unverified, so a miss here just falls through.
        let volume = URL(fileURLWithPath: "/Volumes/\(info.name)")
        if let hash = TheDiscDBContentHash.contentHash(forVolumeAt: volume) {
            candidates = await service.lookup(contentHash: hash)
            exactHash = !candidates.isEmpty
            if exactHash {
                FileLogger.shared.info("rip-vm",
                    "discdb: content-hash \(hash) matched \(candidates.count) disc(s)")
            }
        }

        // Fall back to TMDb id (the proven path — most entries have a
        // null content hash).
        if candidates.isEmpty, let media = cachedMediaResult {
            candidates = await service.lookup(tmdbId: media.tmdbId, mediaType: media.mediaType)
        }
        guard !candidates.isEmpty else {
            FileLogger.shared.info("rip-vm", "discdb: no candidates for '\(info.name)'")
            return
        }

        let plan = TheDiscDBMatcher.match(discInfo: info, candidates: candidates, exactHashMatch: exactHash)

        // Re-check ownership AFTER the network awaits — a user/known-map
        // action (or a re-scan) may have intervened.
        guard assignmentSource.isAutomatic, discInfo?.name == info.name, !Task.isCancelled else {
            FileLogger.shared.info("rip-vm",
                "discdb: plan discarded — state changed during lookup (source=\(assignmentSource))")
            return
        }
        guard plan.trusted else {
            FileLogger.shared.info("rip-vm",
                "discdb: match not trusted for '\(info.name)' — \(plan.reason); keeping heuristics")
            return
        }
        applyDiscDbPlan(plan, info: info)
    }

    /// Install a trusted TheDiscDB plan over the heuristic state. Becomes
    /// authoritative for episode numbering (clears stale sequential
    /// assignments and demotes unmatched episode titles to `.extra` so
    /// nothing collides on the same SxxExx). Names are only written for
    /// extras — overriding a movie/episode title's name would null the
    /// cached TMDb result the publish pipeline relies on.
    func applyDiscDbPlan(_ plan: TheDiscDBMatcher.Plan, info: DiscInfo) {
        // Claim ownership first so the pending async TMDb-runtime writer
        // (scheduled by autoAssignTvEpisodeNumbers) no-ops when it fires.
        assignmentSource = .discDb(release: plan.candidate?.releaseSlug ?? "?")

        // Wipe heuristic/sequential episode numbers — DiscDB is now the
        // source of truth and will reinstall only what it matched.
        titleEpisodeAssignments = [:]

        let matchedIds = Set(plan.matches.map { $0.discTitleId })
        let haveCachedMedia = cachedMediaResult != nil
        var named = 0, episodes = 0

        for match in plan.matches {
            let tid = match.discTitleId
            titleIntents[tid] = match.intent

            if match.intent == .episode {
                if let assignment = plan.episodeAssignments[tid] {
                    titleEpisodeAssignments[tid] = TitleEpisodeAssignment(
                        season: assignment.season,
                        episode: assignment.episode,
                        title: assignment.name
                    )
                    episodes += 1
                } else {
                    // Episode intent without a usable number — demote
                    // rather than risk an unnumbered phantom episode.
                    titleIntents[tid] = .extra
                }
            }

            // Names: extras always; movie/edition only when there's no
            // cached TMDb result to flow through (an override nulls it).
            if let name = plan.titleNames[tid], !name.isEmpty {
                let intent = titleIntents[tid] ?? match.intent
                if intent == .extra || ((intent == .movie || intent == .edition) && !haveCachedMedia) {
                    titleNameOverrides[tid] = name
                    named += 1
                }
            }
        }

        // Any title still classified as an episode that DiscDB didn't
        // match has no number now — demote it to a generic extra so it
        // can't collide with a DiscDB-numbered episode.
        var demoted = 0
        for title in info.titles where !matchedIds.contains(title.id) && titleIntents[title.id] == .episode {
            titleIntents[title.id] = .extra
            titleEpisodeAssignments.removeValue(forKey: title.id)
            demoted += 1
        }

        FileLogger.shared.info("rip-vm",
            "discdb: applied '\(plan.candidate?.releaseSlug ?? "?")' — \(plan.matches.count) matched (\(episodes) episodes, \(named) named), \(demoted) unmatched episode(s) demoted; \(plan.reason)")
        for warning in plan.warnings {
            FileLogger.shared.warn("rip-vm", "discdb: \(warning)")
        }
    }
    /// When a TV match is selected, default every selected (or scanned-eligible)
    /// title's intent to `.episode`. When a movie match is selected, switch any
    /// previously-classified episode intents back to `.movie`. Doesn't override
    /// .extra or .edition — user choices stick.
    private func applyAutoIntent(for match: MediaResult) {
        guard let info = discInfo else { return }
        let target: JobIntent = match.mediaType == "tv" ? .episode : .movie
        let opposite: JobIntent = match.mediaType == "tv" ? .movie : .episode
        for title in info.titles {
            let current = titleIntents[title.id] ?? .movie
            // Only flip the auto-defaulted side; preserve .extra and .edition.
            if current == opposite || titleIntents[title.id] == nil {
                titleIntents[title.id] = target
            }
        }
        FileLogger.shared.info("rip-vm", "auto-classified titles as \(target.rawValue) for \(match.mediaType) match")
    }

    /// Re-run the TMDb disc search with a user-supplied query (used when the auto
    /// search returned nothing or wrong results). Populates `discCandidates`.
    func searchDiscMatches(query: String) {
        Task {
            let tmdb = TMDbService(config: config)
            let results = await tmdb.searchMedia(query: query)
            discCandidates = Array(results.prefix(5))
        }
    }

    func scanDisc() {
        guard !isScanning else { return }
        isScanning = true
        statusText = "Scanning disc…"
        logLines = []
        discInfo = nil
        selectedTitles = []
        discCandidates = []
        unidentifiedDiscName = nil
        previousRipMatch = nil
        readErrorCount = 0  // v3.11.5
        suggestLowerDriveSpeed = false  // v3.11.5
        corruptionEventCount = 0  // v3.11.7
        readErrorOffsets = []  // v3.11.12
        titleEpisodeAssignments = [:]  // v4.0.2 — clear stale TV assignments
        titleIntents = [:]  // v4.0.2 — clear stale intent overrides
        mainFeatureRuntimeMismatch = nil  // v4.0.6 — clear prior banner
        pendingKnownDiscMap = nil  // v4.0.15 — clear prior known-disc prompt
        assignmentSource = .automatic  // v4.0.15 — reset assignment ownership

        runningTask = Task {
            // Best-effort: if the user left the tray open with a disc on it,
            // pull it in before scanning. Drives without a motorized tray
            // (most slot-loaders, slim USB units) just no-op.
            await closeDiscTrayBestEffort(reason: "scan")
            do {
                var info = try await makemkv.scanDisc(volumeLabel: detectedDiscName) { [weak self] line in
                    Task { @MainActor in self?.appendMakeMKVLog(line) }
                }

                // Auto-label titles by duration/size
                info.autoLabel()
                // v4.0.5: apply user-selected mode override. When the
                // user pre-picked TV / Movie before scan, force the
                // categorization to match — overrides the heuristic.
                applyScanModeOverride(to: &info)

                await lookupTMDb(for: &info)

                self.discInfo = info
                // v4.0.6: now that TMDb has been consulted, see if the
                // size-based main-feature pick disagrees with the
                // canonical movie runtime. We don't auto-override —
                // Extended-Edition Blu-rays legitimately have the longer
                // cut as the main feature even though TMDb only knows
                // the theatrical runtime. Banner gives the user a one-
                // click swap when the heuristic actually got it wrong.
                if cachedMediaResult?.mediaType == "movie" {
                    self.mainFeatureRuntimeMismatch = Self.detectMainFeatureMismatch(
                        in: info,
                        tmdbRuntimeMinutes: cachedMediaResult?.runtimeMinutes
                    )
                } else {
                    self.mainFeatureRuntimeMismatch = nil
                }
                // Auto-select titles above min duration
                for title in info.titles where title.durationSeconds >= config.minDuration {
                    selectedTitles.insert(title.id)
                }
                // v3.12.0: default all parsed tracks to included so the
                // baseline behavior (encode everything) is preserved
                // until the user explicitly toggles something off. Reset
                // first to clear stale state from the prior scan.
                selectedAudioTracks = [:]
                selectedSubtitleTracks = [:]
                for title in info.titles {
                    if !title.audioTracks.isEmpty {
                        selectedAudioTracks[title.id] = Set(title.audioTracks.map { $0.id })
                    }
                    if !title.subtitleTracks.isEmpty {
                        selectedSubtitleTracks[title.id] = Set(title.subtitleTracks.map { $0.id })
                    }
                }
                // v3.14.0: apply matching per-disc rule (if any) on top
                // of the default selection state. Pure logic — see
                // `DiscRuleMatcher.firstMatch`.
                applyMatchingRule(for: info)
                // v4.0.2: when titles auto-categorized as .episode by
                // DiscInfo.autoLabel, auto-assign sequential S01EXX
                // episode numbers and mark them with .episode intent
                // so they flow through the TV publish pipeline. Stops
                // the all-titles-collide-on-S01E01 bug that left TV-on-
                // disc rips (e.g. Mortal Kombat Legacy 16-episode disc)
                // as bare _tNN.mkv files in scratch. The user can still
                // override season/episode numbers via TVEpisodePicker.
                autoAssignTvEpisodeNumbers(from: info)
                // v4.1.0: consult TheDiscDB for authoritative per-title
                // classification/names/episode numbers. Runs after the
                // heuristic auto-assignment so a trusted match has the
                // final word (and makes the async TMDb-runtime writer
                // defer by flipping assignmentSource). No-op when the
                // toggle is off, the lookup misses, or the match isn't
                // trusted — the heuristic labelling then stands.
                await applyDiscDbMatch(to: info)
                // Check duplicate-rip registry. Compute fingerprint and look
                // it up; surface the prior entry on the model so the UI can
                // banner-warn the user.
                //
                // v3.11.10: if the user explicitly marked this disc for
                // re-rip from the History tab, suppress the banner — they
                // know it's a duplicate and want to re-rip anyway.
                let fp = DiscFingerprintService.fingerprint(info)
                let forcedRerrip = config.forceRerripFingerprints.contains(fp)
                let prior = await RippedDiscRegistry.shared.entry(forFingerprint: fp)
                self.previousRipMatch = forcedRerrip ? nil : prior
                if forcedRerrip {
                    FileLogger.shared.info("rip-vm",
                        "scan: dup banner suppressed because fingerprint is in forceRerripFingerprints (\(info.name))")
                }
                // v4.0.15: now that we have a fingerprint, see if this is a
                // curated known disc (e.g. shuffled Bluey BBC slipcover BDs).
                // Don't re-prompt if the user already declined this map for
                // this physical disc this session.
                if let map = KnownDiscRegistry.lookup(discName: info.name) {
                    let declineKey = "\(fp)::\(map.id)"
                    if !declinedKnownDiscMaps.contains(declineKey) {
                        self.pendingKnownDiscMap = map
                        FileLogger.shared.info("rip-vm",
                            "known-disc map matched: '\(map.id)' for '\(info.name)' — awaiting user confirmation")
                    } else {
                        FileLogger.shared.info("rip-vm",
                            "known-disc map matched '\(map.id)' but previously declined for this fingerprint — not re-prompting")
                    }
                }
                let displayName = info.mediaTitle.isEmpty ? info.name : info.mediaTitle
                statusText = "Scanned: \(displayName) — \(info.titles.count) titles"
                NotificationService.shared.notify(title: "Scan Complete", message: "\(displayName) — \(info.titles.count) titles")
            } catch {
                statusText = "Scan failed: \(error.localizedDescription)"
                errorMessage = error.localizedDescription
                log.error("Scan failed: \(error.localizedDescription)")
                NotificationService.shared.notify(title: "Scan Failed", message: error.localizedDescription)
            }
            isScanning = false
        }
    }

    func ripSelected() {
        guard !selectedTitles.isEmpty, !isRipping, let info = discInfo else { return }
        // v3.11.5: reset error counters at rip start so the count reflects
        // this rip, not whatever happened during the prior scan.
        readErrorCount = 0
        suggestLowerDriveSpeed = false
        corruptionEventCount = 0  // v3.11.7
        readErrorOffsets = []  // v3.11.12
        // v3.11.10: consume any force-re-rip entry for this disc. One-shot
        // semantics — the next time the user inserts this same disc the
        // dup banner + auto-skip return to normal. If we don't have a
        // discInfo yet we just no-op (shouldn't happen since ripSelected
        // requires a scan, but defensive).
        if let info = discInfo {
            let fp = DiscFingerprintService.fingerprint(info)
            if config.forceRerripFingerprints.remove(fp) != nil {
                FileLogger.shared.info("rip-vm",
                    "consumed forceRerrip entry for \(info.name) at rip start")
            }
        }
        isRipping = true
        if config.preventSleep { SleepAssertion.shared.acquire(reason: "AutoRipper rip in progress") }
        ripProgress = 0
        statusText = "Ripping…"

        let titlesToRip = selectedTitles.sorted()
        // v3.11.6: split the "clean" name (user-visible, used for final
        // destination + UI labels) from the "scratch" name (per-disc-unique
        // via a short fingerprint suffix, used only for the temp rip dir
        // so two simultaneously queued rips can never share a folder).
        let cleanName = OrganizerService.cleanFilename(
            info.mediaTitle.isEmpty ? info.name : info.mediaTitle
        )
        let folderName = cleanName  // alias for legacy code paths (UI strings, finalDir, etc.)
        let scratchFolderName = Self.scratchFolderName(cleanName: cleanName, info: info)
        // Where MakeMKV writes raw rips. Defaults to the legacy in-place path
        // (`<outputDir>/<cleanName>`); falls back to the local scratch dir when
        // `ripScratchDir` is configured. v3.11.6: when staging is on, the
        // scratch dir uses the per-disc-unique `scratchFolderName` (with
        // fingerprint suffix) so two queued rips can never share a folder.
        // When staging is off (legacy in-place rip), we keep the clean
        // `folderName` so the user's output drive layout stays untouched.
        // The `outputDir` local variable name is preserved so the existing
        // PRGV / size-monitor code (which uses it heavily below) keeps
        // working unchanged.
        let scratchBase = config.ripScratchDir.isEmpty ? config.outputDir : config.ripScratchDir
        let scratchSubdir = config.ripScratchDir.isEmpty ? folderName : scratchFolderName
        let outputDir = URL(fileURLWithPath: scratchBase)
            .appendingPathComponent(scratchSubdir).path
        // Where the file ends up after staging. Equals `outputDir` when no
        // scratch dir is configured (no-op staging) — equals
        // `<config.outputDir>/<folderName>` (clean, no fingerprint suffix)
        // when staging is on.
        let finalDir = URL(fileURLWithPath: config.outputDir)
            .appendingPathComponent(folderName).path
        let stagingEnabled = !config.ripScratchDir.isEmpty

        runningTask = Task {
            let start = Date()

            // v4.0.12: register the rip dir so per-title publish/cleanup
            // (running in parallel via QueueViewModel) can't delete the
            // directory while subsequent titles in this same rip session
            // are still being written by MakeMKV. Deregistered in the
            // defer below regardless of success/failure.
            ActiveRipDirectories.register(outputDir)
            defer { ActiveRipDirectories.deregister(outputDir) }

            // Initialize per-title status for the hero view: every selected title
            // starts as .queued, transitions to .ripping/.done/.failed below.
            var initial: [Int: TitleRipStatus] = [:]
            for tid in titlesToRip { initial[tid] = .queued }
            titleRipStatuses = initial

            NotificationService.shared.notify(title: "Ripping", message: "\(folderName) — \(titlesToRip.count) title(s)")

            for (idx, tid) in titlesToRip.enumerated() {
                statusText = "Ripping title \(tid) (\(idx + 1)/\(titlesToRip.count))…"
                currentRippingTitleId = tid
                titleRipStatuses[tid] = .ripping(percent: 0)
                activePhase = .ripping
                // v3.7.2: reset startup phase + caption + counter for the
                // new title's rip startup.
                startupPhase = .startingProcess
                lastInformationalMakeMKVLine = nil
                ripStartedAt = Date()
                let totalTitles = titlesToRip.count
                let titleIndex = idx
                let titleStart = Date()
                let expectedSize = info.titles.first(where: { $0.id == tid })?.sizeBytes ?? 0

                // One JobCard per ripped title — covers rip → encode → done for that title.
                let cardName = totalTitles > 1 ? "\(folderName) — title \(tid)" : folderName
                let card = JobCard(discName: cardName,
                                   nasEnabled: config.nasUploadEnabled,
                                   discord: discord)
                await card.start("rip")

                // Tell AppConfig where the partial rip will live so a crash mid-rip
                // can clean up on next launch. The exact ripFile path isn't known
                // until MakeMKV reports it; record the parent dir for now and
                // refine to the actual file path once we have it (see staging
                // transition below).
                config.inFlightRip = InFlightRip(
                    phase: .ripping,
                    titleId: tid,
                    ripFile: outputDir,
                    stagingDest: nil
                )
                let lastPRGV = LastPRGV()

                // File-size fallback: snapshot existing files in outputDir so we can
                // identify the file MakeMKV is currently writing for *this* title.
                // PRGV from MakeMKV is preferred; this kicks in when PRGV is missing.
                let preexisting: Set<String> = {
                    let fm = FileManager.default
                    return Set((try? fm.contentsOfDirectory(atPath: outputDir)) ?? [])
                }()
                let sizeMonitor = Task.detached {
                    let fm = FileManager.default
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(2))
                        // Skip if PRGV updated within the last 4 seconds — it's authoritative.
                        if Date().timeIntervalSince(lastPRGV.timestamp) < 4 { continue }
                        guard expectedSize > 0,
                              let files = try? fm.contentsOfDirectory(atPath: outputDir) else { continue }
                        let newFiles = files.filter { !preexisting.contains($0) && $0.hasSuffix(".mkv") }
                        var sz: Int64 = 0
                        for f in newFiles {
                            let p = (outputDir as NSString).appendingPathComponent(f)
                            if let attrs = try? fm.attributesOfItem(atPath: p),
                               let s = attrs[.size] as? Int64 { sz += s }
                        }
                        let pct = min(Double(sz) / Double(expectedSize), 0.99)
                        await MainActor.run { [weak self] in
                            guard let self else { return }
                            let overall = (Double(titleIndex) + pct) / Double(totalTitles)
                            // Only apply if we'd actually advance the bar (don't go backwards).
                            if overall > self.ripProgress {
                                self.ripProgress = overall
                                self.statusText = "Ripping title \(tid) (\(titleIndex + 1)/\(totalTitles)) — \(Int(pct * 100))% (size)"
                            }
                        }
                    }
                }

                do {
                    let rippedFile = try await makemkv.ripTitle(
                        titleId: tid,
                        outputDir: outputDir,
                        volumeLabel: detectedDiscName.isEmpty ? info.name : detectedDiscName,
                        progressCallback: { [weak self] pct, _ in
                            lastPRGV.touch()
                            Task { @MainActor in
                                guard let self else { return }
                                let overall = (Double(titleIndex) + Double(pct) / 100.0) / Double(totalTitles)
                                self.ripProgress = overall
                                self.statusText = "Ripping title \(tid) (\(titleIndex + 1)/\(totalTitles)) — \(pct)%"
                                self.titleRipStatuses[tid] = .ripping(percent: pct)
                            }
                        },
                        logCallback: { [weak self] line in
                            Task { @MainActor in self?.appendMakeMKVLog(line) }
                        }
                    )
                    sizeMonitor.cancel()

                    // Stage to outputDir ONLY for .extra titles — they keep
                    // their raw rip and never enter the queue pipeline.
                    // Queue-bound jobs (non-extra) skip staging; QueueViewModel
                    // does the local-encode pipeline straight from scratch
                    // and publishes at the end.
                    let titleIntent = intent(for: tid)
                    let needsStaging = stagingEnabled && titleIntent == .extra
                    let file: URL
                    if needsStaging {
                        let dest = URL(fileURLWithPath: finalDir)
                            .appendingPathComponent(rippedFile.lastPathComponent)
                        config.inFlightRip = InFlightRip(
                            phase: .staging,
                            titleId: tid,
                            ripFile: rippedFile.path,
                            stagingDest: dest.path
                        )
                        // Phase shift: hero block now reads "STAGING …%" and the
                        // bar resets so it reflects staging progress, not the
                        // already-100%-rip.
                        activePhase = .staging
                        ripProgress = 0
                        statusText = "Staging title \(tid) (\(titleIndex + 1)/\(totalTitles)) → \(config.outputDir)…"
                        FileLogger.shared.info("rip-vm",
                            "staging title \(tid): \(rippedFile.path) -> \(dest.path)")
                        do {
                            file = try await stagingService.copyAndVerify(
                                from: rippedFile,
                                to: dest,
                                progress: { [weak self] copied, total in
                                    Task { @MainActor in
                                        guard let self else { return }
                                        let stagePct = total > 0 ? Double(copied) / Double(total) : 0
                                        // Combine staging across all titles in the
                                        // disc so the bar advances monotonically.
                                        let overall = (Double(titleIndex) + stagePct) / Double(totalTitles)
                                        if overall > self.ripProgress {
                                            self.ripProgress = overall
                                        }
                                        let pct = Int(stagePct * 100)
                                        self.statusText = "Staging title \(tid) (\(titleIndex + 1)/\(totalTitles)) — \(pct)%"
                                    }
                                }
                            )
                        } catch {
                            // Staging failed — surface as a rip failure for this title.
                            // ripFile is still on local scratch; cleanupOrphanedRip
                            // (next launch) will leave it intact since the .partial
                            // dest is what we explicitly removed below.
                            config.inFlightRip = nil
                            activePhase = .idle
                            titleRipStatuses[tid] = .failed(message: "Staging failed: \(error.localizedDescription)")
                            statusText = "Staging failed: \(error.localizedDescription)"
                            errorMessage = error.localizedDescription
                            log.error("Staging failed for title \(tid): \(error.localizedDescription)")
                            await card.fail("rip", detail: "Staging: \(error.localizedDescription)")
                            NotificationService.shared.notify(title: "Staging Failed",
                                                              message: "\(folderName): \(error.localizedDescription)")
                            continue
                        }
                    } else {
                        file = rippedFile
                    }

                    // v4.0.3: for .extra titles in Full Auto, ALSO copy the
                    // staged raw rip to the NAS extras folder so it actually
                    // makes it to the user's library. .extra bypasses the
                    // encode/organize/publish pipeline by design (raw rip,
                    // no transcoding), and pre-v4.0.3 the file just sat on
                    // local output forever. The Plex convention is to put
                    // extras under `<Movie or Show>/extras/` so we'll go
                    // there.
                    if titleIntent == .extra,
                       config.publishExtrasToNAS, config.nasUploadEnabled {
                        await publishExtraToNAS(localFile: file, info: info)
                    }

                    let titleElapsed = Date().timeIntervalSince(titleStart)
                    config.inFlightRip = nil
                    activePhase = .idle
                    titleRipStatuses[tid] = .done
                    // Every successfully-ripped title flows through the
                    // encode → organize → scrape → NAS pipeline as its own queue job.
                    let resolution = info.titles.first(where: { $0.id == tid })?.resolution ?? ""
                    let mins = Int(titleElapsed) / 60
                    let secs = Int(titleElapsed) % 60
                    await card.finish("rip", detail: "\(mins)m \(secs)s")
                    let intent = intent(for: tid)
                    let edition = editionLabel(for: tid)
                    let editionParam = (intent == .edition && !edition.isEmpty) ? edition : nil
                    let override = nameOverride(for: tid)
                    let queryName = override.isEmpty ? info.name : override
                    let mediaResult = override.isEmpty ? cachedMediaResult : nil
                    // TV episode assignment (populated by the picker UI; nil today
                    // unless the user has manually injected one via titleEpisodeAssignments).
                    let assignment = episodeAssignment(for: tid)
                    // Disc fingerprint threaded through so the queue's publish
                    // step records the rip in RippedDiscRegistry (the v3.7.1
                    // "already ripped" guard).
                    let discFp = DiscFingerprintService.fingerprint(info)
                    // v3.12.0: HandBrake ordinals from the user's per-title
                    // track selection. nil = use HandBrake's --all-audio /
                    // --all-subtitles default.
                    let audioOrd = self.audioOrdinals(forTitle: tid, in: info)
                    let subOrd = self.subtitleOrdinals(forTitle: tid, in: info)
                    onRipComplete?(CompletedRip(
                        discName: queryName,
                        rippedFile: file,
                        ripElapsed: titleElapsed,
                        resolution: resolution,
                        card: card,
                        mediaResult: mediaResult,
                        intent: intent,
                        editionLabel: editionParam,
                        seasonNumber: assignment?.season,
                        episodeNumber: assignment?.episode,
                        episodeTitle: assignment?.title,
                        discFingerprint: discFp,
                        ripReadErrors: readErrorCount,
                        ripCorruptionEvents: corruptionEventCount,
                        readErrorOffsets: readErrorOffsets,
                        audioTrackOrdinals: audioOrd,
                        subtitleTrackOrdinals: subOrd
                    ))
                } catch {
                    sizeMonitor.cancel()
                    config.inFlightRip = nil
                    titleRipStatuses[tid] = .failed(message: error.localizedDescription)
                    statusText = "Rip failed: \(error.localizedDescription)"
                    errorMessage = error.localizedDescription
                    log.error("Rip failed for title \(tid): \(error.localizedDescription)")
                    await card.fail("rip", detail: error.localizedDescription)
                    NotificationService.shared.notify(title: "Rip Failed", message: "\(folderName): \(error.localizedDescription)")
                }
            }

            // Best-effort: if we used a scratch dir, drop the now-empty per-disc
            // folder so the scratch tree doesn't accumulate stubs.
            if stagingEnabled {
                let fm = FileManager.default
                if let contents = try? fm.contentsOfDirectory(atPath: outputDir), contents.isEmpty {
                    try? fm.removeItem(atPath: outputDir)
                }
            }

            _ = start  // overall start kept for potential summary logging
            // Scrape artwork/NFO into the title folder right after rip
            // (skip in full-auto mode — QueueViewModel handles it after organize)
            // v4.0.13: removed `if !fullAutoEnabled { scrape... }` block.
            // The post-rip pipeline is always-on now; QueueViewModel scrapes
            // artwork after the organize step, so scraping here was dead.

            ripProgress = 1.0
            statusText = "Rip complete"
            isRipping = false
            // v3.7.2: clear startup tracking when rip ends.
            startupPhase = .notStarted
            ripStartedAt = nil
            lastInformationalMakeMKVLine = nil
            if config.preventSleep { SleepAssertion.shared.release() }
            currentRippingTitleId = nil
            // Stash the just-finished media so the "insert next disc" hero can
            // celebrate it briefly before fading back to the empty state.
            lastCompletedMedia = cachedMediaResult
            lastCompletedDiscName = info.mediaTitle.isEmpty ? info.name : info.mediaTitle

            let elapsed = Date().timeIntervalSince(start)
            let mins = Int(elapsed) / 60
            let secs = Int(elapsed) % 60
            NotificationService.shared.notify(title: "Rip Complete", message: "\(folderName) — \(mins)m \(secs)s")

            if config.autoEject { ejectDisc() }

            // v4.0.13: removed post-rip cooldown cache. It was only
            // load-bearing for the auto-poll loop removed in v4.0.5;
            // duplicate-disc detection on the next manual scan is
            // already handled by RippedDiscRegistry (persistent) and
            // the per-disc fingerprint check.

            // Reset UX after a brief delay so the user sees "Rip complete"
            try? await Task.sleep(for: .seconds(3))
            discInfo = nil
            selectedTitles = []
            ripProgress = 0
            logLines = []
            titleRipStatuses = [:]
            statusText = "Ready — insert next disc"
        }
    }

    /// Best-effort `drutil tray close` to pull in a disc the user has placed
    /// on an open tray. Always followed by a short settle delay so MakeMKV has
    /// time to see the freshly-loaded disc.
    ///
    /// Silent on:
    ///   * drives that don't support soft-close (slim USB units, slot-loaders) —
    ///     drutil exits non-zero and we just continue
    ///   * tray already closed with a disc — drutil is a no-op
    ///   * tray already closed with no disc — drutil is a no-op
    ///
    /// Status text is briefly updated to `Closing tray…` so the user sees
    /// *something* happening between clicking the button and the scan starting,
    /// otherwise the click feels unresponsive while the drive spins up.
    private func closeDiscTrayBestEffort(reason: String) async {
        let prev = statusText
        statusText = "Closing tray…"
        let success = await Task.detached { () -> Bool in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/drutil")
            proc.arguments = ["tray", "close"]
            // Pipe stdout/stderr to /dev/null — we only care about exit code.
            proc.standardOutput = Pipe()
            proc.standardError = Pipe()
            do {
                try proc.run()
                proc.waitUntilExit()
                return proc.terminationStatus == 0
            } catch {
                return false
            }
        }.value
        if success {
            FileLogger.shared.info("rip-vm", "tray-close (\(reason)): drutil tray close OK; sleeping for spin-up")
            // Drives need a few seconds after tray close before drutil/MakeMKV
            // can read the disc. Most spin up in ~3–5s; 5s is a reliable floor.
            try? await Task.sleep(for: .seconds(5))
        } else {
            FileLogger.shared.info("rip-vm", "tray-close (\(reason)): drutil tray close not supported / no-op")
        }
        // Restore prior status text if no other code path has overwritten it.
        if statusText == "Closing tray…" { statusText = prev }
    }

    // v4.0.13: `fullAuto()` removed. Only caller was the also-removed
    // `waitForNextDiscAndContinue()` auto-poll loop (v4.0.5). Each rip is
    // now an explicit Scan → Rip click pair driven by `scanDisc()` +
    // `ripSelected()`.

    func ejectDisc() {
        // Reset UI to the empty/insert-next state immediately — visually obvious
        // feedback that the click did something, even before the drive responds.
        discInfo = nil
        selectedTitles = []
        discCandidates = []
        unidentifiedDiscName = nil
        titleRipStatuses = [:]
        ripProgress = 0
        statusText = "Ejecting…"
        detectedDiscType = ""
        detectedDiscName = ""

        Task.detached {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/drutil")
            proc.arguments = ["eject"]
            try? proc.run()
            proc.waitUntilExit()
            // Re-poll drutil so the toolbar/status reflect the now-empty drive.
            await MainActor.run { [weak self] in
                self?.statusText = "Ready — insert a disc"
                self?.detectDisc()
            }
        }
    }

    func abort() {
        runningTask?.cancel()
        runningTask = nil
        // Terminate ALL tracked child processes — when ripping multiple titles
        // (or with HandBrake also running for an earlier title in Full Auto), the
        // single-process terminateLatest left orphans behind.
        ProcessTracker.shared.terminateAll()
        if isRipping && config.preventSleep { SleepAssertion.shared.release() }
        isScanning = false
        isRipping = false
        ripProgress = 0
        currentRippingTitleId = nil
        // v3.7.2: clear startup tracking on abort
        startupPhase = .notStarted
        ripStartedAt = nil
        lastInformationalMakeMKVLine = nil
        // Mark any in-flight title as failed so the UI doesn't show a half-ripped
        // bar forever.
        for (id, status) in titleRipStatuses {
            if case .ripping = status {
                titleRipStatuses[id] = .failed(message: "Aborted by user")
            }
        }
        statusText = "Aborted"
        readErrorCount = 0  // v3.11.5
        suggestLowerDriveSpeed = false  // v3.11.5
        corruptionEventCount = 0  // v3.11.7
        readErrorOffsets = []  // v3.11.12
        activePhase = .idle
        config.inFlightRip = nil
    }
}

/// Per-title rip status used by the RipHeroView. Carries enough info to render
/// a row without re-querying anything.
enum TitleRipStatus: Sendable, Equatable {
    case queued
    case ripping(percent: Int)
    case done
    case failed(message: String)
}

/// Coarse-grained phase exposed to the disc-view UI so the hero block label
/// can switch between "RIPPING" and "STAGING" as the rip flow progresses
/// through MakeMKV → StagingService. Encode/Organize/Scrape/Upload phases
/// happen later in `QueueViewModel` and are surfaced separately by the queue
/// view; we only track here the ones owned by `RipViewModel`.
enum RipPhase: Sendable, Equatable {
    case idle
    case ripping
    case staging
}

/// Substate of `.ripping` for the ~20–60 s "startup" gap between when
/// `makemkvcon mkv` is launched and the first PRGV progress event arrives.
/// Driven by parsing MakeMKV's MSG codes in the log stream so the user
/// gets meaningful feedback during what's otherwise a silent dead zone
/// that *looks* like a duplicate scan but is actually the rip command
/// re-opening + re-walking the disc.
enum RipStartupPhase: Sendable, Equatable {
    case notStarted
    case startingProcess           // makemkvcon launched; nothing said yet
    case openingDrive              // saw MSG:1011 / 2010 — drive being authorized + opened
    case readingDiscStructure      // titles/CINFO being walked (post drive-open, pre 5014)
    case preparingTitle(Int)       // saw MSG:5014 — about to start saving
    case ripping                   // first PRGV — switch to existing progress UI
}

/// TV episode assignment for a single title on a series disc. Set by the
/// (forthcoming v3.3.0) episode picker UI. Carried through to `Job` via
/// `RipViewModel.onRipComplete`.
struct TitleEpisodeAssignment: Sendable, Equatable {
    let season: Int
    let episode: Int
    let title: String
}

/// v4.0.5: pre-scan mode picker that overrides the auto TV/Movie
/// heuristic. Lets the user say "this is TV" up front so AutoRipper
/// doesn't have to guess on edge cases (Bluey-shape short-form
/// children's TV, short DVD movies with 4+ extras that accidentally
/// trigger TV detection, etc.).
enum DiscScanMode: String, Sendable, CaseIterable, Identifiable {
    case auto
    case movie
    case tv

    var id: String { rawValue }

    var displayLabel: String {
        switch self {
        case .auto:  return "Auto"
        case .movie: return "Movie"
        case .tv:    return "TV"
        }
    }

    var sfSymbol: String {
        switch self {
        case .auto:  return "wand.and.stars"
        case .movie: return "film"
        case .tv:    return "tv"
        }
    }
}

/// v4.0.6: a "the size-based main-feature pick disagrees with TMDb's
/// runtime" finding. Surfaced via `RipViewModel.mainFeatureRuntimeMismatch`
/// for the UI banner. Pure value type — equality + immutability so the
/// view diffs cleanly.
///
/// We never auto-apply the suggested swap. Extended-Edition Blu-rays
/// legitimately have the longer cut as the main feature, even though
/// TMDb only knows the theatrical runtime. The user accepts or dismisses.
struct MainFeatureMismatch: Equatable, Sendable {
    /// TMDb's stated movie runtime (seconds). What we compared against.
    let tmdbRuntimeSeconds: Int
    /// The currently-picked main-feature title's id and runtime (seconds).
    let pickedTitleId: Int
    let pickedRuntimeSeconds: Int
    /// The disc title whose runtime is closest to TMDb's. May or may not
    /// be a better choice (e.g., a commentary track of the same length).
    let suggestedTitleId: Int
    let suggestedRuntimeSeconds: Int

    /// Absolute delta between the picked title and TMDb, in seconds.
    /// Driver for the "is this worth surfacing?" threshold.
    var pickedDeltaSeconds: Int {
        abs(pickedRuntimeSeconds - tmdbRuntimeSeconds)
    }
}

/// Tracks the last time MakeMKV's PRGV callback fired. Used by the file-size
/// fallback monitor to back off when PRGV is alive.
private final class LastPRGV: @unchecked Sendable {
    private let lock = NSLock()
    private var _ts: Date = .distantPast
    var timestamp: Date {
        lock.lock(); defer { lock.unlock() }
        return _ts
    }
    func touch() {
        lock.lock(); defer { lock.unlock() }
        _ts = Date()
    }
}
