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
    /// v3.11.5: count of `MSG:2003` read errors MakeMKV reported during the
    /// rip phase. Persisted so the History tab can surface "rip had 3 read
    /// errors" alongside the finished file, helping the user decide whether
    /// to re-rip the disc. Defaults to 0 for old jobs in the store.
    var ripReadErrors: Int = 0
    /// v3.11.7: count of MakeMKV data-corruption events (MSG:2002 / 2017 /
    /// 2018) during the rip. Distinct from `ripReadErrors` — see the
    /// docs on `RipViewModel.corruptionEventCount` for the drive-side
    /// (read errors) vs disc-side (corruption events) failure-mode split
    /// that lets the user pattern-match across discs.
    var ripCorruptionEvents: Int = 0
    /// v3.11.12: byte offsets where MSG:2003 read errors fired during the
    /// rip. Capped at `RipViewModel.readErrorOffsetCap` (50) entries.
    /// Drive Health aggregates these across all jobs to detect offset
    /// clustering — when errors on different discs all happen at similar
    /// offsets, the drive's laser tracking at that radius is the
    /// parsimonious explanation.
    var readErrorOffsets: [Int64] = []
    /// v3.11.14: HandBrake stderr ERROR/WARNING lines captured during
    /// the encode phase. Mirrors the v3.11.5 read-error tracking but
    /// for the encode stage. Capped at `encodeWarningCap` per job.
    /// Surfaced in the History detail when non-empty so the user knows
    /// a "successful" encode may have had non-fatal complaints worth
    /// investigating.
    var encodeWarnings: [String] = []
    /// Cap on the persisted `encodeWarnings` array per job. Keeps the
    /// JSON small even on a runaway encode that floods stderr.
    static let encodeWarningCap = 20
    /// v3.12.0: HandBrake audio track ordinals (1-indexed) to keep in
    /// the encode. nil/empty means "all tracks" (HandBrake's default).
    /// Converted from `RipViewModel.selectedAudioTracks` at rip
    /// completion: the position-within-kind of each selected MakeMKV
    /// audio stream becomes its HandBrake ordinal.
    var audioTrackOrdinals: [Int]?
    /// v3.12.0: HandBrake subtitle track ordinals (1-indexed). Same
    /// semantics as `audioTrackOrdinals`.
    var subtitleTrackOrdinals: [Int]?
    /// v3.11.8: explicit folder-name override for the NAS publish step.
    /// Set during the organize step when the local work dir uses a
    /// per-job-unique container (e.g. `<workRoot>/job-abc.../Mortal Kombat (1995)/`).
    /// Without this, `PublishService.publish` would default to using the
    /// local dir's last path component (the year-or-suffixed name) for the
    /// NAS folder — which we want to be clean. Optional / nil for legacy
    /// jobs that organized into the un-suffixed layout.
    var publishDestFolderName: String?
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
             workDir, publishedFile, publishPhase, discFingerprint, ripReadErrors,
             ripCorruptionEvents, publishDestFolderName, readErrorOffsets,
             encodeWarnings, audioTrackOrdinals, subtitleTrackOrdinals,
             status, error, progress, progressText,
             ripElapsed, encodeElapsed, organizeElapsed, scrapeElapsed, nasElapsed,
             mediaResult, intent, editionLabel,
             seasonNumber, episodeNumber, episodeTitle,
             logLines, createdAt, finishedAt
    }

    init(discName: String, rippedFile: URL, ripElapsed: TimeInterval = 0, resolution: String = "", card: JobCard? = nil, mediaResult: MediaResult? = nil, intent: JobIntent = .movie, editionLabel: String? = nil, seasonNumber: Int? = nil, episodeNumber: Int? = nil, episodeTitle: String? = nil, discFingerprint: String? = nil, ripReadErrors: Int = 0, ripCorruptionEvents: Int = 0, readErrorOffsets: [Int64] = [], audioTrackOrdinals: [Int]? = nil, subtitleTrackOrdinals: [Int]? = nil) {
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
        self.ripReadErrors = ripReadErrors
        self.ripCorruptionEvents = ripCorruptionEvents
        self.readErrorOffsets = readErrorOffsets
        self.audioTrackOrdinals = audioTrackOrdinals
        self.subtitleTrackOrdinals = subtitleTrackOrdinals
    }

    /// Append a streaming log line (capped at 200 to keep JSON small).
    mutating func appendLog(_ line: String) {
        logLines.append(line)
        if logLines.count > 200 { logLines.removeFirst(logLines.count - 200) }
    }
}

extension JobStatus: Codable {}
extension JobIntent: Codable {}
