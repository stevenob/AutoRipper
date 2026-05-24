import Foundation

/// v4.0.15: lookup + pure-function resolution of `KnownDiscMap` entries.
/// Decoupled from `RipViewModel` so the resolver is unit-testable without
/// a real disc.
enum KnownDiscRegistry {
    /// All known disc maps. To add a new release, append its `KnownDiscMap`
    /// here (or to one of the per-show data files) and the registry picks
    /// it up automatically.
    static let entries: [KnownDiscMap] = BlueyDiscMaps.all

    /// Find a matching map by disc volume label (CINFO attr 2). Matching is
    /// normalized — case-insensitive, leading/trailing whitespace trimmed,
    /// and runs of internal whitespace collapsed to a single space. Returns
    /// the first map whose alias list contains a normalized-equal entry.
    static func lookup(discName: String) -> KnownDiscMap? {
        let needle = normalize(discName)
        guard !needle.isEmpty else { return nil }
        for map in entries {
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
}
