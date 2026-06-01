import Foundation

/// Domain models for the TheDiscDB (https://thediscdb.com) integration.
///
/// TheDiscDB is a community database that documents the exact title layout of
/// physical movie/TV discs (which MakeMKV title is the main feature, which are
/// extras / deleted scenes / episodes, their names, season+episode, etc.).
/// AutoRipper uses it to replace its runtime-clustering heuristics with
/// ground-truth metadata when a disc is in the database.
///
/// These are AutoRipper-side domain types — `TheDiscDBService` decodes the
/// GraphQL response into them, and `TheDiscDBMatcher` consumes them. They are
/// deliberately decoupled from the wire format so a server schema tweak only
/// touches the service's private DTOs.

/// A title's content type as reported by TheDiscDB's `item.type`.
///
/// Tolerant of unknown / null values: a brand-new server-side type decodes to
/// `.unknown(raw)` and a null `item.type` (the unnamed sub-segments TheDiscDB
/// stores under a parent like "Deleted Scenes") decodes to `.none`. Neither
/// ever fails decoding.
enum TheDiscDBTitleType: Sendable, Equatable {
    case mainMovie
    case episode
    case `extra`
    case deletedScene
    case trailer
    case interview
    case featurette
    case short
    case music
    /// A type string TheDiscDB returned that we don't model yet.
    case unknown(String)
    /// `item.type` was null — an unnamed segment (e.g. one chunk of a
    /// "Deleted Scenes" reel). Carries no trustworthy classification.
    case none

    init(raw: String?) {
        guard let raw, !raw.isEmpty else { self = .none; return }
        switch raw.lowercased() {
        case "mainmovie":    self = .mainMovie
        case "episode":      self = .episode
        case "extra":        self = .extra
        case "deletedscene": self = .deletedScene
        case "trailer":      self = .trailer
        case "interview":    self = .interview
        case "featurette":   self = .featurette
        case "short":        self = .short
        case "music":        self = .music
        default:             self = .unknown(raw)
        }
    }

    /// Map onto AutoRipper's post-rip `JobIntent`. Everything that isn't a
    /// main feature or an episode rides the conservative `.extra` path.
    var jobIntent: JobIntent {
        switch self {
        case .mainMovie: return .movie
        case .episode:   return .episode
        default:         return .extra
        }
    }

    /// Map onto AutoRipper's `TitleCategory` (the UI label). `nil` for
    /// `.none`/`.unknown` so the caller keeps `DiscInfo.autoLabel`'s guess
    /// rather than overwriting it with something less specific.
    var titleCategory: TitleCategory? {
        switch self {
        case .mainMovie:                       return .mainFeature
        case .episode:                         return .episode
        case .trailer:                         return .trailer
        case .short:                           return .shortExtra
        case .featurette, .interview, .music:  return .featurette
        case .deletedScene, .extra:            return .extra
        case .unknown, .none:                  return nil
        }
    }

    /// True when TheDiscDB carries a real classification for this title (i.e.
    /// not an unnamed `.none` segment).
    var isClassified: Bool {
        if case .none = self { return false }
        return true
    }
}

/// One title on a TheDiscDB disc release.
struct TheDiscDBTitle: Sendable, Equatable, Identifiable {
    /// TheDiscDB's own title index on the disc. NOTE: this does *not* line up
    /// with MakeMKV title ids — TheDiscDB often splits a segment-combined
    /// MakeMKV title into several entries. The matcher pairs by duration, not
    /// index.
    let index: Int
    var id: Int { index }
    let durationSeconds: Int
    /// Bytes, when present. Only a *relative* signal: TheDiscDB and MakeMKV
    /// report slightly different sizes for the same title (remux overhead), so
    /// this is a tiebreaker, never an equality key.
    let sizeBytes: Int64?
    let segmentMap: String?
    let sourceFile: String?
    let type: TheDiscDBTitleType
    /// Human title, e.g. "The Making of Garden State". Empty when unnamed.
    let title: String
    let season: Int?
    let episode: Int?
}

/// A single physical disc within a TheDiscDB release, with the parent media
/// metadata flattened in for convenience.
struct TheDiscDBDisc: Sendable, Equatable {
    /// Uppercase hex MD5 disc fingerprint. `nil` for the many older entries
    /// that predate hashing — those are reachable only via the TMDb-id +
    /// duration fallback.
    let contentHash: String?
    let name: String
    /// Raw format string, e.g. "DVD", "Blu-Ray", "UHD".
    let format: String
    let index: Int
    let mediaTitle: String
    let mediaYear: Int?
    /// "Movie" | "Series".
    let mediaType: String
    let tmdbId: Int?
    let imdbId: String?
    let releaseSlug: String
    let upc: String?
    let titles: [TheDiscDBTitle]

    /// Normalized disc kind for comparison against `DiscInfo.type`
    /// ("dvd" | "bluray"). UHD maps to "bluray" since it rides the same
    /// AutoRipper pipeline. `nil` when unrecognized.
    var normalizedKind: String? {
        let f = format.lowercased()
        if f.contains("blu") { return "bluray" }
        if f.contains("uhd") || f.contains("4k") || f.contains("2160") { return "bluray" }
        if f.contains("dvd") { return "dvd" }
        return nil
    }

    /// The MainMovie title, if the disc has one.
    var mainMovieTitle: TheDiscDBTitle? {
        titles.first { $0.type == .mainMovie }
    }
}

extension TheDiscDBTitle {
    /// Parse a TheDiscDB `"H:MM:SS"` / `"M:SS"` duration into whole seconds.
    /// Mirrors `TitleInfo.durationSeconds` so both sides compare like-for-like.
    static func parseDurationSeconds(_ duration: String) -> Int {
        let parts = duration.split(separator: ":").compactMap { Int($0) }
        switch parts.count {
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        case 2: return parts[0] * 60 + parts[1]
        case 1: return parts[0]
        default: return 0
        }
    }
}
