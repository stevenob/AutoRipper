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
    /// v4.0.6: TMDb-reported runtime in minutes. Movies only — TV
    /// shows have per-episode runtimes via `EpisodeInfo` instead.
    /// Populated by the follow-up `/movie/{id}` fetch after `searchMedia`
    /// returns the top hit. Nil for TV results, and for movies where
    /// the lookup fails or TMDb has no runtime metadata.
    ///
    /// Drives `DiscInfo.autoLabel`'s main-feature pick: when present,
    /// the title closest to this runtime is preferred as `.mainFeature`
    /// over the largest-by-size fallback. Catches cases where a play-
    /// all or director's-cut is bigger than the theatrical, or where
    /// a bonus disc has a bigger remaster than the main feature.
    var runtimeMinutes: Int?

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
