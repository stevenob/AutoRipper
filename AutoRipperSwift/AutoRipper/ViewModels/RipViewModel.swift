import Foundation
import SwiftUI
import os

private let log = Logger(subsystem: "com.autoripper.app", category: "rip-vm")

@MainActor
final class RipViewModel: ObservableObject {
    @Published var discInfo: DiscInfo?
    @Published var scanProgress: String = ""
    @Published var ripProgress: Double = 0
    @Published var isScanning: Bool = false
    @Published var isRipping: Bool = false
    @Published var selectedTitles: Set<Int> = []
    @Published var statusText: String = "Idle"
    @Published var logLines: [String] = []
    @Published var fullAutoEnabled: Bool = false

    private let config: AppConfig
    private let makemkv: MakeMKVService
    private var runningTask: Task<Void, Never>?

    /// Called when a rip completes: (discName, rippedFile, elapsed)
    var onRipComplete: ((String, URL, TimeInterval) -> Void)?

    var minDuration: Int { config.minDuration }

    init(config: AppConfig = .shared) {
        self.config = config
        self.makemkv = MakeMKVService(config: config)
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
                }

                self.discInfo = info
                // Auto-select titles above min duration
                for title in info.titles where title.durationSeconds >= config.minDuration {
                    selectedTitles.insert(title.id)
                }
                let displayName = info.mediaTitle.isEmpty ? info.name : info.mediaTitle
                statusText = "Scanned: \(displayName) — \(info.titles.count) titles"
            } catch {
                statusText = "Scan failed: \(error.localizedDescription)"
                log.error("Scan failed: \(error.localizedDescription)")
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
            for (idx, tid) in titlesToRip.enumerated() {
                statusText = "Ripping title \(tid) (\(idx + 1)/\(titlesToRip.count))…"
                do {
                    let file = try await makemkv.ripTitle(
                        titleId: tid,
                        outputDir: outputDir,
                        progressCallback: { [weak self] pct, text in
                            Task { @MainActor in
                                self?.ripProgress = Double(pct) / 100.0
                                self?.statusText = text
                            }
                        },
                        logCallback: { [weak self] line in
                            Task { @MainActor in self?.logLines.append(line) }
                        }
                    )
                    let elapsed = Date().timeIntervalSince(start)
                    // Only queue for encode pipeline when Full Auto is on (largest title only)
                    if fullAutoEnabled && tid == largestId {
                        onRipComplete?(info.name, file, elapsed)
                    }
                } catch {
                    statusText = "Rip failed: \(error.localizedDescription)"
                    log.error("Rip failed for title \(tid): \(error.localizedDescription)")
                }
            }
            ripProgress = 1.0
            statusText = "Rip complete"
            isRipping = false

            if config.autoEject { ejectDisc() }
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
        isScanning = false
        isRipping = false
        ripProgress = 0
        statusText = "Aborted"
    }
}
