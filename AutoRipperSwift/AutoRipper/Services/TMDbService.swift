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

    /// Search TMDb for movies and TV shows.
    func searchMedia(query: String) async -> [MediaResult] {
        guard !apiKey.isEmpty else {
            log.warning("TMDb API key not configured")
            return []
        }
        if let cached = TMDbCache.shared.cachedSearch(query) {
            return cached
        }
        let (cleaned, discYear) = Self.cleanDiscName(query)
        guard var url = URL(string: "\(baseURL)/search/multi") else { return [] }
        var queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "query", value: cleaned),
        ]
        if let year = discYear {
            queryItems.append(URLQueryItem(name: "year", value: String(year)))
        }
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
            TMDbCache.shared.storeSearch(query, results)
            return results
        } catch {
            log.error("TMDb search failed: \(error.localizedDescription)")
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
            let result = MediaResult(
                title: item.title, year: year, mediaType: "movie",
                tmdbId: item.id, overview: item.overview ?? "",
                posterPath: item.posterPath, backdropPath: item.backdropPath
            )
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
                    name: ep.name ?? ""
                )
            }
            TMDbCache.shared.storeEpisodes(tvId: tvId, season: season, eps)
            return eps
        } catch {
            log.error("TMDb season fetch failed: \(error.localizedDescription)")
            return []
        }
    }
}

// MARK: - Codable Response Models

private struct TMDbSearchResponse: Codable {
    let results: [TMDbSearchItem]
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

    enum CodingKeys: String, CodingKey {
        case id, title, overview
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

    enum CodingKeys: String, CodingKey {
        case name
        case seasonNumber = "season_number"
        case episodeNumber = "episode_number"
    }
}
