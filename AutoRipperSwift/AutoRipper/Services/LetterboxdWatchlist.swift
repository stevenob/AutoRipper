import Foundation
import os

private let log = Logger(subsystem: "com.autoripper.app", category: "letterboxd")

/// One film parsed from a Letterboxd watchlist CSV export.
///
/// The free-account export historically only carries
/// `Date,Name,Year,Letterboxd URI`, so `tmdbId`/`imdbId` are optional and the
/// importer resolves missing TMDb IDs from (name, year) via `TMDbService`.
struct LetterboxdFilm: Equatable, Codable, Sendable {
    let name: String
    let year: Int?
    var tmdbId: Int?
    let imdbId: String?
    let letterboxdURI: String?
}

/// Pure, dependency-free parser for Letterboxd watchlist CSV exports.
///
/// Tolerant by design: it keys off the header row (case-insensitive) instead
/// of fixed column positions, supports quoted fields containing commas,
/// embedded newlines, and escaped (`""`) quotes, and silently skips rows that
/// have no usable title.
enum LetterboxdWatchlistCSV {
    /// Parse the full text of a watchlist CSV into films.
    static func parse(_ text: String) -> [LetterboxdFilm] {
        // Strip a leading UTF-8 BOM so the first header ("Date"/"Name") matches.
        let cleaned = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        let records = splitRecords(cleaned)
        guard let header = records.first else { return [] }

        // Build a case-insensitive header → index map.
        var index: [String: Int] = [:]
        for (i, raw) in header.enumerated() {
            index[raw.trimmingCharacters(in: .whitespaces).lowercased()] = i
        }
        func col(_ names: [String]) -> Int? {
            for n in names { if let i = index[n] { return i } }
            return nil
        }
        let nameCol = col(["name", "title"])
        let yearCol = col(["year"])
        let tmdbCol = col(["tmdb id", "tmdbid", "tmdb"])
        let imdbCol = col(["imdb id", "imdbid", "imdb"])
        let uriCol = col(["letterboxd uri", "uri", "url"])

        // Without a name/title column we can't do anything useful.
        guard let nameCol else { return [] }

        var films: [LetterboxdFilm] = []
        for record in records.dropFirst() {
            func field(_ i: Int?) -> String? {
                guard let i, i < record.count else { return nil }
                let v = record[i].trimmingCharacters(in: .whitespaces)
                return v.isEmpty ? nil : v
            }
            guard let name = field(nameCol) else { continue }
            let year = field(yearCol).flatMap { Int($0) }
            let tmdbId = field(tmdbCol).flatMap { Int($0) }
            let imdbId = field(imdbCol)
            let uri = field(uriCol)
            films.append(LetterboxdFilm(
                name: name, year: year, tmdbId: tmdbId,
                imdbId: imdbId, letterboxdURI: uri))
        }
        return films
    }

    /// Split CSV text into records of fields, honoring RFC-4180-style quoting.
    private static func splitRecords(_ text: String) -> [[String]] {
        var records: [[String]] = []
        var field = ""
        var record: [String] = []
        var inQuotes = false
        // Iterate unicode scalars, not Characters: Swift treats "\r\n" as a
        // single Character grapheme, which would defeat newline detection.
        let scalars = Array(text.unicodeScalars)
        let quote: Unicode.Scalar = "\""
        let comma: Unicode.Scalar = ","
        let cr: Unicode.Scalar = "\r"
        let lf: Unicode.Scalar = "\n"
        var i = 0
        func endField() { record.append(field); field = "" }
        func endRecord() {
            endField()
            // Drop fully-empty trailing records (e.g. trailing newline).
            if !(record.count == 1 && record[0].isEmpty) { records.append(record) }
            record = []
        }
        while i < scalars.count {
            let c = scalars[i]
            if inQuotes {
                if c == quote {
                    if i + 1 < scalars.count && scalars[i + 1] == quote {
                        field.unicodeScalars.append(quote)
                        i += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.unicodeScalars.append(c)
                }
            } else {
                switch c {
                case quote: inQuotes = true
                case comma: endField()
                case cr:
                    // Swallow CR; the following LF (if any) ends the record.
                    if i + 1 < scalars.count && scalars[i + 1] == lf {
                        i += 1
                    }
                    endRecord()
                case lf: endRecord()
                default: field.unicodeScalars.append(c)
                }
            }
            i += 1
        }
        // Flush any trailing field/record not terminated by a newline.
        if !field.isEmpty || !record.isEmpty { endRecord() }
        return records
    }
}

/// Persisted snapshot of an imported watchlist.
struct LetterboxdWatchlistData: Codable, Equatable, Sendable {
    /// Resolved TMDb movie IDs the user wants to watch.
    var tmdbIds: [Int]
    /// Total films found in the imported CSV.
    var importedCount: Int
    /// How many of those resolved to a TMDb ID.
    var resolvedCount: Int
    /// When the import last completed.
    var lastImported: Date
}

/// Holds the user's imported Letterboxd watchlist and answers membership
/// queries so the UI can flag scanned discs that are on it.
///
/// Read-only with respect to Letterboxd: nothing is ever written back. The
/// CSV is parsed locally and missing TMDb IDs are resolved through the user's
/// own TMDb key. Persisted as JSON in Application Support, mirroring
/// `RippedDiscRegistry`.
@MainActor
final class LetterboxdWatchlistStore: ObservableObject {
    static let shared = LetterboxdWatchlistStore()

    /// Resolved TMDb movie IDs, for O(1) membership checks from the UI.
    @Published private(set) var tmdbIds: Set<Int> = []
    @Published private(set) var importedCount: Int = 0
    @Published private(set) var resolvedCount: Int = 0
    @Published private(set) var lastImported: Date?
    @Published private(set) var isImporting: Bool = false
    /// Transient live progress shown only while importing, e.g. "Resolving 42 / 180…".
    @Published private(set) var progress: String = ""
    /// Persistent result of the last import (success summary or error). Survives
    /// after the import finishes so failures aren't silently cleared.
    @Published private(set) var status: String = ""

    private let storeURL: URL
    private var importTask: Task<Void, Never>?

    init(storeURL: URL? = nil) {
        if let storeURL {
            self.storeURL = storeURL
        } else {
            let support = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
            let appDir = support.appendingPathComponent("AutoRipper", isDirectory: true)
            try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
            self.storeURL = appDir.appendingPathComponent("letterboxd-watchlist.json")
        }
        load()
    }

    /// Whether `tmdbId` is a movie on the imported watchlist. The watchlist
    /// only ever holds movie IDs, so callers should also confirm the disc was
    /// identified as a movie before trusting a match.
    func contains(_ tmdbId: Int?) -> Bool {
        guard let tmdbId else { return false }
        return tmdbIds.contains(tmdbId)
    }

    /// True once a watchlist has been imported.
    var hasWatchlist: Bool { lastImported != nil }

    /// Start importing a watchlist CSV on a cancellable background task.
    func beginImport(at url: URL, config: AppConfig = .shared) {
        importTask?.cancel()
        importTask = Task { [weak self] in
            await self?.importCSV(at: url, config: config)
        }
    }

    /// Cancel an in-flight import (leaves any previously imported watchlist intact).
    func cancelImport() {
        importTask?.cancel()
    }

    /// Import a watchlist CSV at `url`, resolving any films lacking a TMDb ID
    /// via `TMDbService`. On read/parse/resolution failure the existing
    /// watchlist is preserved rather than overwritten.
    func importCSV(at url: URL, config: AppConfig = .shared) async {
        guard !isImporting else { return }
        isImporting = true
        progress = "Reading…"
        defer { isImporting = false; progress = "" }

        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            // Letterboxd exports are UTF-8, but fall back to Latin-1 for safety.
            guard let alt = try? String(contentsOf: url, encoding: .isoLatin1) else {
                log.error("watchlist read failed: \(error.localizedDescription, privacy: .public)")
                status = "Couldn't read the file."
                return
            }
            text = alt
        }

        let films = LetterboxdWatchlistCSV.parse(text)
        guard !films.isEmpty else {
            status = "No films found in that file — is it a Letterboxd watchlist.csv?"
            return
        }

        let needsResolution = films.contains { $0.tmdbId == nil }
        if needsResolution && config.tmdbApiKey.trimmingCharacters(in: .whitespaces).isEmpty {
            status = "Set a TMDb API key in the TMDb tab, then import again."
            return
        }

        let tmdb = TMDbService(config: config)
        var resolved = Set<Int>()
        let total = films.count
        for (i, film) in films.enumerated() {
            if Task.isCancelled {
                status = "Import cancelled — previous watchlist kept."
                return
            }
            if let id = film.tmdbId {
                resolved.insert(id)
            } else if let id = await Self.resolveTmdbId(for: film, using: tmdb) {
                resolved.insert(id)
            }
            if i % 10 == 0 || i == total - 1 {
                progress = "Resolving \(i + 1) / \(total)…"
            }
        }

        // Guard against wiping a good watchlist when nothing resolved (e.g. a
        // network outage or rate-limit during the whole run).
        guard !resolved.isEmpty else {
            status = hasWatchlist
                ? "Couldn't match any films (network issue?) — kept your previous watchlist."
                : "Couldn't match any of the \(total) films to TMDb."
            return
        }

        tmdbIds = resolved
        importedCount = total
        resolvedCount = resolved.count
        lastImported = Date()
        save()
        let unmatched = total - resolved.count
        status = unmatched > 0
            ? "Imported \(resolved.count) of \(total) films (\(unmatched) couldn't be matched)."
            : "Imported \(resolved.count) films."
    }

    /// Forget the imported watchlist.
    func clear() {
        importTask?.cancel()
        tmdbIds = []
        importedCount = 0
        resolvedCount = 0
        lastImported = nil
        status = ""
        try? FileManager.default.removeItem(at: storeURL)
    }

    // MARK: - Resolution

    /// Resolve a film to a TMDb movie ID. Movies only (Letterboxd is a film
    /// catalogue, and movie/TV IDs are separate namespaces). When the export
    /// carries a year, require an exact-year match to avoid flagging remakes or
    /// same-title films; without a year, take the top movie result.
    private static func resolveTmdbId(for film: LetterboxdFilm, using tmdb: TMDbService) async -> Int? {
        let movies = await tmdb.searchMovies(title: film.name, year: film.year)
        guard !movies.isEmpty else { return nil }
        if let year = film.year {
            return movies.first(where: { $0.year == year })?.tmdbId
        }
        return movies.first?.tmdbId
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return }
        guard let data = try? Data(contentsOf: storeURL) else { return }
        do {
            let stored = try JSONDecoder().decode(LetterboxdWatchlistData.self, from: data)
            tmdbIds = Set(stored.tmdbIds)
            importedCount = stored.importedCount
            resolvedCount = stored.resolvedCount
            lastImported = stored.lastImported
            log.info("loaded \(self.tmdbIds.count) watchlist IDs")
        } catch {
            log.warning("failed to decode watchlist: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func save() {
        let stored = LetterboxdWatchlistData(
            tmdbIds: Array(tmdbIds),
            importedCount: importedCount,
            resolvedCount: resolvedCount,
            lastImported: lastImported ?? Date())
        do {
            let data = try JSONEncoder().encode(stored)
            let tmp = storeURL.appendingPathExtension("tmp")
            try data.write(to: tmp)
            if FileManager.default.fileExists(atPath: storeURL.path) {
                _ = try FileManager.default.replaceItemAt(storeURL, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: storeURL)
            }
        } catch {
            log.error("watchlist save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
