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
    /// In-memory ring buffer of recent fps samples per active encode job. Capped
    /// at 60 samples (~1 minute of HandBrake's progress callbacks at ~1Hz).
    @Published private(set) var fpsHistory: [String: [Double]] = [:]
    private static let fpsHistoryCap = 60

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
        let prunedIds = loaded.filter { job in
            (job.status == .done || job.status == .failed)
                && (job.finishedAt ?? job.createdAt) < cutoff
        }.map(\.id)
        for id in prunedIds { ThumbnailExtractor.shared.remove(jobId: id) }
        loaded.removeAll { prunedIds.contains($0.id) }
        let pruned = beforePrune - loaded.count
        jobs = loaded
        FileLogger.shared.info("queue", "loaded \(loaded.count) jobs (interrupted: \(rescued), pruned: \(pruned))")
    }

    func addJob(discName: String, rippedFile: URL, ripElapsed: TimeInterval, resolution: String = "", card: JobCard? = nil, mediaResult: MediaResult? = nil, intent: JobIntent = .movie, editionLabel: String? = nil, seasonNumber: Int? = nil, episodeNumber: Int? = nil, episodeTitle: String? = nil) {
        let job = Job(discName: discName, rippedFile: rippedFile, ripElapsed: ripElapsed, resolution: resolution, card: card, mediaResult: mediaResult, intent: intent, editionLabel: editionLabel, seasonNumber: seasonNumber, episodeNumber: episodeNumber, episodeTitle: episodeTitle)
        jobs.append(job)
        let extra = editionLabel.map { " {edition-\($0)}" } ?? ""
        let ep = (seasonNumber != nil || episodeNumber != nil)
            ? " S\(seasonNumber ?? 0)E\(episodeNumber ?? 0)"
            : ""
        FileLogger.shared.info("queue", "added job: \(job.discName) [\(intent.rawValue)\(extra)\(ep)] <- \(rippedFile.path)")
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
            await GenericWebhookService(config: config).notifyComplete(jobs[index])
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
        if config.preventSleep { SleepAssertion.shared.acquire(reason: "AutoRipper encode in progress") }
        defer { if config.preventSleep { SleepAssertion.shared.release() } }

        FileLogger.shared.info("queue", "encode start: \(jobs[index].discName) <- \(jobs[index].rippedFile.path)")
        do {
            let encoded = try await encodeJob(at: index)
            let encodeElapsed = Date().timeIntervalSince(encodeStart)
            jobs[index].encodeElapsed = encodeElapsed
            jobs[index].encodedFile = encoded
            FileLogger.shared.info("queue", "encode done: \(jobs[index].discName) in \(formatElapsed(encodeElapsed)) -> \(encoded.path)")
            await card.finish("encode", detail: formatElapsed(encodeElapsed))

            // Extract preview thumbnails (best-effort — silent failure is fine).
            // Captured async so the rest of the pipeline doesn't block on HandBrake.
            let jobId = jobs[index].id
            let hbPath = config.handbrakePath
            let encodedPath = encoded.path
            Task.detached(priority: .utility) {
                await ThumbnailExtractor.shared.extract(jobId: jobId, inputPath: encodedPath, count: 6, handbrakePath: hbPath)
            }

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
            await GenericWebhookService(config: config).notifyFailed(jobs[index])
            return
        }

        // Organize
        jobs[index].status = .organizing
        jobs[index].progressText = "Organizing…"
        await card.start("organize")
        let organizeStart = Date()

        do {
            let source = jobs[index].encodedFile ?? jobs[index].rippedFile
            let dest: URL
            let edition = jobs[index].editionLabel
            if let media = tmdbMedia {
                if media.mediaType == "tv" || jobs[index].intent == .episode {
                    // TV — use job's season/episode/title fields if set, else
                    // fall back to S01E01 placeholder. v3.3.0's picker UI
                    // populates the fields; today they're typically nil.
                    dest = OrganizerService.buildTvPath(
                        outputDir: config.outputDir,
                        show: media.title,
                        season: jobs[index].seasonNumber ?? 1,
                        episode: jobs[index].episodeNumber ?? 1,
                        episodeName: jobs[index].episodeTitle ?? ""
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
            jobs[index].organizeElapsed = Date().timeIntervalSince(organizeStart)
            await card.finish("organize")
        } catch {
            jobs[index].status = .failed
            jobs[index].error = error.localizedDescription
            jobs[index].progressText = "Organize failed"
            jobs[index].finishedAt = Date()
            jobs[index].organizeElapsed = Date().timeIntervalSince(organizeStart)
            await card.fail("organize", detail: error.localizedDescription)
            return
        }

        // Scrape
        jobs[index].status = .scraping
        jobs[index].progressText = "Scraping artwork…"
        await card.start("scrape")
        let scrapeStart = Date()

        let destDir = (jobs[index].organizedFile ?? jobs[index].rippedFile)
            .deletingLastPathComponent()
        let artwork = ArtworkService()
        let scraped: Bool
        // For TV episodes, write per-episode NFO + show-level artwork. The
        // organize step landed the file in Show/Season XX/Show - SXXEXX.mkv,
        // so destDir here is the season folder. ArtworkService writes the
        // show-level files to its parent (handled internally).
        if jobs[index].intent == .episode || tmdbMedia?.mediaType == "tv" {
            scraped = await artwork.scrapeAndSaveEpisode(
                discName: tmdbMedia?.title ?? jobs[index].discName,
                destDir: destDir,
                season: jobs[index].seasonNumber ?? 1,
                episode: jobs[index].episodeNumber ?? 1,
                episodeName: jobs[index].episodeTitle ?? ""
            )
        } else if let media = tmdbMedia {
            scraped = await artwork.scrapeAndSave(media: media, destDir: destDir)
        } else {
            scraped = await artwork.scrapeAndSave(discName: jobs[index].discName, destDir: destDir)
        }
        jobs[index].scrapeElapsed = Date().timeIntervalSince(scrapeStart)
        if scraped {
            await card.finish("scrape")
        } else {
            await card.fail("scrape", detail: "No TMDb results")
        }

        // NAS upload
        let nasStart = Date()
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
                    jobs[index].nasElapsed = Date().timeIntervalSince(nasStart)
                    await card.complete(footer: buildFooter(ripElapsed: jobs[index].ripElapsed, encodeElapsed: jobs[index].encodeElapsed))
                    NotificationService.shared.notify(title: "Job Complete", message: jobs[index].discName)
                    await GenericWebhookService(config: config).notifyComplete(jobs[index])
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

                // Clean up local files after successful NAS copy — frees disk space.
                try? fm.removeItem(at: sourceDir)

                jobs[index].nasElapsed = Date().timeIntervalSince(nasStart)
                await card.finish("nas", detail: nasDest.path)
            } catch {
                jobs[index].status = .failed
                jobs[index].error = "NAS copy failed: \(error.localizedDescription)"
                jobs[index].progressText = "NAS copy failed"
                jobs[index].finishedAt = Date()
                jobs[index].nasElapsed = Date().timeIntervalSince(nasStart)
                await card.fail("nas", detail: error.localizedDescription)
                NotificationService.shared.notify(title: "NAS Copy Failed", message: jobs[index].discName)
                await GenericWebhookService(config: config).notifyFailed(jobs[index])
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
        await GenericWebhookService(config: config).notifyComplete(jobs[index])

        // Disk space may have just been freed (NAS copy + local cleanup). Give any
        // jobs that previously failed with disk-space errors another shot.
        retryDiskSpaceFailures()
    }

    /// Walks the queue and re-queues any failed-with-disk-space jobs. Triggered
    /// after a successful NAS upload (which frees local disk space) and after
    /// any other operation that meaningfully reclaims storage.
    func retryDiskSpaceFailures() {
        let candidates = jobs.enumerated().filter { _, job in
            job.status == .failed && Self.isDiskSpaceFailure(job)
        }.map { $0.offset }

        for i in candidates {
            // Sanity: source must still exist on disk to retry.
            guard FileManager.default.fileExists(atPath: jobs[i].rippedFile.path) else { continue }
            FileLogger.shared.info("queue", "auto-retrying disk-space failure: \(jobs[i].discName)")
            jobs[i].status = .queued
            jobs[i].error = ""
            jobs[i].progress = 0
            jobs[i].progressText = "Re-queued (disk space freed)"
            jobs[i].finishedAt = nil
            jobs[i].logLines = []
        }
        if !candidates.isEmpty { startWorkerIfNeeded() }
    }

    /// Heuristic: true if the failure looks like a disk-space problem. Catches
    /// both the pre-flight check (HandBrakeService.preflightDiskSpace) and the
    /// HandBrake mid-encode "No space left on device" error.
    static func isDiskSpaceFailure(_ job: Job) -> Bool {
        let msg = job.error.lowercased()
        return msg.contains("not enough free space")
            || msg.contains("no space left on device")
            || (msg.contains("exit code 4") && msg.contains("space"))
    }

    /// Extract an FPS reading like "62.4 fps" from a HandBrake progress line.
    static func extractFPS(from text: String) -> Double? {
        // Match "<float> fps" — HandBrake's PRGV-derived status line typically
        // contains something like "Encoding: 43% — ETA 14m32s (62.4 fps)".
        guard let regex = try? NSRegularExpression(pattern: #"(\d+(?:\.\d+)?)\s*fps"#) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = regex.firstMatch(in: text, range: range),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return Double(text[r])
    }

    private func encodeJob(at index: Int) async throws -> URL {
        let input = jobs[index].rippedFile
        let outputPath = input.deletingPathExtension().path + "_encoded.mkv"

        currentTask = Task {
            // This is just a container for cancellation
        }

        // If the job has no resolution (typically because it was imported via drag-
        // and-drop rather than ripped from a disc), scan the source so autoPreset
        // can pick the right preset. Otherwise a 4K MKV would be downscaled to
        // the 1080p fallback preset.
        if jobs[index].resolution.isEmpty {
            let detected = await handbrake.scanResolution(inputPath: input.path)
            if !detected.isEmpty {
                jobs[index].resolution = detected
                FileLogger.shared.info("queue", "scanned resolution for \(input.lastPathComponent): \(detected)")
            }
        }

        // Pick preset by resolution, fallback to 1080p
        let preset = HandBrakeService.autoPreset(for: jobs[index].resolution)
            ?? "H.265 Apple VideoToolbox 1080p"
        FileLogger.shared.info("queue", "encode preset: \(preset) (resolution=\(jobs[index].resolution.isEmpty ? "unknown" : jobs[index].resolution))")

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
                        // Parse "(62.4 fps)" out of the progress text and append
                        // to the rolling fps history for this job.
                        if let fps = Self.extractFPS(from: text) {
                            var hist = self.fpsHistory[jobId] ?? []
                            hist.append(fps)
                            if hist.count > Self.fpsHistoryCap {
                                hist.removeFirst(hist.count - Self.fpsHistoryCap)
                            }
                            self.fpsHistory[jobId] = hist
                        }
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
        ThumbnailExtractor.shared.remove(jobId: jobId)
        jobs.remove(at: i)
    }

    /// Re-run TMDb lookup with a user-supplied query for a job that's already in
    /// the queue/history. Updates `mediaResult` and `discName` so the remaining
    /// pipeline stages (organize/scrape) use the corrected metadata.
    ///
    /// Safe to call from any non-terminal stage — but if organize has already
    /// moved the file, the user will need to manually move it (we don't reorganize
    /// completed jobs to avoid overwriting NAS-uploaded files).
    func reidentify(jobId: String, newQuery: String) async {
        guard let i = jobs.firstIndex(where: { $0.id == jobId }) else { return }
        let trimmed = newQuery.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        FileLogger.shared.info("queue", "reidentify \(jobs[i].discName) -> \(trimmed)")
        let tmdb = TMDbService(config: config)
        let results = await tmdb.searchMedia(query: trimmed)
        var match = results.first
        if var m = match {
            if m.mediaType == "movie", let d = await tmdb.getMovieDetails(tmdbId: m.tmdbId) { m = d }
            else if m.mediaType == "tv", let d = await tmdb.getTvDetails(tmdbId: m.tmdbId) { m = d }
            match = m
        }
        guard let i2 = jobs.firstIndex(where: { $0.id == jobId }) else { return }
        jobs[i2].discName = trimmed
        jobs[i2].mediaResult = match
        if let m = match {
            FileLogger.shared.info("queue", "reidentify: matched \(m.displayTitle)")
        } else {
            FileLogger.shared.warn("queue", "reidentify: still no TMDb match for \"\(trimmed)\"")
        }
    }

    /// Reorder a queued job to a different position. Only operates on `.queued`
    /// jobs — in-flight, failed, and completed jobs keep their relative position
    /// so the worker's "find next queued" semantics aren't disturbed.
    func reorder(jobId: String, to newQueuedIndex: Int) {
        guard let from = jobs.firstIndex(where: { $0.id == jobId }) else { return }
        guard jobs[from].status == .queued else { return }
        let queuedIndices = jobs.enumerated().filter { $0.element.status == .queued }.map { $0.offset }
        guard !queuedIndices.isEmpty else { return }
        let clampedTarget = max(0, min(newQueuedIndex, queuedIndices.count - 1))
        let targetIdx = queuedIndices[clampedTarget]
        guard from != targetIdx else { return }
        let job = jobs.remove(at: from)
        let insertAt = from < targetIdx ? targetIdx : targetIdx
        jobs.insert(job, at: insertAt)
        FileLogger.shared.info("queue", "reordered \(job.discName) to position \(clampedTarget) of queued jobs")
    }

    /// Drag-and-drop reorder helper: moves `droppedId` to immediately before
    /// `targetId`. Both must be queued (in-flight/failed/done are no-ops).
    /// Returns true if a reorder happened.
    @discardableResult
    func reorder(droppedId: String, beforeTargetId targetId: String) -> Bool {
        guard droppedId != targetId else { return false }
        guard let from = jobs.firstIndex(where: { $0.id == droppedId }) else { return false }
        guard let to = jobs.firstIndex(where: { $0.id == targetId }) else { return false }
        guard jobs[from].status == .queued, jobs[to].status == .queued else { return false }
        let job = jobs.remove(at: from)
        let insertAt = from < to ? to - 1 : to
        jobs.insert(job, at: insertAt)
        FileLogger.shared.info("queue", "reorder: moved \(job.discName) into position \(insertAt)")
        return true
    }

    /// Bulk Retry — applied to any failed jobs in the supplied id set.
    func retryAll(jobIds: Set<String>) {
        for id in jobIds { retry(jobId: id) }
    }

    /// Bulk Remove — only valid for terminal jobs (.done or .failed).
    func removeAll(jobIds: Set<String>) {
        for id in jobIds { remove(jobId: id) }
    }

    /// Bulk Cancel — abort the in-flight job (if its id is in the set) and mark
    /// any queued jobs in the set as failed-by-user.
    func cancelAll(jobIds: Set<String>) {
        for id in jobIds {
            guard let i = jobs.firstIndex(where: { $0.id == id }) else { continue }
            switch jobs[i].status {
            case .queued:
                jobs[i].status = .failed
                jobs[i].error = "Cancelled by user"
                jobs[i].progressText = "Cancelled"
                jobs[i].finishedAt = Date()
            case .encoding, .organizing, .scraping, .uploading:
                abortCurrent()
            default:
                break
            }
        }
    }
    /// Active jobs: queued, in-flight, AND failed (failures stay in queue so the
    /// user can Retry without digging through history). Only completed jobs leave.
    var activeJobs: [Job] {
        jobs.filter { $0.status != .done }
    }

    /// Number of failed jobs in the queue — used by the sidebar badge to surface
    /// attention-needed counts separately from in-flight progress.
    var failedCount: Int {
        jobs.filter { $0.status == .failed }.count
    }

    /// History (completed only), newest first.
    var historyJobs: [Job] {
        jobs.filter { $0.status == .done }
            .sorted { ($0.finishedAt ?? $0.createdAt) > ($1.finishedAt ?? $1.createdAt) }
    }

    /// Heuristic estimated remaining time across active jobs in the queue. Returns
    /// nil if no in-flight job has enough data to estimate yet.
    func totalRemainingETA() -> TimeInterval? {
        var total: TimeInterval = 0
        var hasEstimate = false
        for job in jobs where job.status != .done && job.status != .failed {
            switch job.status {
            case .encoding:
                // Use elapsed encode time + remaining %, capped at sensible range.
                if job.progress > 5 {
                    let elapsed = (Date().timeIntervalSince(job.createdAt))
                    let perPct = elapsed / Double(job.progress)
                    let remaining = perPct * Double(100 - job.progress)
                    if remaining > 0 && remaining < 86_400 {
                        total += remaining
                        hasEstimate = true
                    }
                }
            case .organizing, .scraping, .uploading:
                total += 30  // typically <1m each; rough bucket
                hasEstimate = true
            case .queued:
                // Use the average completed-job encode time as a rough estimate.
                let avg = averageEncodeElapsed
                total += avg
                hasEstimate = true
            default: break
            }
        }
        return hasEstimate ? total : nil
    }

    private var averageEncodeElapsed: TimeInterval {
        let done = jobs.filter { $0.status == .done && $0.encodeElapsed > 0 }
        guard !done.isEmpty else { return 1200 }  // 20-min default for first run
        let sum = done.reduce(0.0) { $0 + $1.encodeElapsed }
        return sum / Double(done.count)
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
