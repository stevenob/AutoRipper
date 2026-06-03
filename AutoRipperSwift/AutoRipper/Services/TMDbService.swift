import Foundation
import os

private let log = Logger(subsystem: "com.autoripper.app", category: "tmdb")

private let baseURL = "https://api.themoviedb.org/3"

/// Process-wide TMDb response cache. Shared across `TMDbService` instances so
/// repeat scans of the same disc don't re-hit the network.
private final class TMDbCache: @unchecked Sendable {
    static let shared = TMDbCache()
    private let lock = NSLock()
    private var search: [String: [MediaResult]] = [:]
    private var movieDetails: [Int: MediaResult] = [:]
    private var tvDetails: [Int: MediaResult] = [:]
    private var episodes: [String: [EpisodeInfo]] = [:]  // key: "<tvId>:<season>"

    func cachedSearch(_ query: String) -> [MediaResult]? {
        lock.lock(); defer { lock.unlock() }
        return search[query]
    }
    func storeSearch(_ query: String, _ results: [MediaResult]) {
        lock.lock(); defer { lock.unlock() }
        search[query] = results
    }
    func cachedMovie(_ id: Int) -> MediaResult? {
        lock.lock(); defer { lock.unlock() }
        return movieDetails[id]
    }
    func storeMovie(_ id: Int, _ r: MediaResult) {
        lock.lock(); defer { lock.unlock() }
        movieDetails[id] = r
    }
    func cachedTv(_ id: Int) -> MediaResult? {
        lock.lock(); defer { lock.unlock() }
        return tvDetails[id]
    }
    func storeTv(_ id: Int, _ r: MediaResult) {
        lock.lock(); defer { lock.unlock() }
        tvDetails[id] = r
    }
    func cachedEpisodes(tvId: Int, season: Int) -> [EpisodeInfo]? {
        lock.lock(); defer { lock.unlock() }
        return episodes["\(tvId):\(season)"]
    }
    func storeEpisodes(tvId: Int, season: Int, _ eps: [EpisodeInfo]) {
        lock.lock(); defer { lock.unlock() }
        episodes["\(tvId):\(season)"] = eps
    }
}

/// TMDb API client for movie/TV metadata lookup.
struct TMDbService {
    private let session = URLSession.shared
    private let config: AppConfig

    init(config: AppConfig = .shared) {
        self.config = config
    }

    private var apiKey: String { config.tmdbApiKey }

    /// Clean a disc name for TMDb search (strip tags, underscores, etc.)
    /// Also extracts a 4-digit year (1900–2099) if present before stripping trailing digits.
    static func cleanDiscName(_ name: String) -> (query: String, year: Int?) {
        var cleaned = name.replacingOccurrences(of: "_", with: " ")

        // Extract year before we strip trailing digits
        var extractedYear: Int?
        if let regex = try? NSRegularExpression(pattern: #"\b(19\d{2}|20\d{2})\b"#) {
            let range = NSRange(cleaned.startIndex..., in: cleaned)
            if let m = regex.firstMatch(in: cleaned, range: range),
               let r = Range(m.range(at: 1), in: cleaned) {
                extractedYear = Int(cleaned[r])
            }
        }

        // Strip parenthetical version tags (e.g. "(Unrated)", "(Extended Cut)", "(Director's Cut)")
        if let regex = try? NSRegularExpression(pattern: #"\([^)]*\)"#) {
            cleaned = regex.stringByReplacingMatches(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned), withTemplate: "")
        }

        // v4.0.9: TV-on-disc marker detection. Bluey discs ship with
        // labels like "Bluey S1 Second Half", "Bluey- Season One - The
        // First Half", "BLUEY_S1_SECOND_HALF" — none of which TMDb
        // recognizes verbatim. The show name always precedes the
        // season/half/disc marker, so we find the earliest marker and
        // truncate everything from there. Preserves single-word and
        // movie names (no markers → no-op). Skip when the marker
        // starts at position 0 to avoid clobbering legit movie titles
        // that happen to start with these words (e.g. a hypothetical
        // "First Half" as the actual film title).
        let tvMarkers = [
            // Season abbreviations: S1, S02 (must be S+digits, not bare S)
            #"\bS\d+\b"#,
            // "Season N" and "Season One/Two/.../Ten"
            #"\b(?:SEASON|SERIES)\s+(?:\d+|ONE|TWO|THREE|FOUR|FIVE|SIX|SEVEN|EIGHT|NINE|TEN)\b"#,
            // "First Half" / "Second Half" / etc. — common on multi-disc TV releases
            #"\b(?:FIRST|SECOND|THIRD|FOURTH|FIFTH|SIXTH)\s+HALF\b"#,
        ]
        var earliestTVMarker: Int?
        for pattern in tvMarkers {
            guard let regex = try? NSRegularExpression(
                pattern: pattern, options: .caseInsensitive) else { continue }
            let range = NSRange(cleaned.startIndex..., in: cleaned)
            if let m = regex.firstMatch(in: cleaned, range: range),
               m.range.location > 0 {
                if earliestTVMarker == nil || m.range.location < earliestTVMarker! {
                    earliestTVMarker = m.range.location
                }
            }
        }
        if let cut = earliestTVMarker,
           let cutIdx = cleaned.index(cleaned.startIndex, offsetBy: cut, limitedBy: cleaned.endIndex) {
            cleaned = String(cleaned[..<cutIdx])
            // Strip trailing punctuation/whitespace leftover from the
            // truncation point ("Bluey- " → "Bluey").
            if let regex = try? NSRegularExpression(pattern: #"[-_:.\s]+$"#) {
                cleaned = regex.stringByReplacingMatches(
                    in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned),
                    withTemplate: "")
            }
        }

        // Strip leading single letter prefix before a number (e.g. T28 → 28)
        if let regex = try? NSRegularExpression(pattern: #"^[A-Za-z](?=\d)"#) {
            cleaned = regex.stringByReplacingMatches(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned), withTemplate: "")
        }
        // Strip trailing numbers that look like disc metadata (e.g. 169, 01)
        if let regex = try? NSRegularExpression(pattern: #"\d{2,4}$"#) {
            cleaned = regex.stringByReplacingMatches(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned), withTemplate: "")
        }
        // Insert space between letters and numbers (e.g. 28DAYS → 28 DAYS)
        if let regex = try? NSRegularExpression(pattern: #"(\d)([A-Za-z])"#) {
            cleaned = regex.stringByReplacingMatches(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned), withTemplate: "$1 $2")
        }
        if let regex = try? NSRegularExpression(pattern: #"([A-Za-z])(\d)"#) {
            cleaned = regex.stringByReplacingMatches(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned), withTemplate: "$1 $2")
        }
        // Strip common disc tags
        let tags = [
            "DISC\\s*\\d*", "BD", "DVD", "\\d{3,4}[pi]",
            "HEVC", "HDR", "ATMOS", "DTS", "AVC", "VC-?\\d",
        ]
        for tag in tags {
            if let regex = try? NSRegularExpression(pattern: "\\b\(tag)\\b", options: .caseInsensitive) {
                cleaned = regex.stringByReplacingMatches(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned), withTemplate: "")
            }
        }
        // Normalize whitespace
        cleaned = cleaned.components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        // Title case
        return (cleaned.capitalized, extractedYear)
    }

    /// Stably re-rank search results so any whose release year matches the
    /// requested `year` come first, preserving TMDb's relevance order within
    /// each group. No-op when `year` is nil or nothing matches. This is what
    /// lets a disc/label like "Batman 1989" resolve to the 1989 film even
    /// though TMDb's multi-search ranks newer same-name titles higher.
    static func rankByYear(_ results: [MediaResult], year: Int?) -> [MediaResult] {
        guard let year else { return results }
        return results.enumerated().sorted { lhs, rhs in
            let lMatch = lhs.element.year == year
            let rMatch = rhs.element.year == year
            if lMatch != rMatch { return lMatch }
            return lhs.offset < rhs.offset
        }.map { $0.element }
    }

    /// Search TMDb for movies and TV shows.
    func searchMedia(query: String) async -> [MediaResult] {
        guard !apiKey.isEmpty else {
            log.warning("TMDb API key not configured")
            FileLogger.shared.warn("tmdb", "searchMedia: TMDb API key not configured — returning empty")
            return []
        }
        if let cached = TMDbCache.shared.cachedSearch(query) {
            FileLogger.shared.info("tmdb",
                "searchMedia: cache hit for '\(query)' → \(cached.count) results")
            return cached
        }
        let (cleaned, discYear) = Self.cleanDiscName(query)
        guard var url = URL(string: "\(baseURL)/search/multi") else { return [] }
        // NOTE: /search/multi silently ignores the `year` parameter (unlike
        // /search/movie's primary_release_year), so we do NOT send it. Instead
        // we re-rank results client-side below to surface the year the user
        // asked for — otherwise titles like "Batman 1989" stay buried beneath
        // more-recent same-name films and TV shows.
        let queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "query", value: cleaned),
        ]
        url.append(queryItems: queryItems)

        do {
            let (data, _) = try await session.data(from: url)
            let response = try JSONDecoder().decode(TMDbSearchResponse.self, from: data)
            let results: [MediaResult] = response.results.prefix(10).compactMap { item -> MediaResult? in
                guard item.mediaType == "movie" || item.mediaType == "tv" else { return nil }
                let title = item.title ?? item.name ?? ""
                let dateStr = item.releaseDate ?? item.firstAirDate ?? ""
                let year = dateStr.count >= 4 ? Int(dateStr.prefix(4)) : nil
                return MediaResult(
                    title: title, year: year, mediaType: item.mediaType,
                    tmdbId: item.id, overview: item.overview ?? "",
                    posterPath: item.posterPath, backdropPath: item.backdropPath
                )
            }
            let ranked = Self.rankByYear(results, year: discYear)
            FileLogger.shared.info("tmdb",
                "searchMedia: '\(query)' → cleaned='\(cleaned)' year=\(discYear.map { String($0) } ?? "nil") → \(ranked.count) result(s), top='\(ranked.first?.displayTitle ?? "nil")'")
            TMDbCache.shared.storeSearch(query, ranked)
            return ranked
        } catch {
            log.error("TMDb search failed: \(error.localizedDescription)")
            FileLogger.shared.error("tmdb",
                "searchMedia: '\(query)' → cleaned='\(cleaned)' FAILED: \(error.localizedDescription)")
            return []
        }
    }

    /// Fetch full movie details by TMDb ID.
    func getMovieDetails(tmdbId: Int) async -> MediaResult? {
        guard !apiKey.isEmpty else { return nil }
        if let cached = TMDbCache.shared.cachedMovie(tmdbId) { return cached }
        guard let url = URL(string: "\(baseURL)/movie/\(tmdbId)?api_key=\(apiKey)") else { return nil }
        do {
            let (data, _) = try await session.data(from: url)
            let item = try JSONDecoder().decode(TMDbMovieDetail.self, from: data)
            let year = item.releaseDate.flatMap { $0.count >= 4 ? Int($0.prefix(4)) : nil }
            var result = MediaResult(
                title: item.title, year: year, mediaType: "movie",
                tmdbId: item.id, overview: item.overview ?? "",
                posterPath: item.posterPath, backdropPath: item.backdropPath
            )
            // v4.0.6: populate runtime so autoLabel can match the
            // closest-duration disc title to .mainFeature.
            result.runtimeMinutes = item.runtime
            TMDbCache.shared.storeMovie(tmdbId, result)
            return result
        } catch {
            log.error("TMDb movie detail failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Fetch TV show details by TMDb ID.
    func getTvDetails(tmdbId: Int) async -> MediaResult? {
        guard !apiKey.isEmpty else { return nil }
        if let cached = TMDbCache.shared.cachedTv(tmdbId) { return cached }
        guard let url = URL(string: "\(baseURL)/tv/\(tmdbId)?api_key=\(apiKey)") else { return nil }
        do {
            let (data, _) = try await session.data(from: url)
            let item = try JSONDecoder().decode(TMDbTvDetail.self, from: data)
            let year = item.firstAirDate.flatMap { $0.count >= 4 ? Int($0.prefix(4)) : nil }
            let result = MediaResult(
                title: item.name, year: year, mediaType: "tv",
                tmdbId: item.id, overview: item.overview ?? "",
                posterPath: item.posterPath, backdropPath: item.backdropPath
            )
            TMDbCache.shared.storeTv(tmdbId, result)
            return result
        } catch {
            log.error("TMDb TV detail failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Fetch episode list for a specific season of a TV show.
    func getSeasonEpisodes(tvId: Int, season: Int) async -> [EpisodeInfo] {
        guard !apiKey.isEmpty else { return [] }
        if let cached = TMDbCache.shared.cachedEpisodes(tvId: tvId, season: season) { return cached }
        guard let url = URL(string: "\(baseURL)/tv/\(tvId)/season/\(season)?api_key=\(apiKey)") else { return [] }
        do {
            let (data, _) = try await session.data(from: url)
            let response = try JSONDecoder().decode(TMDbSeasonResponse.self, from: data)
            let eps = response.episodes.map { ep in
                EpisodeInfo(
                    seasonNumber: ep.seasonNumber ?? season,
                    episodeNumber: ep.episodeNumber ?? 0,
                    name: ep.name ?? "",
                    runtimeMinutes: ep.runtime
                )
            }
            TMDbCache.shared.storeEpisodes(tvId: tvId, season: season, eps)
            return eps
        } catch {
            log.error("TMDb season fetch failed: \(error.localizedDescription)")
            return []
        }
    }

    /// Search TMDb for movies using a clean, canonical title (no disc-label
    /// normalization), optionally constrained by release year.
    ///
    /// Used by Letterboxd watchlist resolution, where titles are already
    /// canonical (e.g. "2001: A Space Odyssey") and must NOT be run through
    /// `cleanDiscName`, which would strip embedded numbers/years.
    func searchMovies(title: String, year: Int?) async -> [MediaResult] {
        guard !apiKey.isEmpty else { return [] }
        guard var url = URL(string: "\(baseURL)/search/movie") else { return [] }
        var items = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "query", value: title),
        ]
        if let year { items.append(URLQueryItem(name: "year", value: String(year))) }
        url.append(queryItems: items)
        do {
            let (data, _) = try await session.data(from: url)
            let response = try JSONDecoder().decode(TMDbMovieSearchResponse.self, from: data)
            return response.results.prefix(10).map { item -> MediaResult in
                let y = item.releaseDate.flatMap { $0.count >= 4 ? Int($0.prefix(4)) : nil }
                return MediaResult(
                    title: item.title ?? "", year: y, mediaType: "movie",
                    tmdbId: item.id, overview: item.overview ?? "",
                    posterPath: item.posterPath, backdropPath: item.backdropPath)
            }
        } catch {
            log.error("TMDb movie search failed: \(error.localizedDescription)")
            return []
        }
    }
}

// MARK: - Codable Response Models

private struct TMDbSearchResponse: Codable {
    let results: [TMDbSearchItem]
}

private struct TMDbMovieSearchResponse: Codable {
    let results: [TMDbMovieSearchItem]
}

private struct TMDbMovieSearchItem: Codable {
    let id: Int
    let title: String?
    let releaseDate: String?
    let overview: String?
    let posterPath: String?
    let backdropPath: String?

    enum CodingKeys: String, CodingKey {
        case id, title, overview
        case releaseDate = "release_date"
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
    }
}

private struct TMDbSearchItem: Codable {
    let id: Int
    let mediaType: String
    let title: String?
    let name: String?
    let releaseDate: String?
    let firstAirDate: String?
    let overview: String?
    let posterPath: String?
    let backdropPath: String?

    enum CodingKeys: String, CodingKey {
        case id, title, name, overview
        case mediaType = "media_type"
        case releaseDate = "release_date"
        case firstAirDate = "first_air_date"
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
    }
}

private struct TMDbMovieDetail: Codable {
    let id: Int
    let title: String
    let releaseDate: String?
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    /// v4.0.6: TMDb provides runtime in minutes on the movie detail
    /// endpoint. Used by `DiscInfo.autoLabel` to pick the disc title
    /// whose duration matches.
    let runtime: Int?

    enum CodingKeys: String, CodingKey {
        case id, title, overview, runtime
        case releaseDate = "release_date"
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
    }
}

private struct TMDbTvDetail: Codable {
    let id: Int
    let name: String
    let firstAirDate: String?
    let overview: String?
    let posterPath: String?
    let backdropPath: String?

    enum CodingKeys: String, CodingKey {
        case id, name, overview
        case firstAirDate = "first_air_date"
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
    }
}

private struct TMDbSeasonResponse: Codable {
    let episodes: [TMDbEpisodeItem]
}

private struct TMDbEpisodeItem: Codable {
    let seasonNumber: Int?
    let episodeNumber: Int?
    let name: String?
    /// v4.0.4: TMDb provides runtime in minutes. Optional because some
    /// older shows have null runtime metadata.
    let runtime: Int?

    enum CodingKeys: String, CodingKey {
        case name
        case runtime
        case seasonNumber = "season_number"
        case episodeNumber = "episode_number"
    }
}
