import Foundation
import SwiftUI
import Combine
import os

private let log = Logger(subsystem: "com.autoripper.app", category: "queue-vm")

@MainActor
final class QueueViewModel: ObservableObject {
    @Published var jobs: [Job] = []

    private let config: AppConfig
    private let handbrake: HandBrakeService
    private let discord: DiscordService
    private let store: JobStore
    private var workerTask: Task<Void, Never>?
    private var currentTask: Task<Void, Never>?
    private var saveCancellable: AnyCancellable?

    init(config: AppConfig = .shared, store: JobStore = .shared) {
        self.config = config
        self.handbrake = HandBrakeService(config: config)
        self.discord = DiscordService(config: config)
        self.store = store
        loadFromStore()
        // Persist on every change, but throttle to ~1 Hz so rapid encode-progress
        // ticks (which currently fire every ~100ms via HandBrake's PRGV) don't
        // generate dozens of full JSON rewrites per second. Trailing-edge ensures
        // the final state always lands.
        saveCancellable = $jobs
            .dropFirst()
            .throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)
            .sink { [store] jobs in store.save(jobs) }
    }

    private func loadFromStore() {
        var loaded = store.load()
        // Any job that was mid-pipeline when the app was killed/crashed is now stale.
        // Mark as failed so the user can see what happened and decide whether to retry.
        let interrupted: Set<JobStatus> = [.encoding, .organizing, .scraping, .uploading]
        var rescued = 0
        for i in loaded.indices where interrupted.contains(loaded[i].status) {
            loaded[i].status = .failed
            loaded[i].error = "Interrupted (app exited mid-job)"
            loaded[i].progressText = "Interrupted"
            loaded[i].finishedAt = Date()
            rescued += 1
        }
        // Drop any history older than the retention window (default 30 days).
        let retention = TimeInterval(max(1, config.historyRetentionDays) * 86_400)
        let cutoff = Date().addingTimeInterval(-retention)
        let beforePrune = loaded.count
        loaded.removeAll { job in
            (job.status == .done || job.status == .failed)
                && (job.finishedAt ?? job.createdAt) < cutoff
        }
        let pruned = beforePrune - loaded.count
        jobs = loaded
        FileLogger.shared.info("queue", "loaded \(loaded.count) jobs (interrupted: \(rescued), pruned: \(pruned))")
    }

    func addJob(discName: String, rippedFile: URL, ripElapsed: TimeInterval, resolution: String = "", card: JobCard? = nil, mediaResult: MediaResult? = nil, intent: JobIntent = .movie, editionLabel: String? = nil) {
        let job = Job(discName: discName, rippedFile: rippedFile, ripElapsed: ripElapsed, resolution: resolution, card: card, mediaResult: mediaResult, intent: intent, editionLabel: editionLabel)
        jobs.append(job)
        let extra = editionLabel.map { " {edition-\($0)}" } ?? ""
        FileLogger.shared.info("queue", "added job: \(job.discName) [\(intent.rawValue)\(extra)] <- \(rippedFile.path)")
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
            jobs[idx].finishedAt = Date()
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
        let card = jobs[index].card ?? JobCard(
            discName: jobs[index].discName,
            nasEnabled: config.nasUploadEnabled,
            discord: discord
        )

        // Rip stage already done — only mark if card was just created (no pre-existing card)
        if jobs[index].card == nil {
            await card.finish("rip", detail: formatElapsed(jobs[index].ripElapsed))
        }

        // .extra titles bypass the post-rip pipeline entirely — keep raw rip in place,
        // mark the job done, fire the notification, and return.
        if jobs[index].intent == .extra {
            FileLogger.shared.info("queue", "extra: skipping encode/organize/scrape for \(jobs[index].discName)")
            jobs[index].status = .done
            jobs[index].progress = 100
            jobs[index].progressText = "Extra — kept as raw rip"
            jobs[index].finishedAt = Date()
            await card.skip("encode")
            await card.skip("organize")
            await card.skip("scrape")
            await card.skip("nas")
            await card.complete(footer: "Kept as raw rip (no encode)")
            NotificationService.shared.notify(title: "Extra Saved", message: jobs[index].discName)
            return
        }

        // Use cached TMDb result if available, otherwise look up
        let tmdbMedia: MediaResult?
        if let cached = jobs[index].mediaResult {
            tmdbMedia = cached
        } else {
            let tmdb = TMDbService(config: config)
            tmdbMedia = (await tmdb.searchMedia(query: jobs[index].discName)).first
        }

        // Encode
        jobs[index].status = .encoding
        jobs[index].progressText = "Encoding…"
        await card.start("encode")
        let encodeStart = Date()

        FileLogger.shared.info("queue", "encode start: \(jobs[index].discName) <- \(jobs[index].rippedFile.path)")
        do {
            let encoded = try await encodeJob(at: index)
            let encodeElapsed = Date().timeIntervalSince(encodeStart)
            jobs[index].encodeElapsed = encodeElapsed
            jobs[index].encodedFile = encoded
            FileLogger.shared.info("queue", "encode done: \(jobs[index].discName) in \(formatElapsed(encodeElapsed)) -> \(encoded.path)")
            await card.finish("encode", detail: formatElapsed(encodeElapsed))
            // Delete original rip to save space
            let rippedPath = jobs[index].rippedFile.path
            if rippedPath != encoded.path, FileManager.default.fileExists(atPath: rippedPath) {
                try? FileManager.default.removeItem(at: jobs[index].rippedFile)
            }
        } catch {
            jobs[index].status = .failed
            jobs[index].error = error.localizedDescription
            jobs[index].progressText = "Encode failed"
            jobs[index].finishedAt = Date()
            FileLogger.shared.error("queue", "encode FAILED: \(jobs[index].discName) — \(error.localizedDescription)")
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
            let dest: URL
            let edition = jobs[index].editionLabel
            if let media = tmdbMedia {
                if media.mediaType == "tv" {
                    // For TV, use the TV path builder
                    dest = OrganizerService.buildTvPath(
                        outputDir: config.outputDir,
                        show: media.title,
                        season: 1,
                        episode: 1
                    )
                } else {
                    dest = OrganizerService.buildMoviePath(
                        outputDir: config.outputDir,
                        title: media.title,
                        year: media.year,
                        edition: jobs[index].intent == .edition ? edition : nil
                    )
                }
            } else {
                dest = OrganizerService.buildMoviePath(
                    outputDir: config.outputDir,
                    title: OrganizerService.cleanFilename(jobs[index].discName),
                    edition: jobs[index].intent == .edition ? edition : nil
                )
            }
            let organized = try OrganizerService.organizeFile(source: source, destination: dest)
            jobs[index].organizedFile = organized
            await card.finish("organize")
        } catch {
            jobs[index].status = .failed
            jobs[index].error = error.localizedDescription
            jobs[index].progressText = "Organize failed"
            jobs[index].finishedAt = Date()
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
        let scraped: Bool
        if let media = tmdbMedia {
            scraped = await artwork.scrapeAndSave(media: media, destDir: destDir)
        } else {
            scraped = await artwork.scrapeAndSave(discName: jobs[index].discName, destDir: destDir)
        }
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
                let sourceDir = source.deletingLastPathComponent()
                let folderName = sourceDir.lastPathComponent

                // Pick the right NAS base path based on media type
                let isTV = tmdbMedia?.mediaType == "tv"
                let nasBase = isTV ? config.nasTvPath : config.nasMoviesPath

                guard !nasBase.isEmpty else {
                    await card.skip("nas")
                    // jump to done
                    jobs[index].status = .done
                    jobs[index].progress = 100
                    jobs[index].progressText = "Complete (NAS path not configured)"
                    jobs[index].finishedAt = Date()
                    await card.complete(footer: buildFooter(ripElapsed: jobs[index].ripElapsed, encodeElapsed: jobs[index].encodeElapsed))
                    NotificationService.shared.notify(title: "Job Complete", message: jobs[index].discName)
                    return
                }

                let nasDest = URL(fileURLWithPath: nasBase).appendingPathComponent(folderName)

                // Remove existing destination if present
                let fm = FileManager.default
                if fm.fileExists(atPath: nasDest.path) {
                    try fm.removeItem(at: nasDest)
                }

                // Copy entire organized folder to NAS
                try fm.copyItem(at: sourceDir, to: nasDest)
                jobs[index].progressText = "Copied to NAS: \(nasDest.path)"

                // Clean up local files after successful NAS copy
                try? fm.removeItem(at: sourceDir)

                await card.finish("nas", detail: nasDest.path)
            } catch {
                jobs[index].status = .failed
                jobs[index].error = "NAS copy failed: \(error.localizedDescription)"
                jobs[index].progressText = "NAS copy failed"
                jobs[index].finishedAt = Date()
                await card.fail("nas", detail: error.localizedDescription)
                NotificationService.shared.notify(title: "NAS Copy Failed", message: jobs[index].discName)
                return
            }
        } else {
            await card.skip("nas")
        }

        // Done — clean up rip source directory (if it wasn't already removed by NAS step)
        let ripDir = jobs[index].rippedFile.deletingLastPathComponent()
        let organizedDir = (jobs[index].organizedFile ?? jobs[index].rippedFile).deletingLastPathComponent()
        if ripDir.path != organizedDir.path, FileManager.default.fileExists(atPath: ripDir.path) {
            try? FileManager.default.removeItem(at: ripDir)
        }

        jobs[index].status = .done
        jobs[index].progress = 100
        jobs[index].progressText = "Complete"
        jobs[index].finishedAt = Date()
        await card.complete(footer: buildFooter(ripElapsed: jobs[index].ripElapsed, encodeElapsed: jobs[index].encodeElapsed))
        NotificationService.shared.notify(title: "Job Complete", message: jobs[index].discName)
    }

    private func encodeJob(at index: Int) async throws -> URL {
        let input = jobs[index].rippedFile
        let outputPath = input.deletingPathExtension().path + "_encoded.mkv"

        currentTask = Task {
            // This is just a container for cancellation
        }

        // Pick preset by resolution, fallback to 1080p
        let preset = HandBrakeService.autoPreset(for: jobs[index].resolution)
            ?? "H.265 Apple VideoToolbox 1080p"

        // Pass nil track lists so HandBrake uses --all-audio / --all-subtitles
        // and we skip the separate scanTracks pass (which on large MKVs takes
        // multiple seconds). The result is the same: every track survives.
        let jobId = jobs[index].id
        let result = try await handbrake.encode(
            inputPath: input.path,
            outputPath: outputPath,
            preset: preset,
            audioTracks: nil,
            subtitleTracks: nil,
            progressCallback: { [weak self] pct, text in
                Task { @MainActor in
                    guard let self else { return }
                    if index < self.jobs.count {
                        self.jobs[index].progress = pct
                        self.jobs[index].progressText = text
                    }
                }
            },
            logCallback: { [weak self] line in
                Task { @MainActor in
                    guard let self else { return }
                    if let i = self.jobs.firstIndex(where: { $0.id == jobId }) {
                        self.jobs[i].appendLog(line)
                    }
                }
            }
        )
        currentTask = nil
        return result
    }

    // MARK: - Public actions for Queue/History views

    /// Retry a failed job — resets it to .queued and lets the worker pick it up.
    /// Only valid when the source rip file still exists on disk.
    func retry(jobId: String) {
        guard let i = jobs.firstIndex(where: { $0.id == jobId }) else { return }
        guard jobs[i].status == .failed else { return }
        guard FileManager.default.fileExists(atPath: jobs[i].rippedFile.path) else {
            jobs[i].error = "Source rip is no longer on disk: \(jobs[i].rippedFile.path)"
            return
        }
        jobs[i].status = .queued
        jobs[i].error = ""
        jobs[i].progress = 0
        jobs[i].progressText = "Queued for retry"
        jobs[i].finishedAt = nil
        jobs[i].logLines = []
        FileLogger.shared.info("queue", "retry: \(jobs[i].discName) (\(jobId))")
        startWorkerIfNeeded()
    }

    /// Remove a job from the queue/history (terminal state only).
    func remove(jobId: String) {
        guard let i = jobs.firstIndex(where: { $0.id == jobId }) else { return }
        guard jobs[i].status == .done || jobs[i].status == .failed else { return }
        jobs.remove(at: i)
    }

    /// Active jobs (queued + in-flight).
    var activeJobs: [Job] {
        jobs.filter { $0.status != .done && $0.status != .failed }
    }

    /// History (terminal state), newest first.
    var historyJobs: [Job] {
        jobs.filter { $0.status == .done || $0.status == .failed }
            .sorted { ($0.finishedAt ?? $0.createdAt) > ($1.finishedAt ?? $1.createdAt) }
    }

    private func pruneFinished() {
        let retention = TimeInterval(max(1, config.historyRetentionDays) * 86_400)
        let cutoff = Date().addingTimeInterval(-retention)
        jobs.removeAll { job in
            (job.status == .done || job.status == .failed)
                && (job.finishedAt ?? job.createdAt) < cutoff
        }
    }

    private func formatElapsed(_ interval: TimeInterval) -> String {
        let mins = Int(interval) / 60
        let secs = Int(interval) % 60
        return "\(mins)m \(secs)s"
    }

    private func buildFooter(ripElapsed: TimeInterval, encodeElapsed: TimeInterval) -> String {
        let total = ripElapsed + encodeElapsed
        return "Rip: \(formatElapsed(ripElapsed))  •  Encode: \(formatElapsed(encodeElapsed))  •  Total: \(formatElapsed(total))"
    }
}
