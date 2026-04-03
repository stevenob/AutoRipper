import Foundation
import os

private let log = Logger(subsystem: "com.autoripper.app", category: "update")

/// Checks GitHub Releases for a newer version of AutoRipper.
@MainActor
final class UpdateService: ObservableObject {
    static let currentVersion = "2.1.0"
    private static let repoAPI = "https://api.github.com/repos/stevenob/AutoRipper/releases/latest"

    @Published var updateAvailable: Bool = false
    @Published var latestVersion: String = ""
    @Published var releaseURL: String = ""
    @Published var releaseNotes: String = ""

    func checkForUpdates() {
        Task {
            guard let url = URL(string: Self.repoAPI) else { return }
            do {
                var request = URLRequest(url: url)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.timeoutInterval = 10

                let (data, _) = try await URLSession.shared.data(for: request)
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tagName = json["tag_name"] as? String,
                      let htmlURL = json["html_url"] as? String else { return }

                let remote = tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                if remote != Self.currentVersion && isNewer(remote: remote, current: Self.currentVersion) {
                    latestVersion = remote
                    releaseURL = htmlURL
                    releaseNotes = (json["body"] as? String) ?? ""
                    updateAvailable = true
                    log.info("Update available: \(remote)")
                } else {
                    log.info("Up to date (\(Self.currentVersion))")
                }
            } catch {
                log.error("Update check failed: \(error.localizedDescription)")
            }
        }
    }

    private func isNewer(remote: String, current: String) -> Bool {
        let r = remote.split(separator: ".").compactMap { Int($0) }
        let c = current.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(r.count, c.count) {
            let rv = i < r.count ? r[i] : 0
            let cv = i < c.count ? c[i] : 0
            if rv > cv { return true }
            if rv < cv { return false }
        }
        return false
    }
}
