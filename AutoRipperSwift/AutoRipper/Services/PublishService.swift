import Foundation
import os

private let log = Logger(subsystem: "com.autoripper.app", category: "publish")

enum PublishError: Error, LocalizedError {
    case sourceMissing(String)
    case destinationUnreachable(String)
    case copyFailed(String)
    case verificationFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .sourceMissing(let p): return "Publish source missing: \(p)"
        case .destinationUnreachable(let p): return "Publish destination not reachable: \(p)"
        case .copyFailed(let m): return "Publish copy failed: \(m)"
        case .verificationFailed(let m): return "Publish verification failed: \(m)"
        case .cancelled: return "Publish cancelled"
        }
    }
}

/// Hands a finished, locally-organized job's files off to the NAS library.
/// Designed to be **safe alongside existing siblings** — does NOT replace
/// whole destination folders, which would silently destroy other movie
/// editions or other TV episodes/seasons that share a parent folder.
///
/// For a movie at `<scratch>/Blade Runner (1982)/Blade Runner (1982).mkv`
/// publishing into `/Volumes/NAS/Movies/`, the result is
/// `/Volumes/NAS/Movies/Blade Runner (1982)/Blade Runner (1982).mkv` plus
/// any artwork / NFO siblings, with **any other existing files in
/// `/Volumes/NAS/Movies/Blade Runner (1982)/` left untouched** (e.g. an
/// existing Director's Cut from a previous publish).
///
/// On same-volume hand-offs (e.g. user has both scratch and library on the
/// NAS) the publish is a single `FileManager.moveItem` — server-side rename,
/// instant. Cross-volume hand-offs use `StagingService` for chunked, verified,
/// crash-safe copy that **preserves the local source** until the swap
/// succeeds.
actor PublishService {
    private let staging: StagingService

    init(staging: StagingService = StagingService()) {
        self.staging = staging
    }

    /// Publishes the directory tree rooted at `localDir` into `libraryRoot`.
    /// By default, the directory's name (e.g. "Blade Runner (1982)") becomes
    /// a child folder of `libraryRoot`; files inside are placed into that
    /// child folder, preserving any existing siblings there.
    ///
    /// - Parameters:
    ///   - localDir: organized + scraped local working directory.
    ///   - libraryRoot: NAS library root (e.g. `/Volumes/ServerShare/Movies`).
    ///   - destFolderName: optional override for the destination folder
    ///     name on the NAS. When non-nil, the published files land in
    ///     `libraryRoot/<destFolderName>/...` instead of
    ///     `libraryRoot/<localDir.lastPathComponent>/...`. This lets
    ///     callers use a per-job-unique scratch folder name locally
    ///     (e.g. with a job-id suffix to avoid sibling-job collisions in
    ///     the organize step) while keeping the final NAS layout clean.
    ///     Default `nil` preserves legacy behavior.
    ///   - progress: byte-level progress callback for UI. Fires ~once per
    ///     chunk during file copies.
    ///   - phaseUpdate: notified when the publish moves between sub-phases
    ///     (`.copying` -> `.verifying` -> `.swapping` -> `.done`). Used to
    ///     persist `Job.publishPhase` for crash-recovery on relaunch.
    /// - Returns: the final library directory URL on success.
    @discardableResult
    func publish(
        localDir: URL,
        libraryRoot: URL,
        destFolderName: String? = nil,
        progress: ((Int64, Int64) -> Void)? = nil,
        phaseUpdate: ((PublishPhase) -> Void)? = nil
    ) async throws -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: localDir.path) else {
            throw PublishError.sourceMissing(localDir.path)
        }
        try fm.createDirectory(at: libraryRoot, withIntermediateDirectories: true)

        // v3.11.8: allow caller to override the destination folder name so
        // the local work dir can carry a job-uniqueness suffix without
        // polluting the NAS layout.
        let folderName = destFolderName ?? localDir.lastPathComponent
        let destDir = libraryRoot.appendingPathComponent(folderName)
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)

        log.info("publish: \(localDir.path, privacy: .public) -> \(destDir.path, privacy: .public)")

        // Same-volume fast path: per-file rename. Even though both source and
        // dest are on the same FS, we still copy file-by-file (rather than
        // moving the whole folder) so existing siblings at destDir are
        // preserved. rename(2) within the same FS is metadata-only, so this
        // is still effectively instant.
        let sameVolume = localDir.sameVolume(as: libraryRoot)
        if sameVolume {
            phaseUpdate?(.swapping)
            try await renamePerFile(from: localDir, to: destDir, progress: progress)
            phaseUpdate?(.done)
            log.info("publish (same-volume rename) done: \(destDir.path, privacy: .public)")
            return destDir
        }

        // Cross-volume: chunked + verified copy that keeps the local source
        // intact until everything's verified at dest. We do this on a per-file
        // basis (not as one big folder copy) so existing siblings at destDir
        // are not nuked by the dir-level swap.
        phaseUpdate?(.copying)
        try await copyPerFileKeepingSource(
            from: localDir,
            to: destDir,
            progress: progress
        )
        phaseUpdate?(.verifying)
        try verifyAllFilesPresent(localDir: localDir, destDir: destDir)
        phaseUpdate?(.done)
        log.info("publish (cross-volume copy) done: \(destDir.path, privacy: .public)")
        return destDir
    }

    /// For same-volume publish: walk source, for each file rename it into
    /// the matching slot under destDir, creating intermediate dirs as needed.
    /// Existing destination files with the same name are replaced (it's a
    /// re-publish of the same content); other siblings at destDir are
    /// untouched.
    private func renamePerFile(
        from sourceDir: URL,
        to destDir: URL,
        progress: ((Int64, Int64) -> Void)?
    ) async throws {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: sourceDir,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw PublishError.copyFailed("could not enumerate \(sourceDir.path)")
        }
        let resolvedSourcePrefix = sourceDir.resolvingSymlinksInPath().path + "/"
        var entries: [(URL, String, Int64)] = []
        var total: Int64 = 0
        while let url = enumerator.nextObject() as? URL {
            let v = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard v.isRegularFile == true else { continue }
            let resolved = url.resolvingSymlinksInPath().path
            let rel = resolved.hasPrefix(resolvedSourcePrefix)
                ? String(resolved.dropFirst(resolvedSourcePrefix.count))
                : url.lastPathComponent
            let size = Int64(v.fileSize ?? 0)
            entries.append((url, rel, size))
            total += size
        }

        var done: Int64 = 0
        for (src, rel, size) in entries {
            if Task.isCancelled { throw PublishError.cancelled }
            var dest = destDir
            for component in rel.split(separator: "/") {
                dest = dest.appendingPathComponent(String(component))
            }
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                if fm.fileExists(atPath: dest.path) {
                    try fm.removeItem(at: dest)  // same-name replace; siblings safe
                }
                try fm.moveItem(at: src, to: dest)
            } catch {
                throw PublishError.copyFailed("rename \(rel): \(error.localizedDescription)")
            }
            done += size
            progress?(done, total)
        }
        // v3.11.8: source dir may still hold this caller's siblings (the
        // per-file rename above moved every regular file to dest, but
        // hidden dotfiles like .DS_Store remain). Use the safer helper
        // — drops the dir only if no foreign files remain. With v3.11.6
        // per-disc-unique scratch, foreign files shouldn't occur in
        // practice, but defense in depth costs nothing.
        SafeFSCleanup.removeDirIfEmpty(sourceDir)
    }

    /// Cross-volume: per-file chunked copy that preserves source files until
    /// each verifies at dest. Uses the StagingService keep-source variant
    /// per file. Source remains intact on any failure for retry-from-disk.
    private func copyPerFileKeepingSource(
        from sourceDir: URL,
        to destDir: URL,
        progress: ((Int64, Int64) -> Void)?
    ) async throws {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: sourceDir,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw PublishError.copyFailed("could not enumerate \(sourceDir.path)")
        }
        let resolvedSourcePrefix = sourceDir.resolvingSymlinksInPath().path + "/"
        var entries: [(URL, String, Int64)] = []
        var total: Int64 = 0
        while let url = enumerator.nextObject() as? URL {
            let v = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard v.isRegularFile == true else { continue }
            let resolved = url.resolvingSymlinksInPath().path
            let rel = resolved.hasPrefix(resolvedSourcePrefix)
                ? String(resolved.dropFirst(resolvedSourcePrefix.count))
                : url.lastPathComponent
            let size = Int64(v.fileSize ?? 0)
            entries.append((url, rel, size))
            total += size
        }

        // Sub-folder copy via StagingService keep-source — single file at a
        // time so the folder-level swap doesn't affect siblings.
        var done: Int64 = 0
        for (src, rel, size) in entries {
            if Task.isCancelled { throw PublishError.cancelled }
            var dest = destDir
            for component in rel.split(separator: "/") {
                dest = dest.appendingPathComponent(String(component))
            }
            // Use a temp folder pattern: stage to <dest>.partial, then rename.
            // We can't use StagingService.copyDirectoryAndVerifyKeepingSource
            // here directly because that method's swap targets a folder, not
            // a single file — and we want each file to swap independently
            // so existing destination siblings are untouched throughout.
            try await copyAndVerifySingleFile(from: src, to: dest)
            done += size
            progress?(done, total)
        }
    }

    /// Per-file chunked copy + size-verify + atomic rename, leaving source intact.
    /// The keep-source single-file primitive used by the cross-volume publish.
    private func copyAndVerifySingleFile(from source: URL, to destination: URL) async throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else {
            throw PublishError.sourceMissing(source.path)
        }
        let sourceAttrs = try fm.attributesOfItem(atPath: source.path)
        guard let sourceSize = sourceAttrs[.size] as? Int64 else {
            throw PublishError.copyFailed("could not read source size: \(source.path)")
        }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        let partial = destination.appendingPathExtension("partial")
        if fm.fileExists(atPath: partial.path) { try? fm.removeItem(at: partial) }
        guard fm.createFile(atPath: partial.path, contents: nil) else {
            throw PublishError.copyFailed("could not create \(partial.path)")
        }

        let inHandle: FileHandle
        let outHandle: FileHandle
        do { inHandle = try FileHandle(forReadingFrom: source) }
        catch {
            try? fm.removeItem(at: partial)
            throw PublishError.copyFailed("open source: \(error.localizedDescription)")
        }
        do { outHandle = try FileHandle(forWritingTo: partial) }
        catch {
            try? inHandle.close()
            try? fm.removeItem(at: partial)
            throw PublishError.copyFailed("open dest: \(error.localizedDescription)")
        }
        defer {
            try? inHandle.close()
            try? outHandle.close()
        }

        let chunkSize = 8 * 1024 * 1024
        while true {
            if Task.isCancelled {
                try? fm.removeItem(at: partial)
                throw PublishError.cancelled
            }
            let chunk = inHandle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            do { try outHandle.write(contentsOf: chunk) }
            catch {
                try? fm.removeItem(at: partial)
                throw PublishError.copyFailed("write: \(error.localizedDescription)")
            }
        }
        try? outHandle.synchronize()
        try? outHandle.close()
        try? inHandle.close()

        guard let partialAttrs = try? fm.attributesOfItem(atPath: partial.path),
              let partialSize = partialAttrs[.size] as? Int64,
              partialSize == sourceSize else {
            try? fm.removeItem(at: partial)
            throw PublishError.verificationFailed("size mismatch: \(source.lastPathComponent)")
        }
        do {
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: partial)
            } else {
                try fm.moveItem(at: partial, to: destination)
            }
        } catch {
            try? fm.removeItem(at: partial)
            throw PublishError.copyFailed("rename: \(error.localizedDescription)")
        }
    }

    /// Verify every regular file under sourceDir has a same-sized counterpart
    /// at the equivalent path under destDir. Throws on any mismatch — the
    /// caller will leave the local source intact and surface the failure.
    private func verifyAllFilesPresent(localDir: URL, destDir: URL) throws {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: localDir,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let resolvedSourcePrefix = localDir.resolvingSymlinksInPath().path + "/"
        while let url = enumerator.nextObject() as? URL {
            let v = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard v.isRegularFile == true else { continue }
            let resolved = url.resolvingSymlinksInPath().path
            let rel = resolved.hasPrefix(resolvedSourcePrefix)
                ? String(resolved.dropFirst(resolvedSourcePrefix.count))
                : url.lastPathComponent
            var dest = destDir
            for component in rel.split(separator: "/") {
                dest = dest.appendingPathComponent(String(component))
            }
            guard fm.fileExists(atPath: dest.path) else {
                throw PublishError.verificationFailed("missing at dest: \(rel)")
            }
            let destAttrs = try fm.attributesOfItem(atPath: dest.path)
            let srcSize = Int64(v.fileSize ?? 0)
            let destSize = destAttrs[.size] as? Int64 ?? -1
            if srcSize != destSize {
                throw PublishError.verificationFailed("size mismatch \(rel): src=\(srcSize) dst=\(destSize)")
            }
        }
    }
}
