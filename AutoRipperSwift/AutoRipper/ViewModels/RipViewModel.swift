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

    /// Per-title intent (Movie / Episode / Edition / Extra). Defaults to .movie when unset.
    @Published var titleIntents: [Int: JobIntent] = [:]
    /// Per-title edition label (e.g. "Theatrical", "Director's Cut"). Used only when intent == .edition.
    @Published var titleEditionLabels: [Int: String] = [:]
    /// Per-title TMDb search override. When set (and intent == .movie), the title is queued
    /// with this name as the search query instead of the disc name. Used for collection discs
    /// where each title is a different movie (e.g. Saw 1+2+3 on one disc).
    @Published var titleNameOverrides: [Int: String] = [:]

    func intent(for titleId: Int) -> JobIntent { titleIntents[titleId] ?? .movie }
    func editionLabel(for titleId: Int) -> String { titleEditionLabels[titleId] ?? "" }
    func nameOverride(for titleId: Int) -> String { titleNameOverrides[titleId] ?? "" }

    private let config: AppConfig
    private let makemkv: MakeMKVService
    private let discord: DiscordService
    private var runningTask: Task<Void, Never>?
    private var cachedMediaResult: MediaResult?

    /// Called when a rip completes: (discName, rippedFile, elapsed, resolution, card, mediaResult, intent, editionLabel)
    var onRipComplete: ((String, URL, TimeInterval, String, JobCard?, MediaResult?, JobIntent, String?) -> Void)?

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
                self?.detectedDiscType = discType
                self?.detectedDiscName = discName
                if !discType.isEmpty {
                    let name = discName.isEmpty ? "" : " — \(discName)"
                    self?.statusText = "\(discType) detected\(name)"
                } else {
                    self?.statusText = "No disc detected"
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
            if var info = discInfo {
                info.mediaTitle = enriched.displayTitle
                discInfo = info
            }
            FileLogger.shared.info("rip-vm", "user picked disc match: \(enriched.displayTitle)")
        }
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
                var info = try await makemkv.scanDisc { [weak self] line in
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

            NotificationService.shared.notify(title: "Ripping", message: "\(folderName) — \(titlesToRip.count) title(s)")

            for (idx, tid) in titlesToRip.enumerated() {
                statusText = "Ripping title \(tid) (\(idx + 1)/\(titlesToRip.count))…"
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
                            }
                        },
                        logCallback: { [weak self] line in
                            Task { @MainActor in self?.logLines.append(line) }
                        }
                    )
                    let titleElapsed = Date().timeIntervalSince(titleStart)
                    sizeMonitor.cancel()
                    config.inFlightRipPath = nil
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
                        // If the user set a per-title name override, use that as the search
                        // query and skip the cached disc-level TMDb result (which was looked
                        // up against the disc name and won't match the override).
                        let override = nameOverride(for: tid)
                        let queryName = override.isEmpty ? info.name : override
                        let mediaResult = override.isEmpty ? cachedMediaResult : nil
                        onRipComplete?(queryName, file, titleElapsed, resolution, card, mediaResult, intent, editionParam)
                    }
                } catch {
                    sizeMonitor.cancel()
                    config.inFlightRipPath = nil
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
    private func waitForNextDiscAndContinue() async {
        FileLogger.shared.info("rip-vm", "batch: waiting for next disc")
        // The drive needs a moment after eject before drutil reports an empty tray.
        try? await Task.sleep(for: .seconds(5))
        while batchModeEnabled && !Task.isCancelled {
            let detected = await currentDiscType()
            if !detected.isEmpty {
                FileLogger.shared.info("rip-vm", "batch: new disc detected (\(detected)), starting Full Auto")
                statusText = "Batch — \(detected) detected, scanning…"
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
                var info = try await makemkv.scanDisc { [weak self] line in
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
        Task.detached {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/drutil")
            proc.arguments = ["eject"]
            try? proc.run()
            proc.waitUntilExit()
        }
    }

    func abort() {
        runningTask?.cancel()
        runningTask = nil
        ProcessTracker.shared.terminateLatest()
        isScanning = false
        isRipping = false
        ripProgress = 0
        statusText = "Aborted"
        batchModeEnabled = false  // abort breaks the batch loop
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
