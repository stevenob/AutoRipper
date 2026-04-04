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

    private let config: AppConfig
    private let makemkv: MakeMKVService
    private let discord: DiscordService
    private var runningTask: Task<Void, Never>?

    /// Called when a rip completes: (discName, rippedFile, elapsed, resolution)
    var onRipComplete: ((String, URL, TimeInterval, String) -> Void)?

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

            await MainActor.run { [weak self] in
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
                if let match = results.first {
                    info.mediaTitle = match.displayTitle
                } else {
                    await discord.notifyError("⚠️ TMDb could not identify disc: \(info.name)")
                    NotificationService.shared.notify(title: "Unknown Disc", message: info.name)
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
        // In Full Auto, only queue the largest title for encode
        let largestId = info.titles
            .filter { selectedTitles.contains($0.id) }
            .max(by: { $0.sizeBytes < $1.sizeBytes })?.id

        runningTask = Task {
            let start = Date()
            await discord.notifyInfo("🎬 Ripping \(folderName) — \(titlesToRip.count) title(s)")
            NotificationService.shared.notify(title: "Ripping", message: "\(folderName) — \(titlesToRip.count) title(s)")

            for (idx, tid) in titlesToRip.enumerated() {
                statusText = "Ripping title \(tid) (\(idx + 1)/\(titlesToRip.count))…"
                let expectedSize = info.titles.first(where: { $0.id == tid })?.sizeBytes ?? 0

                // Monitor file size for progress
                let monitorDir = outputDir
                let expectedSz = expectedSize
                let sizeMonitor = Task.detached {
                    let fm = FileManager.default
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(2))
                        guard let files = try? fm.contentsOfDirectory(atPath: monitorDir) else { continue }
                        let mkvFiles = files.filter { $0.hasSuffix(".mkv") }
                        var totalSize: Int64 = 0
                        for f in mkvFiles {
                            let path = URL(fileURLWithPath: monitorDir).appendingPathComponent(f).path
                            if let attrs = try? fm.attributesOfItem(atPath: path),
                               let size = attrs[.size] as? Int64 {
                                totalSize += size
                            }
                        }
                        if expectedSz > 0 {
                            let pct = min(Double(totalSize) / Double(expectedSz), 0.99)
                            let sizeMB = totalSize / (1024 * 1024)
                            let totalMB = expectedSz / (1024 * 1024)
                            await MainActor.run { [weak self] in
                                self?.ripProgress = pct
                                self?.statusText = "Ripping: \(Int(pct * 100))% — \(sizeMB) / \(totalMB) MB"
                            }
                        }
                    }
                }

                do {
                    let file = try await makemkv.ripTitle(
                        titleId: tid,
                        outputDir: outputDir,
                        logCallback: { [weak self] line in
                            Task { @MainActor in self?.logLines.append(line) }
                        }
                    )
                    sizeMonitor.cancel()
                    let elapsed = Date().timeIntervalSince(start)
                    // Only queue for encode pipeline when Full Auto is on (largest title only)
                    if fullAutoEnabled && tid == largestId {
                        let resolution = info.titles.first(where: { $0.id == tid })?.resolution ?? ""
                        onRipComplete?(info.name, file, elapsed, resolution)
                    }
                } catch {
                    sizeMonitor.cancel()
                    statusText = "Rip failed: \(error.localizedDescription)"
                    errorMessage = error.localizedDescription
                    log.error("Rip failed for title \(tid): \(error.localizedDescription)")
                    await discord.notifyError("Rip failed for \(folderName): \(error.localizedDescription)")
                    NotificationService.shared.notify(title: "Rip Failed", message: "\(folderName): \(error.localizedDescription)")
                }
            }

            // Scrape artwork/NFO into the title folder right after rip
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

            ripProgress = 1.0
            statusText = "Rip complete"
            isRipping = false

            let elapsed = Date().timeIntervalSince(start)
            let mins = Int(elapsed) / 60
            let secs = Int(elapsed) % 60
            await discord.notifySuccess("\(folderName) — rip complete in \(mins)m \(secs)s")
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
