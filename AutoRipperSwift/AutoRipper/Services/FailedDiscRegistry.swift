import Foundation
import os

private let log = Logger(subsystem: "com.autoripper.app", category: "failed-registry")

/// Posted (on the main actor) after a failed-disc entry is recorded or removed,
/// so an open Failed-Discs view can refresh itself live.
extension Notification.Name {
    static let failedDiscsChanged = Notification.Name("failedDiscsChanged")
}

/// One record per disc that aborted during the MakeMKV rip stage (disc
/// unreadable / hard read error). Keyed by disc fingerprint so re-failing the
/// same disc updates one entry instead of piling up duplicates.
struct FailedDiscEntry: Codable, Equatable, Sendable {
    /// Most-recent failure time (drives newest-first sorting).
    var date: Date
    /// Raw MakeMKV volume label, e.g. "AVATAR_THE_WAY_OF_WATER".
    var volumeLabel: String
    /// TMDb-matched title (bare, no year). Nil when the disc wasn't matched.
    var title: String?
    var year: Int?
    /// "movie" or "tv". Nil when unmatched.
    var mediaType: String?
    var tmdbId: Int?
    /// Latest MakeMKV / pipeline error string for this disc.
    var reason: String
    /// MakeMKV title IDs that failed on this disc (accumulated across attempts).
    var failedTitleIds: [Int]
    var readErrors: Int
    var corruptionEvents: Int

    /// User-facing name: "Title (Year)" when matched, else the volume label.
    var displayName: String {
        if let title {
            if let year { return "\(title) (\(year))" }
            return title
        }
        return volumeLabel.isEmpty ? "Unknown disc" : volumeLabel
    }
}

/// Durable list of discs that failed to rip, so the user can look them up in
/// Radarr/Sonarr (or another source) instead of silently losing the failure.
///
/// Persisted as JSON in Application Support, and—on every change—mirrored to
/// two sibling export files regenerated from the full set:
///   * `failed-discs.csv`          — every field, for spreadsheets / grep.
///   * `failed-discs-radarr.json`  — movies with a TMDb id, as Radarr custom
///     list entries `[{ "title", "tmdb_id" }]`. (Sonarr needs TVDB ids, which
///     we don't have, so TV failures are CSV/in-app only.)
///
/// Thread safety: actor-confined. UI callers hop in via `await`.
actor FailedDiscRegistry {
    static let shared = FailedDiscRegistry()

    private let storeURL: URL
    private var entries: [String: FailedDiscEntry] = [:]
    private var loaded = false

    private var exportDir: URL { storeURL.deletingLastPathComponent() }
    private var csvURL: URL { exportDir.appendingPathComponent("failed-discs.csv") }
    private var radarrURL: URL { exportDir.appendingPathComponent("failed-discs-radarr.json") }

    init(storeURL: URL? = nil) {
        if let storeURL {
            self.storeURL = storeURL
        } else {
            let support = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
            let appDir = support.appendingPathComponent("AutoRipper", isDirectory: true)
            try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
            self.storeURL = appDir.appendingPathComponent("failed-discs.json")
        }
    }

    /// Record (or merge into) a failed disc. Merges `failedTitleIds` and keeps
    /// any previously-captured TMDb match if the new failure lacks one.
    func record(key: String, entry: FailedDiscEntry) {
        ensureLoaded()
        var merged = entry
        if let existing = entries[key] {
            merged.failedTitleIds = Array(Set(existing.failedTitleIds)
                .union(entry.failedTitleIds)).sorted()
            if merged.title == nil {
                merged.title = existing.title
                merged.year = existing.year
                merged.mediaType = existing.mediaType
                merged.tmdbId = existing.tmdbId
            }
        }
        if entries[key] == merged { return }
        entries[key] = merged
        save()
    }

    /// Remove one entry.
    func forget(key: String) {
        ensureLoaded()
        if entries.removeValue(forKey: key) != nil { save() }
    }

    /// Drop all records (also clears the export files).
    func clear() {
        ensureLoaded()
        if entries.isEmpty { return }
        entries.removeAll()
        save()
    }

    /// All entries, newest failure first, paired with their key.
    func all() -> [(key: String, entry: FailedDiscEntry)] {
        ensureLoaded()
        return entries
            .sorted { $0.value.date > $1.value.date }
            .map { ($0.key, $0.value) }
    }

    /// One-time import of historical `MSG:5003` failures parsed from the app
    /// log. Entries are keyed `log:<folder>` so they can't collide with live
    /// fingerprint-keyed failures, and re-running is idempotent. No TMDb match
    /// is available from the log, so backfilled rows are display-only (title =
    /// the output folder name, e.g. "Avatar The Way of Water (2022)").
    func backfill(from failures: [ParsedLogFailure]) {
        ensureLoaded()
        for f in failures {
            let key = "log:\(f.folderName)"
            if entries[key] != nil { continue }
            entries[key] = FailedDiscEntry(
                date: f.date ?? Date(),
                volumeLabel: f.folderName,
                title: nil, year: nil, mediaType: nil, tmdbId: nil,
                reason: "Imported from log — MakeMKV failed to save title",
                failedTitleIds: f.titleId.map { [$0] } ?? [],
                readErrors: 0, corruptionEvents: 0
            )
        }
        save()
    }

    /// Plain "Title (Year)" lines, newest first — for the Copy-titles button.
    func titlesText() -> String {
        all().map { $0.entry.displayName }.joined(separator: "\n")
    }

    /// Newline-joined TMDb ids (movies and tv), newest first.
    func tmdbIdsText() -> String {
        all().compactMap { $0.entry.tmdbId.map(String.init) }.joined(separator: "\n")
    }

    /// Directory the export files live in (for "Reveal in Finder").
    func exportDirectory() -> URL { exportDir }

    // MARK: - Private

    private func ensureLoaded() {
        if loaded { return }
        loaded = true
        guard FileManager.default.fileExists(atPath: storeURL.path),
              let data = try? Data(contentsOf: storeURL) else { return }
        do {
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            entries = try dec.decode([String: FailedDiscEntry].self, from: data)
            log.info("loaded \(self.entries.count) failed-disc entries")
        } catch {
            log.warning("failed to decode failed-disc registry: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func save() {
        do {
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            let data = try enc.encode(entries)
            try atomicWrite(data, to: storeURL)
        } catch {
            log.error("save failed: \(error.localizedDescription, privacy: .public)")
        }
        // Exports are best-effort and regenerated from the full set; a failure
        // here must never block the authoritative JSON above.
        regenerateExports()
        NotificationCenter.default.post(name: .failedDiscsChanged, object: nil)
    }

    private func regenerateExports() {
        let sorted = entries.values.sorted { $0.date > $1.date }
        let iso = ISO8601DateFormatter()

        // CSV — quote every field, double embedded quotes.
        var csv = "date,name,title,year,media_type,tmdb_id,volume_label,failed_titles,read_errors,corruption_events,reason\n"
        for e in sorted {
            let cols: [String] = [
                iso.string(from: e.date),
                e.displayName,
                e.title ?? "",
                e.year.map(String.init) ?? "",
                e.mediaType ?? "",
                e.tmdbId.map(String.init) ?? "",
                e.volumeLabel,
                e.failedTitleIds.map(String.init).joined(separator: " "),
                String(e.readErrors),
                String(e.corruptionEvents),
                e.reason,
            ]
            csv += cols.map(Self.csvQuote).joined(separator: ",") + "\n"
        }
        if let data = csv.data(using: .utf8) { try? atomicWrite(data, to: csvURL) }

        // Radarr custom list — movies with a TMDb id only.
        let radarr: [[String: Any]] = sorted.compactMap { e in
            guard e.mediaType == "movie", let id = e.tmdbId else { return nil }
            return ["title": e.title ?? e.volumeLabel, "tmdb_id": id]
        }
        if let data = try? JSONSerialization.data(withJSONObject: radarr,
                                                  options: [.prettyPrinted, .sortedKeys]) {
            try? atomicWrite(data, to: radarrURL)
        }
    }

    private static func csvQuote(_ field: String) -> String {
        "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private func atomicWrite(_ data: Data, to url: URL) throws {
        let tmp = url.appendingPathExtension("tmp")
        try data.write(to: tmp)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }
}

extension FailedDiscRegistry {
    /// Runs once per install: scans the app log (current + rotated) for past
    /// `MSG:5003` rip failures and seeds them into the registry, so discs that
    /// failed before this feature existed still appear in the Failed tab.
    /// Guarded by a UserDefaults flag so it never re-runs.
    static func runLogBackfillIfNeeded() {
        let flag = "failedDiscsLogBackfillDone"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: flag) else { return }
        Task {
            let base = FileLogger.shared.logFileURL
            var text = ""
            for u in [base, base.appendingPathExtension("1")] {
                if let t = try? String(contentsOf: u, encoding: .utf8) { text += "\n" + t }
            }
            let failures = FailedDiscLogScanner.parse(text)
            if !failures.isEmpty {
                await FailedDiscRegistry.shared.backfill(from: failures)
            }
            defaults.set(true, forKey: flag)
        }
    }
}
