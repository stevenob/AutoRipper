import Foundation

/// v4.0.4: pure matcher that pairs disc titles with TMDb episodes by
/// closest runtime. Used by `RipViewModel` to auto-populate episode
/// numbers for TV-on-disc rips instead of the v4.0.2 naive
/// title-order-equals-episode-order heuristic.
///
/// **Why runtime matching beats title-order matching.** Discs interleave
/// episodes with extras / featurettes / intros / bumpers. Title 1 on the
/// disc is often a "play all" menu intro; title 2 might be an episode;
/// title 3 a behind-the-scenes featurette. Naïvely numbering by title id
/// assigns episodes to extras and vice-versa. Comparing each title's
/// duration to the known episode runtimes from TMDb is dramatically
/// more accurate — most TV shows have tight per-episode runtime
/// variance (a 22-min sitcom is always 21–23 min).
///
/// **Algorithm.** Greedy assignment by closest |Δruntime|:
///   1. Filter disc titles to those categorized `.episode` by autoLabel
///      (already filters out menus, trailers, and sub-2-min stubs)
///   2. Filter TMDb episodes to those with known runtime
///   3. For each (disc title, episode) pair compute |Δseconds|
///   4. Greedy: take the smallest Δ assignment, remove both from
///      consideration, repeat until one side is exhausted
///   5. Unassigned disc titles → no episode mapping (caller treats
///      as .extra or falls back to title-order numbering)
///
/// Greedy is good enough at this scale (always ≤ 20×20 = 400 pairs).
/// Hungarian assignment would be globally optimal but the implementation
/// complexity isn't justified for the typical 8–12 episodes / 10–16
/// titles per disc.
///
/// Tolerance: matches with |Δ| > 4 minutes are rejected as
/// unrelated (an episode is "missing" from the disc or a title is an
/// extra masquerading as an episode-like runtime).
enum TVEpisodeMatcher {

    /// Output of a single disc title → episode pairing.
    struct Match: Sendable, Equatable {
        let discTitleId: Int
        let episode: EpisodeInfo
        /// |disc duration - episode runtime|, in seconds. Lower is
        /// better. Exposed for the caller (e.g. to log low-confidence
        /// matches).
        let deltaSeconds: Int
    }

    /// Maximum runtime delta (seconds) for a match to be considered
    /// real. 4 minutes is wide enough to forgive ad-break / intro
    /// trimming differences between disc + broadcast cuts, tight
    /// enough to reject obvious extras matching an episode by accident.
    static let maxDeltaSeconds = 4 * 60

    /// Run the matcher. Returns the set of accepted pairings; titles
    /// not present in the result didn't find an episode within
    /// `maxDeltaSeconds`.
    static func match(titles: [TitleInfo], episodes: [EpisodeInfo]) -> [Match] {
        // Episodes with known runtime only.
        let eligibleEpisodes = episodes.filter { ($0.runtimeMinutes ?? 0) > 0 }
        guard !eligibleEpisodes.isEmpty else { return [] }
        // Only .episode-categorized disc titles play. Convert to
        // seconds for like-for-like comparison.
        let eligibleTitles = titles.filter { $0.category == .episode }
        guard !eligibleTitles.isEmpty else { return [] }

        // Build the candidate-pair list with |delta|.
        var candidates: [(titleId: Int, episode: EpisodeInfo, delta: Int)] = []
        for title in eligibleTitles {
            let titleSec = title.durationSeconds
            for ep in eligibleEpisodes {
                let epSec = (ep.runtimeMinutes ?? 0) * 60
                let delta = abs(titleSec - epSec)
                if delta <= maxDeltaSeconds {
                    candidates.append((titleId: title.id, episode: ep, delta: delta))
                }
            }
        }

        // Greedy: take smallest-delta pair, remove both endpoints,
        // repeat. Ties broken by lower episode number (so a 22-min
        // title that's equally close to E03 and E07 prefers E03).
        candidates.sort { a, b in
            if a.delta != b.delta { return a.delta < b.delta }
            return a.episode.episodeNumber < b.episode.episodeNumber
        }
        var usedTitles = Set<Int>()
        var usedEpisodes = Set<String>()  // "season:episode"
        var result: [Match] = []
        for cand in candidates {
            if usedTitles.contains(cand.titleId) { continue }
            let epKey = "\(cand.episode.seasonNumber):\(cand.episode.episodeNumber)"
            if usedEpisodes.contains(epKey) { continue }
            result.append(Match(
                discTitleId: cand.titleId,
                episode: cand.episode,
                deltaSeconds: cand.delta
            ))
            usedTitles.insert(cand.titleId)
            usedEpisodes.insert(epKey)
        }
        return result
    }
}
