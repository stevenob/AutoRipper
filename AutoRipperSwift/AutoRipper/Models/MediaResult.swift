import Foundation

/// A search result from the TMDb API.
struct MediaResult: Sendable, Codable {
    let title: String
    let year: Int?
    let mediaType: String  // "movie" or "tv"
    let tmdbId: Int
    var overview: String = ""
    var posterPath: String?
    var backdropPath: String?

    var displayTitle: String {
        if let year {
            return "\(title) (\(year))"
        }
        return title
    }
}

/// Episode information from TMDb.
struct EpisodeInfo: Sendable, Codable {
    let seasonNumber: Int
    let episodeNumber: Int
    let name: String
}
