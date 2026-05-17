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
struct EpisodeInfo: Sendable, Codable, Equatable {
    let seasonNumber: Int
    let episodeNumber: Int
    let name: String
    /// v4.0.4: episode runtime in minutes from TMDb. Used by the
    /// duration-based episode matcher to map disc titles → episodes
    /// when the disc-title order doesn't reliably correspond to
    /// broadcast/episode order (which is often — extras and bumpers
    /// are interspersed). Nil when TMDb doesn't have a runtime for
    /// the episode (rare; happens on shows with sparse metadata).
    let runtimeMinutes: Int?
}
