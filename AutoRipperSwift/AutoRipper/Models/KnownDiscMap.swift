import Foundation

/// v4.0.15: a curated entry that maps a specific physical disc release to the
/// canonical season / episode metadata for every title on it. Used to fix the
/// common problem that multi-disc TV releases shuffle title order on disc, so
/// neither sequential numbering nor TMDb-runtime matching produces the right
/// SxxExx labels.
///
/// First dataset: the BBC slipcover Bluey Season 1–3 Blu-rays. The
/// `titleMappings` key is MakeMKV's 0-based title id (matches the trailing
/// `_tNN` in the auto-named output filename). Entries with a non-nil
/// `skipReason` are NOT ripped — they're language duplicates or other
/// known-uninteresting tracks the user wants AutoRipper to deselect.
struct KnownDiscMap: Sendable, Identifiable {
    /// Stable id, e.g. `"bluey-s2-first-half"`. Used as the cache key for
    /// "user already declined this map for this disc fingerprint" memory and
    /// as the `assignmentSource` discriminator.
    let id: String

    /// Canonical disc-volume label as reported by MakeMKV's CINFO attr 2.
    /// Matching is normalized (case-insensitive, whitespace-collapsed) and
    /// any of these strings will trigger a match. Multiple entries support
    /// known label variants across firmware versions / regional pressings.
    let discNameAliases: [String]

    /// Human-readable disc name for the banner UI.
    /// e.g. "Bluey · Season 2 · First Half · BBC Slipcover".
    let displayName: String

    /// Show name used by the publish pipeline. Authoritative — overrides
    /// whatever TMDb returned for the disc.
    let showName: String

    /// Optional TMDb show id. When set, future versions can sanity-check
    /// the cached TMDb match before applying the map.
    let expectedTmdbId: Int?

    /// Per-title episode mapping, keyed by MakeMKV title id.
    let titleMappings: [Int: KnownDiscEpisode]
}

/// One entry inside a `KnownDiscMap.titleMappings`. Either a real episode
/// (with `season`, `episode`, `name`) or a "skip this title" marker
/// (`skipReason` non-nil — `season/episode/name` are ignored).
struct KnownDiscEpisode: Sendable, Equatable {
    let season: Int
    let episode: Int
    let name: String
    /// Non-nil → don't rip this title. e.g. "French-only duplicate of
    /// 'Markets' (S01E20)". Surfaced in logs and the banner summary.
    let skipReason: String?

    static func episode(_ season: Int, _ episode: Int, _ name: String) -> KnownDiscEpisode {
        KnownDiscEpisode(season: season, episode: episode, name: name, skipReason: nil)
    }

    static func skip(_ reason: String) -> KnownDiscEpisode {
        KnownDiscEpisode(season: 0, episode: 0, name: "", skipReason: reason)
    }

    var isSkip: Bool { skipReason != nil }
}

/// Output of the pure `KnownDiscRegistry.resolve(for:map:)` function.
/// Captures exactly the state changes a `KnownDiscMap` would produce on a
/// given `DiscInfo`, with no `RipViewModel` coupling. The viewmodel turns
/// this into actual mutations under MainActor in one place.
struct KnownDiscApplyPlan: Sendable, Equatable {
    /// New `titleEpisodeAssignments` entries to install for each title id.
    let assignments: [Int: TitleEpisodeAssignment]
    /// New `titleIntents` entries (typically all `.episode`).
    let intents: [Int: JobIntent]
    /// Title ids the user wants removed from `selectedTitles` (skips).
    let deselectedTitleIds: Set<Int>
    /// Title ids in `map.titleMappings` that didn't have a matching title
    /// id in the scanned disc. Surfaced in logs as a coverage warning.
    let missingTitleIds: Set<Int>
    /// Title ids on the disc that the map doesn't cover. Their existing
    /// auto-categorization (bonus / featurette / trailer) is preserved.
    let unmappedTitleIds: Set<Int>
}

/// Who currently owns the per-title episode assignments? Lets late-arriving
/// async writers (TMDb runtime matching, TVEpisodePicker auto-resequence)
/// step aside when a known-disc map has been applied.
///
///   * `.automatic` — default; sequential + TMDb-runtime matching may write
///   * `.knownMap(id)` — a curated map is in force; auto writers no-op
///   * `.manual` — user has hand-edited; auto writers also no-op
enum AssignmentSource: Sendable, Equatable {
    case automatic
    case knownMap(id: String)
    case manual

    var isAutomatic: Bool {
        if case .automatic = self { return true }
        return false
    }
}
