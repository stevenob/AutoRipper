import Foundation

extension URL {
    /// True if `self` and `other` live on the same volume — i.e., a `rename(2)`
    /// between them would be a fast metadata-only operation (no data copy).
    ///
    /// Critical for the publish step: if the rip-scratch local SSD and the NAS
    /// library destination happen to be the same volume (or, in the legacy
    /// outputDir-on-NAS configuration, both source and dest live on the SMB
    /// share), `FileManager.moveItem` becomes an instant rename instead of a
    /// 6-GB read-write round-trip across the network.
    ///
    /// Fail-safe: returns `false` if either URL's volume identifier is
    /// unavailable. We never want to *assume* same-volume and accidentally
    /// take the fast path on a remote share that does not actually support
    /// cross-share rename.
    func sameVolume(as other: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.volumeIdentifierKey]
        // volumeIdentifier is typed as Optional<NSCopying & NSSecureCoding & NSObjectProtocol>
        // by Swift's Foundation overlay — it's always an NSObject in practice
        // (typically an NSNumber wrapping the dev_t), so isEqual gives us
        // straightforward identity comparison without needing AnyHashable.
        guard let lhs = try? self.resourceValues(forKeys: keys).volumeIdentifier,
              let rhs = try? other.resourceValues(forKeys: keys).volumeIdentifier,
              let l = lhs as? NSObject,
              let r = rhs as? NSObject
        else { return false }
        return l.isEqual(r)
    }
}
