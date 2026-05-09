import Foundation
import os

private let log = Logger(subsystem: "com.autoripper.app", category: "library-notify")

/// Result of a library refresh attempt — used in tests and verbose logging.
/// The actual queue pipeline ignores this beyond logging, since refresh
/// failures should never block a successful publish.
enum LibraryNotifyResult: Equatable {
    case skipped(reason: String)        // not configured, or not applicable
    case success(server: String)
    case failure(server: String, error: String)
}

/// Pings Plex / Jellyfin libraries to scan for new media after a successful
/// publish, so newly ripped movies show up in the user's clients within
/// seconds rather than waiting for the next periodic scan.
///
/// Best-effort throughout: any failure is logged and reported via the
/// returned `LibraryNotifyResult` but never propagated to the caller. A
/// down server, a bad token, or a transient network error must not be
/// allowed to fail an otherwise-successful publish.
///
/// API surface:
///   * Plex: `POST {url}/library/sections/{id}/refresh?X-Plex-Token={token}`
///   * Jellyfin: `POST {url}/Library/Refresh` with `X-Emby-Token: {key}`
///
/// Both support querying-by-section/path for a more targeted refresh, but
/// the simpler endpoint is enough — Plex's section refresh is fast even
/// when the library is large, and Jellyfin's full refresh is the
/// well-supported one.
actor LibraryNotifierService {
    private let config: AppConfig
    /// Injected URLSession so tests can swap in a URLProtocol mock.
    private let session: URLSession

    init(config: AppConfig = .shared, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    /// Trigger a library refresh on every configured server. Called once
    /// per successful publish from `QueueViewModel.runPublishStep`.
    /// `isTV` selects the right Plex section ID (movies vs TV); Jellyfin
    /// refresh is library-wide.
    func notifyAfterPublish(isTV: Bool) async -> [LibraryNotifyResult] {
        var results: [LibraryNotifyResult] = []
        results.append(await refreshPlex(isTV: isTV))
        results.append(await refreshJellyfin())
        return results
    }

    /// POST to Plex's section-refresh endpoint. Returns .skipped if Plex
    /// isn't configured (URL or token empty, or the relevant section ID
    /// missing).
    func refreshPlex(isTV: Bool) async -> LibraryNotifyResult {
        let urlBase = config.plexUrl.trimmingCharacters(in: .whitespaces)
        let token = config.plexToken.trimmingCharacters(in: .whitespaces)
        let section = (isTV ? config.plexTvSectionId : config.plexMoviesSectionId)
            .trimmingCharacters(in: .whitespaces)
        guard !urlBase.isEmpty, !token.isEmpty, !section.isEmpty else {
            return .skipped(reason: "Plex not configured")
        }
        guard URL(string: urlBase) != nil else {
            return .failure(server: "Plex", error: "Invalid Plex URL: \(urlBase)")
        }
        // Build URL with token as query param. Both header and query work
        // on Plex — query is friendlier to test mocks because URLProtocol
        // recievers can read the URL but headers may be stripped by
        // URLSession depending on request shape.
        let trimmedBase = urlBase.hasSuffix("/") ? String(urlBase.dropLast()) : urlBase
        let endpoint = "\(trimmedBase)/library/sections/\(section)/refresh?X-Plex-Token=\(token)"
        guard let url = URL(string: endpoint) else {
            return .failure(server: "Plex", error: "Could not build refresh URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        req.timeoutInterval = 10

        do {
            let (_, response) = try await session.data(for: req)
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                log.info("Plex refresh OK: section \(section, privacy: .public)")
                return .success(server: "Plex")
            }
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            log.warning("Plex refresh non-2xx: \(code)")
            return .failure(server: "Plex", error: "HTTP \(code)")
        } catch {
            log.warning("Plex refresh error: \(error.localizedDescription, privacy: .public)")
            return .failure(server: "Plex", error: error.localizedDescription)
        }
    }

    /// POST to Jellyfin's library-refresh endpoint (which scans all libraries).
    /// Returns .skipped if Jellyfin isn't configured.
    func refreshJellyfin() async -> LibraryNotifyResult {
        let urlBase = config.jellyfinUrl.trimmingCharacters(in: .whitespaces)
        let key = config.jellyfinApiKey.trimmingCharacters(in: .whitespaces)
        guard !urlBase.isEmpty, !key.isEmpty else {
            return .skipped(reason: "Jellyfin not configured")
        }
        let trimmedBase = urlBase.hasSuffix("/") ? String(urlBase.dropLast()) : urlBase
        guard let url = URL(string: "\(trimmedBase)/Library/Refresh") else {
            return .failure(server: "Jellyfin", error: "Could not build refresh URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "X-Emby-Token")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 10

        do {
            let (_, response) = try await session.data(for: req)
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                log.info("Jellyfin refresh OK")
                return .success(server: "Jellyfin")
            }
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            log.warning("Jellyfin refresh non-2xx: \(code)")
            return .failure(server: "Jellyfin", error: "HTTP \(code)")
        } catch {
            log.warning("Jellyfin refresh error: \(error.localizedDescription, privacy: .public)")
            return .failure(server: "Jellyfin", error: error.localizedDescription)
        }
    }
}
