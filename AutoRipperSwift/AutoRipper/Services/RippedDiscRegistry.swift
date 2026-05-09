import Foundation
import os

private let log = Logger(subsystem: "com.autoripper.app", category: "ripped-registry")

/// One-line record stored per fingerprint.
struct RippedDiscEntry: Codable, Equatable, Sendable {
    /// When the publish for this disc completed.
    let date: Date
    /// Display name of the disc when it was ripped (mostly for UI/log readability).
    let discName: String
    /// Final NAS / library path of the published file (or empty if NAS upload was off).
    let publishedPath: String
}

/// Tracks which discs have already been completely ripped and published.
/// Used by the UI to surface a "Already ripped on <date>" banner when the
/// user re-inserts a disc, so they don't accidentally re-rip the same
/// content during a long batch session.
///
/// Persisted as JSON in Application Support so it survives across launches
/// and isn't cleared by the queue retention pruner (which only governs
/// in-flight job state, not ripped-disc history).
///
/// Thread safety: actor-confined. UI callers hop in via `await`.
actor RippedDiscRegistry {
    static let shared = RippedDiscRegistry()

    private let storeURL: URL
    private var entries: [String: RippedDiscEntry] = [:]
    private var loaded = false

    init(storeURL: URL? = nil) {
        if let storeURL {
            self.storeURL = storeURL
        } else {
            let support = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
            let appDir = support.appendingPathComponent("AutoRipper", isDirectory: true)
            try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
            self.storeURL = appDir.appendingPathComponent("ripped-discs.json")
        }
    }

    /// Look up a fingerprint. Returns the entry if present, nil otherwise.
    func entry(forFingerprint fp: String) -> RippedDiscEntry? {
        ensureLoaded()
        return entries[fp]
    }

    /// Record a successful publish. Idempotent: re-recording the same
    /// fingerprint with the same date/path is a no-op (avoids unnecessary
    /// disk writes).
    func record(fingerprint: String, entry: RippedDiscEntry) {
        ensureLoaded()
        if entries[fingerprint] == entry { return }
        entries[fingerprint] = entry
        save()
    }

    /// Forget a fingerprint. Used by the (future) Settings "Clear ripped-disc
    /// history" button and by tests.
    func forget(fingerprint: String) {
        ensureLoaded()
        if entries.removeValue(forKey: fingerprint) != nil {
            save()
        }
    }

    /// Drop all records.
    func clear() {
        ensureLoaded()
        if entries.isEmpty { return }
        entries.removeAll()
        save()
    }

    /// All entries — sorted by most-recent date first. Cheap; already in memory.
    func all() -> [(fingerprint: String, entry: RippedDiscEntry)] {
        ensureLoaded()
        return entries
            .sorted { $0.value.date > $1.value.date }
            .map { ($0.key, $0.value) }
    }

    // MARK: - Private

    private func ensureLoaded() {
        if loaded { return }
        loaded = true
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return }
        guard let data = try? Data(contentsOf: storeURL) else { return }
        do {
            entries = try JSONDecoder().decode([String: RippedDiscEntry].self, from: data)
            log.info("loaded \(self.entries.count) entries from \(self.storeURL.path, privacy: .public)")
        } catch {
            log.warning("failed to decode registry, starting empty: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(entries)
            // Atomic write to a sibling temp file then rename, so a crash
            // mid-write can't corrupt the registry.
            let tmp = storeURL.appendingPathExtension("tmp")
            try data.write(to: tmp)
            if FileManager.default.fileExists(atPath: storeURL.path) {
                _ = try FileManager.default.replaceItemAt(storeURL, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: storeURL)
            }
        } catch {
            log.error("save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
