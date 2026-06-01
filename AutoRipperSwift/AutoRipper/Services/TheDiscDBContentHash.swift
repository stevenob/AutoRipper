import Foundation
import CryptoKit

/// Computes TheDiscDB's disc `ContentHash` so AutoRipper can do an exact
/// lookup against the database.
///
/// Algorithm (ported from TheDiscDb/web `HashingExtensions.CalculateHash`):
/// an MD5 over the concatenation of each relevant file's **size**, encoded as
/// an 8-byte little-endian `Int64`, with files taken in directory order. The
/// digest is rendered as uppercase hex with no separators. Only file *sizes*
/// contribute to the hash — names, timestamps, and contents do not.
///
/// Relevant files:
///   * Blu-ray / UHD: `BDMV/STREAM/*.m2ts`
///   * DVD:           every file in `VIDEO_TS/`
///
/// IMPORTANT — best effort. The exact *file ordering* TheDiscDB uses comes from
/// the contributor's browser File System Access API enumeration, which we
/// approximate here with a case-insensitive filename sort. That ordering has
/// **not** yet been validated against a real disc with a known non-null
/// TheDiscDB hash. Therefore `contentHash(forVolumeAt:)` must be treated as an
/// optimization only: a miss means "no exact match, fall back to TMDb +
/// duration matching" — never an error. The pure `contentHash(fileSizes:)`
/// core is fully deterministic and unit-tested.
enum TheDiscDBContentHash {

    /// Pure hash of an ordered list of file sizes — the unit-testable core.
    /// Deterministic and disc-independent.
    static func contentHash(fileSizes: [Int64]) -> String {
        var md5 = Insecure.MD5()
        for size in fileSizes {
            var littleEndian = size.littleEndian
            withUnsafeBytes(of: &littleEndian) { md5.update(bufferPointer: $0) }
        }
        return md5.finalize().map { String(format: "%02X", $0) }.joined()
    }

    /// Best-effort compute of a mounted disc's content hash. Returns `nil` when
    /// the expected disc structure is absent or unreadable. Heavily logged so a
    /// silent never-match is diagnosable from the log.
    static func contentHash(forVolumeAt volume: URL) -> String? {
        let fm = FileManager.default

        // Blu-ray / UHD: BDMV/STREAM/*.m2ts
        let stream = volume.appendingPathComponent("BDMV/STREAM", isDirectory: true)
        if let sizes = orderedFileSizes(in: stream, fm: fm,
                                        matching: { $0.lowercased().hasSuffix(".m2ts") }),
           !sizes.isEmpty {
            let hash = contentHash(fileSizes: sizes)
            FileLogger.shared.info("thediscdb",
                "contentHash: BDMV/STREAM \(sizes.count) m2ts files → \(hash)")
            return hash
        }

        // DVD: every file in VIDEO_TS/
        let videoTs = volume.appendingPathComponent("VIDEO_TS", isDirectory: true)
        if let sizes = orderedFileSizes(in: videoTs, fm: fm, matching: { _ in true }),
           !sizes.isEmpty {
            let hash = contentHash(fileSizes: sizes)
            FileLogger.shared.info("thediscdb",
                "contentHash: VIDEO_TS \(sizes.count) files → \(hash)")
            return hash
        }

        FileLogger.shared.warn("thediscdb",
            "contentHash: no readable BDMV/STREAM or VIDEO_TS under \(volume.path)")
        return nil
    }

    /// Regular-file sizes in `dir`, filtered by `matching`, ordered by
    /// case-insensitive filename. `nil` if the directory can't be read.
    private static func orderedFileSizes(in dir: URL, fm: FileManager,
                                         matching: (String) -> Bool) -> [Int64]? {
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let files = entries
            .filter { matching($0.lastPathComponent) }
            .sorted { $0.lastPathComponent.lowercased() < $1.lastPathComponent.lowercased() }

        var sizes: [Int64] = []
        for file in files {
            let rv = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard rv?.isRegularFile == true, let size = rv?.fileSize else { continue }
            sizes.append(Int64(size))
        }
        return sizes
    }
}
