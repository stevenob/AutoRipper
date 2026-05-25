import Foundation

/// v4.0.15: lookup + pure-function resolution of `KnownDiscMap` entries.
/// Decoupled from `RipViewModel` so the resolver is unit-testable without
/// a real disc.
///
/// v4.0.17: also supports user-loadable JSON packs via
/// `refresh(userMapsFolder:)`. Built-in maps (Bluey) are merged with
/// any user packs found in the configured folder; user maps with the
/// same `id` as a built-in win.
enum KnownDiscRegistry {
    /// Built-in maps shipped with the app. Read-only.
    static let builtIn: [KnownDiscMap] = BlueyDiscMaps.all

    /// Combined registry — built-in + user maps from the last refresh.
    /// Mutated only via `refresh(userMapsFolder:)`. Reads are lock-
    /// protected so concurrent lookups (e.g. from `RipViewModel.scanDisc`
    /// running on its Task) see a consistent snapshot.
    nonisolated(unsafe) private static var _entries: [KnownDiscMap] = BlueyDiscMaps.all
    nonisolated(unsafe) private static let lock = NSLock()
    nonisolated(unsafe) private static var _lastLoadStats: LoadStats =
        LoadStats(builtInCount: BlueyDiscMaps.all.count, userMapCount: 0, fileCount: 0, errors: [])

    /// Current snapshot. Safe to call concurrently.
    static var entries: [KnownDiscMap] {
        lock.lock()
        defer { lock.unlock() }
        return _entries
    }

    /// Stats about the last refresh — surfaced in the Settings UI.
    static var lastLoadStats: LoadStats {
        lock.lock()
        defer { lock.unlock() }
        return _lastLoadStats
    }

    /// v4.0.17: re-scan the user maps folder and rebuild the merged
    /// registry. Safe to call repeatedly. Empty / missing folder = use
    /// built-in only.
    ///
    /// User maps with `id` matching a built-in override that built-in
    /// entry. Within user packs, later files do NOT override earlier
    /// files on duplicate id — the first one wins (deterministic order
    /// by filename). Duplicates are reported in the stats.
    @discardableResult
    static func refresh(userMapsFolder: String?) -> LoadStats {
        var combined = builtIn
        let builtInIds = Set(builtIn.map(\.id))
        var fileCount = 0
        var userMaps: [KnownDiscMap] = []
        var errors: [String] = []
        var seenUserIds: Set<String> = []
        if let folder = userMapsFolder?.trimmingCharacters(in: .whitespacesAndNewlines),
           !folder.isEmpty {
            let url = URL(fileURLWithPath: folder, isDirectory: true)
            let results = KnownDiscMapLoader.loadAll(in: url)
            fileCount = results.count
            for result in results {
                errors.append(contentsOf: result.errors.map { "\(result.path): \($0)" })
                for map in result.maps {
                    if seenUserIds.contains(map.id) {
                        errors.append("\(result.path): duplicate id '\(map.id)' ignored")
                        continue
                    }
                    seenUserIds.insert(map.id)
                    userMaps.append(map)
                }
            }
            // User maps override built-ins by id: remove built-ins that
            // share an id with any user map.
            if !seenUserIds.isEmpty {
                combined.removeAll { seenUserIds.contains($0.id) && builtInIds.contains($0.id) }
            }
            combined.append(contentsOf: userMaps)
        }
        let stats = LoadStats(
            builtInCount: builtIn.count,
            userMapCount: userMaps.count,
            fileCount: fileCount,
            errors: errors
        )
        lock.lock()
        _entries = combined
        _lastLoadStats = stats
        lock.unlock()
        return stats
    }

    /// Find a matching map by disc volume label (CINFO attr 2). Matching is
    /// normalized — case-insensitive, leading/trailing whitespace trimmed,
    /// and runs of internal whitespace collapsed to a single space. Returns
    /// the first map whose alias list contains a normalized-equal entry.
    static func lookup(discName: String) -> KnownDiscMap? {
        let needle = normalize(discName)
        guard !needle.isEmpty else { return nil }
        let snapshot = entries
        for map in snapshot {
            for alias in map.discNameAliases where normalize(alias) == needle {
                return map
            }
        }
        return nil
    }

    /// Pure function — given a scanned `DiscInfo` and a matched
    /// `KnownDiscMap`, compute the exact state changes the map would
    /// produce. Has no side effects; callers (i.e. `RipViewModel`) apply
    /// the resulting plan under `@MainActor`.
    ///
    /// Coverage rules:
    ///   * For every title id in `map.titleMappings`:
    ///     - If the disc *has* a title with that id, the map's entry
    ///       drives `assignments` / `intents` / `deselectedTitleIds`.
    ///     - If the disc *doesn't* have that id, the title id is recorded
    ///       in `missingTitleIds`. (Surfaced in logs as a coverage
    ///       warning — the disc is a different pressing, region variant,
    ///       or has been mis-fingerprinted.)
    ///   * Title ids on the disc that the map *doesn't* cover are
    ///     recorded in `unmappedTitleIds`. The caller leaves their
    ///     existing auto-label / auto-intent state alone (typically
    ///     they're bonus content, menus, trailers).
    static func resolve(for info: DiscInfo, map: KnownDiscMap) -> KnownDiscApplyPlan {
        let discTitleIds = Set(info.titles.map(\.id))
        var assignments: [Int: TitleEpisodeAssignment] = [:]
        var intents: [Int: JobIntent] = [:]
        var deselected: Set<Int> = []
        var missing: Set<Int> = []

        for (titleId, entry) in map.titleMappings {
            guard discTitleIds.contains(titleId) else {
                missing.insert(titleId)
                continue
            }
            if entry.isSkip {
                deselected.insert(titleId)
                intents[titleId] = .extra
            } else {
                assignments[titleId] = TitleEpisodeAssignment(
                    season: entry.season,
                    episode: entry.episode,
                    title: entry.name
                )
                intents[titleId] = .episode
            }
        }

        let mappedIds = Set(map.titleMappings.keys)
        let unmapped = discTitleIds.subtracting(mappedIds)

        return KnownDiscApplyPlan(
            assignments: assignments,
            intents: intents,
            deselectedTitleIds: deselected,
            missingTitleIds: missing,
            unmappedTitleIds: unmapped
        )
    }

    /// Normalize a disc label for matching: lowercase, trim, collapse
    /// whitespace. Exposed for tests.
    static func normalize(_ s: String) -> String {
        let lower = s.lowercased()
        let trimmed = lower.trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsed = trimmed
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed
    }

    /// Summary of the most recent `refresh` for the Settings UI.
    struct LoadStats: Sendable, Equatable {
        let builtInCount: Int
        let userMapCount: Int
        let fileCount: Int
        let errors: [String]
        var totalCount: Int { builtInCount + userMapCount }
    }
}

