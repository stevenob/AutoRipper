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
    /// When on, after a Full Auto rip ejects the disc, the app polls for the next
    /// disc and runs Full Auto again automatically. Disables on the next call to
    /// `abort()` or when the user toggles it off.
    @Published var batchModeEnabled: Bool = false
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
    private var runningTask: Task<Void, Never>?
    /// TMDb match for the current disc. Published so the rip hero / queue rows can
    /// observe and update reactively if the user picks a different match mid-rip.
    @Published private(set) var cachedMediaResult: MediaResult?

    /// Called when a rip completes: (discName, rippedFile, elapsed, resolution, card, mediaResult, intent, editionLabel, season, episode, episodeTitle)
    var onRipComplete: ((String, URL, TimeInterval, String, JobCard?, MediaResult?, JobIntent, String?, Int?, Int?, String?) -> Void)?

    var minDuration: Int { config.minDuration }

    init(config: AppConfig = .shared) {
        self.config = config
        self.makemkv = MakeMKVService(config: config)
        self.discord = DiscordService(config: config)
        cleanupOrphanedRip()
        detectDisc()
    }

    /// If a rip was in flight when the app exited/crashed, MakeMKV left a partial
    /// `.mkv` on disk. Delete it (and its parent dir if empty) so the user doesn't
    /// later think it's a real rip.
    private func cleanupOrphanedRip() {
        guard let path = config.inFlightRipPath else { return }
        let url = URL(fileURLWithPath: path)
        let dir = url.deletingLastPathComponent()
        let fm = FileManager.default
        if fm.fileExists(atPath: path) {
            try? fm.removeItem(at: url)
            FileLogger.shared.warn("rip-vm", "cleaned up partial rip from previous session: \(path)")
        }
        // Try to remove the dir if it's now empty (don't recurse — leave any user files).
        if let contents = try? fm.contentsOfDirectory(atPath: dir.path), contents.isEmpty {
            try? fm.removeItem(at: dir)
        }
        config.inFlightRipPath = nil
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

        runningTask = Task {
            do {
                var info = try await makemkv.scanDisc(volumeLabel: detectedDiscName) { [weak self] line in
                    Task { @MainActor in self?.logLines.append(line) }
                }

                // Auto-label titles by duration/size
                info.autoLabel()

                await lookupTMDb(for: &info)

                self.discInfo = info
                // Auto-select titles above min duration
                for title in info.titles where title.durationSeconds >= config.minDuration {
                    selectedTitles.insert(title.id)
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
        isRipping = true
        if config.preventSleep { SleepAssertion.shared.acquire(reason: "AutoRipper rip in progress") }
        ripProgress = 0
        statusText = "Ripping…"

        let titlesToRip = selectedTitles.sorted()
        let baseDir = config.outputDir
        // Use TMDb title if available, otherwise clean disc name
        let folderName = OrganizerService.cleanFilename(
            info.mediaTitle.isEmpty ? info.name : info.mediaTitle
        )
        let outputDir = URL(fileURLWithPath: baseDir)
            .appendingPathComponent(folderName).path

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
                // can clean up on next launch.
                config.inFlightRipPath = outputDir
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
                    let file = try await makemkv.ripTitle(
                        titleId: tid,
                        outputDir: outputDir,
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
                            Task { @MainActor in self?.logLines.append(line) }
                        }
                    )
                    let titleElapsed = Date().timeIntervalSince(titleStart)
                    sizeMonitor.cancel()
                    config.inFlightRipPath = nil
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
                        onRipComplete?(queryName, file, titleElapsed, resolution, card, mediaResult, intent, editionParam,
                                       assignment?.season, assignment?.episode, assignment?.title)
                    }
                } catch {
                    sizeMonitor.cancel()
                    config.inFlightRipPath = nil
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

            _ = start  // overall start kept for potential summary logging
            // Scrape artwork/NFO into the title folder right after rip
            // (skip in full-auto mode — QueueViewModel handles it after organize)
            if !fullAutoEnabled {
                statusText = "Scraping artwork & NFO…"
                logLines.append("Scraping artwork for \(folderName)…")
                let destDir = URL(fileURLWithPath: outputDir)
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

            // Reset UX after a brief delay so the user sees "Rip complete"
            try? await Task.sleep(for: .seconds(3))
            discInfo = nil
            selectedTitles = []
            ripProgress = 0
            logLines = []
            titleRipStatuses = [:]
            statusText = batchModeEnabled && fullAutoEnabled
                ? "Batch — insert next disc"
                : "Ready — insert next disc"

            // Batch mode: wait for the next disc to appear, then auto-Full-Auto.
            if batchModeEnabled && fullAutoEnabled {
                await waitForNextDiscAndContinue()
            }
        }
    }

    /// Polls drutil until a disc is detected (or the user disables batch mode /
    /// aborts), then kicks off Full Auto. Used by `batch-mode`.
    ///
    /// Two-phase wait so we don't trigger on the disc that *just* finished:
    ///   1. Wait until drutil reports NO disc (eject completed).
    ///   2. Wait until drutil reports a disc (next one inserted).
    private func waitForNextDiscAndContinue() async {
        FileLogger.shared.info("rip-vm", "batch: waiting for eject to complete")
        statusText = "Batch — waiting for eject…"
        // Phase 1: wait for the drive to be empty.
        // Bail out after ~60s if drutil never reports empty (some drives lie).
        var waited = 0
        while batchModeEnabled && !Task.isCancelled && waited < 60 {
            let detected = await currentDiscType()
            if detected.isEmpty { break }
            try? await Task.sleep(for: .seconds(2))
            waited += 2
        }
        guard batchModeEnabled, !Task.isCancelled else {
            FileLogger.shared.info("rip-vm", "batch: stopped during eject wait")
            return
        }

        FileLogger.shared.info("rip-vm", "batch: drive empty, waiting for next disc")
        statusText = batchModeEnabled
            ? "Batch — insert next disc"
            : "Ready — insert next disc"

        // Phase 2: poll for new disc insertion.
        while batchModeEnabled && !Task.isCancelled {
            let detected = await currentDiscType()
            if !detected.isEmpty {
                FileLogger.shared.info("rip-vm", "batch: new disc detected (\(detected)), starting Full Auto")
                statusText = "Batch — \(detected) detected, scanning…"
                // Give MakeMKV a moment to see the freshly-mounted disc — some drives
                // report it in drutil before the volume actually mounts.
                try? await Task.sleep(for: .seconds(3))
                await MainActor.run { self.fullAuto() }
                return
            }
            try? await Task.sleep(for: .seconds(5))
        }
        FileLogger.shared.info("rip-vm", "batch: stopped (batchModeEnabled=\(batchModeEnabled))")
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

    func fullAuto() {
        guard !isScanning, !isRipping else { return }
        isScanning = true
        statusText = "Full Auto: scanning…"
        logLines = []

        runningTask = Task {
            do {
                var info = try await makemkv.scanDisc(volumeLabel: detectedDiscName) { [weak self] line in
                    Task { @MainActor in self?.logLines.append(line) }
                }
                info.autoLabel()
                await lookupTMDb(for: &info)
                self.discInfo = info
                isScanning = false

                // Pick the largest title above min duration
                let candidates = info.titles.filter { $0.durationSeconds >= config.minDuration }
                guard let best = candidates.max(by: { $0.sizeBytes < $1.sizeBytes }) else {
                    statusText = "No titles meet minimum duration"
                    return
                }
                selectedTitles = [best.id]
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
        // Mark any in-flight title as failed so the UI doesn't show a half-ripped
        // bar forever.
        for (id, status) in titleRipStatuses {
            if case .ripping = status {
                titleRipStatuses[id] = .failed(message: "Aborted by user")
            }
        }
        statusText = "Aborted"
        batchModeEnabled = false  // abort breaks the batch loop
        config.inFlightRipPath = nil
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
