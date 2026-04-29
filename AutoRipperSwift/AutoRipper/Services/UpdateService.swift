import Foundation
import AppKit
import os

private let log = Logger(subsystem: "com.autoripper.app", category: "update")

/// Checks GitHub Releases for a newer version of AutoRipper, and installs it
/// in-place when the user opts in. Trust model: we already trust the GitHub
/// Releases asset (we publish it), so a "download + mount + copy + relaunch"
/// flow is sufficient — no need for Sparkle's signature verification overhead.
@MainActor
final class UpdateService: ObservableObject {
    static let currentVersion = "3.4.5"
    private static let repoAPI = "https://api.github.com/repos/stevenob/AutoRipper/releases/latest"

    @Published var updateAvailable: Bool = false
    @Published var latestVersion: String = ""
    @Published var releaseURL: String = ""
    @Published var releaseNotes: String = ""
    /// Direct download URL of the AutoRipper-Installer.dmg asset attached to the
    /// latest release. Populated alongside `updateAvailable`.
    @Published var dmgURL: String = ""
    /// True while a download/install is in flight — UI uses this to disable
    /// the install button and show a progress indicator.
    @Published var installing: Bool = false
    @Published var installError: String?

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
                    // Find the AutoRipper-Installer.dmg asset.
                    if let assets = json["assets"] as? [[String: Any]] {
                        for a in assets {
                            if let name = a["name"] as? String, name.hasSuffix(".dmg"),
                               let dl = a["browser_download_url"] as? String {
                                dmgURL = dl
                                break
                            }
                        }
                    }
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

    /// Downloads the latest DMG, mounts it, schedules a background helper to
    /// swap the bundle into /Applications and relaunch, then quits this app.
    func downloadAndInstall() {
        guard !installing else { return }
        guard let url = URL(string: dmgURL) else {
            installError = "No DMG URL"
            return
        }
        installing = true
        installError = nil

        Task {
            do {
                // 1. Download to a temp file.
                let (tempURL, _) = try await URLSession.shared.download(from: url)
                let dmgPath = NSTemporaryDirectory() + "AutoRipper-Update-\(UUID().uuidString).dmg"
                try FileManager.default.moveItem(atPath: tempURL.path, toPath: dmgPath)
                FileLogger.shared.info("update", "downloaded DMG to \(dmgPath)")

                // 2. Mount it. hdiutil prints the mount point on stdout.
                let mountPoint = try mountDMG(at: dmgPath)
                FileLogger.shared.info("update", "mounted at \(mountPoint)")

                // 3. Find AutoRipper.app inside the mount.
                let appInside = (mountPoint as NSString).appendingPathComponent("AutoRipper.app")
                guard FileManager.default.fileExists(atPath: appInside) else {
                    throw NSError(domain: "UpdateService", code: 1, userInfo: [NSLocalizedDescriptionKey: "AutoRipper.app not found in DMG"])
                }

                // 4. Write a helper script that waits for us to quit, swaps the
                //    bundle, unmounts the DMG, and relaunches.
                let scriptPath = try writeInstallHelper(appInside: appInside, mountPoint: mountPoint, dmgPath: dmgPath)

                // 5. Launch the helper detached, then quit ourselves.
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/bin/bash")
                proc.arguments = [scriptPath]
                try proc.run()
                FileLogger.shared.info("update", "launched install helper, quitting now")

                // Brief delay so the helper script is definitely running before we exit.
                try? await Task.sleep(for: .milliseconds(300))
                NSApp.terminate(nil)
            } catch {
                installError = error.localizedDescription
                installing = false
                FileLogger.shared.error("update", "install failed: \(error.localizedDescription)")
            }
        }
    }

    private func mountDMG(at dmgPath: String) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        proc.arguments = ["attach", dmgPath, "-nobrowse", "-quiet"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw NSError(domain: "UpdateService", code: 2, userInfo: [NSLocalizedDescriptionKey: "hdiutil attach failed"])
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        // hdiutil prints lines like: "/dev/disk6s1     Apple_HFS     /Volumes/AutoRipper"
        for line in output.components(separatedBy: .newlines) {
            if let range = line.range(of: "/Volumes/") {
                return String(line[range.lowerBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        throw NSError(domain: "UpdateService", code: 3, userInfo: [NSLocalizedDescriptionKey: "hdiutil mount point not found in output"])
    }

    private func writeInstallHelper(appInside: String, mountPoint: String, dmgPath: String) throws -> String {
        // Helper waits for the running AutoRipper to exit, replaces the bundle
        // in /Applications, clears the quarantine xattr (we ad-hoc/dev-cert sign
        // builds, no notarization), unmounts the DMG, and relaunches.
        let script = """
        #!/bin/bash
        set -e
        # Wait up to 10s for AutoRipper to quit.
        for i in $(seq 1 20); do
          if ! pgrep -x AutoRipper >/dev/null; then break; fi
          sleep 0.5
        done
        rm -rf /Applications/AutoRipper.app
        cp -R "\(appInside)" /Applications/
        xattr -dr com.apple.quarantine /Applications/AutoRipper.app 2>/dev/null || true
        hdiutil detach "\(mountPoint)" -quiet || true
        rm -f "\(dmgPath)"
        open /Applications/AutoRipper.app
        """
        let path = NSTemporaryDirectory() + "autoripper-install-\(UUID().uuidString).sh"
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        // Make executable.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/chmod")
        proc.arguments = ["+x", path]
        try proc.run()
        proc.waitUntilExit()
        return path
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
