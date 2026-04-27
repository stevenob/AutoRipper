import Foundation
import os

private let log = Logger(subsystem: "com.autoripper.app", category: "thumbs")

/// Extracts JPEG preview frames from a partial or completed encoded MKV.
///
/// Uses HandBrakeCLI's `--previews <count>:0` flag to pull up to N evenly-spaced
/// frames into a temp dir, then copies them into per-job storage. HandBrakeCLI
/// is already a hard dependency of AutoRipper so this avoids adding an ffmpeg
/// requirement.
///
/// Storage: `~/Library/Application Support/AutoRipper/thumbs/<jobId>/00.jpg ...`
final class ThumbnailExtractor: @unchecked Sendable {
    static let shared = ThumbnailExtractor()

    private let baseDir: URL
    private let queue = DispatchQueue(label: "com.autoripper.app.thumbs", qos: .utility)

    private init() {
        baseDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AutoRipper/thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
    }

    /// Directory holding the JPEGs for a job (created on demand).
    func directory(for jobId: String) -> URL {
        baseDir.appendingPathComponent(jobId, isDirectory: true)
    }

    /// All currently-available thumbnail file URLs for a job, sorted by index.
    func thumbnails(for jobId: String) -> [URL] {
        let dir = directory(for: jobId)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names
            .filter { $0.hasSuffix(".jpg") }
            .sorted()
            .map { dir.appendingPathComponent($0) }
    }

    /// Delete a job's thumbnail directory (called when the job is pruned/removed).
    func remove(jobId: String) {
        let dir = directory(for: jobId)
        try? FileManager.default.removeItem(at: dir)
    }

    /// Extract `count` evenly-spaced previews from `inputPath` (the partial or
    /// completed encoded MKV) and store them as 00.jpg, 01.jpg, ... in the job's
    /// thumbnail dir. Skips silently on failure — preview thumbs are best-effort.
    ///
    /// `handbrakePath` is the configured HandBrakeCLI binary.
    func extract(jobId: String, inputPath: String, count: Int = 6, handbrakePath: String) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                self.runExtract(jobId: jobId, inputPath: inputPath, count: count, handbrakePath: handbrakePath)
                cont.resume()
            }
        }
    }

    private func runExtract(jobId: String, inputPath: String, count: Int, handbrakePath: String) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: inputPath),
              fm.isExecutableFile(atPath: handbrakePath) else { return }

        // HandBrakeCLI writes preview JPEGs to /tmp/<basename>-N.jpg by default
        // when --previews is used. We pipe the output to a known temp dir.
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("autoripper-thumbs-\(jobId)-\(UUID().uuidString)")
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        // --previews COUNT:STORE writes COUNT evenly-spaced JPEGs to STORE; STORE=1
        // writes them next to the input. We cd into our temp dir to scope the writes.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: handbrakePath)
        proc.arguments = ["--input", inputPath, "--previews", "\(count):1", "--scan"]
        proc.currentDirectoryURL = tmp
        let nullPipe = Pipe()
        proc.standardOutput = nullPipe
        proc.standardError = nullPipe

        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            log.warning("preview extract failed to launch: \(error.localizedDescription)")
            return
        }

        // Find generated *.jpg in the temp dir, copy + rename into our store.
        guard let names = try? fm.contentsOfDirectory(atPath: tmp.path) else { return }
        let jpgs = names.filter { $0.hasSuffix(".jpg") }.sorted()
        guard !jpgs.isEmpty else {
            log.debug("no previews produced for \(jobId)")
            return
        }

        let dest = directory(for: jobId)
        try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
        // Clear stale thumbs from previous extracts so the order is consistent.
        if let existing = try? fm.contentsOfDirectory(atPath: dest.path) {
            for n in existing where n.hasSuffix(".jpg") {
                try? fm.removeItem(at: dest.appendingPathComponent(n))
            }
        }
        for (i, name) in jpgs.enumerated() {
            let src = tmp.appendingPathComponent(name)
            let dst = dest.appendingPathComponent(String(format: "%02d.jpg", i))
            try? fm.copyItem(at: src, to: dst)
        }
        log.info("extracted \(jpgs.count) preview thumbs for job \(jobId, privacy: .public)")
    }
}
