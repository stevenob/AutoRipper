import Foundation

/// Status of a job in the processing queue.
enum JobStatus: String, Sendable {
    case queued, encoding, organizing, scraping, uploading, done, failed
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
    var status: JobStatus = .queued
    var error: String = ""
    var progress: Int = 0
    var progressText: String = "Queued"
    var ripElapsed: TimeInterval = 0
    var encodeElapsed: TimeInterval = 0
    var mediaResult: MediaResult?
    var intent: JobIntent = .movie
    /// For `intent == .edition` only — e.g. "Theatrical", "Director's Cut".
    /// Becomes the `{edition-...}` tag in the output filename.
    var editionLabel: String?
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
             status, error, progress, progressText, ripElapsed, encodeElapsed,
             mediaResult, intent, editionLabel, logLines, createdAt, finishedAt
    }

    init(discName: String, rippedFile: URL, ripElapsed: TimeInterval = 0, resolution: String = "", card: JobCard? = nil, mediaResult: MediaResult? = nil, intent: JobIntent = .movie, editionLabel: String? = nil) {
        self.id = "job_\(Int(Date().timeIntervalSince1970 * 1_000_000))"
        self.discName = discName
        self.rippedFile = rippedFile
        self.ripElapsed = ripElapsed
        self.resolution = resolution
        self.card = card
        self.mediaResult = mediaResult
        self.intent = intent
        self.editionLabel = editionLabel
    }

    /// Append a streaming log line (capped at 200 to keep JSON small).
    mutating func appendLog(_ line: String) {
        logLines.append(line)
        if logLines.count > 200 { logLines.removeFirst(logLines.count - 200) }
    }
}

extension JobStatus: Codable {}
extension JobIntent: Codable {}
