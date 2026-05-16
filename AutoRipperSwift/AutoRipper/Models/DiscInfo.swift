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
    /// v3.12.0: per-track metadata parsed from MakeMKV's SINFO lines.
    /// Powers the track-selection UI that lets the user trim e.g. a
    /// 7-language audio bundle down to just English + commentary.
    /// Defaults to empty arrays so older scans / mocked test fixtures
    /// keep working unchanged.
    var audioTracks: [DiscAudioTrack] = []
    var subtitleTracks: [DiscSubtitleTrack] = []

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

/// v3.12.0: audio-track metadata parsed from MakeMKV's SINFO lines.
/// Lets the user trim e.g. a multi-language audio bundle in the UI.
struct DiscAudioTrack: Identifiable, Sendable, Hashable {
    /// Per-title track id assigned by MakeMKV.
    let id: Int
    let languageCode: String
    let languageName: String
    let codec: String
    let channels: String
    var displayLabel: String {
        let lang = languageName.isEmpty ? languageCode.uppercased() : languageName
        let codecPart = codec.isEmpty ? "" : " · \(codec)"
        let chanPart = channels.isEmpty ? "" : " · \(channels)"
        return "\(lang)\(codecPart)\(chanPart)".trimmingCharacters(in: .whitespaces)
    }
}

/// v3.12.0: subtitle-track metadata parsed from MakeMKV's SINFO lines.
struct DiscSubtitleTrack: Identifiable, Sendable, Hashable {
    let id: Int
    let languageCode: String
    let languageName: String
    let codec: String
    let forced: Bool
    var displayLabel: String {
        let lang = languageName.isEmpty ? languageCode.uppercased() : languageName
        let codecPart = codec.isEmpty ? "" : " · \(codec)"
        let forcedPart = forced ? " · forced" : ""
        return "\(lang)\(codecPart)\(forcedPart)".trimmingCharacters(in: .whitespaces)
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
    ///
    /// v3.10.0: alternate cuts also get a runtime-delta-based edition hint
    /// appended to the label (e.g. "🎬 Director's Cut (+18 min)") via the
    /// `editionHintForAlternateCut` helper.
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
            } else if secs >= 3600 && Self.isLikelyAlternateCut(of: secs, vs: mainSeconds) {
                // v3.10.0: real-world Director's Cuts are often +20-60 min
                // longer than the theatrical (LoTR Ext +51 min, Donnie Darko
                // +20 min, Blade Runner Final Cut basically equal). Wider
                // threshold using an absolute-minute window so very-long
                // extended cuts of long movies still match.
                cat = .alternateCut
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
            // v3.10.0: enrich .alternateCut labels with a heuristic edition
            // hint based on runtime delta vs the main feature. Other
            // categories keep the simple displayLabel.
            if cat == .alternateCut {
                titles[i].label = Self.editionHintForAlternateCut(
                    titleSeconds: secs, mainSeconds: mainSeconds
                )
            } else {
                titles[i].label = cat.displayLabel
            }
        }
    }

    /// True if `value` is within `percent` (as a fraction, e.g. 0.05 = 5%)
    /// of `reference`. Returns false if reference ≤ 0.
    private static func isWithinPercent(_ value: Int, of reference: Int, percent: Double) -> Bool {
        guard reference > 0 else { return false }
        let delta = Double(abs(value - reference)) / Double(reference)
        return delta <= percent
    }

    /// v3.10.0: detect an alternate cut by absolute time delta rather than
    /// pure percentage. Real-world Director's Cuts often add 20-60 min
    /// (LoTR Extended +51 min, Avatar Special Ed +16 min) which a tight ±5%
    /// would miss. Title must be feature-length (already enforced upstream
    /// via the ≥3600s gate) AND its runtime delta from the main feature
    /// must be ≤ 60 minutes — beyond that it's almost certainly a separate
    /// movie (double feature) rather than a cut.
    private static func isLikelyAlternateCut(of titleSeconds: Int, vs mainSeconds: Int) -> Bool {
        let deltaMin = abs(titleSeconds - mainSeconds) / 60
        return deltaMin <= 60
    }

    /// v3.10.0: friendly label for an `.alternateCut` title, based on the
    /// runtime delta vs the disc's main feature.
    ///
    /// Conventional naming for alternate cuts (used by Plex/Jellyfin
    /// `{edition-X}` tags and most home-media communities):
    ///   * Within ±2 min of main → "Alt Version" (different angle, audio mix)
    ///   * Main + 3 to 15 min → "Extended Cut"
    ///   * Main + 15 to 45 min → "Director's Cut"
    ///   * Main + 45 min+ → "Ultimate Cut"
    ///   * Main - 3 to -15 min → "TV Cut"
    ///   * Main - 15 to -45 min → "Theatrical Cut"
    ///   * Main - 45 min+ → "Short Cut"
    ///
    /// Visible-for-tests so unit tests can lock in the threshold boundaries
    /// without needing a full DiscInfo.
    static func editionHintForAlternateCut(titleSeconds: Int, mainSeconds: Int) -> String {
        let deltaMin = (titleSeconds - mainSeconds) / 60
        let absDelta = abs(deltaMin)
        let edition: String
        if absDelta <= 2 {
            edition = "Alt Version"
        } else if deltaMin > 0 {
            if deltaMin <= 15 {
                edition = "Extended Cut"
            } else if deltaMin <= 45 {
                edition = "Director's Cut"
            } else {
                edition = "Ultimate Cut"
            }
        } else {
            if absDelta <= 15 {
                edition = "TV Cut"
            } else if absDelta <= 45 {
                edition = "Theatrical Cut"
            } else {
                edition = "Short Cut"
            }
        }
        // Render with the same emoji as TitleCategory.alternateCut so the UI
        // stays visually consistent.
        let sign = deltaMin >= 0 ? "+" : "−"
        let deltaLabel = absDelta == 0 ? "same" : "\(sign)\(absDelta) min"
        return "🎬 \(edition) (\(deltaLabel))"
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
