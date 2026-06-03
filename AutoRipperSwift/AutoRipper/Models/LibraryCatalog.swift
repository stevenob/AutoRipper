import Foundation

/// A library catalog the user can search from the Library tab.
///
/// Two kinds are supported because public libraries run different catalog
/// platforms:
/// - `.carlConnect`: TLC CARL•Connect Discovery ("LS2 PAC"). Has a private
///   JSON search endpoint, so AutoRipper searches it in-app and shows
///   per-branch availability. `url` is the catalog root.
/// - `.externalLink`: any other platform (e.g. Polaris PowerPAC) that has no
///   usable JSON API. AutoRipper can't show results in-app, so searching
///   opens the catalog's own web search in the browser. `url` is a search URL
///   template containing the `{query}` placeholder.
struct LibraryCatalog: Identifiable, Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case carlConnect
        case externalLink
    }

    var id: UUID
    var name: String
    var url: String
    var kind: Kind

    init(id: UUID = UUID(), name: String, url: String, kind: Kind) {
        self.id = id
        self.name = name
        self.url = url
        self.kind = kind
    }

    /// Placeholder substituted with the (encoded) search term for
    /// `.externalLink` catalogs.
    static let queryPlaceholder = "{query}"

    // Stable IDs for the two built-in catalogs so a seeded selection stays
    // valid across launches and migrations.
    static let loudounID = UUID(uuidString: "A1000000-0000-0000-0000-000000000001")!
    static let fairfaxID = UUID(uuidString: "A1000000-0000-0000-0000-000000000002")!

    /// The catalogs a fresh install (or a pre-multi-catalog upgrade) starts
    /// with. `legacyLoudounURL` migrates a custom Loudoun URL a user may have
    /// set under the old single-catalog setting.
    static func builtInSeeds(legacyLoudounURL: String?) -> [LibraryCatalog] {
        let loudounURL = (legacyLoudounURL?.isEmpty == false)
            ? legacyLoudounURL!
            : "https://catalog.library.loudoun.gov"
        return [
            LibraryCatalog(id: loudounID,
                           name: "Loudoun County Public Library",
                           url: loudounURL,
                           kind: .carlConnect),
            LibraryCatalog(id: fairfaxID,
                           name: "Fairfax County Public Library",
                           url: "https://fcplcat.fairfaxcounty.gov/polaris/search/searchresults.aspx?ctx=1.1033.0.0.1&type=Keyword&term=\(queryPlaceholder)&by=KW",
                           kind: .externalLink),
        ]
    }

    /// Resolve the selected catalog, falling back to the first one if the
    /// stored selection id no longer matches any catalog (e.g. it was deleted).
    static func resolveSelection(id: String, in catalogs: [LibraryCatalog]) -> LibraryCatalog? {
        catalogs.first { $0.id.uuidString == id } ?? catalogs.first
    }

    /// True when an `.externalLink` template is usable: it must contain the
    /// `{query}` placeholder and produce a valid http(s) URL for a sample term.
    static func isValidExternalTemplate(_ template: String) -> Bool {
        template.contains(queryPlaceholder)
            && externalSearchURL(template: template, query: "sample") != nil
    }

    /// Build the browser URL for an `.externalLink` search by substituting the
    /// percent-encoded `query` into `template`. Returns nil when the query is
    /// empty, the template has no `{query}` placeholder, or the result isn't a
    /// valid http(s) URL.
    static func externalSearchURL(template: String, query: String) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              template.contains(queryPlaceholder),
              let encoded = encodeQueryValue(trimmed) else { return nil }
        let filled = template.replacingOccurrences(of: queryPlaceholder, with: encoded)
        guard let url = URL(string: filled),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    /// Percent-encode a search term for safe substitution into a URL query
    /// value. Encodes everything except RFC 3986 unreserved characters, so
    /// `&`, `+`, `=`, `(`, `)`, spaces, etc. are all escaped (spaces → %20).
    static func encodeQueryValue(_ value: String) -> String? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed)
    }
}
