import Foundation

/// Persistent JSON-backed store for jobs (active queue + history).
///
/// File: `~/Library/Application Support/AutoRipper/jobs.json`
///
/// Atomic write on every `save()`. Loads on startup. JSON was chosen over SQLite
/// because the dataset is small (hundreds of jobs in practice) and avoiding a
/// dependency keeps the build simple.
final class JobStore: @unchecked Sendable {
    static let shared = JobStore(url: defaultURL())

    private let queue = DispatchQueue(label: "com.autoripper.app.jobstore")
    private let url: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// Default production location.
    static func defaultURL() -> URL {
        let supportDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AutoRipper", isDirectory: true)
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        return supportDir.appendingPathComponent("jobs.json")
    }

    /// Inject a custom URL for tests (e.g. a temp file).
    init(url: URL) {
        self.url = url
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )

        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = enc

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
    }

    /// Synchronous read. Returns `[]` if the file doesn't exist or fails to decode.
    func load() -> [Job] {
        queue.sync {
            guard let data = try? Data(contentsOf: url) else { return [] }
            do {
                return try decoder.decode([Job].self, from: data)
            } catch {
                FileLogger.shared.error("jobstore", "failed to decode jobs.json: \(error.localizedDescription)")
                // Back up the bad file so we don't keep failing.
                let backup = url.deletingPathExtension().appendingPathExtension("json.corrupt")
                try? FileManager.default.removeItem(at: backup)
                try? FileManager.default.moveItem(at: url, to: backup)
                return []
            }
        }
    }

    /// Async write — debounced via the serial queue so rapid status updates
    /// (e.g. progress ticks) collapse without blocking the caller.
    func save(_ jobs: [Job]) {
        queue.async { [encoder, url] in
            do {
                let data = try encoder.encode(jobs)
                try data.write(to: url, options: .atomic)
            } catch {
                FileLogger.shared.error("jobstore", "failed to write jobs.json: \(error.localizedDescription)")
            }
        }
    }

    /// Returns the file URL (for debugging / "reveal in Finder").
    var fileURL: URL { url }
}
