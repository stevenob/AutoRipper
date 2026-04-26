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

    /// Per-title intent (Movie / Episode / Edition / Extra). Defaults to .movie when unset.
    @Published var titleIntents: [Int: JobIntent] = [:]
    /// Per-title edition label (e.g. "Theatrical", "Director's Cut"). Used only when intent == .edition.
    @Published var titleEditionLabels: [Int: String] = [:]

    func intent(for titleId: Int) -> JobIntent { titleIntents[titleId] ?? .movie }
    func editionLabel(for titleId: Int) -> String { titleEditionLabels[titleId] ?? "" }

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
        detectDisc()
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

    func scanDisc() {
        guard !isScanning else { return }
        isScanning = true
        statusText = "Scanning disc…"
        logLines = []
        discInfo = nil
        selectedTitles = []

        runningTask = Task {
            do {
                var info = try await makemkv.scanDisc { [weak self] line in
                    Task { @MainActor in self?.logLines.append(line) }
                }

                // Auto-label titles by duration/size
                info.autoLabel()

                // TMDb lookup to get the real movie/show name
                let tmdb = TMDbService(config: config)
                let results = await tmdb.searchMedia(query: info.name)
                if var match = results.first {
                    // Fetch full details for poster/backdrop paths
                    if match.mediaType == "movie", let details = await tmdb.getMovieDetails(tmdbId: match.tmdbId) {
                        match = details
                    } else if match.mediaType == "tv", let details = await tmdb.getTvDetails(tmdbId: match.tmdbId) {
                        match = details
                    }
                    info.mediaTitle = match.displayTitle
                    self.cachedMediaResult = match
                } else {
                    await discord.notifyError("⚠️ TMDb could not identify disc: \(info.name)")
                    NotificationService.shared.notify(title: "Unknown Disc", message: info.name)
                    self.cachedMediaResult = nil
                }

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

                do {
                    let file = try await makemkv.ripTitle(
                        titleId: tid,
                        outputDir: outputDir,
                        progressCallback: { [weak self] pct, _ in
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
                        onRipComplete?(info.name, file, titleElapsed, resolution, card, cachedMediaResult, intent, editionParam)
                    }
                } catch {
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
            statusText = "Ready — insert next disc"
        }
    }

    func fullAuto() {
        guard !isScanning, !isRipping else { return }
        isScanning = true
        statusText = "Full Auto: scanning…"
        logLines = []

        runningTask = Task {
            do {
                let info = try await makemkv.scanDisc { [weak self] line in
                    Task { @MainActor in self?.logLines.append(line) }
                }
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
    }
}
