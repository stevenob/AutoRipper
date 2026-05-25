import Foundation

/// v4.0.17: JSON schema for user-loadable known-disc map packs. One JSON
/// file contains an array of `KnownDiscMap` entries (e.g. all six discs
/// for a series release in a single file). Files live in
/// `AppConfig.knownDiscMapsFolder` and are loaded at app launch + on
/// settings change + on user-triggered Reload.
///
/// Schema example:
/// ```json
/// {
///   "version": 1,
///   "discMaps": [
///     {
///       "id": "bluey-s1-first-half",
///       "discNameAliases": ["Bluey: Season One - The First Half"],
///       "displayName": "Bluey · Season 1 · First Half (BBC Slipcover)",
///       "showName": "Bluey",
///       "expectedTmdbId": 82728,
///       "titleMappings": {
///         "1": { "season": 1, "episode": 25, "name": "Taxi" },
///         "26": { "skipReason": "French-only duplicate of 'Markets' (S01E20)" },
///         "27": { "season": 1, "episode": 26, "name": "The Beach" }
///       }
///     }
///   ]
/// }
/// ```
///
/// Top-level `version` is reserved for future schema migrations.
/// Current accepted value: `1`.

/// JSON envelope: a pack of disc maps. One file = one pack.
struct KnownDiscMapPackJSON: Codable, Sendable {
    let version: Int
    let discMaps: [KnownDiscMapJSON]
}

/// Codable mirror of `KnownDiscMap`. Validated + converted by
/// `KnownDiscMapLoader.load(from:)`.
struct KnownDiscMapJSON: Codable, Sendable {
    let id: String
    let discNameAliases: [String]
    let displayName: String
    let showName: String
    let expectedTmdbId: Int?
    /// Keyed by *string-encoded* title id so JSON object keys parse
    /// naturally. Loader converts to `[Int: KnownDiscEpisode]`.
    let titleMappings: [String: KnownDiscEpisodeJSON]
}

/// Codable mirror of `KnownDiscEpisode`. A non-nil `skipReason`
/// indicates "skip"; the other fields are ignored. When `skipReason`
/// is nil, `season`/`episode`/`name` are required.
struct KnownDiscEpisodeJSON: Codable, Sendable {
    let season: Int?
    let episode: Int?
    let name: String?
    let skipReason: String?
}

/// Result of attempting to load one file. Either a successful pack or
/// a list of human-readable error messages (one per problem).
struct KnownDiscMapPackLoadResult: Sendable {
    let path: String
    let maps: [KnownDiscMap]
    let errors: [String]
}

/// Lightweight error wrapper so `Result<KnownDiscMap, ValidationError>`
/// composes cleanly. Carries a human-readable message.
struct KnownDiscMapValidationError: Error, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
}

/// v4.0.17: scans a folder, parses each `*.json` as a
/// `KnownDiscMapPackJSON`, converts to `[KnownDiscMap]`.
enum KnownDiscMapLoader {
    /// Scan `folder` for `*.json` files (non-recursive). Returns one
    /// result per file. Files that fail to parse are reported via the
    /// `errors` field — they don't block other files from loading.
    static func loadAll(in folder: URL) -> [KnownDiscMapPackLoadResult] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: folder,
                                                          includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles]) else {
            return []
        }
        let jsonURLs = contents
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return jsonURLs.map { load(from: $0) }
    }

    /// Load a single file. Surfaces top-level decode errors and per-map
    /// validation errors as human-readable strings.
    static func load(from url: URL) -> KnownDiscMapPackLoadResult {
        guard let data = try? Data(contentsOf: url) else {
            return KnownDiscMapPackLoadResult(
                path: url.path, maps: [], errors: ["Could not read file"]
            )
        }
        let decoder = JSONDecoder()
        let pack: KnownDiscMapPackJSON
        do {
            pack = try decoder.decode(KnownDiscMapPackJSON.self, from: data)
        } catch {
            return KnownDiscMapPackLoadResult(
                path: url.path, maps: [],
                errors: ["JSON decode failed: \(error.localizedDescription)"]
            )
        }
        guard pack.version == 1 else {
            return KnownDiscMapPackLoadResult(
                path: url.path, maps: [],
                errors: ["Unsupported schema version \(pack.version) (expected 1)"]
            )
        }
        var maps: [KnownDiscMap] = []
        var errors: [String] = []
        for (idx, dto) in pack.discMaps.enumerated() {
            switch convert(dto) {
            case .success(let map):
                maps.append(map)
            case .failure(let err):
                errors.append("discMaps[\(idx)] (id='\(dto.id)'): \(err.message)")
            }
        }
        return KnownDiscMapPackLoadResult(path: url.path, maps: maps, errors: errors)
    }

    /// Pure conversion JSON DTO → strongly typed `KnownDiscMap` with
    /// validation. Exposed `internal` for unit tests.
    static func convert(_ dto: KnownDiscMapJSON) -> Result<KnownDiscMap, KnownDiscMapValidationError> {
        guard !dto.id.isEmpty else { return .failure(KnownDiscMapValidationError("missing id")) }
        guard !dto.discNameAliases.isEmpty else { return .failure(KnownDiscMapValidationError("discNameAliases is empty")) }
        guard !dto.showName.isEmpty else { return .failure(KnownDiscMapValidationError("missing showName")) }
        var mappings: [Int: KnownDiscEpisode] = [:]
        for (key, value) in dto.titleMappings {
            guard let titleId = Int(key) else {
                return .failure(KnownDiscMapValidationError("titleMappings key '\(key)' is not an integer"))
            }
            switch convertEpisode(value) {
            case .success(let entry):
                mappings[titleId] = entry
            case .failure(let err):
                return .failure(KnownDiscMapValidationError("titleMappings['\(key)']: \(err.message)"))
            }
        }
        guard !mappings.isEmpty else { return .failure(KnownDiscMapValidationError("titleMappings is empty")) }
        return .success(KnownDiscMap(
            id: dto.id,
            discNameAliases: dto.discNameAliases,
            displayName: dto.displayName.isEmpty ? dto.id : dto.displayName,
            showName: dto.showName,
            expectedTmdbId: dto.expectedTmdbId,
            titleMappings: mappings
        ))
    }

    static func convertEpisode(_ dto: KnownDiscEpisodeJSON) -> Result<KnownDiscEpisode, KnownDiscMapValidationError> {
        if let reason = dto.skipReason, !reason.isEmpty {
            return .success(KnownDiscEpisode.skip(reason))
        }
        guard let season = dto.season, season > 0 else {
            return .failure(KnownDiscMapValidationError("missing/invalid 'season' (and no 'skipReason')"))
        }
        guard let episode = dto.episode, episode > 0 else {
            return .failure(KnownDiscMapValidationError("missing/invalid 'episode' (and no 'skipReason')"))
        }
        let name = dto.name ?? ""
        return .success(KnownDiscEpisode.episode(season, episode, name))
    }

    // MARK: Sample export

    /// Build a sample JSON pack the user can copy as a starting point.
    /// Two disc-map entries, one with a skip entry, demonstrating the
    /// complete schema.
    static func sampleJSONString() -> String {
        let body = """
        {
          "version": 1,
          "discMaps": [
            {
              "id": "example-show-s1-disc1",
              "discNameAliases": ["EXAMPLE_SHOW_S1_D1", "Example Show: Season 1 Disc 1"],
              "displayName": "Example Show · Season 1 · Disc 1",
              "showName": "Example Show",
              "expectedTmdbId": 12345,
              "titleMappings": {
                "1": { "season": 1, "episode": 1, "name": "Pilot" },
                "2": { "season": 1, "episode": 2, "name": "Second Episode" },
                "3": { "skipReason": "Spanish-language duplicate of episode 1" }
              }
            },
            {
              "id": "example-show-s1-disc2",
              "discNameAliases": ["EXAMPLE_SHOW_S1_D2"],
              "displayName": "Example Show · Season 1 · Disc 2",
              "showName": "Example Show",
              "expectedTmdbId": 12345,
              "titleMappings": {
                "1": { "season": 1, "episode": 3, "name": "Third Episode" },
                "2": { "season": 1, "episode": 4, "name": "Fourth Episode" }
              }
            }
          ]
        }
        """
        return body
    }
}
