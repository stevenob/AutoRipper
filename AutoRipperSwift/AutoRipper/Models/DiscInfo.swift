import Foundation

/// A single title on a disc, parsed from MakeMKV output.
struct TitleInfo: Identifiable, Sendable {
    let id: Int
    let name: String
    let duration: String
    let sizeBytes: Int64
    let chapters: Int
    let fileOutput: String
    var resolution: String = ""
    var label: String = ""
    /// Structured category produced by `DiscInfo.autoLabel`. Useful for the
    /// titles table to group, filter, and select default rips by intent
    /// rather than relying on the emoji label string.
    var category: TitleCategory = .unknown

    var durationSeconds: Int {
        let parts = duration.split(separator: ":").compactMap { Int($0) }
        switch parts.count {
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        case 2: return parts[0] * 60 + parts[1]
        case 1: return parts[0]
        default: return 0
        }
    }

    var humanSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    var resolutionLabel: String {
        guard !resolution.isEmpty,
              let height = resolution.split(separator: "x").last.flatMap({ Int($0) })
        else { return "" }
        switch height {
        case 2000...: return "4K"
        case 1000...: return "1080p"
        case 700...: return "720p"
        case 500...: return "576p"
        default: return "480p"
        }
    }
}

/// Auto-detected category for a title. Drives the emoji label string +
/// can be queried programmatically by Auto mode for smarter selection.
///
/// Detection is layered:
///   1. The largest title by size is always `.mainFeature`.
///   2. Titles ≥ 60 min whose runtime is within ±5% of the main feature
///      are `.alternateCut` (Director's Cut, Extended, etc.).
///   3. Titles whose runtime matches the main feature ±0.5% but with
///      smaller size are `.alternateAudio` (typical commentary track
///      structure on some discs).
///   4. TV episode shapes (≥3 titles, runtimes clustered, 18–90 min) get
///      labeled `.episode`.
///   5. Otherwise by duration: < 60s trailer · < 5 min short extra ·
///      < 30 min extra · < 60 min featurette · ≥ 60 min bonus feature.
enum TitleCategory: String, Sendable, Codable, CaseIterable {
    case mainFeature
    case alternateCut
    case alternateAudio
    case episode
    case bonusFeature
    case featurette
    case `extra`
    case shortExtra
    case trailer
    case unknown

    /// Emoji + label string used by the existing UI.
    var displayLabel: String {
        switch self {
        case .mainFeature:    return "🎬 Main Feature"
        case .alternateCut:   return "🎬 Alternate Cut"
        case .alternateAudio: return "🔊 Alt Audio / Commentary"
        case .episode:        return "📺 Episode"
        case .bonusFeature:   return "🎥 Bonus Feature"
        case .featurette:     return "🎥 Featurette"
        case .extra:          return "📀 Extra"
        case .shortExtra:     return "🎞️ Short Extra"
        case .trailer:        return "⏭️ Trailer"
        case .unknown:        return "❓ Unknown"
        }
    }

    /// Short label used by the summary line (no emoji).
    var shortName: String {
        switch self {
        case .mainFeature:    return "main"
        case .alternateCut:   return "alt cut"
        case .alternateAudio: return "alt audio"
        case .episode:        return "episode"
        case .bonusFeature:   return "bonus feature"
        case .featurette:     return "featurette"
        case .extra:          return "extra"
        case .shortExtra:     return "short extra"
        case .trailer:        return "trailer"
        case .unknown:        return "title"
        }
    }
}

/// Information about a scanned disc.
struct DiscInfo: Sendable {
    let name: String
    let type: String  // "dvd" or "bluray"
    var titles: [TitleInfo] = []
    var mediaTitle: String = ""

    /// Auto-label titles based on duration, size, runtime clustering, and the
    /// presence of TV-episode shapes. Updates both `category` and the
    /// human-readable `label` for each title.
    ///
    /// Detection order (more specific rules first):
    ///   1. Largest by size → `mainFeature`
    ///   2. If `looksLikeTVSeason`, every clustered-runtime title in the
    ///      18–90 min window → `episode` (overrides the size-based main
    ///      feature, since on a season-disc the "biggest" episode is just
    ///      another episode).
    ///   3. Runtime within ±5% of main feature & ≥ 60 min & not the main
    ///      itself → `alternateCut`
    ///   4. Runtime within ±0.5% of main feature & strictly smaller size →
    ///      `alternateAudio`
    ///   5. Otherwise duration-bucketed extras/featurettes/trailers.
    mutating func autoLabel() {
        guard !titles.isEmpty else { return }

        let largestIndex = titles.indices.max(by: { titles[$0].sizeBytes < titles[$1].sizeBytes })!
        let mainSeconds = titles[largestIndex].durationSeconds
        let mainSize = titles[largestIndex].sizeBytes

        // TV season: if the disc looks like a season, every clustered
        // episode-runtime title becomes .episode. The biggest one no
        // longer pulls "main feature" away from a sibling.
        let isTVSeason = looksLikeTVSeason
        let episodeIds = isTVSeason ? Set(tvEpisodeCandidateIds) : Set<Int>()

        for i in titles.indices {
            let t = titles[i]
            let secs = t.durationSeconds
            let cat: TitleCategory

            if episodeIds.contains(t.id) {
                cat = .episode
            } else if i == largestIndex {
                cat = .mainFeature
            } else if secs >= 60 && Self.isWithinPercent(secs, of: mainSeconds, percent: 0.05) {
                // Same-runtime as main but might be alt audio (smaller size)
                // or a full alternate cut. Use size tolerance to disambiguate.
                if Self.isWithinPercent(secs, of: mainSeconds, percent: 0.005)
                    && t.sizeBytes < mainSize {
                    cat = .alternateAudio
                } else {
                    cat = .alternateCut
                }
            } else if secs >= 5400 {                    // ≥ 90 min: probably another full feature
                cat = .bonusFeature
            } else if secs >= 1800 {                    // 30–90 min
                cat = .featurette
            } else if secs >= 300 {                     // 5–30 min
                cat = .extra
            } else if secs >= 60 {                      // 1–5 min
                cat = .shortExtra
            } else {                                    // < 60 s
                cat = .trailer
            }
            titles[i].category = cat
            titles[i].label = cat.displayLabel
        }
    }

    /// True if `value` is within `percent` (as a fraction, e.g. 0.05 = 5%)
    /// of `reference`. Returns false if reference ≤ 0.
    private static func isWithinPercent(_ value: Int, of reference: Int, percent: Double) -> Bool {
        guard reference > 0 else { return false }
        let delta = Double(abs(value - reference)) / Double(reference)
        return delta <= percent
    }

    /// One-line summary of the title category breakdown — e.g.
    /// `1 main · 1 alt cut · 3 featurettes · 14 extras · 47 trailers`.
    /// Categories with zero entries are omitted. Used by the disc panel
    /// header so the user gets a quick "what's on this disc" overview
    /// without scrolling through the titles table.
    var categorySummary: String {
        // Tally + render in declaration order so important categories
        // (main feature, alt cut) appear first.
        var counts: [(TitleCategory, Int)] = []
        for cat in TitleCategory.allCases {
            let n = titles.filter { $0.category == cat }.count
            if n > 0 { counts.append((cat, n)) }
        }
        return counts
            .map { cat, n in
                if n == 1 { return "1 \(cat.shortName)" }
                // Quick pluralization: cat.shortName + s. Special-case
                // ones that don't pluralize cleanly.
                let plural: String
                switch cat {
                case .alternateAudio: plural = "alt audio tracks"
                case .alternateCut:   plural = "alt cuts"
                case .mainFeature:    plural = "main features"
                default:              plural = cat.shortName + "s"
                }
                return "\(n) \(plural)"
            }
            .joined(separator: " · ")
    }

    /// Heuristic: does this disc look like a TV-series season?
    /// Triggers when there are 3+ titles whose durations cluster within ±15%
    /// and each is between 18 and 90 minutes (typical episode length).
    var looksLikeTVSeason: Bool {
        let candidates = titles.filter { $0.durationSeconds >= 18 * 60 && $0.durationSeconds <= 90 * 60 }
        guard candidates.count >= 3 else { return false }
        let durations = candidates.map { Double($0.durationSeconds) }
        let avg = durations.reduce(0, +) / Double(durations.count)
        guard avg > 0 else { return false }
        return durations.allSatisfy { abs($0 - avg) / avg <= 0.15 }
    }

    /// Title IDs that match the TV-episode heuristic — useful for auto-selecting.
    var tvEpisodeCandidateIds: [Int] {
        titles
            .filter { $0.durationSeconds >= 18 * 60 && $0.durationSeconds <= 90 * 60 }
            .map { $0.id }
    }
}
