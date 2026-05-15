import Foundation

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

    /// Removes `dir` **only if** it contains nothing but hidden dotfiles
    /// (or is already empty). No-op on missing dir. Use this when a
    /// caller has already moved/deleted its owned content out via other
    /// means and just wants to drop the now-empty parent without risking
    /// a sibling-wipeout if it turns out the parent still contains files.
    static func removeDirIfEmpty(_ dir: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return }
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
