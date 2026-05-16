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
    static let currentVersion = "3.12.2"
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

    /// v3.9.0: re-check every 6h while the app is running (it's a long-batch
    /// app, easily left open all day). Stored as a nonisolated unsafe ref
    /// behind the actor since Timer is best held weakly.
    private var periodicTimer: Timer?

    /// v3.9.0: how long to suppress the banner after the user dismisses it.
    /// Persisted in UserDefaults so it survives relaunches.
    private static let snoozeDuration: TimeInterval = 86_400  // 24h
    private static let snoozeKey = "updateSnoozedUntil"
    private static let autoCheckKey = "updateAutoCheckEnabled"

    /// v3.9.0: user-controllable kill switch. Reads from defaults; defaults
    /// to true (auto-check on, matching prior behavior).
    static var autoCheckEnabled: Bool {
        get {
            let d = UserDefaults(suiteName: "group.com.autoripper")!
            return d.object(forKey: autoCheckKey) as? Bool ?? true
        }
        set {
            UserDefaults(suiteName: "group.com.autoripper")!.set(newValue, forKey: autoCheckKey)
        }
    }

    func checkForUpdates() {
        // v3.9.0: respect the user's "disable auto-check" preference and any
        // active snooze. Manual checks via the menu bar item bypass the
        // snooze (force = true), but normal launch / periodic checks honor
        // both gates.
        checkForUpdates(force: false)
    }

    /// `force` = true bypasses both the auto-check toggle and the snooze
    /// window. Used by the explicit "Check for Updates…" menu item.
    func checkForUpdates(force: Bool) {
        if !force {
            guard Self.autoCheckEnabled else {
                log.info("auto-check disabled by user")
                return
            }
            if let snoozeUntil = UserDefaults(suiteName: "group.com.autoripper")!
                .object(forKey: Self.snoozeKey) as? Date,
               snoozeUntil > Date() {
                log.info("update check snoozed until \(snoozeUntil)")
                return
            }
        }
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
                    // v3.11.13: clear any stale install error from a prior
                    // failed attempt. Without this, the error string keeps
                    // appearing under the version label in the update
                    // banner even when the issue (e.g. a transient hdiutil
                    // parse failure) has been resolved server-side by a
                    // subsequent fresh DMG.
                    installError = nil
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

    /// v3.9.0: kicks off a periodic re-check timer. Called from
    /// `ContentView.onAppear` after the initial check.
    func startPeriodicChecks() {
        periodicTimer?.invalidate()
        // 6 hours between checks — long enough to not hammer GitHub's API,
        // short enough that batch users will see updates the same day
        // they're published.
        let interval: TimeInterval = 6 * 3600
        periodicTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkForUpdates() }
        }
        // Tolerate scheduler slop (don't wake the system specifically for
        // this).
        periodicTimer?.tolerance = 300
    }

    /// v3.9.0: dismiss the update banner and suppress re-prompting for the
    /// configured snooze window. Used by the banner's X button. The user can
    /// re-trigger via the "Check for Updates…" menu item if they change
    /// their mind.
    func snoozeDismiss() {
        let until = Date().addingTimeInterval(Self.snoozeDuration)
        UserDefaults(suiteName: "group.com.autoripper")!.set(until, forKey: Self.snoozeKey)
        updateAvailable = false
        log.info("update snoozed until \(until)")
    }

    /// Clear any active snooze. Called by `checkForUpdates(force: true)`
    /// from the explicit menu item so the user's intent overrides the
    /// banner-dismiss suppression.
    static func clearSnooze() {
        UserDefaults(suiteName: "group.com.autoripper")!.removeObject(forKey: snoozeKey)
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

                // v3.11.4: force-flush UserDefaults before terminate. The
                // install helper's wait loop polls every 0.5s for 10s for
                // AutoRipper to exit; meanwhile cfprefsd's async flush of
                // any settings the user just touched might lag. Explicit
                // sync here means the next launch of the freshly-replaced
                // bundle reads the up-to-date values.
                UserDefaults(suiteName: "group.com.autoripper")?.synchronize()
                UserDefaults.standard.synchronize()
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
        // v3.11.13: switched from `-quiet` (which suppresses the tabular
        // device-tree the old parser depended on, breaking the mount-point
        // extraction on macOS 14+) to `-plist`, which gives us a stable
        // machine-readable shape. The PropertyListSerialization-based
        // parser below recovers the mount point from the canonical
        // system-entities array, and falls back to the legacy substring
        // search if the plist parse ever fails (defense in depth).
        proc.arguments = ["attach", dmgPath, "-nobrowse", "-plist"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw NSError(domain: "UpdateService", code: 2, userInfo: [NSLocalizedDescriptionKey: "hdiutil attach failed"])
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let mount = Self.parseMountPointFromHdiutilPlist(data) {
            return mount
        }
        // Legacy fallback: tabular parse for environments where -plist
        // output is unparseable for some reason.
        let output = String(data: data, encoding: .utf8) ?? ""
        for line in output.components(separatedBy: .newlines) {
            if let range = line.range(of: "/Volumes/") {
                return String(line[range.lowerBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        throw NSError(domain: "UpdateService", code: 3, userInfo: [NSLocalizedDescriptionKey: "hdiutil mount point not found in output"])
    }

    /// v3.11.13: parse `hdiutil attach -plist` output and return the
    /// first non-empty `mount-point` value from the `system-entities`
    /// array. Returns nil on any parse failure so the caller can fall
    /// back to legacy tabular parsing.
    ///
    /// Exposed as `nonisolated static` so unit tests can verify the
    /// parser against fixture plist output without spinning up hdiutil
    /// or hopping onto the main actor.
    nonisolated static func parseMountPointFromHdiutilPlist(_ data: Data) -> String? {
        guard let plist = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any] else {
            return nil
        }
        guard let entities = plist["system-entities"] as? [[String: Any]] else {
            return nil
        }
        for entity in entities {
            if let mount = entity["mount-point"] as? String, !mount.isEmpty {
                return mount.trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
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
