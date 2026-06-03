import Foundation
import os

private let log = Logger(subsystem: "com.autoripper.app", category: "library-catalog")

/// A single holding (physical copy) of a catalog title at one branch.
struct LibraryHolding: Identifiable, Equatable, Sendable {
    let id: Int
    let onShelf: Bool
    let branchName: String
    let collectionName: String
    let callNumber: String
}

/// A search result from a TLC CARL•Connect Discovery catalog.
struct CatalogResult: Identifiable, Equatable, Sendable {
    let id: Int
    let title: String
    let author: String
    let year: String
    /// Raw catalog format string, e.g. "DVD", "Blu-Ray", "Book", "eBook".
    let format: String
    let holdings: [LibraryHolding]
    /// Deep link to the record on the catalog website.
    let detailURL: URL?

    /// Copies currently on the shelf (available to borrow now).
    var availableCount: Int { holdings.filter { $0.onShelf }.count }
    /// Total physical copies across all branches.
    var copyCount: Int { holdings.count }
    /// Distinct branches with at least one copy on the shelf, sorted.
    var availableBranches: [String] {
        Array(Set(holdings.filter { $0.onShelf }.map { $0.branchName })).sorted()
    }
    /// True for physical video discs (the formats AutoRipper can rip).
    var isVideoDisc: Bool {
        let f = format.lowercased()
        return f.contains("dvd") || f.contains("blu") || f.contains("blu-ray")
    }
    var displayTitle: String {
        year.isEmpty ? title : "\(title) (\(year))"
    }
}

/// Searches a TLC CARL•Connect Discovery ("LS2 PAC") public library catalog
/// via its private JSON endpoint — the same one the catalog website calls.
///
/// There is no official/public API or key for this platform, so this targets
/// the unauthenticated `POST /search` endpoint and decodes the records.
/// Read-only; nothing is written to the catalog.
struct LoudounCatalogService {
    let baseURL: String
    private let session: URLSession

    init(baseURL: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    /// Search the catalog for `term`, returning up to `limit` records.
    func search(term: String, limit: Int = 25) async throws -> [CatalogResult] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let root = Self.normalizedRoot(baseURL),
              let url = URL(string: "\(root)/search") else {
            throw CatalogError.badConfiguration
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let payload = SearchRequest(
            searchTerm: trimmed, hitsPerPage: limit, startIndex: 0,
            facetFilters: [], branchFilters: [], sortCriteria: "Relevancy",
            dbCodes: [], frbrSearch: false)
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            log.error("catalog search HTTP \(http.statusCode)")
            throw CatalogError.server(http.statusCode)
        }
        return try Self.parseOrThrow(data, baseURL: root)
    }

    /// Decode a search response, throwing if the payload can't be read at all
    /// (e.g. the private endpoint changed shape or the host returned HTML).
    /// Individual malformed records are skipped, not fatal.
    static func parseOrThrow(_ data: Data, baseURL: String) throws -> [CatalogResult] {
        let root = normalizedRoot(baseURL) ?? baseURL
        guard let response = try? JSONDecoder().decode(SearchResponse.self, from: data) else {
            log.warning("catalog response failed to decode")
            throw CatalogError.unexpectedResponse
        }
        return (response.resources ?? []).compactMap { wrapper -> CatalogResult? in
            guard let raw = wrapper.value, let id = raw.id else { return nil }
            let holdings = (raw.holdingsInformations ?? []).compactMap { $0.value }.map { h in
                LibraryHolding(
                    id: h.id ?? 0,
                    onShelf: h.onshelf ?? false,
                    branchName: h.branchName ?? "",
                    collectionName: h.collectionName ?? "",
                    callNumber: h.callClass ?? "")
            }
            return CatalogResult(
                id: id,
                title: raw.shortTitle ?? "Untitled",
                author: raw.shortAuthor ?? "",
                year: raw.publicationDate?.publicationDate ?? "",
                format: raw.format ?? "",
                holdings: holdings,
                detailURL: URL(string: "\(root)/?section=resource&resourceid=\(id)"))
        }
    }

    /// Non-throwing convenience used by unit tests.
    static func parse(_ data: Data, baseURL: String) -> [CatalogResult] {
        (try? parseOrThrow(data, baseURL: baseURL)) ?? []
    }

    /// Validate and normalize a catalog base URL: require an http(s) scheme and
    /// host, strip any query/fragment, and drop a trailing slash.
    static func normalizedRoot(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard var comps = URLComponents(string: trimmed),
              let scheme = comps.scheme?.lowercased(), scheme == "http" || scheme == "https",
              comps.host != nil else { return nil }
        comps.query = nil
        comps.fragment = nil
        var s = comps.string ?? trimmed
        while s.hasSuffix("/") { s.removeLast() }
        return s.isEmpty ? nil : s
    }

    enum CatalogError: LocalizedError {
        case badConfiguration
        case server(Int)
        case unexpectedResponse

        var errorDescription: String? {
            switch self {
            case .badConfiguration:
                return "The library catalog URL is invalid. Check it in the catalog source settings (gear icon)."
            case .server(let code):
                return "The library catalog returned an error (HTTP \(code))."
            case .unexpectedResponse:
                return "Couldn't read the catalog's response. The catalog may have changed or blocked the search — try the catalog website, or update the catalog URL."
            }
        }
    }
}

// MARK: - Wire models

private struct SearchRequest: Encodable {
    let searchTerm: String
    let hitsPerPage: Int
    let startIndex: Int
    let facetFilters: [String]
    let branchFilters: [String]
    let sortCriteria: String
    let dbCodes: [String]
    let frbrSearch: Bool
}

private struct SearchResponse: Decodable {
    let totalHits: Int?
    let resources: [Lossy<RawResource>]?
}

/// Decodes a single element, swallowing per-element decode failures so one
/// malformed record (e.g. a changed field type) doesn't discard the whole
/// response. Safe for unkeyed containers: the element decoder advances the
/// index regardless of whether the wrapped type decoded.
private struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

private struct RawResource: Decodable {
    let id: Int?
    let format: String?
    let shortTitle: String?
    let shortAuthor: String?
    let publicationDate: PublicationDate?
    let holdingsInformations: [Lossy<RawHolding>]?
}

private struct PublicationDate: Decodable {
    let publicationDate: String?
}

private struct RawHolding: Decodable {
    let id: Int?
    let onshelf: Bool?
    let branchName: String?
    let collectionName: String?
    let callClass: String?
}
