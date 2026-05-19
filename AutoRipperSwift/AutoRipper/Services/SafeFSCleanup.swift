import Foundation

/// v4.0.12: process-wide registry of directories that are currently
/// being written to by an active MakeMKV rip. Read by `SafeFSCleanup`
/// so a per-title encode → publish → cleanup pass can't delete the
/// directory while a sibling rip from the same session is still
/// in-flight.
///
/// Background: on a TV-season disc (e.g. Bluey, 27 episodes), each
/// title rip writes into the same `<outputDir>/<show>` directory,
/// and the encode→organize→publish pipeline for title N runs in
/// parallel with the rip of title N+1. Without this guard, title N's
/// cleanup deleted the empty source dir between MakeMKV's
/// `createDirectory` for title N+1 and its first write — the rip
/// then failed with POSIX "No such file or directory".
///
/// Pure Set<String> behind an NSLock. No actor isolation so background
/// tasks can register/unregister and main actor callers (RipViewModel)
/// can too without await dances.
enum ActiveRipDirectories {
    nonisolated(unsafe) private static var dirs: Set<String> = []
    nonisolated(unsafe) private static let lock = NSLock()

    /// Register a directory as actively being ripped into. Call at
    /// the start of a multi-title rip; pair with `deregister(_:)` at
    /// the end (success OR failure paths both).
    static func register(_ path: String) {
        let canon = (path as NSString).standardizingPath
        lock.lock(); defer { lock.unlock() }
        dirs.insert(canon)
    }

    static func deregister(_ path: String) {
        let canon = (path as NSString).standardizingPath
        lock.lock(); defer { lock.unlock() }
        dirs.remove(canon)
    }

    /// True when `path` (or any ancestor) is currently being ripped
    /// into. Cleanup helpers MUST skip removal when this is true.
    static func isActive(_ path: String) -> Bool {
        let canon = (path as NSString).standardizingPath
        lock.lock(); defer { lock.unlock() }
        if dirs.contains(canon) { return true }
        // Also catch the case where `path` is a descendant of an
        // active rip dir (defense in depth — present implementation
        // always registers the exact rip dir).
        for active in dirs {
            if canon.hasPrefix(active + "/") { return true }
        }
        return false
    }

    /// Test-only: drain the registry. Production code should always
    /// pair register/deregister so this stays empty.
    static func _resetForTests() {
        lock.lock(); defer { lock.unlock() }
        dirs.removeAll()
    }
}

/// v3.11.8: shared file-system cleanup helpers with safety guarantees.
///
/// Background: the v3.11.5/v3.11.6 Mortal Kombat data-loss bug was caused
/// by blanket `FileManager.removeItem(at: parentDir)` calls in multiple
/// services after a per-file move/copy operation. When two queued jobs
/// accidentally shared a parent dir, the first job's cleanup wiped the
/// second job's not-yet-encoded source. v3.11.6 introduced an ownership-
/// aware helper in QueueViewModel; v3.11.8 promotes it to a shared
/// utility so PublishService, StagingService, and any future cleanup
/// site can use the same safe primitives.
///
/// All functions here are pure (no global state), synchronous (no
/// concurrency hazards), and best-effort (silently swallow errors —
/// callers typically log themselves). Free functions / namespaced enum
/// rather than a class so non-MainActor callers (actors, background
/// tasks) can use them without isolation gymnastics.
enum SafeFSCleanup {

    /// Removes only the files this caller explicitly owns from `dir`,
    /// then drops `dir` itself **only if** no foreign files remain
    /// (hidden dotfiles like `.DS_Store` don't count as foreign — they're
    /// OS noise, not user data).
    ///
    /// Files in `ownedFiles` whose parent is **not** `dir` are skipped
    /// entirely — defense in depth so a caller passing a stale URL from
    /// a different directory can't reach across and cause damage.
    /// Symlinks are resolved before the ownership comparison to avoid
    /// aliased-path false-negatives on macOS.
    ///
    /// - Parameters:
    ///   - dir: parent directory to consider for removal.
    ///   - ownedFiles: file URLs the caller knows it created/owns.
    static func cleanupOwnedFilesAndRemoveDirIfEmpty(dir: URL, ownedFiles: [URL]) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return }
        let canonicalDir = dir.resolvingSymlinksInPath().standardizedFileURL
        for f in ownedFiles {
            let canonicalParent = f.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
            guard canonicalParent == canonicalDir else { continue }
            if fm.fileExists(atPath: f.path) {
                try? fm.removeItem(at: f)
            }
        }
        removeDirIfEmpty(dir)
    }

    /// v4.0.1: extended cleanup variant that also scrubs known scrape
    /// artifact extensions (jpg/png/nfo) before the empty-dir check.
    ///
    /// Background: after a successful publish, the local sourceDir
    /// contains the organized .mkv (which we remove via `ownedFiles`)
    /// PLUS the artwork + NFO files placed there by `ArtworkService`.
    /// The publish step copied those artwork files to NAS too, so the
    /// local copies are redundant — but `cleanupOwnedFilesAndRemoveDirIfEmpty`
    /// only knows about the explicit `ownedFiles` list, leaving the
    /// artwork stranded. Result: scratch dir slowly fills up with
    /// `Movie Title (Year)/fanart.jpg + movie.nfo + poster.jpg`
    /// folders that the user has to clean manually.
    ///
    /// The known-extension list is narrow on purpose. We do NOT scrub
    /// .mkv (those are user data — if `ownedFiles` didn't cover them,
    /// the user owns the mistake too), and we do NOT scrub everything
    /// non-mkv (a stray text file the user dropped in shouldn't get
    /// nuked).
    static func cleanupOwnedFilesAndScrubArtifacts(dir: URL, ownedFiles: [URL]) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return }
        let canonicalDir = dir.resolvingSymlinksInPath().standardizedFileURL
        // Step 1: remove explicit owned files.
        for f in ownedFiles {
            let canonicalParent = f.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
            guard canonicalParent == canonicalDir else { continue }
            if fm.fileExists(atPath: f.path) {
                try? fm.removeItem(at: f)
            }
        }
        // Step 2: scrub known scrape-artifact extensions. These are
        // always derived/duplicated content (the originals are now on
        // NAS via PublishService.publish), so removing them is safe.
        if let entries = try? fm.contentsOfDirectory(atPath: dir.path) {
            for name in entries {
                let lower = name.lowercased()
                let isArtifact = lower.hasSuffix(".jpg")
                    || lower.hasSuffix(".jpeg")
                    || lower.hasSuffix(".png")
                    || lower.hasSuffix(".nfo")
                if isArtifact {
                    let path = (dir.path as NSString).appendingPathComponent(name)
                    try? fm.removeItem(atPath: path)
                }
            }
        }
        // Step 3: drop the now-empty dir (or log foreign files remaining).
        removeDirIfEmpty(dir)
    }

    /// Removes `dir` **only if** it contains nothing but hidden dotfiles
    /// (or is already empty). No-op on missing dir. Use this when a
    /// caller has already moved/deleted its owned content out via other
    /// means and just wants to drop the now-empty parent without risking
    /// a sibling-wipeout if it turns out the parent still contains files.
    static func removeDirIfEmpty(_ dir: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return }
        // v4.0.12: never delete a directory that's still being
        // written to by an active rip. On TV-season discs the same
        // `<outputDir>/<show>` directory hosts every episode rip in
        // sequence; without this guard, title N's publish-cleanup
        // raced ahead of title N+1's MakeMKV write and the rip failed
        // with POSIX "No such file or directory".
        if ActiveRipDirectories.isActive(dir.path) {
            FileLogger.shared.info(
                "fs",
                "skip dir cleanup (active rip in progress): \(dir.path)"
            )
            return
        }
        let contents = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        let nonHidden = contents.filter { !$0.hasPrefix(".") }
        if nonHidden.isEmpty {
            try? fm.removeItem(at: dir)
        } else {
            FileLogger.shared.info(
                "fs",
                "skip dir cleanup (\(nonHidden.count) foreign file(s) remain): \(dir.path)"
            )
        }
    }
}
