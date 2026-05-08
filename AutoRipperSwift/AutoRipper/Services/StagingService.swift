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
}
