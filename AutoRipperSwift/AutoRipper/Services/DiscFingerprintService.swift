import Foundation
import CryptoKit

/// Produces a stable disc fingerprint from a `DiscInfo`. Same physical disc
/// inserted twice (or by two different drives) yields the same fingerprint;
/// different discs yield different fingerprints.
///
/// The fingerprint deliberately ignores volatile fields like the chosen
/// MakeMKV preset, scan timestamp, and any TMDb-derived `mediaTitle` —
/// only the structural-on-disc properties matter.
///
/// Schema (one line per title, `\n` separated, then SHA-256):
///     name=<discName>
///     type=<dvd|bluray>
///     <titleId>|<durationSeconds>|<sizeBytes>
///     <titleId>|<durationSeconds>|<sizeBytes>
///     ...
///
/// Title rows are sorted by titleId so input order doesn't change the hash.
enum DiscFingerprintService {

    /// Compute the SHA-256 hex digest of the canonical fingerprint string
    /// for `info`. Pure; does not touch the filesystem.
    static func fingerprint(_ info: DiscInfo) -> String {
        let canonical = canonicalString(info)
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Visible-for-tests: the canonical string we hash. Lets unit tests
    /// assert the schema didn't change accidentally.
    static func canonicalString(_ info: DiscInfo) -> String {
        var lines: [String] = [
            "name=\(info.name)",
            "type=\(info.type)",
        ]
        let sortedTitles = info.titles.sorted { $0.id < $1.id }
        for t in sortedTitles {
            lines.append("\(t.id)|\(t.durationSeconds)|\(t.sizeBytes)")
        }
        return lines.joined(separator: "\n")
    }
}
