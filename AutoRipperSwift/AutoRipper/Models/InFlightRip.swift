import Foundation

/// Persisted mid-pipeline state for a rip-in-flight, used for crash/exit recovery.
///
/// Replaces the legacy `inFlightRipPath: String?` (UserDefaults `inFlightRipPath`),
/// which was set to a *directory* but cleanup code treated it as a *file*. The
/// structured form lets us know:
///   * which phase was active when we exited (so cleanup picks the right files)
///   * which exact `ripFile` MakeMKV was writing
///   * which exact `stagingDest` we were copying to (and might have left
///     behind as a `.partial`)
///
/// JSON-encoded into the same UserDefaults suite as `AppConfig`.
struct InFlightRip: Codable, Equatable {
    enum Phase: String, Codable {
        /// MakeMKV is writing into `ripFile`. On recovery, delete `ripFile` (it's
        /// guaranteed incomplete) and then drop empty parent dirs.
        case ripping
        /// Rip is done; `StagingService` is copying `ripFile` -> `stagingDest`.
        /// On recovery, delete `stagingDest.partial` (and `stagingDest` if it
        /// exists but is smaller than the source — i.e., a never-completed
        /// rename). Leave `ripFile` in place — it's the authoritative copy.
        case staging
    }

    var phase: Phase
    var titleId: Int
    /// Absolute path of the file MakeMKV writes to / wrote to. Always set.
    var ripFile: String
    /// Absolute path of the destination during the staging copy. Only set when
    /// `phase == .staging`.
    var stagingDest: String?
}
