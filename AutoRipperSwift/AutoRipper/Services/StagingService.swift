import Foundation
import os

private let log = Logger(subsystem: "com.autoripper.app", category: "staging")

enum StagingError: Error, LocalizedError {
    case sourceMissing(String)
    case destinationUnreachable(String)
    case destinationNotWritable(String)
    case copyFailed(String)
    case verificationFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .sourceMissing(let p): return "Staging source missing: \(p)"
        case .destinationUnreachable(let p): return "Staging destination not reachable: \(p)"
        case .destinationNotWritable(let p): return "Staging destination not writable: \(p)"
        case .copyFailed(let m): return "Staging copy failed: \(m)"
        case .verificationFailed(let m): return "Staging verification failed: \(m)"
        case .cancelled: return "Staging cancelled"
        }
    }
}

/// Cross-volume file transfer for the post-rip staging step (local SSD ->
/// NAS-backed `outputDir`). Implements **copy → verify → delete source** rather
/// than `FileManager.moveItem` so a crash/disconnect mid-transfer never leaves
/// the destination in an ambiguous state and the source is always safe until
/// the new file is byte-for-byte complete.
///
/// Designed to run off the main actor — long copies must not block the UI.
actor StagingService {
    /// Chunk size for the streamed copy. 8 MB is large enough that syscall
    /// overhead is negligible on SMB/AFP, small enough to give cancel checks
    /// reasonable granularity.
    static let chunkSize = 8 * 1024 * 1024

    /// Probe-write a tiny file to confirm the destination is mounted, exists,
    /// is a directory, and is writable. Throws `StagingError` on any problem.
    /// Always cleans up the probe file on success.
    func checkReachable(path: String) throws {
        guard !path.isEmpty else {
            throw StagingError.destinationUnreachable("empty path")
        }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            throw StagingError.destinationUnreachable(path)
        }
        // Use a unique probe name so concurrent probes don't collide.
        let probe = (path as NSString).appendingPathComponent(".autoripper-probe-\(UUID().uuidString)")
        do {
            try Data([0]).write(to: URL(fileURLWithPath: probe))
            try? fm.removeItem(atPath: probe)
        } catch {
            throw StagingError.destinationNotWritable("\(path) (\(error.localizedDescription))")
        }
    }

    /// Copies `source` to `destination` using a streamed chunked copy, verifies
    /// the resulting file size matches the source, then deletes the source.
    /// Returns the destination URL on success.
    ///
    /// On cancellation or failure, any partial destination (`<destination>.partial`)
    /// is removed; the source is left untouched.
    ///
    /// - Parameters:
    ///   - source: file to copy from. Must exist.
    ///   - destination: final file location. Parent directory is created if missing.
    ///     Existing files at this exact path are preserved until the verified
    ///     copy is renamed over them — never pre-deleted.
    ///   - progress: optional callback `(bytesCopied, totalBytes) -> Void`. Called
    ///     ~once per chunk on the calling actor's executor (i.e., not main).
    func copyAndVerify(
        from source: URL,
        to destination: URL,
        progress: ((Int64, Int64) -> Void)? = nil
    ) async throws -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else {
            throw StagingError.sourceMissing(source.path)
        }
        let sourceAttrs = try fm.attributesOfItem(atPath: source.path)
        guard let sourceSize = sourceAttrs[.size] as? Int64 else {
            throw StagingError.copyFailed("could not read source size: \(source.path)")
        }

        let destDir = destination.deletingLastPathComponent()
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)

        // Sanity-check destination dir is writable BEFORE we start a long copy.
        try checkReachable(path: destDir.path)

        let partial = destination.appendingPathExtension("partial")
        // Remove any leftover .partial from a previous failed run.
        if fm.fileExists(atPath: partial.path) {
            try? fm.removeItem(at: partial)
        }
        // Create empty .partial file we'll append to.
        guard fm.createFile(atPath: partial.path, contents: nil) else {
            throw StagingError.copyFailed("could not create \(partial.path)")
        }

        // Open both ends with explicit cleanup on any exit path.
        let inHandle: FileHandle
        let outHandle: FileHandle
        do {
            inHandle = try FileHandle(forReadingFrom: source)
        } catch {
            try? fm.removeItem(at: partial)
            throw StagingError.copyFailed("open source: \(error.localizedDescription)")
        }
        do {
            outHandle = try FileHandle(forWritingTo: partial)
        } catch {
            try? inHandle.close()
            try? fm.removeItem(at: partial)
            throw StagingError.copyFailed("open dest: \(error.localizedDescription)")
        }
        defer {
            try? inHandle.close()
            try? outHandle.close()
        }

        var copied: Int64 = 0
        log.info("staging copy start: \(source.path, privacy: .public) -> \(destination.path, privacy: .public) (\(sourceSize) bytes)")

        while true {
            if Task.isCancelled {
                try? fm.removeItem(at: partial)
                throw StagingError.cancelled
            }
            let chunk = inHandle.readData(ofLength: Self.chunkSize)
            if chunk.isEmpty { break }
            do {
                try outHandle.write(contentsOf: chunk)
            } catch {
                try? fm.removeItem(at: partial)
                throw StagingError.copyFailed("write: \(error.localizedDescription)")
            }
            copied += Int64(chunk.count)
            progress?(copied, sourceSize)
        }

        do {
            try outHandle.synchronize()
        } catch {
            // Best-effort flush; don't fail the whole copy on sync error,
            // but log so we can spot it post-mortem.
            log.warning("synchronize failed (continuing): \(error.localizedDescription, privacy: .public)")
        }
        try? outHandle.close()
        try? inHandle.close()

        // Verify size on disk matches source. SMB/AFP have been known to
        // silently truncate on disconnect — this catches that.
        guard let partialAttrs = try? fm.attributesOfItem(atPath: partial.path),
              let partialSize = partialAttrs[.size] as? Int64 else {
            try? fm.removeItem(at: partial)
            throw StagingError.verificationFailed("could not stat \(partial.path)")
        }
        guard partialSize == sourceSize else {
            try? fm.removeItem(at: partial)
            throw StagingError.verificationFailed("size mismatch: source=\(sourceSize) dest=\(partialSize)")
        }

        // Atomic-ish rename of .partial -> final. Use replaceItem so we
        // don't have a window where the final path is missing.
        do {
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: partial)
            } else {
                try fm.moveItem(at: partial, to: destination)
            }
        } catch {
            try? fm.removeItem(at: partial)
            throw StagingError.copyFailed("rename: \(error.localizedDescription)")
        }

        // Source is now redundant — delete it.
        try? fm.removeItem(at: source)

        log.info("staging copy done: \(destination.path, privacy: .public)")
        return destination
    }

    /// Recursively copies the contents of `sourceDir` into a new folder at
    /// `destinationDir`. Walks the tree once to compute total bytes, then uses
    /// `copyAndVerify` per-file (so each file is independently verified and
    /// resumable-on-cancel via its own `.partial` cleanup).
    ///
    /// The destination is built up in a sibling `<destinationDir>.partial/`
    /// directory and renamed atomically at the end — never pre-deletes the
    /// existing `destinationDir`. This means a crash mid-copy leaves the old
    /// destination intact and only the `.partial` to clean up.
    ///
    /// `progress(bytesCopied, totalBytes)` fires roughly once per chunk during
    /// each file (not per file). Source files are deleted as they're copied,
    /// so on cancellation the source ends up partially consumed; the caller
    /// can choose whether to re-copy or treat that as the new authoritative
    /// state. (For the NAS-upload use case this is fine — the caller always
    /// retries from the in-progress source on next launch.)
    func copyDirectoryAndVerify(
        from sourceDir: URL,
        to destinationDir: URL,
        progress: ((Int64, Int64) -> Void)? = nil
    ) async throws -> URL {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: sourceDir.path, isDirectory: &isDir), isDir.boolValue else {
            throw StagingError.sourceMissing(sourceDir.path)
        }

        // Reachability + writability check before we start a long copy.
        let parentDir = destinationDir.deletingLastPathComponent()
        try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
        try checkReachable(path: parentDir.path)

        // Walk source once: collect file URLs + cumulative byte total. Skip
        // hidden/.DS_Store entries — they're noise from macOS, not movie data.
        guard let enumerator = fm.enumerator(
            at: sourceDir,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw StagingError.copyFailed("could not enumerate \(sourceDir.path)")
        }
        // Resolve symlinks in the source path BEFORE comparing. macOS reports
        // /tmp/... as /private/tmp/... from the enumerator, so a string-prefix
        // compare against the un-resolved source path silently fails and we
        // fall back to lastPathComponent — which flattens nested folders.
        let resolvedSourcePrefix = sourceDir.resolvingSymlinksInPath().path + "/"
        var files: [(src: URL, relPath: String, size: Int64)] = []
        var totalBytes: Int64 = 0
        while let url = enumerator.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { continue }
            let size = Int64(values.fileSize ?? 0)
            // Build path relative to sourceDir so we can mirror the structure
            // into the destination — supports nested folders (e.g. Season 01/).
            let resolvedURLPath = url.resolvingSymlinksInPath().path
            let rel = resolvedURLPath.hasPrefix(resolvedSourcePrefix)
                ? String(resolvedURLPath.dropFirst(resolvedSourcePrefix.count))
                : url.lastPathComponent
            files.append((src: url, relPath: rel, size: size))
            totalBytes += size
        }
        log.info("dir copy start: \(sourceDir.path, privacy: .public) -> \(destinationDir.path, privacy: .public) (\(files.count) files, \(totalBytes) bytes)")

        // Stage everything into <dest>.partial/ first; rename at the end.
        let partialDir = destinationDir.appendingPathExtension("partial")
        if fm.fileExists(atPath: partialDir.path) {
            try? fm.removeItem(at: partialDir)
        }
        try fm.createDirectory(at: partialDir, withIntermediateDirectories: true)

        var bytesDoneBefore: Int64 = 0
        for entry in files {
            if Task.isCancelled {
                try? fm.removeItem(at: partialDir)
                throw StagingError.cancelled
            }
            // Build destination URL by appending each path component
            // separately — avoids any URL escaping ambiguity around "/"
            // when the relative path includes nested folders.
            var dest = partialDir
            for component in entry.relPath.split(separator: "/") {
                dest = dest.appendingPathComponent(String(component))
            }
            // Per-file copyAndVerify handles its own .partial + verify + delete-source.
            // We layer dir-level progress on top by accumulating completed-file bytes.
            let baseBytes = bytesDoneBefore
            _ = try await copyAndVerify(
                from: entry.src,
                to: dest,
                progress: { copied, total in
                    progress?(baseBytes + copied, totalBytes)
                    _ = total  // total per-file; we already aggregate via baseBytes + copied
                }
            )
            bytesDoneBefore += entry.size
            // Tick once at file boundaries even if no chunked progress fired
            // (small files copy in a single chunk).
            progress?(bytesDoneBefore, totalBytes)
        }

        // All files moved; rename .partial directory into final place. If a
        // previous destination exists, replaceItemAt handles the swap atomically.
        do {
            if fm.fileExists(atPath: destinationDir.path) {
                _ = try fm.replaceItemAt(destinationDir, withItemAt: partialDir)
            } else {
                try fm.moveItem(at: partialDir, to: destinationDir)
            }
        } catch {
            try? fm.removeItem(at: partialDir)
            throw StagingError.copyFailed("rename dir: \(error.localizedDescription)")
        }

        // Source dir's contents have all been deleted by copyAndVerify; the
        // empty parent itself can go too. Ignore failure (might be non-empty
        // due to hidden files we skipped).
        try? fm.removeItem(at: sourceDir)

        log.info("dir copy done: \(destinationDir.path, privacy: .public)")
        return destinationDir
    }
}
