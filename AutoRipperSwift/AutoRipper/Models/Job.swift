import Foundation

/// Status of a job in the processing queue.
enum JobStatus: String, Sendable {
    case queued, encoding, organizing, scraping, uploading, done, failed
}

/// Phase of the publish step (the final NAS hand-off). Used so retry can
/// resume from the right point and crash-recovery on relaunch can clean up
/// `<dest>.partial/` scaffolding for jobs interrupted mid-publish.
enum PublishPhase: String, Sendable, Codable {
    case notStarted    // publish hasn't begun (or job hasn't reached publish yet)
    case copying       // PublishService is per-file copying into <dest>.partial/
    case verifying     // copy done, verifying byte sizes match
    case swapping      // partial -> final rename in progress
    case done          // published; published file lives at job.publishedFile
}

/// What kind of content a queued title represents. Used by the post-rip pipeline
/// to decide naming, organizing, and whether to encode at all.
enum JobIntent: String, Sendable {
    case movie     // standard single-feature movie
    case episode   // TV episode
    case edition   // alternate cut of a movie (theatrical/unrated/director's cut)
    case extra     // bonus content — keep raw rip, skip encode/organize/scrape
}

/// A single ripped file going through the post-rip pipeline.
struct Job: Identifiable, Sendable, Codable {
    let id: String
    var discName: String
    let rippedFile: URL
    var resolution: String = ""
    var encodedFile: URL?
    var organizedFile: URL?
    /// Local-scratch directory the encode/organize/scrape pipeline writes into
    /// when the local-encode flow is active (v3.6.0+). Allows cleanup-on-crash
    /// to find and remove the work area when a job is interrupted, and gives
    /// retry logic a stable anchor for the in-flight workspace.
    var workDir: URL?
    /// Final NAS / library path of the published file. Nil until publish
    /// completes. `Reveal in Finder` and webhook payloads prefer this when set.
    var publishedFile: URL?
    /// Where in the publish step we are. Used by retry-from-phase logic and by
    /// the relaunch cleanup to know whether to nuke a `<dest>.partial/`.
    var publishPhase: PublishPhase = .notStarted
    /// Stable disc fingerprint computed at scan time. Persisted with the job
    /// so v3.7.1's `RippedDiscRegistry` can record it when publish completes.
    /// Optional for backward compat — old jobs in the store don't have one,
    /// and we just skip recording for them.
    var discFingerprint: String?
    var status: JobStatus = .queued
    var error: String = ""
    var progress: Int = 0
    var progressText: String = "Queued"
    var ripElapsed: TimeInterval = 0
    var encodeElapsed: TimeInterval = 0
    var organizeElapsed: TimeInterval = 0
    var scrapeElapsed: TimeInterval = 0
    var nasElapsed: TimeInterval = 0
    var mediaResult: MediaResult?
    var intent: JobIntent = .movie
    /// For `intent == .edition` only — e.g. "Theatrical", "Director's Cut".
    /// Becomes the `{edition-...}` tag in the output filename.
    var editionLabel: String?
    /// TV episode metadata — populated when `intent == .episode`. v3.3.0 picker UI
    /// will set these; today they're optional and `processJob` falls back to S01E01.
    var seasonNumber: Int?
    var episodeNumber: Int?
    var episodeTitle: String?
    /// Streaming log lines from HandBrake/MakeMKV captured during processing.
    /// Capped at 200 lines to keep persisted JSON small.
    var logLines: [String] = []
    /// When the job was created (used for history retention pruning).
    var createdAt: Date = Date()
    /// When the job reached a terminal state (.done or .failed). Nil while in flight.
    var finishedAt: Date?

    /// JobCard is a class with a non-Codable Discord webhook session — it's runtime
    /// state, not durable. Skipped during serialization and rebuilt on demand.
    nonisolated(unsafe) var card: JobCard?

    private enum CodingKeys: String, CodingKey {
        case id, discName, rippedFile, resolution, encodedFile, organizedFile,
             workDir, publishedFile, publishPhase, discFingerprint,
             status, error, progress, progressText,
             ripElapsed, encodeElapsed, organizeElapsed, scrapeElapsed, nasElapsed,
             mediaResult, intent, editionLabel,
             seasonNumber, episodeNumber, episodeTitle,
             logLines, createdAt, finishedAt
    }

    init(discName: String, rippedFile: URL, ripElapsed: TimeInterval = 0, resolution: String = "", card: JobCard? = nil, mediaResult: MediaResult? = nil, intent: JobIntent = .movie, editionLabel: String? = nil, seasonNumber: Int? = nil, episodeNumber: Int? = nil, episodeTitle: String? = nil, discFingerprint: String? = nil) {
        self.id = "job_\(Int(Date().timeIntervalSince1970 * 1_000_000))"
        self.discName = discName
        self.rippedFile = rippedFile
        self.ripElapsed = ripElapsed
        self.resolution = resolution
        self.card = card
        self.mediaResult = mediaResult
        self.intent = intent
        self.editionLabel = editionLabel
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.episodeTitle = episodeTitle
        self.discFingerprint = discFingerprint
    }

    /// Append a streaming log line (capped at 200 to keep JSON small).
    mutating func appendLog(_ line: String) {
        logLines.append(line)
        if logLines.count > 200 { logLines.removeFirst(logLines.count - 200) }
    }
}

extension JobStatus: Codable {}
extension JobIntent: Codable {}
