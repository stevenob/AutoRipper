import Foundation

/// v4.0.14: payload describing a finished per-title rip, handed from
/// `RipViewModel.onRipComplete` to `QueueViewModel.addJob(_:)`.
///
/// Replaces the previous 17-parameter callback closure — fragile to
/// thread across the upcoming `RipOrchestrator` extraction and trivially
/// easy to mis-order at the call site. The single struct gives us field
/// names at every callsite.
///
/// Mirrors the shape of `Job.init` minus the `status`/`progress`/etc.
/// internal state that the queue manages itself.
struct CompletedRip {
    /// User-facing disc name (the TMDb match's `displayTitle` when
    /// matched, otherwise the raw MakeMKV volume label).
    let discName: String
    /// Path to the freshly-ripped MKV in scratch/output.
    let rippedFile: URL
    /// Wall-clock seconds spent inside MakeMKV's `ripTitle` for this title.
    let ripElapsed: TimeInterval
    /// MakeMKV-reported source resolution string (e.g. `"1920x1080"`).
    /// Empty when unknown — the encode preset picker falls back to a
    /// resolution-agnostic default.
    let resolution: String
    /// JobCard tracks the rip → encode → publish phases for Discord +
    /// History. RipOrchestrator builds and starts it; QueueViewModel
    /// receives ownership at addJob time and drives the remaining phases.
    let card: JobCard
    /// TMDb match for the disc, threaded through so QueueViewModel
    /// doesn't have to re-query. May be nil when the user used a
    /// per-title name override (treat as fresh disc — search at queue time).
    let mediaResult: MediaResult?
    /// Title-level intent (movie / episode / edition / extra).
    let intent: JobIntent
    /// Edition label (e.g. "Director's Cut"). Only set when intent == .edition.
    let editionLabel: String?
    /// TV-only fields populated when intent == .episode. Driven by
    /// the TVEpisodePicker UI / autoAssignTvEpisodeNumbers / TMDb
    /// runtime matcher.
    let seasonNumber: Int?
    let episodeNumber: Int?
    let episodeTitle: String?
    /// Disc fingerprint so the queue's publish step can record this
    /// rip in RippedDiscRegistry (the v3.7.1 "already ripped" guard).
    let discFingerprint: String?
    /// MakeMKV-side error counts captured during this title's rip. Drive
    /// Health uses these for aggregate verdicts; History shows them as pills.
    let ripReadErrors: Int
    let ripCorruptionEvents: Int
    /// Logical block offsets of read errors. Sparse when ripReadErrors == 0.
    let readErrorOffsets: [Int64]
    /// HandBrake ordinal lists derived from the user's per-title track
    /// selection. nil means "use HandBrake defaults" (all-audio / all-subtitles).
    let audioTrackOrdinals: [Int]?
    let subtitleTrackOrdinals: [Int]?
}
