import Foundation
import SwiftUI
import os

private let log = Logger(subsystem: "com.autoripper.app", category: "queue-vm")

@MainActor
final class QueueViewModel: ObservableObject {
    @Published var jobs: [Job] = []

    private let config: AppConfig
    private let handbrake: HandBrakeService
    private let discord: DiscordService
    private var workerTask: Task<Void, Never>?
    private var currentTask: Task<Void, Never>?

    init(config: AppConfig = .shared) {
        self.config = config
        self.handbrake = HandBrakeService(config: config)
        self.discord = DiscordService(config: config)
    }

    func addJob(discName: String, rippedFile: URL, ripElapsed: TimeInterval) {
        let job = Job(discName: discName, rippedFile: rippedFile, ripElapsed: ripElapsed)
        jobs.append(job)
        startWorkerIfNeeded()
    }

    func abortCurrent() {
        currentTask?.cancel()
        currentTask = nil
        if let idx = jobs.firstIndex(where: {
            $0.status != .done && $0.status != .failed && $0.status != .queued
        }) {
            jobs[idx].status = .failed
            jobs[idx].error = "Aborted by user"
            jobs[idx].progressText = "Aborted"
        }
    }

    var statusLabel: String {
        let active = jobs.filter { $0.status != .done && $0.status != .failed }
        if active.isEmpty { return "Idle" }
        let done = jobs.filter { $0.status == .done }.count
        return "Processing \(done + 1) of \(jobs.count)"
    }

    // MARK: - Worker

    private func startWorkerIfNeeded() {
        guard workerTask == nil else { return }
        workerTask = Task {
            while !Task.isCancelled {
                guard let idx = jobs.firstIndex(where: { $0.status == .queued }) else { break }
                await processJob(at: idx)
                pruneFinished()
            }
            workerTask = nil
        }
    }

    private func processJob(at index: Int) async {
        let card = JobCard(discName: jobs[index].discName,
                           nasEnabled: config.nasUploadEnabled,
                           discord: discord)

        // Rip stage already done
        await card.finish("rip", detail: formatElapsed(jobs[index].ripElapsed))

        // Encode
        jobs[index].status = .encoding
        jobs[index].progressText = "Encoding…"
        await card.start("encode")

        do {
            let encoded = try await encodeJob(at: index)
            jobs[index].encodedFile = encoded
            await card.finish("encode")
        } catch {
            jobs[index].status = .failed
            jobs[index].error = error.localizedDescription
            jobs[index].progressText = "Encode failed"
            await card.fail("encode", detail: error.localizedDescription)
            NotificationService.shared.notify(title: "Encode Failed", message: jobs[index].discName)
            return
        }

        // Organize
        jobs[index].status = .organizing
        jobs[index].progressText = "Organizing…"
        await card.start("organize")

        do {
            let source = jobs[index].encodedFile ?? jobs[index].rippedFile
            let dest = OrganizerService.buildMoviePath(
                outputDir: config.outputDir,
                title: jobs[index].discName
            )
            let organized = try OrganizerService.organizeFile(source: source, destination: dest)
            jobs[index].organizedFile = organized
            await card.finish("organize")
        } catch {
            jobs[index].status = .failed
            jobs[index].error = error.localizedDescription
            jobs[index].progressText = "Organize failed"
            await card.fail("organize", detail: error.localizedDescription)
            return
        }

        // Scrape
        jobs[index].status = .scraping
        jobs[index].progressText = "Scraping artwork…"
        await card.start("scrape")

        let destDir = (jobs[index].organizedFile ?? jobs[index].rippedFile)
            .deletingLastPathComponent()
        let artwork = ArtworkService()
        let scraped = await artwork.scrapeAndSave(discName: jobs[index].discName, destDir: destDir)
        if scraped {
            await card.finish("scrape")
        } else {
            await card.fail("scrape", detail: "No TMDb results")
        }

        // NAS upload
        if config.nasUploadEnabled {
            jobs[index].status = .uploading
            jobs[index].progressText = "Copying to NAS…"
            await card.start("nas")

            do {
                let source = jobs[index].organizedFile ?? jobs[index].rippedFile
                let nasBase = config.nasMoviesPath
                let nasDest = URL(fileURLWithPath: nasBase)
                    .appendingPathComponent(source.deletingLastPathComponent().lastPathComponent)
                    .appendingPathComponent(source.lastPathComponent)
                try FileManager.default.createDirectory(
                    at: nasDest.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try FileManager.default.copyItem(at: source, to: nasDest)
                await card.finish("nas")
            } catch {
                await card.fail("nas", detail: error.localizedDescription)
            }
        } else {
            await card.skip("nas")
        }

        // Done
        jobs[index].status = .done
        jobs[index].progress = 100
        jobs[index].progressText = "Complete"
        await card.complete(footer: "Total: \(formatElapsed(jobs[index].ripElapsed))")
        NotificationService.shared.notify(title: "Job Complete", message: jobs[index].discName)
    }

    private func encodeJob(at index: Int) async throws -> URL {
        let input = jobs[index].rippedFile
        let outputPath = input.deletingPathExtension().path + "_encoded.mkv"

        currentTask = Task {
            // This is just a container for cancellation
        }

        let result = try await handbrake.encode(
            inputPath: input.path,
            outputPath: outputPath,
            preset: config.defaultPreset,
            progressCallback: { [weak self] pct, text in
                Task { @MainActor in
                    guard let self else { return }
                    if index < self.jobs.count {
                        self.jobs[index].progress = pct
                        self.jobs[index].progressText = text
                    }
                }
            }
        )
        currentTask = nil
        return result
    }

    private func pruneFinished() {
        let finished = jobs.filter { $0.status == .done || $0.status == .failed }
        if finished.count > 50 {
            let excess = finished.count - 50
            let toRemove = finished.prefix(excess).map(\.id)
            jobs.removeAll { toRemove.contains($0.id) }
        }
    }

    private func formatElapsed(_ interval: TimeInterval) -> String {
        let mins = Int(interval) / 60
        let secs = Int(interval) % 60
        return "\(mins)m \(secs)s"
    }
}
