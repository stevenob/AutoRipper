import Foundation

/// Pure matcher that maps a scanned `DiscInfo` onto a TheDiscDB disc release,
/// producing a `TheDiscDBMatchPlan` of per-title intents / names / episodes.
///
/// Mirrors the project's existing pure-resolver pattern (`TVEpisodeMatcher`,
/// `KnownDiscRegistry.resolve`): no side effects, no view-model coupling — the
/// caller applies the plan under `@MainActor`.
///
/// **Why duration, not index.** TheDiscDB title indexes don't line up with
/// MakeMKV title ids (TheDiscDB splits segment-combined MakeMKV titles into
/// several entries). Each disc title is matched to its closest TheDiscDB title
/// by runtime, greedily, one-to-one.
///
/// **Confidence + conservatism.** A 1:1 match isn't trusted blindly:
///   * Same-duration siblings (e.g. five 2-min trailers) are disambiguated by
///     relative size; if still ambiguous the match is downgraded to `.low` and
///     no specific name/type is applied.
///   * Matches to a `.none` (unnamed) TheDiscDB segment are always `.low`.
///   * Only `.high`-confidence, classified matches get a name and their real
///     `JobIntent`/category; `.low` matches fall back to the safe `.extra`
///     intent and keep `DiscInfo.autoLabel`'s category guess.
/// This means a wrong duration tie degrades to "some extra", never to a
/// mis-named main feature or episode.
enum TheDiscDBMatcher {

    /// Default match tolerance. The PoC matched Garden State at exact-second
    /// equality; 3s forgives rounding between MakeMKV and TheDiscDB.
    static let defaultToleranceSeconds = 3
    /// Two TheDiscDB titles whose runtimes are within this window of a disc
    /// title are considered an ambiguous (duration-tie) match.
    static let ambiguityWindowSeconds = 2
    /// A `.high` size-tiebreak needs the winner's size within this relative
    /// delta of the disc title's size.
    static let sizeAgreementFraction = 0.10
    /// For movie discs, the disc's largest-by-size title must agree with the
    /// TheDiscDB MainMovie runtime within this many seconds, or the candidate
    /// isn't trusted.
    static let mainFeatureToleranceSeconds = 5
    /// Minimum fraction of disc titles that must match before a plan is
    /// trusted.
    static let minMatchRatio = 0.75

    enum Confidence: String, Sendable, Equatable { case high, low }

    /// One disc-title → TheDiscDB-title resolution, with full provenance.
    struct TitleMatch: Sendable, Equatable {
        let discTitleId: Int          // MakeMKV title id
        let dbTitleIndex: Int         // TheDiscDB title index
        let deltaSeconds: Int         // |runtime difference|
        let sizeDeltaFraction: Double?  // |Δsize|/dbSize when both known
        let confidence: Confidence
        let type: TheDiscDBTitleType
        /// Resolved intent the caller should apply. `.low` always yields
        /// `.extra` (never promotes to movie/episode on a shaky match).
        let intent: JobIntent
        /// `nil` unless the match is `.high` and TheDiscDB names the title.
        let name: String?
        /// `nil` → keep `autoLabel`'s category. Set only on `.high` matches.
        let category: TitleCategory?
        let season: Int?
        let episode: Int?
    }

    /// The full result. `trusted == false` ⇒ caller ignores it and keeps its
    /// heuristic labelling.
    struct Plan: Sendable, Equatable {
        let trusted: Bool
        let candidate: TheDiscDBDisc?
        /// Human-readable reason the candidate was selected or rejected.
        let reason: String
        let matches: [TitleMatch]
        let unmatchedDiscTitleIds: [Int]
        let unmatchedDBIndexes: [Int]
        let warnings: [String]
        let matchRatio: Double

        static let untrusted = Plan(
            trusted: false, candidate: nil, reason: "no candidate",
            matches: [], unmatchedDiscTitleIds: [], unmatchedDBIndexes: [],
            warnings: [], matchRatio: 0
        )

        // Convenience projections for the eventual view-model application.
        var intents: [Int: JobIntent] {
            Dictionary(uniqueKeysWithValues: matches.map { ($0.discTitleId, $0.intent) })
        }
        var titleNames: [Int: String] {
            var out: [Int: String] = [:]
            for m in matches where m.name != nil { out[m.discTitleId] = m.name }
            return out
        }
        var categories: [Int: TitleCategory] {
            var out: [Int: TitleCategory] = [:]
            for m in matches where m.category != nil { out[m.discTitleId] = m.category }
            return out
        }
        var episodeAssignments: [Int: (season: Int, episode: Int, name: String)] {
            var out: [Int: (season: Int, episode: Int, name: String)] = [:]
            for m in matches where m.intent == .episode {
                if let s = m.season, let e = m.episode {
                    out[m.discTitleId] = (s, e, m.name ?? "")
                }
            }
            return out
        }
    }

    /// Select the best candidate disc from `candidates` (e.g. all releases of a
    /// TMDb id, or all discs sharing a content hash) and build its plan.
    /// `exactHashMatch` relaxes the format/main-feature trust gate because the
    /// content hash already uniquely identified the disc.
    static func match(discInfo: DiscInfo,
                      candidates: [TheDiscDBDisc],
                      tolerance: Int = defaultToleranceSeconds,
                      exactHashMatch: Bool = false) -> Plan {
        guard !candidates.isEmpty else { return .untrusted }

        // Score every candidate; prefer same-format discs.
        let scored = candidates
            .map { build(discInfo: discInfo, candidate: $0, tolerance: tolerance) }
            .sorted { lhs, rhs in
                let lFmt = formatMatches(discInfo, lhs.candidate)
                let rFmt = formatMatches(discInfo, rhs.candidate)
                if lFmt != rFmt { return lFmt }            // format match wins
                if lhs.matchRatio != rhs.matchRatio { return lhs.matchRatio > rhs.matchRatio }
                return matchedCount(lhs) > matchedCount(rhs)
            }

        guard let best = scored.first else { return .untrusted }
        var warnings = best.warnings
        var reason = "selected release '\(best.candidate?.releaseSlug ?? "?")' disc \(best.candidate?.index ?? 0)"

        // Trust gate.
        if !exactHashMatch {
            if let cand = best.candidate, !formatMatches(discInfo, cand) {
                warnings.append("format mismatch: disc is \(discInfo.type), candidate is \(cand.format)")
            }
            if best.matchRatio < minMatchRatio {
                return rejected(best, reason: "match ratio \(pct(best.matchRatio)) < \(pct(minMatchRatio))",
                                extraWarnings: warnings)
            }
            if let mainAgreement = mainFeatureDisagreement(discInfo: discInfo, candidate: best.candidate) {
                return rejected(best, reason: mainAgreement, extraWarnings: warnings)
            }
            // Ambiguity between top two candidates of differing identity.
            if scored.count > 1 {
                let runnerUp = scored[1]
                if runnerUp.candidate?.releaseSlug != best.candidate?.releaseSlug,
                   formatMatches(discInfo, runnerUp.candidate) == formatMatches(discInfo, best.candidate),
                   abs(runnerUp.matchRatio - best.matchRatio) < 0.001,
                   matchedCount(runnerUp) == matchedCount(best) {
                    return rejected(best,
                        reason: "ambiguous: '\(best.candidate?.releaseSlug ?? "?")' and '\(runnerUp.candidate?.releaseSlug ?? "?")' score equally",
                        extraWarnings: warnings)
                }
            }
        } else {
            reason = "content-hash match: " + reason
        }

        return Plan(
            trusted: true,
            candidate: best.candidate,
            reason: reason,
            matches: best.matches,
            unmatchedDiscTitleIds: best.unmatchedDiscTitleIds,
            unmatchedDBIndexes: best.unmatchedDBIndexes,
            warnings: warnings,
            matchRatio: best.matchRatio
        )
    }

    // MARK: - Per-candidate matching

    /// Build the (untrusted) plan body for a single candidate disc.
    static func build(discInfo: DiscInfo,
                      candidate: TheDiscDBDisc,
                      tolerance: Int) -> Plan {
        let discTitles = discInfo.titles

        // All within-tolerance pairs, sorted for a stable greedy pass:
        // smallest runtime delta first, then smallest relative size delta,
        // then lower db index.
        struct Pair { let titleId: Int; let db: TheDiscDBTitle; let delta: Int; let sizeFrac: Double? }
        var pairs: [Pair] = []
        for t in discTitles {
            for db in candidate.titles {
                let delta = abs(t.durationSeconds - db.durationSeconds)
                guard delta <= tolerance else { continue }
                pairs.append(Pair(titleId: t.id, db: db, delta: delta,
                                  sizeFrac: relativeSizeDelta(discBytes: t.sizeBytes, dbBytes: db.sizeBytes)))
            }
        }
        pairs.sort { a, b in
            if a.delta != b.delta { return a.delta < b.delta }
            switch (a.sizeFrac, b.sizeFrac) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: break
            }
            return a.db.index < b.db.index
        }

        var usedTitles = Set<Int>()
        var usedDB = Set<Int>()
        var matches: [TitleMatch] = []
        for p in pairs {
            if usedTitles.contains(p.titleId) || usedDB.contains(p.db.index) { continue }
            usedTitles.insert(p.titleId)
            usedDB.insert(p.db.index)

            let ambiguous = isAmbiguous(discTitleId: p.titleId, db: candidate.titles, discTitles: discTitles)
            let confidence = resolveConfidence(type: p.db.type, ambiguous: ambiguous, sizeFrac: p.sizeFrac)
            let high = confidence == .high
            matches.append(TitleMatch(
                discTitleId: p.titleId,
                dbTitleIndex: p.db.index,
                deltaSeconds: p.delta,
                sizeDeltaFraction: p.sizeFrac,
                confidence: confidence,
                type: p.db.type,
                intent: high ? p.db.type.jobIntent : .extra,
                name: (high && p.db.type.isClassified && !p.db.title.isEmpty) ? p.db.title : nil,
                category: high ? p.db.type.titleCategory : nil,
                season: high ? p.db.season : nil,
                episode: high ? p.db.episode : nil
            ))
        }
        matches.sort { $0.discTitleId < $1.discTitleId }

        let unmatchedDisc = discTitles.map(\.id).filter { !usedTitles.contains($0) }.sorted()
        let unmatchedDB = candidate.titles.map(\.index).filter { !usedDB.contains($0) }.sorted()
        let ratio = discTitles.isEmpty ? 0 : Double(matches.count) / Double(discTitles.count)

        var warnings: [String] = []
        let lowCount = matches.filter { $0.confidence == .low }.count
        if lowCount > 0 { warnings.append("\(lowCount) low-confidence match(es) kept as generic extras") }

        return Plan(
            trusted: false, candidate: candidate, reason: "",
            matches: matches, unmatchedDiscTitleIds: unmatchedDisc,
            unmatchedDBIndexes: unmatchedDB, warnings: warnings, matchRatio: ratio
        )
    }

    // MARK: - Helpers

    private static func resolveConfidence(type: TheDiscDBTitleType,
                                          ambiguous: Bool,
                                          sizeFrac: Double?) -> Confidence {
        if !type.isClassified { return .low }          // unnamed segment
        if !ambiguous { return .high }                 // unique runtime
        // Duration tie: trust only if size clearly agrees.
        if let frac = sizeFrac, frac <= sizeAgreementFraction { return .high }
        return .low
    }

    /// True when more than one TheDiscDB title sits within
    /// `ambiguityWindowSeconds` of this disc title's runtime — i.e. duration
    /// alone can't uniquely identify it.
    private static func isAmbiguous(discTitleId: Int,
                                    db: [TheDiscDBTitle],
                                    discTitles: [TitleInfo]) -> Bool {
        guard let t = discTitles.first(where: { $0.id == discTitleId }) else { return true }
        let near = db.filter { abs($0.durationSeconds - t.durationSeconds) <= ambiguityWindowSeconds }
        return near.count > 1
    }

    private static func relativeSizeDelta(discBytes: Int64?, dbBytes: Int64?) -> Double? {
        guard let disc = discBytes, let db = dbBytes, db > 0 else { return nil }
        return Double(abs(disc - db)) / Double(db)
    }

    private static func formatMatches(_ discInfo: DiscInfo, _ candidate: TheDiscDBDisc?) -> Bool {
        guard let kind = candidate?.normalizedKind else { return false }
        return kind == discInfo.type.lowercased()
    }

    /// For a movie disc, returns a rejection reason if the disc's largest title
    /// doesn't agree with the candidate's MainMovie runtime; `nil` when there's
    /// no MainMovie to check or they agree.
    private static func mainFeatureDisagreement(discInfo: DiscInfo,
                                                candidate: TheDiscDBDisc?) -> String? {
        guard let main = candidate?.mainMovieTitle else { return nil }
        guard let largest = discInfo.titles.max(by: { $0.sizeBytes < $1.sizeBytes }) else { return nil }
        let delta = abs(largest.durationSeconds - main.durationSeconds)
        if delta > mainFeatureToleranceSeconds {
            return "main-feature runtime disagreement: disc \(largest.durationSeconds)s vs DB \(main.durationSeconds)s"
        }
        return nil
    }

    private static func matchedCount(_ plan: Plan) -> Int { plan.matches.count }

    private static func rejected(_ plan: Plan, reason: String, extraWarnings: [String]) -> Plan {
        Plan(trusted: false, candidate: plan.candidate, reason: reason,
             matches: plan.matches, unmatchedDiscTitleIds: plan.unmatchedDiscTitleIds,
             unmatchedDBIndexes: plan.unmatchedDBIndexes,
             warnings: extraWarnings + plan.warnings, matchRatio: plan.matchRatio)
    }

    private static func pct(_ x: Double) -> String { "\(Int((x * 100).rounded()))%" }
}
