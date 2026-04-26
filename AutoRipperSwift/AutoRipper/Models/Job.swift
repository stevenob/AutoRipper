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
struct Job: Identifiable, Sendable {
    let id: String
    let discName: String
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
    nonisolated(unsafe) var card: JobCard?

    init(discName: String, rippedFile: URL, ripElapsed: TimeInterval = 0, resolution: String = "", card: JobCard? = nil, mediaResult: MediaResult? = nil, intent: JobIntent = .movie) {
        self.id = "job_\(Int(Date().timeIntervalSince1970 * 1_000_000))"
        self.discName = discName
        self.rippedFile = rippedFile
        self.ripElapsed = ripElapsed
        self.resolution = resolution
        self.card = card
        self.mediaResult = mediaResult
        self.intent = intent
    }
}
