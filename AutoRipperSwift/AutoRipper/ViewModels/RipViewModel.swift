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
    @Published var fullAutoEnabled: Bool = false
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
    /// v3.11.2: true when Auto mode has finished scanning a disc and is
    /// paused awaiting the user's "Rip" click. Set when
    /// `config.autoConfirmBeforeRip == true` AND the scan in `fullAuto`
    /// completed. Cleared as soon as `ripSelected` starts, on abort, or
    /// on a new scan. Wired into the UI's Rip-button enablement.
    @Published var awaitingAutoRipConfirm: Bool = false
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
    /// v3.7.2: in-memory cache of discs the auto loop just skipped because
    /// they were already in the rip registry. Avoids re-scanning when the
    /// drive's hardware auto-close pulls the same disc back in moments after
    /// we ejected it. Keyed by detected volume label (cheap from drutil/
    /// diskutil — no MakeMKV scan needed). Entries expire after the cooldown
    /// window so the user can intentionally re-rip after clearing the registry.
    private var recentlySkippedDiscNames: [(name: String, at: Date)] = []
    /// Cooldown window for `recentlySkippedDiscNames`. 5 min is long enough
    /// to absorb the drive's tray-cycle behavior and short enough that an
    /// intentional re-rip works without restarting the app.
    private static let recentlySkippedCooldown: TimeInterval = 300
    /// TMDb match for the current disc. Published so the rip hero / queue rows can
    /// observe and update reactively if the user picks a different match mid-rip.
    @Published private(set) var cachedMediaResult: MediaResult?

    /// Called when a rip completes: (discName, rippedFile, elapsed, resolution, card, mediaResult, intent, editionLabel, season, episode, episodeTitle, discFingerprint, ripReadErrors, ripCorruptionEvents)
    var onRipComplete: ((String, URL, TimeInterval, String, JobCard?, MediaResult?, JobIntent, String?, Int?, Int?, String?, String?, Int, Int) -> Void)?

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

    /// v3.11.6: how many MSG:2003 read errors trigger the "try slower drive
    /// speed" banner. 5 is a reasonable balance — single transient errors
    /// are routine on used media (don't pester the user); persistent
    /// per-sector failures (5+ in one rip) signal a disc or drive issue
    /// worth pausing for.
    static let readErrorSuggestThreshold = 5

    /// v3.11.6: pure check for whether a MakeMKV log line represents a
    /// single read-error event worth counting. MSG:2003 = "Posix error"
    /// raw read failure at a specific offset (one per failed sector).
    /// MSG:2022 = end-of-rip summary ("Encountered N read errors") — we
    /// deliberately ignore that one because the per-event MSG:2003 lines
    /// have already given us the count, and counting both would double.
    static func isReadErrorLine(_ line: String) -> Bool {
        line.hasPrefix("MSG:2003")
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
        let tmdb = TMDbService(config: config)
        let results = await tmdb.searchMedia(query: info.name)
        self.discCandidates = Array(results.prefix(5))
        if var match = results.first {
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
        } else {
            await discord.notifyError("⚠️ TMDb could not identify disc: \(info.name)")
            NotificationService.shared.notify(title: "Unknown Disc", message: info.name)
            self.cachedMediaResult = nil
            self.unidentifiedDiscName = info.name
        }
    }

    /// Replace the auto-picked TMDb match with one of the alternatives, or with
    /// a result from a manual search. Updates `discInfo.mediaTitle` so the UI
    /// header reflects the choice and the rip uses the right folder name.
    func selectDiscMatch(_ match: MediaResult) {
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
        awaitingAutoRipConfirm = false  // v3.11.2
        readErrorCount = 0  // v3.11.5
        suggestLowerDriveSpeed = false  // v3.11.5
        corruptionEventCount = 0  // v3.11.7

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

                await lookupTMDb(for: &info)

                self.discInfo = info
                // Auto-select titles above min duration
                for title in info.titles where title.durationSeconds >= config.minDuration {
                    selectedTitles.insert(title.id)
                }
                // Check duplicate-rip registry. Compute fingerprint and look
                // it up; surface the prior entry on the model so the UI can
                // banner-warn the user.
                let fp = DiscFingerprintService.fingerprint(info)
                let prior = await RippedDiscRegistry.shared.entry(forFingerprint: fp)
                self.previousRipMatch = prior
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
        // v3.11.2: clearing the pause flag the moment a rip starts means the
        // UI's Rip button can return to its standard disabled-while-ripping
        // state and the auto loop knows the user committed.
        awaitingAutoRipConfirm = false
        // v3.11.5: reset error counters at rip start so the count reflects
        // this rip, not whatever happened during the prior scan.
        readErrorCount = 0
        suggestLowerDriveSpeed = false
        corruptionEventCount = 0  // v3.11.7
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
                // Only created in full-auto mode (manual mode skips post-rip pipeline).
                var card: JobCard? = nil
                if fullAutoEnabled {
                    let cardName = totalTitles > 1 ? "\(folderName) — title \(tid)" : folderName
                    card = JobCard(discName: cardName,
                                   nasEnabled: config.nasUploadEnabled,
                                   discord: discord)
                    await card?.start("rip")
                }

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

                    // Stage to outputDir ONLY for jobs that won't enter the
                    // queue pipeline. Queue-bound jobs (full-auto, non-extra)
                    // skip staging — QueueViewModel does the local-encode
                    // pipeline straight from scratch and publishes at the end.
                    //
                    // Cases that still need staging:
                    //   * .extra titles (kept as raw rip; never enter queue)
                    //   * manual-mode rips (no queue at all)
                    //
                    // For everything else (full-auto + non-extra), the rip
                    // file stays in scratch and `file` points there directly.
                    let titleIntent = intent(for: tid)
                    let needsStaging = stagingEnabled
                        && (!fullAutoEnabled || titleIntent == .extra)
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
                            if fullAutoEnabled {
                                await card?.fail("rip", detail: "Staging: \(error.localizedDescription)")
                            } else {
                                await discord.notifyError("Staging failed for \(folderName): \(error.localizedDescription)")
                            }
                            NotificationService.shared.notify(title: "Staging Failed",
                                                              message: "\(folderName): \(error.localizedDescription)")
                            continue
                        }
                    } else {
                        file = rippedFile
                    }

                    let titleElapsed = Date().timeIntervalSince(titleStart)
                    config.inFlightRip = nil
                    activePhase = .idle
                    titleRipStatuses[tid] = .done
                    // In Full Auto, every successfully-ripped title flows through the
                    // encode → organize → scrape → NAS pipeline as its own queue job.
                    // Manual mode still ends here (rip-only).
                    if fullAutoEnabled {
                        let resolution = info.titles.first(where: { $0.id == tid })?.resolution ?? ""
                        let mins = Int(titleElapsed) / 60
                        let secs = Int(titleElapsed) % 60
                        await card?.finish("rip", detail: "\(mins)m \(secs)s")
                        let intent = intent(for: tid)
                        let edition = editionLabel(for: tid)
                        let editionParam = (intent == .edition && !edition.isEmpty) ? edition : nil
                        let override = nameOverride(for: tid)
                        let queryName = override.isEmpty ? info.name : override
                        let mediaResult = override.isEmpty ? cachedMediaResult : nil
                        // TV episode assignment (populated by v3.3.0 picker UI; nil today
                        // unless the user has manually injected one via titleEpisodeAssignments).
                        let assignment = episodeAssignment(for: tid)
                        // Compute disc fingerprint from the current scan info
                        // and thread it through to the queue, so v3.7.1's
                        // RippedDiscRegistry can record the publish.
                        let discFp = DiscFingerprintService.fingerprint(info)
                        onRipComplete?(queryName, file, titleElapsed, resolution, card, mediaResult, intent, editionParam,
                                       assignment?.season, assignment?.episode, assignment?.title, discFp,
                                       readErrorCount, corruptionEventCount)
                    }
                } catch {
                    sizeMonitor.cancel()
                    config.inFlightRip = nil
                    titleRipStatuses[tid] = .failed(message: error.localizedDescription)
                    statusText = "Rip failed: \(error.localizedDescription)"
                    errorMessage = error.localizedDescription
                    log.error("Rip failed for title \(tid): \(error.localizedDescription)")
                    if fullAutoEnabled {
                        await card?.fail("rip", detail: error.localizedDescription)
                    } else {
                        await discord.notifyError("Rip failed for \(folderName): \(error.localizedDescription)")
                    }
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
            if !fullAutoEnabled {
                statusText = "Scraping artwork & NFO…"
                logLines.append("Scraping artwork for \(folderName)…")
                // When staging is on, the rip files now live at `finalDir`; the
                // scratch `outputDir` was deleted just above. Always scrape into
                // wherever the files actually ended up.
                let destDir = URL(fileURLWithPath: stagingEnabled ? finalDir : outputDir)
                let artwork = ArtworkService()
                let scraped = await artwork.scrapeAndSave(
                    discName: info.name,
                    destDir: destDir,
                    logCallback: { [weak self] line in
                        Task { @MainActor in self?.logLines.append(line) }
                    }
                )
                if scraped {
                    logLines.append("✓ Artwork & NFO saved")
                }
            }

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
            if !fullAutoEnabled {
                await discord.notifySuccess("\(folderName) — rip complete in \(mins)m \(secs)s")
            }
            NotificationService.shared.notify(title: "Rip Complete", message: "\(folderName) — \(mins)m \(secs)s")

            if config.autoEject { ejectDisc() }

            // v3.11.1: protect against post-rip re-detect loop. The drive's
            // hardware auto-close behavior (LG WH16NS40 etc.) can pull the
            // just-ejected disc back in before the queue's publish step
            // records its fingerprint in RippedDiscRegistry — leaving a
            // window where the auto poll loop sees a "new" disc that's
            // actually the same one we just ripped. Add its volume label
            // to the in-memory cooldown cache so the poll loop ignores it
            // until the registry catches up (or the user removes the disc).
            //
            // We use the SAME 5-min cooldown window as the existing
            // recentlySkippedDiscNames cache. By the time it expires, the
            // queue's publish step (worst case ~30 min on slow NAS but
            // typically much faster) should have recorded the fingerprint
            // in the persistent registry, which will then take over as the
            // duplicate guard.
            if fullAutoEnabled {
                let justRippedName = detectedDiscName.isEmpty ? info.name : detectedDiscName
                if !justRippedName.isEmpty {
                    recentlySkippedDiscNames.append((name: justRippedName, at: Date()))
                    pruneRecentlySkipped()
                    FileLogger.shared.info("rip-vm",
                        "auto: post-rip cooldown set for \(justRippedName) (5 min)")
                }
            }

            // Reset UX after a brief delay so the user sees "Rip complete"
            try? await Task.sleep(for: .seconds(3))
            discInfo = nil
            selectedTitles = []
            ripProgress = 0
            logLines = []
            titleRipStatuses = [:]
            statusText = fullAutoEnabled
                ? "Auto — insert next disc"
                : "Ready — insert next disc"

            // Auto mode: wait for the next disc to appear, then run again.
            if fullAutoEnabled {
                await waitForNextDiscAndContinue()
            }
        }
    }

    /// Polls drutil until a disc is detected (or the user disables Auto mode /
    /// aborts), then kicks off Full Auto on the new disc.
    ///
    /// Two-phase wait so we don't trigger on the disc that *just* finished:
    ///   1. Wait until drutil reports NO disc (eject completed).
    ///   2. Wait until drutil reports a disc (next one inserted).
    private func waitForNextDiscAndContinue() async {
        FileLogger.shared.info("rip-vm", "auto: waiting for eject to complete")
        statusText = "Auto — waiting for eject…"
        // Phase 1: wait for the drive to be empty.
        // Bail out after ~60s if drutil never reports empty (some drives lie).
        var waited = 0
        while fullAutoEnabled && !Task.isCancelled && waited < 60 {
            let detected = await currentDiscType()
            if detected.isEmpty { break }
            try? await Task.sleep(for: .seconds(2))
            waited += 2
        }
        guard fullAutoEnabled, !Task.isCancelled else {
            FileLogger.shared.info("rip-vm", "auto: stopped during eject wait")
            return
        }

        FileLogger.shared.info("rip-vm", "auto: drive empty, waiting for next disc")
        statusText = "Auto — insert next disc"

        // Phase 2: poll for new disc insertion.
        // Periodically attempt a tray close — lets the user drop a disc on an
        // open tray and walk away. drutil tray close is a no-op when the tray
        // is already shut, and silently fails on drives without soft-close.
        var pollsSinceClose = 0
        while fullAutoEnabled && !Task.isCancelled {
            let detected = await currentDiscType()
            if !detected.isEmpty {
                // v3.7.2: re-detect the disc to update detectedDiscName so the
                // cooldown check below has the freshest volume label.
                detectDisc()
                // Give detectDisc's detached task a moment to populate
                // detectedDiscName from diskutil before we check the cache.
                try? await Task.sleep(for: .seconds(2))
                if isRecentlySkipped(volumeName: detectedDiscName) {
                    FileLogger.shared.info("rip-vm",
                        "auto: ignoring \(detectedDiscName) — recently skipped (within cooldown)")
                    statusText = "Auto — same disc still loaded, ignoring"
                    // Re-eject; some drives need a nudge.
                    ejectDisc()
                    try? await Task.sleep(for: .seconds(8))
                    continue
                }
                FileLogger.shared.info("rip-vm", "auto: new disc detected (\(detected)), starting Full Auto")
                statusText = "Auto — \(detected) detected, scanning…"
                // Give MakeMKV a moment to see the freshly-mounted disc — some drives
                // report it in drutil before the volume actually mounts.
                try? await Task.sleep(for: .seconds(3))
                await MainActor.run { self.fullAuto() }
                return
            }
            // Try a tray close every ~30s while idle. If the user dropped a
            // disc on the open tray, the next poll cycle picks it up.
            if pollsSinceClose >= 6 {
                await closeDiscTrayBestEffort(reason: "auto-poll")
                pollsSinceClose = 0
            } else {
                pollsSinceClose += 1
            }
            try? await Task.sleep(for: .seconds(5))
        }
        FileLogger.shared.info("rip-vm", "auto: stopped (fullAutoEnabled=\(fullAutoEnabled))")
    }

    /// True if `volumeName` was added to `recentlySkippedDiscNames` within the
    /// cooldown window. Empty names never match.
    func isRecentlySkipped(volumeName: String) -> Bool {
        guard !volumeName.isEmpty else { return false }
        pruneRecentlySkipped()
        return recentlySkippedDiscNames.contains { $0.name == volumeName }
    }

    /// Drop expired entries from the recently-skipped cache. Called before
    /// every read and after every write.
    func pruneRecentlySkipped() {
        let cutoff = Date().addingTimeInterval(-Self.recentlySkippedCooldown)
        recentlySkippedDiscNames.removeAll { $0.at < cutoff }
    }

    /// Synchronous-style query of drutil for current disc type, "" if no disc.
    private func currentDiscType() async -> String {
        await Task.detached { () -> String in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/drutil")
            proc.arguments = ["status"]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            try? proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard let output = String(data: data, encoding: .utf8) else { return "" }
            for line in output.components(separatedBy: .newlines) {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("Type:") {
                    let v = t.replacingOccurrences(of: "Type:", with: "").trimmingCharacters(in: .whitespaces)
                    if v.lowercased().contains("bd") || v.lowercased().contains("blu") { return "Blu-ray" }
                    if v.lowercased().contains("dvd") { return "DVD" }
                }
            }
            return ""
        }.value
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

    func fullAuto() {
        guard !isScanning, !isRipping else { return }
        isScanning = true
        statusText = "Full Auto: scanning…"
        logLines = []

        runningTask = Task {
            // Best-effort tray close so the user can drop a disc on the open
            // tray and click Auto without first manually pushing it shut.
            await closeDiscTrayBestEffort(reason: "auto")
            do {
                var info = try await makemkv.scanDisc(volumeLabel: detectedDiscName) { [weak self] line in
                    Task { @MainActor in self?.appendMakeMKVLog(line) }
                }
                info.autoLabel()
                await lookupTMDb(for: &info)
                self.discInfo = info
                let fp = DiscFingerprintService.fingerprint(info)
                self.previousRipMatch = await RippedDiscRegistry.shared.entry(forFingerprint: fp)
                isScanning = false

                // v3.7.2: skip auto-re-rip when the disc is already in the
                // registry. Prevents the auto-eject + drive-auto-close +
                // re-scan loop the user hit on the LG WH16NS40. The user
                // can disable via Settings → Library → "Skip already-ripped".
                if let prior = self.previousRipMatch, config.skipAlreadyRippedInAuto {
                    let dateStr = ISO8601DateFormatter().string(from: prior.date)
                    FileLogger.shared.info("rip-vm",
                        "auto: skipping already-ripped disc \(prior.discName) (originally ripped \(dateStr))")
                    statusText = "Skipped — already ripped"
                    NotificationService.shared.notify(
                        title: "Skipped: already ripped",
                        message: "\(prior.discName) — originally on \(prior.date.formatted(date: .abbreviated, time: .shortened))"
                    )
                    // Cache the disc name so the auto poll loop doesn't
                    // bother re-scanning it if the drive's auto-close
                    // pulls it back in shortly.
                    let detectedName = self.detectedDiscName.isEmpty ? info.name : self.detectedDiscName
                    self.recentlySkippedDiscNames.append((name: detectedName, at: Date()))
                    self.pruneRecentlySkipped()
                    // Eject so the auto poll can move on.
                    ejectDisc()
                    return
                }

                // Pick the largest title above min duration
                let candidates = info.titles.filter { $0.durationSeconds >= config.minDuration }
                guard let best = candidates.max(by: { $0.sizeBytes < $1.sizeBytes }) else {
                    statusText = "No titles meet minimum duration"
                    return
                }
                selectedTitles = [best.id]

                // v3.11.2: opt-in "review before rip" pause. When enabled,
                // Auto stops here and waits for the user to click the big
                // Rip button. The auto poll loop is paused via the
                // awaitingAutoRipConfirm flag — once the user presses Rip,
                // ripSelected runs and the standard post-rip eject + poll
                // path resumes. The user can also abort (ejects without
                // ripping) via the Abort button.
                if config.autoConfirmBeforeRip {
                    awaitingAutoRipConfirm = true
                    statusText = "Auto — review titles and press Rip"
                    FileLogger.shared.info("rip-vm", "auto: paused for user confirmation")
                    // Don't call ripSelected() — the UI's Rip button will
                    // invoke it when the user clicks.
                    return
                }

                ripSelected()
            } catch {
                statusText = "Full Auto failed: \(error.localizedDescription)"
                isScanning = false
            }
        }
    }

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
        // Abort always exits the auto loop. The user must explicitly re-enable
        // Full Auto to resume hands-free behavior.
        fullAutoEnabled = false
        awaitingAutoRipConfirm = false  // v3.11.2
        readErrorCount = 0  // v3.11.5
        suggestLowerDriveSpeed = false  // v3.11.5
        corruptionEventCount = 0  // v3.11.7
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
