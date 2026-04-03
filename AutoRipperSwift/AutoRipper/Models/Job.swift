import Foundation

/// Status of a job in the processing queue.
enum JobStatus: String, Sendable {
    case queued, encoding, organizing, scraping, uploading, done, failed
}

/// A single ripped file going through the post-rip pipeline.
struct Job: Identifiable, Sendable {
    let id: String
    let discName: String
    let rippedFile: URL
    var encodedFile: URL?
    var organizedFile: URL?
    var status: JobStatus = .queued
    var error: String = ""
    var progress: Int = 0
    var progressText: String = "Queued"
    var ripElapsed: TimeInterval = 0

    init(discName: String, rippedFile: URL, ripElapsed: TimeInterval = 0) {
        self.id = "job_\(Int(Date().timeIntervalSince1970 * 1000))"
        self.discName = discName
        self.rippedFile = rippedFile
        self.ripElapsed = ripElapsed
    }
}
