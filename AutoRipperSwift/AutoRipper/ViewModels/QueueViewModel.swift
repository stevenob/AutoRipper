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
    private let stagingService = StagingService()
    private let publishService = PublishService()
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
        let fm = FileManager.default
        for i in loaded.indices where interrupted.contains(loaded[i].status) {
            loaded[i].status = .failed
            loaded[i].error = "Interrupted (app exited mid-job)"
            loaded[i].progressText = "Interrupted"
            loaded[i].finishedAt = Date()
            rescued += 1
            // Best-effort: clean up any `<dest>.partial/` folder/files left
            // behind by an interrupted publish. If publish was in copying or
            // verifying phase the partial dir is at the parent of the (yet-to-
            // exist) publishedFile; if swapping was in flight we can't be
            // 100% sure where it ended up, but the partial pattern is the
            // same. Source workspace stays intact so a retry can re-publish.
            let inPublish = loaded[i].publishPhase == .copying
                || loaded[i].publishPhase == .verifying
                || loaded[i].publishPhase == .swapping
            if inPublish, let pub = loaded[i].publishedFile {
                let partial = pub.deletingLastPathComponent().path + ".partial"
                if fm.fileExists(atPath: partial) {
                    try? fm.removeItem(atPath: partial)
                    FileLogger.shared.warn("queue", "cleaned partial publish: \(partial)")
                }
            }
            // Reset publishPhase so retry starts clean.
            if loaded[i].publishPhase != .done { loaded[i].publishPhase = .notStarted }
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

    func addJob(discName: String, rippedFile: URL, ripElapsed: TimeInterval, resolution: String = "", card: JobCard? = nil, mediaResult: MediaResult? = nil, intent: JobIntent = .movie, editionLabel: String? = nil, seasonNumber: Int? = nil, episodeNumber: Int? = nil, episodeTitle: String? = nil, discFingerprint: String? = nil, ripReadErrors: Int = 0, ripCorruptionEvents: Int = 0) {
        let job = Job(discName: discName, rippedFile: rippedFile, ripElapsed: ripElapsed, resolution: resolution, card: card, mediaResult: mediaResult, intent: intent, editionLabel: editionLabel, seasonNumber: seasonNumber, episodeNumber: episodeNumber, episodeTitle: episodeTitle, discFingerprint: discFingerprint, ripReadErrors: ripReadErrors, ripCorruptionEvents: ripCorruptionEvents)
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
        let queued = jobs.filter { $0.status == .queued }.count
        let inFlight = active.count - queued
        // When the queue is mostly done ("Processing 33 of 33" reads as if
        // we're stuck on the last one but actually means "started job #33"),
        // surface what's actually happening: "Job 33 of 33 · 32 done".
        // When still early ("Job 1 of 33 · 32 queued"), the queued count
        // helps the user see they have a lot of work ahead.
        let position = done + inFlight  // jobs we've started so far
        if queued > 0 {
            return "Job \(position) of \(jobs.count) · \(queued) queued"
        }
        return "Job \(position) of \(jobs.count)"
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

        // ─── v3.6.0 local-encode pipeline ───
        // Derive the work root (where encode/organize/scrape land their files)
        // and the library root (where publish hands the final folder off to).
        //
        // workRoot = ripScratchDir if configured, else outputDir. Either way,
        // it's the local-fast volume the rip is already sitting on, so encode
        // / organize / scrape all run against fast disk.
        //
        // libraryRoot = the NAS movies/tv path (or, when NAS upload is off,
        // outputDir — keeps the legacy "library = outputDir" behavior).
        let workRoot = config.ripScratchDir.isEmpty ? config.outputDir : config.ripScratchDir
        let isTV = tmdbMedia?.mediaType == "tv" || jobs[index].intent == .episode
        let libraryRootStr: String = {
            if config.nasUploadEnabled {
                let base = isTV ? config.nasTvPath : config.nasMoviesPath
                return base.isEmpty ? config.outputDir : base
            }
            return config.outputDir
        }()

        // Pre-flight free space check on workRoot, conservatively budget
        // 2× source size + 1 GB safety margin for HandBrake's encode workspace.
        // ScratchReservationService accounts for any concurrent jobs already
        // holding scratch budget so this passes only if there is *real*
        // headroom right now, not just on paper.
        let sourceSize: Int64 = {
            let attrs = try? FileManager.default.attributesOfItem(atPath: jobs[index].rippedFile.path)
            return (attrs?[.size] as? Int64) ?? 0
        }()
        let requiredBytes: Int64 = sourceSize * 2 + 1_073_741_824
        let reservation = await ScratchReservationService.shared
            .canReserve(atPath: workRoot, additionalBytes: requiredBytes)
        if !reservation.ok {
            jobs[index].status = .failed
            jobs[index].error = "Not enough local space at \(workRoot) — need \(requiredBytes / 1_073_741_824) GB, "
                + "short by \(reservation.shortfallBytes / 1_073_741_824) GB. "
                + "Free up disk or move Rip Scratch Dir to a larger volume."
            jobs[index].progressText = "Insufficient local space"
            jobs[index].finishedAt = Date()
            FileLogger.shared.error("queue", "preflight: \(jobs[index].error)")
            await card.fail("encode", detail: "Insufficient space")
            NotificationService.shared.notify(title: "Insufficient Space", message: jobs[index].discName)
            await GenericWebhookService(config: config).notifyFailed(jobs[index])
            return
        }
        await ScratchReservationService.shared.reserve(jobId: jobs[index].id, bytes: requiredBytes)
        defer { Task { await ScratchReservationService.shared.release(jobId: jobs[index].id) } }

        // If we're retrying a job that already has an organized file on disk,
        // skip encode/organize/scrape — they're done. Jump straight into the
        // publish step. This is the retry-from-publish path.
        let resumeFromPublish = jobs[index].organizedFile != nil
            && FileManager.default.fileExists(atPath: jobs[index].organizedFile!.path)
        if resumeFromPublish {
            FileLogger.shared.info("queue", "resume from publish: \(jobs[index].discName)")
            await card.skip("encode")
            await card.skip("organize")
            await card.skip("scrape")
            await runPublishStep(at: index, card: card, tmdbMedia: tmdbMedia, isTV: isTV)
            return
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
                        outputDir: workRoot,
                        show: media.title,
                        season: jobs[index].seasonNumber ?? 1,
                        episode: jobs[index].episodeNumber ?? 1,
                        episodeName: jobs[index].episodeTitle ?? ""
                    )
                } else {
                    dest = OrganizerService.buildMoviePath(
                        outputDir: workRoot,
                        title: media.title,
                        year: media.year,
                        edition: jobs[index].intent == .edition ? edition : nil
                    )
                }
            } else {
                dest = OrganizerService.buildMoviePath(
                    outputDir: workRoot,
                    title: OrganizerService.cleanFilename(jobs[index].discName),
                    edition: jobs[index].intent == .edition ? edition : nil
                )
            }
            let organized = try OrganizerService.organizeFile(source: source, destination: dest)
            jobs[index].organizedFile = organized
            // Record the work directory so cleanup-on-crash can find and
            // remove it if the publish step doesn't complete.
            jobs[index].workDir = organized.deletingLastPathComponent()
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

        // Publish + done — extracted so retry-from-publish can call it directly.
        await runPublishStep(at: index, card: card, tmdbMedia: tmdbMedia, isTV: isTV)
    }

    /// Publish the job's organized local folder to the NAS library, then mark
    /// done and fire notifications. Called both as the final step of a fresh
    /// pipeline and directly when retrying a job that already has an
    /// organized file on disk.
    private func runPublishStep(at index: Int, card: JobCard, tmdbMedia: MediaResult?, isTV: Bool) async {
        // Publish — hand the locally-organized + scraped folder off to the
        // NAS library. Same-volume hand-offs become server-side renames
        // (instant). Cross-volume hand-offs are chunked + verified copies that
        // **leave the local source intact** until the swap succeeds, so a
        // crash mid-publish is recoverable.
        let nasStart = Date()
        if config.nasUploadEnabled {
            jobs[index].status = .uploading
            jobs[index].progressText = "Publishing — 0%"
            jobs[index].publishPhase = .copying
            await card.start("nas")

            do {
                let source = jobs[index].organizedFile ?? jobs[index].rippedFile
                let sourceDir = source.deletingLastPathComponent()
                let nasBase = isTV ? config.nasTvPath : config.nasMoviesPath

                guard !nasBase.isEmpty else {
                    await card.skip("nas")
                    // jump to done
                    jobs[index].status = .done
                    jobs[index].progress = 100
                    jobs[index].progressText = "Complete (NAS path not configured)"
                    jobs[index].finishedAt = Date()
                    jobs[index].nasElapsed = Date().timeIntervalSince(nasStart)
                    jobs[index].publishPhase = .notStarted
                    await card.complete(footer: buildFooter(ripElapsed: jobs[index].ripElapsed, encodeElapsed: jobs[index].encodeElapsed))
                    NotificationService.shared.notify(title: "Job Complete", message: jobs[index].discName)
                    await GenericWebhookService(config: config).notifyComplete(jobs[index])
                    return
                }

                let libraryRoot = URL(fileURLWithPath: nasBase)
                let jobIdx = index
                let jobId = jobs[index].id
                let publishedDir = try await publishService.publish(
                    localDir: sourceDir,
                    libraryRoot: libraryRoot,
                    progress: { [weak self] copied, total in
                        Task { @MainActor in
                            guard let self, total > 0 else { return }
                            let pct = Int(Double(copied) / Double(total) * 100)
                            guard self.jobs.indices.contains(jobIdx),
                                  self.jobs[jobIdx].id == jobId,
                                  self.jobs[jobIdx].status == .uploading else { return }
                            if pct != self.jobs[jobIdx].progress {
                                self.jobs[jobIdx].progress = pct
                                self.jobs[jobIdx].progressText = "Publishing — \(pct)%"
                            }
                        }
                    },
                    phaseUpdate: { [weak self] phase in
                        Task { @MainActor in
                            guard let self else { return }
                            guard self.jobs.indices.contains(jobIdx),
                                  self.jobs[jobIdx].id == jobId else { return }
                            self.jobs[jobIdx].publishPhase = phase
                        }
                    }
                )
                // Resolve the published file's final URL (organized file's
                // name relative to its old parent dir, but rooted at
                // publishedDir).
                let oldPath = source.path
                let prefix = sourceDir.path + "/"
                let rel = oldPath.hasPrefix(prefix)
                    ? String(oldPath.dropFirst(prefix.count))
                    : source.lastPathComponent
                var finalURL = publishedDir
                for c in rel.split(separator: "/") {
                    finalURL = finalURL.appendingPathComponent(String(c))
                }
                jobs[index].publishedFile = finalURL
                jobs[index].progressText = "Published: \(publishedDir.path)"

                // Now that the dest is verified, we can drop the local
                // workspace. The PublishService.renamePerFile path already
                // moves files out (so source is gone for same-volume); for
                // cross-volume keep-source we do the cleanup here.
                //
                // v3.11.6: defensive — only remove the source dir if it's
                // empty *of foreign files*. We enumerate, drop any files
                // that belong to this job (the organized file + scrape
                // siblings live here by design), then remove the dir only
                // if nothing else is left. Protects against a sibling
                // job's rip source accidentally living in the same dir.
                Self.cleanupOwnedFilesAndRemoveDirIfEmpty(
                    dir: sourceDir,
                    ownedFiles: [jobs[index].organizedFile, jobs[index].rippedFile].compactMap { $0 }
                )
                jobs[index].workDir = nil
                jobs[index].publishPhase = .done
                jobs[index].nasElapsed = Date().timeIntervalSince(nasStart)
                await card.finish("nas", detail: publishedDir.path)

                // v3.7.1: record this disc as published in the registry so
                // future re-insertions of the same disc surface a "Already
                // ripped on <date>" banner. Only records if a fingerprint
                // was supplied (older queue jobs may not have one).
                if let fp = jobs[index].discFingerprint, !fp.isEmpty {
                    let entry = RippedDiscEntry(
                        date: Date(),
                        discName: jobs[index].discName,
                        publishedPath: publishedDir.path
                    )
                    Task { await RippedDiscRegistry.shared.record(fingerprint: fp, entry: entry) }
                }

                // v3.7: best-effort library refresh hooks. Fire after a
                // successful publish so newly ripped media shows up in Plex /
                // Jellyfin within seconds. Failures are logged but never block
                // the otherwise-successful job — the file is already on the NAS.
                let notifier = LibraryNotifierService(config: config)
                let results = await notifier.notifyAfterPublish(isTV: isTV)
                for r in results {
                    switch r {
                    case .success(let server):
                        FileLogger.shared.info("queue", "library refresh: \(server) ✓")
                    case .failure(let server, let err):
                        FileLogger.shared.warn("queue", "library refresh: \(server) ✗ \(err)")
                    case .skipped:
                        break  // expected when not configured
                    }
                }
            } catch {
                jobs[index].status = .failed
                jobs[index].error = "Publish failed: \(error.localizedDescription)"
                jobs[index].progressText = "Publish failed"
                jobs[index].finishedAt = Date()
                jobs[index].nasElapsed = Date().timeIntervalSince(nasStart)
                await card.fail("nas", detail: error.localizedDescription)
                NotificationService.shared.notify(title: "Publish Failed", message: jobs[index].discName)
                await GenericWebhookService(config: config).notifyFailed(jobs[index])
                return
            }
        } else {
            await card.skip("nas")
        }

        // Done — clean up rip source directory (if it wasn't already removed
        // by the publish step above).
        //
        // v3.11.6: this is the high-risk cleanup. Pre-v3.11.6 we did a blind
        // removeItem(at: ripDir), which wiped the entire scratch parent —
        // including any sibling job's not-yet-encoded rip source if it
        // happened to share the same parent. We now remove only files this
        // job knows about, then drop the parent only if empty.
        let ripDir = jobs[index].rippedFile.deletingLastPathComponent()
        let organizedDir = (jobs[index].organizedFile ?? jobs[index].rippedFile).deletingLastPathComponent()
        if ripDir.path != organizedDir.path {
            Self.cleanupOwnedFilesAndRemoveDirIfEmpty(
                dir: ripDir,
                ownedFiles: [jobs[index].rippedFile, jobs[index].encodedFile].compactMap { $0 }
            )
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

        // Choose the most-advanced still-existing source for retry.
        // - If publish failed but encode/organize succeeded, the organized
        //   file in workDir is the authoritative starting point — re-publish
        //   from there, skip re-encoding.
        // - If encode failed, restart from rippedFile (raw rip).
        let fm = FileManager.default
        if let organized = jobs[i].organizedFile,
           fm.fileExists(atPath: organized.path) {
            // Resume from publish — organized file is the authoritative copy
            // of what should land in the library.
            FileLogger.shared.info("queue", "retry from publish: \(jobs[i].discName) (\(jobId))")
            jobs[i].status = .queued
            jobs[i].error = ""
            jobs[i].progress = 0
            jobs[i].progressText = "Queued for retry (publish)"
            jobs[i].finishedAt = nil
            jobs[i].publishPhase = .notStarted
            jobs[i].logLines = []
            startWorkerIfNeeded()
            return
        }
        // Otherwise the queue worker will redo encode from rippedFile.
        guard fm.fileExists(atPath: jobs[i].rippedFile.path) else {
            jobs[i].error = "Source rip is no longer on disk: \(jobs[i].rippedFile.path)"
            return
        }
        jobs[i].status = .queued
        jobs[i].error = ""
        jobs[i].progress = 0
        jobs[i].progressText = "Queued for retry"
        jobs[i].finishedAt = nil
        jobs[i].publishPhase = .notStarted
        jobs[i].logLines = []
        FileLogger.shared.info("queue", "retry from rip: \(jobs[i].discName) (\(jobId))")
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

    /// Aggregate stats over completed history jobs, formatted for display
    /// in the History tab's badge / header. Returns nil when no completed
    /// jobs exist yet (caller shows the simpler "X completed" badge).
    ///
    /// Computed:
    ///   * count       — completed jobs in history
    ///   * runtimeHrs  — total wall-clock pipeline time across all jobs
    ///   * mediaHours  — total content runtime (rip-time as proxy if title
    ///                   length isn't persisted on Job; in practice rip
    ///                   time correlates closely with disc runtime)
    ///   * sizesAvail  — true iff at least one job has rippedFile + encodedFile
    ///                   on disk so we can compute compression savings
    ///   * compressionRatio — encoded/raw, only when sizesAvail
    var historyStats: HistoryStats? {
        let completed = historyJobs
        guard !completed.isEmpty else { return nil }
        let totalPipelineTime = completed.reduce(0.0) { sum, j in
            sum + j.ripElapsed + j.encodeElapsed + j.organizeElapsed
                + j.scrapeElapsed + j.nasElapsed
        }
        let totalRipTime = completed.reduce(0.0) { $0 + $1.ripElapsed }
        return HistoryStats(
            count: completed.count,
            totalPipelineSeconds: totalPipelineTime,
            totalRipSeconds: totalRipTime,
            averagePerJobSeconds: totalPipelineTime / Double(completed.count)
        )
    }
}

/// Aggregate stats over the completed History tab, computed on demand
/// from `QueueViewModel.jobs`. Lightweight value type so the UI can hold
/// snapshots in @State without observing the whole queue.
struct HistoryStats: Sendable, Equatable {
    let count: Int
    let totalPipelineSeconds: TimeInterval
    let totalRipSeconds: TimeInterval
    let averagePerJobSeconds: TimeInterval

    /// e.g. "33 discs · 42h 18m total processing · ~1h 17m avg/job"
    var summaryLine: String {
        let totalHM = Self.formatHM(totalPipelineSeconds)
        let avgHM = Self.formatHM(averagePerJobSeconds)
        let noun = count == 1 ? "disc" : "discs"
        return "\(count) \(noun) · \(totalHM) total processing · ~\(avgHM) avg/job"
    }

    private static func formatHM(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        let h = s / 3600
        let m = (s % 3600) / 60
        if h == 0 { return "\(m)m" }
        return "\(h)h \(m)m"
    }
}

extension QueueViewModel {
    // Helper stub so HistoryStats stays defined at file scope and Sendable.

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

    /// v3.11.6: targeted scratch-dir cleanup. Removes only the files this
    /// job knows it owns (typically the rip source, encoded output, and/or
    /// organized output), then drops the parent dir **only** if no foreign
    /// files remain. Subdirectories are inspected non-recursively (their
    /// presence keeps the parent alive).
    ///
    /// Background: prior to v3.11.6 the post-publish and post-done cleanup
    /// blindly called `removeItem(at: parentDir)`. When two simultaneously
    /// queued discs happened to share a scratch folder (e.g. both resolved
    /// to "Mortal Kombat II (2026)" via TMDb scrape), the first job's
    /// cleanup wiped the second job's not-yet-encoded rip source. v3.11.6
    /// fixes the collision at the source (per-disc-unique scratch names)
    /// AND defends against any future collision by making cleanup file-
    /// aware instead of dir-aware.
    ///
    /// Visible-for-tests as `internal static` so unit tests can exercise
    /// the file-owning semantics without spinning up a full QueueViewModel.
    static func cleanupOwnedFilesAndRemoveDirIfEmpty(dir: URL, ownedFiles: [URL]) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return }
        // Canonicalize the target dir once: standardize URL syntax AND
        // resolve symlinks so we compare against the real on-disk path.
        // Without symlink resolution, an owned file that lives under an
        // aliased path could be considered "outside" and skipped, leaving
        // scratch dirs uncleaned (mostly a false-negative — safer than
        // false-positives, but still worth handling).
        let canonicalDir = dir.resolvingSymlinksInPath().standardizedFileURL
        // Remove only the files we explicitly own. Anything else (e.g. a
        // sibling job's rip source) stays put.
        for f in ownedFiles {
            // Only touch files inside `dir` — never reach across into
            // unrelated paths. Defense in depth in case a caller passes a
            // file whose parent isn't `dir`.
            let canonicalParent = f.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
            guard canonicalParent == canonicalDir else { continue }
            if fm.fileExists(atPath: f.path) {
                try? fm.removeItem(at: f)
            }
        }
        // Drop the parent dir only if empty (ignoring hidden dotfiles like
        // .DS_Store which we consider OS noise, not user data).
        let contents = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        let nonHidden = contents.filter { !$0.hasPrefix(".") }
        if nonHidden.isEmpty {
            try? fm.removeItem(at: dir)
        } else {
            FileLogger.shared.info(
                "queue",
                "skip scratch dir cleanup (\(nonHidden.count) foreign file(s) remain): \(dir.path)"
            )
        }
    }
}
