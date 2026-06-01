import Foundation
import os

private let log = Logger(subsystem: "com.autoripper.app", category: "thediscdb")

/// TheDiscDB's public GraphQL endpoint. No API key required (verified live).
private let graphQLEndpoint = "https://thediscdb.com/graphql"

/// Process-wide cache for TheDiscDB lookups, mirroring `TMDbService`'s
/// `NSLock`-guarded singleton so repeat scans of the same disc don't re-hit the
/// network.
private final class TheDiscDBCache: @unchecked Sendable {
    static let shared = TheDiscDBCache()
    private let lock = NSLock()
    private var byHash: [String: [TheDiscDBDisc]] = [:]
    private var byTmdb: [String: [TheDiscDBDisc]] = [:]

    func cachedHash(_ hash: String) -> [TheDiscDBDisc]? {
        lock.lock(); defer { lock.unlock() }
        return byHash[hash]
    }
    func storeHash(_ hash: String, _ discs: [TheDiscDBDisc]) {
        lock.lock(); defer { lock.unlock() }
        byHash[hash] = discs
    }
    func cachedTmdb(_ key: String) -> [TheDiscDBDisc]? {
        lock.lock(); defer { lock.unlock() }
        return byTmdb[key]
    }
    func storeTmdb(_ key: String, _ discs: [TheDiscDBDisc]) {
        lock.lock(); defer { lock.unlock() }
        byTmdb[key] = discs
    }
}

/// Read-only client for TheDiscDB's GraphQL API. Returns AutoRipper domain
/// models (`TheDiscDBDisc`), flattening the GraphQL
/// mediaItem → release → disc → title shape.
struct TheDiscDBService {
    private let session = URLSession.shared

    /// Look up every disc whose `contentHash` matches `hash` (exact path).
    ///
    /// Returns an array because the same physical pressing can appear in
    /// multiple releases / box sets — the caller's matcher picks the best one.
    /// `hash` is normalized to uppercase and validated as 32 hex chars; an
    /// invalid hash returns `[]` without a network call.
    func lookup(contentHash hash: String) async -> [TheDiscDBDisc] {
        let normalized = hash.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard Self.isValidContentHash(normalized) else {
            FileLogger.shared.warn("thediscdb",
                "lookup(contentHash): rejecting malformed hash '\(hash)'")
            return []
        }
        if let cached = TheDiscDBCache.shared.cachedHash(normalized) { return cached }

        let query = """
        query($h: String) {
          mediaItems(where: { releases: { some: { discs: { some: { contentHash: { eq: $h } } } } } }) {
            nodes { ...MediaFields }
          }
        }
        \(Self.mediaFragment)
        """
        let items = await execute(query: query, variables: ["h": normalized])
        // The query returns whole media items; keep only the disc(s) that
        // actually carry the requested hash.
        let discs = Self.flatten(items).filter {
            ($0.contentHash?.uppercased() ?? "") == normalized
        }
        FileLogger.shared.info("thediscdb",
            "lookup(contentHash): \(normalized) → \(discs.count) disc(s)")
        TheDiscDBCache.shared.storeHash(normalized, discs)
        return discs
    }

    /// Look up every disc of the media item with the given TMDb id (fallback
    /// path used when no content hash is available on either side).
    ///
    /// `mediaType` ("movie" | "tv"), when supplied, is used only for the cache
    /// key and caller-side filtering — the query keys solely on the TMDb id,
    /// which is unique per media item.
    func lookup(tmdbId: Int, mediaType: String? = nil) async -> [TheDiscDBDisc] {
        let cacheKey = "\(tmdbId):\(mediaType ?? "")"
        if let cached = TheDiscDBCache.shared.cachedTmdb(cacheKey) { return cached }

        let query = """
        query($t: String) {
          mediaItems(where: { externalids: { tmdb: { eq: $t } } }) {
            nodes { ...MediaFields }
          }
        }
        \(Self.mediaFragment)
        """
        let items = await execute(query: query, variables: ["t": String(tmdbId)])
        let discs = Self.flatten(items)
        FileLogger.shared.info("thediscdb",
            "lookup(tmdbId): \(tmdbId) → \(discs.count) disc(s) across \(items.count) media item(s)")
        TheDiscDBCache.shared.storeTmdb(cacheKey, discs)
        return discs
    }

    /// Uppercase hex, 8–128 chars (MD5 is 32; widened to match the server's
    /// own `^[a-fA-F0-9]{8,128}$` validation).
    static func isValidContentHash(_ hash: String) -> Bool {
        guard (8...128).contains(hash.count) else { return false }
        return hash.allSatisfy { $0.isHexDigit }
    }

    // MARK: - GraphQL plumbing

    /// Shared selection set so both queries fetch the same shape.
    private static let mediaFragment = """
    fragment MediaFields on MediaItem {
      title
      year
      type
      externalids { tmdb imdb }
      releases {
        slug
        upc
        discs(order: { index: ASC }) {
          index
          name
          format
          contentHash
          titles(order: { index: ASC }) {
            index
            duration
            size
            segmentMap
            sourceFile
            item { title type season episode }
          }
        }
      }
    }
    """

    private func execute(query: String, variables: [String: String]) async -> [GQLMediaItem] {
        guard let url = URL(string: graphQLEndpoint) else { return [] }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 25

        let body: [String: Any] = ["query": query, "variables": variables]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return [] }
        request.httpBody = data

        do {
            let (responseData, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                FileLogger.shared.warn("thediscdb",
                    "GraphQL HTTP \(http.statusCode) for query")
                return []
            }
            let decoded = try JSONDecoder().decode(GQLResponse.self, from: responseData)
            if let errors = decoded.errors, !errors.isEmpty {
                FileLogger.shared.warn("thediscdb",
                    "GraphQL errors: \(errors.map(\.message).joined(separator: "; "))")
            }
            return decoded.data?.mediaItems?.nodes ?? []
        } catch {
            log.warning("GraphQL request failed: \(error.localizedDescription)")
            FileLogger.shared.warn("thediscdb",
                "GraphQL request failed: \(error.localizedDescription)")
            return []
        }
    }

    /// Flatten GraphQL media items into a flat list of `TheDiscDBDisc`.
    private static func flatten(_ items: [GQLMediaItem]) -> [TheDiscDBDisc] {
        var discs: [TheDiscDBDisc] = []
        for item in items {
            let tmdb = item.externalids?.tmdb.flatMap { Int($0) }
            for release in item.releases ?? [] {
                for disc in release.discs ?? [] {
                    let titles: [TheDiscDBTitle] = (disc.titles ?? []).map { t in
                        TheDiscDBTitle(
                            index: t.index ?? 0,
                            durationSeconds: TheDiscDBTitle.parseDurationSeconds(t.duration ?? ""),
                            sizeBytes: t.size,
                            segmentMap: t.segmentMap,
                            sourceFile: t.sourceFile,
                            type: TheDiscDBTitleType(raw: t.item?.type),
                            title: t.item?.title ?? "",
                            season: t.item?.season?.value,
                            episode: t.item?.episode?.value
                        )
                    }
                    discs.append(TheDiscDBDisc(
                        contentHash: disc.contentHash,
                        name: disc.name ?? "",
                        format: disc.format ?? "",
                        index: disc.index ?? 0,
                        mediaTitle: item.title ?? "",
                        mediaYear: item.year,
                        mediaType: item.type ?? "",
                        tmdbId: tmdb,
                        imdbId: item.externalids?.imdb,
                        releaseSlug: release.slug ?? "",
                        upc: release.upc,
                        titles: titles
                    ))
                }
            }
        }
        return discs
    }
}

// MARK: - GraphQL response DTOs (private wire format)

private struct GQLResponse: Decodable {
    let data: GQLData?
    let errors: [GQLError]?
}
private struct GQLError: Decodable { let message: String }
private struct GQLData: Decodable { let mediaItems: GQLConnection? }
private struct GQLConnection: Decodable { let nodes: [GQLMediaItem] }

private struct GQLMediaItem: Decodable {
    let title: String?
    let year: Int?
    let type: String?
    let externalids: GQLExternalIds?
    let releases: [GQLRelease]?
}
private struct GQLExternalIds: Decodable {
    let tmdb: String?
    let imdb: String?
}
private struct GQLRelease: Decodable {
    let slug: String?
    let upc: String?
    let discs: [GQLDisc]?
}
private struct GQLDisc: Decodable {
    let index: Int?
    let name: String?
    let format: String?
    let contentHash: String?
    let titles: [GQLTitle]?
}
private struct GQLTitle: Decodable {
    let index: Int?
    let duration: String?
    let size: Int64?
    let segmentMap: String?
    let sourceFile: String?
    let item: GQLItem?
}
private struct GQLItem: Decodable {
    let title: String?
    let type: String?
    let season: FlexibleInt?
    let episode: FlexibleInt?
}

/// Decodes a value that TheDiscDB may emit as either a JSON number or a JSON
/// string (season/episode are typed loosely on the server). Null and
/// non-numeric strings yield `value == nil`.
private struct FlexibleInt: Decodable {
    let value: Int?
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = nil
        } else if let i = try? container.decode(Int.self) {
            value = i
        } else if let s = try? container.decode(String.self) {
            value = Int(s)
        } else {
            value = nil
        }
    }
}
